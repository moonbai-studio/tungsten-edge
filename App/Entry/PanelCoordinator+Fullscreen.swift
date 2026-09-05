import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · 全屏：监听、CG 同步探测、AX 异步探测、绿灯 / 空间切换的预测隐藏与回滚。
// 2026-09-05 从 PanelCoordinator.swift 按 extension 拆出，只搬不改。
struct FullscreenIntentTransaction {
    let generation: UInt64
    let pid: pid_t
    let focusedWindowID: CGWindowID
    let screenCGFrame: CGRect
}
struct FullscreenSpaceHold {
    let generation: UInt64
    let pid: pid_t?
    let screenCGFrame: CGRect?
}

extension PanelCoordinator {
    // MARK: - Fullscreen Monitor

    func setupFullscreenMonitor() {
        let nc = NSWorkspace.shared.notificationCenter
        // token 式观察者（全仓库统一写法；selector 式是 unowned-unsafe）。queue 传 nil = 在投递线程
        // 同步执行，这两条通知本就在主线程投递，所以时序与原 selector 路径逐字一致；assumeIsolated 只是
        // 把这一事实告诉编译器，不额外加一跳（全屏预测隐藏对这一跳敏感）。
        workspaceObserverTokens.append(nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        })
        workspaceObserverTokens.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleAppActivated(note) }
        })
        lastActiveApplicationPID = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?.processIdentifier
        fullscreenReconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fullscreenReconcileIfNeeded() }
        }
        fullscreenReconcileTimer?.tolerance = 0.5
    }

    /// 编排层接通 / 断开全屏意图路由。断开时取消在飞的预测（设置关掉、权限挂起、拆单元）。
    func setFullscreenIntentRouting(enabled: Bool) {
        fullscreenIntentRoutingEnabled = enabled && !isSuspendedForPermissionLoss
        guard !fullscreenIntentRoutingEnabled else { return }
        if let transaction = fullscreenIntentTransaction {
            cancelFullscreenIntent(generation: transaction.generation, reason: "disabled")
        }
        if let spaceGeneration = fullscreenSpaceIntentGeneration {
            cancelFullscreenSpaceArrowIntent(generation: spaceGeneration, reason: "disabled")
        }
    }

    private func handleSpaceChange() {
        let spaceHoldGeneration = beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.postSpaceConfirmationDelay
        )
        // Sync CG check: fires before the panel has a chance to appear, no AX = no main-thread risk
        let cgFullscreen = checkFullscreenViaCGSync()
        applyFullscreenVisibility(
            cgFullscreen,
            source: "space-cg",
            expectedIntentGeneration: fullscreenIntentTransaction?.generation,
            pid: lastActiveApplicationPID,
            screenCGFrame: currentPanelScreenCGFrame(),
            expectedSpaceHoldGeneration: spaceHoldGeneration
        )
        // Async AX secondary check: catches edge cases CG misses (e.g. games on a non-zero layer)
        if !cgFullscreen || fullscreenIntentTransaction == nil {
            triggerAsyncFullscreenCheck(
                expectedSpaceHoldGeneration: spaceHoldGeneration,
                source: "space-ax"
            )
        }
        // 兜底：显隐路径之外也可能丢成员资格（issue #19），换桌面是用户唯一会察觉的时刻。
        repairAllSpacesMembershipIfNeeded()
    }

    private func handleAppActivated(_ note: Notification) {
        // 用通知携带的"刚激活的 app"，不读滞后的 frontmostApplication（AGENTS 守则）
        let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        lastActiveApplicationPID = activated?.processIdentifier
        let spaceHoldGeneration = beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.activationFallbackDelay
        )
        cancelFullscreenIntentIfContextChanged(activePID: activated?.processIdentifier)
        triggerAsyncFullscreenCheck(
            pid: lastActiveApplicationPID,
            expectedSpaceHoldGeneration: spaceHoldGeneration,
            source: "app-activation-ax"
        )
    }

    // MARK: - Sync CG fullscreen probe (main thread only, no AX)

    private func checkFullscreenViaCGSync() -> Bool {
        guard let panel = dockPanel else { return false }
        let screen = panelCurrentScreen(panel: panel)
        let screenCGFrame = Self.toCGRect(screen)
        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let candidate = WindowLiftCGWindowProbe.frontmostLargeWindow(
            on: screenCGFrame,
            excludingPID: ourPID
        ) else { return false }

        let cgBounds = candidate.quartzFrame
        let t: CGFloat = 8
        return abs(cgBounds.width  - screenCGFrame.width)  < t
            && abs(cgBounds.height - screenCGFrame.height) < t
            && abs(cgBounds.minX   - screenCGFrame.minX)   < t
            && abs(cgBounds.minY   - screenCGFrame.minY)   < t
    }

    // MARK: - Async AX fullscreen probe (secondary / fallback)

    private func triggerAsyncFullscreenCheck(
        pid explicitPID: pid_t? = nil,
        expectedSpaceHoldGeneration explicitSpaceHoldGeneration: UInt64? = nil,
        isFinalSpaceHoldWindowedConfirmation: Bool = false,
        isFinalSpaceIntentVerdict: Bool = false,
        source: String = "ax"
    ) {
        guard let panel = dockPanel else { return }
        // Convert to CG coords on main thread; AX kAXPositionAttribute also uses CG (top-left origin)
        let screenCGFrame = Self.toCGRect(panelCurrentScreen(panel: panel))
        let frontPID = explicitPID ?? lastActiveApplicationPID
        fullscreenProbeGeneration &+= 1
        let probeGeneration = fullscreenProbeGeneration
        let expectedIntentGeneration = fullscreenIntentTransaction?.generation
        let expectedSpaceHoldGeneration = explicitSpaceHoldGeneration ?? fullscreenSpaceHold?.generation
        Task.detached { [weak self] in
            let verdict = Self.detectFullscreenViaAX(pid: frontPID, screenCGFrame: screenCGFrame)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard probeGeneration == self.fullscreenProbeGeneration else {
                    return
                }
                // 三态 → 交给现有 `applyFullscreenVisibility` 的仍是一个布尔；保持 / 120ms 确认 /
                // 终审序列一概不变，变的只是「焦点窗口在别的屏上」时那个布尔从哪来：
                // 多屏下（③④，以及固定档的条不在焦点屏时）AX 对本屏说不出话，改问 SkyLight
                // 本屏的当前空间；读不到就是无信息——**不是 false**，否则 B 屏的条会冒到 B 的
                // 全屏空间上。终审调用必须收尾，无信息时退回本屏的 CG 同步探测。
                let fullscreen: Bool
                let resolvedSource: String
                switch verdict {
                case .fullscreen:
                    fullscreen = true
                    resolvedSource = source
                case .windowed:
                    fullscreen = false
                    resolvedSource = source
                case .notOnThisScreen:
                    guard Self.slsVerdictEnabled else {
                        fullscreen = false
                        resolvedSource = source
                        break
                    }
                    if let fromSpace = self.fullscreenVerdictFromSpaceLayout() {
                        fullscreen = fromSpace
                        resolvedSource = "\(source)-sls"
                    } else if isFinalSpaceHoldWindowedConfirmation || isFinalSpaceIntentVerdict {
                        fullscreen = self.checkFullscreenViaCGSync()
                        resolvedSource = "\(source)-cgfallback"
                    } else {
                        return
                    }
                }
                self.applyFullscreenVisibility(
                    fullscreen,
                    source: resolvedSource,
                    expectedIntentGeneration: expectedIntentGeneration,
                    pid: frontPID,
                    screenCGFrame: screenCGFrame,
                    expectedSpaceHoldGeneration: expectedSpaceHoldGeneration,
                    isFinalSpaceHoldWindowedConfirmation: isFinalSpaceHoldWindowedConfirmation,
                    isFinalSpaceIntentVerdict: isFinalSpaceIntentVerdict
                )
            }
        }
    }

    private func fullscreenReconcileIfNeeded() {
        guard visibilityState.hideReasons.contains(.fullscreen) else { return }
        triggerAsyncFullscreenCheck()
    }

    private func applyFullscreenVisibility(
        _ isFullscreen: Bool,
        source: String,
        expectedIntentGeneration: UInt64? = nil,
        pid: pid_t? = nil,
        screenCGFrame: CGRect? = nil,
        expectedSpaceHoldGeneration: UInt64? = nil,
        isFinalSpaceHoldWindowedConfirmation: Bool = false,
        isFinalSpaceIntentVerdict: Bool = false
    ) {
        // 方向键预测进行中：这一段由预测自己收口，不进下面的常规判定。
        if let spaceGeneration = fullscreenSpaceIntentGeneration {
            if isFullscreen {
                guard visibilityState.confirmFullscreenTransition(generation: spaceGeneration) else {
                    return
                }
                clearFullscreenSpaceArrowIntent()
                fullscreenIntentLogger.notice(
                    "space-confirmed source=\(source, privacy: .public) generation=\(spaceGeneration, privacy: .public)"
                )
                closeDrawer()
                closeFolderPopup()
                dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
                reconcilePanelVisibility()
                logFullscreenVerdict(true, source: source)
                return
            }
            // **不能采信空间切换那一刻的 false 判定**——2026-08-09 实测：桌面→全屏时
            // `space-cg` 在通知当下一律返回 false（过渡期假判定），照它撤销就是把刚藏好的
            // 任务条又放回全屏画面上，闪烁与「任务条停在全屏应用上面」都是这么来的。
            // `FullscreenSpaceHold` 当初等 120ms 再定，就是为了躲同一个坑，这里沿用它的节奏。
            guard isFinalSpaceIntentVerdict else {
                if source == "space-cg" {
                    scheduleFullscreenSpaceIntentVerdict(generation: spaceGeneration)
                }
                return
            }
            cancelFullscreenSpaceArrowIntent(generation: spaceGeneration, reason: "space-windowed")
        }
        switch FullscreenSpaceHoldDecision.disposition(
            isFullscreenVerdict: isFullscreen,
            expectedGeneration: expectedSpaceHoldGeneration,
            activeGeneration: fullscreenSpaceHold?.generation,
            isFinalWindowedConfirmation: isFinalSpaceHoldWindowedConfirmation
        ) {
        case .stale:
            return
        case .hold:
            return
        case .apply:
            if let hold = fullscreenSpaceHold {
                finishFullscreenSpaceHold(generation: hold.generation)
            }
        }
        if isFullscreen {
            if let transaction = fullscreenIntentTransaction {
                guard expectedIntentGeneration == transaction.generation,
                      pid == transaction.pid,
                      screenCGFrame == transaction.screenCGFrame,
                      isFullscreenIntentContextCurrent(transaction),
                      visibilityState.confirmFullscreenTransition(generation: transaction.generation) else {
                    return
                }
                finishFullscreenIntentTransaction()
                fullscreenIntentLogger.notice(
                    "confirmed source=\(source, privacy: .public) generation=\(transaction.generation, privacy: .public)"
                )
            } else {
                visibilityState.setFullscreen(true)
            }
            closeDrawer()
            closeFolderPopup()
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        } else {
            if fullscreenIntentTransaction != nil { return }
            visibilityState.setFullscreen(false)
        }
        reconcilePanelVisibility()
        logFullscreenVerdict(isFullscreen, source: source)
    }

    /// 任务条被藏/被放出来时的唯一取证行。**必须带 source 和隐藏理由**：用户报「任务条不见了」时，
    /// 只有这两项能区分是哪条判定动的手（issue #19 就是因为只打 active= 而无从下手）。
    private func logFullscreenVerdict(_ isFullscreen: Bool, source: String) {
        let reasons = visibilityState.hideReasons
        var parts: [String] = []
        if reasons.contains(.fullscreen) { parts.append("fullscreen") }
        if reasons.contains(.fullscreenTransitionPending) { parts.append("pending") }
        if reasons.contains(.edgeAutoHide) { parts.append("edge") }
        let reasonText = parts.isEmpty ? "none" : parts.joined(separator: "+")
        logger.info(
            "[fullscreen] active=\(isFullscreen, privacy: .public) source=\(source, privacy: .public) reasons=\(reasonText, privacy: .public) pid=\(self.lastActiveApplicationPID ?? -1, privacy: .public)"
        )
    }

    /// 编排层把 tap 的请求**广播**给每个单元；`screenCGFrame` 守卫让只有那块屏的单元动手
    ///（一块屏进全屏只藏那块屏的条）。
    func beginFullscreenIntent(_ request: FullscreenIntentRequest) {
        guard fullscreenIntentRoutingEnabled,
              fullscreenIntentTransaction == nil,
              request.screenCGFrame == currentPanelScreenCGFrame(),
              lastActiveApplicationPID == request.pid else {
            return
        }
        fullscreenIntentGeneration &+= 1
        let generation = fullscreenIntentGeneration
        fullscreenProbeGeneration &+= 1
        fullscreenIntentTransaction = FullscreenIntentTransaction(
            generation: generation,
            pid: request.pid,
            focusedWindowID: request.focusedWindowID,
            screenCGFrame: request.screenCGFrame
        )
        fullscreenIntentTimeoutTimer?.invalidate()
        visibilityState.beginFullscreenTransition(generation: generation)

        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil
        cancelEdgeWake()

        orderOutPanelsForFullscreenPrediction()
        fullscreenIntentLogger.notice(
            "pending source=\(request.source.rawValue, privacy: .public) generation=\(generation, privacy: .public) pid=\(request.pid, privacy: .public)"
        )

        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelFullscreenIntent(generation: generation, reason: "timeout")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenIntentTimeoutTimer = timer

        DispatchQueue.main.async { [weak self] in
            guard let self, self.fullscreenIntentTransaction?.generation == generation else { return }
            self.reconcilePanelVisibility()
        }
    }

    func cancelFullscreenIntent(generation: UInt64, reason: String) {
        guard fullscreenIntentTransaction?.generation == generation,
              visibilityState.timeoutFullscreenTransition(generation: generation) else {
            return
        }
        finishFullscreenIntentTransaction()
        fullscreenProbeGeneration &+= 1
        fullscreenIntentLogger.notice(
            "cancelled reason=\(reason, privacy: .public) generation=\(generation, privacy: .public)"
        )
        reconcilePanelVisibility()
    }

    private func finishFullscreenIntentTransaction() {
        fullscreenIntentTransaction = nil
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenIntentTimeoutTimer = nil
    }

    /// 预测命中后把每一块面板都移出 WindowServer。抽屉/弹窗必须走「立即」路径：输入已经
    /// 被 tap 扣住了，等不了淡出动画。
    private func orderOutPanelsForFullscreenPrediction() {
        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil
        cancelEdgeWake()

        dragController.cancelDrag()
        closeDrawerImmediately()
        closeFolderPopup(immediately: true)
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)

        panelsAreVisible = false
        // 预测路径也是「因全屏而藏」：之后的揭示同样走淡入。
        lastHideWasForFullscreen = true
        // 全屏预测的快速隐藏路径不经过 applyPanelVisibility，角标门控要单独通知。
        onLogicalVisibilityChanged?(false)
        orderDockSurfaceOut()
        capsulePanel?.orderOut(nil)
        drawerPanel?.orderOut(nil)
        folderPopupPanel?.orderOut(nil)
        windowTitleTooltipPanel?.orderOut(nil)
    }

    // MARK: - 切换到全屏空间的预测隐藏（Control+←/→ 与三指水平滑动）

    /// 从普通桌面切到全屏空间时，系统的空间切换通知晚于 WindowServer 抓取过渡快照，
    /// 所以事后再藏一定来不及（`Docs/05` 已实测）。这里在**输入投递之前**先藏：
    /// 方向键领先空间切换约 `550ms`，三指滑动约 `950–1130ms`，两者都已实测足够。
    ///
    /// 触发条件里「目标方向的相邻空间必须是全屏空间」那道闸在 `FullscreenIntentMonitor`
    /// 里就判掉了，到这里的都是真要进全屏空间的。
    func beginFullscreenSpaceIntent(direction: SpaceSwitchDirection) {
        guard fullscreenIntentRoutingEnabled,
              fullscreenIntentTransaction == nil,
              fullscreenSpaceIntentGeneration == nil,
              !isSuspendedForPermissionLoss,
              // 已经在全屏空间里（任务条本就藏着）→ 没有可闪的东西，别插手。
              !visibilityState.hideReasons.contains(.fullscreen) else {
            return
        }
        fullscreenIntentGeneration &+= 1
        let generation = fullscreenIntentGeneration
        fullscreenSpaceIntentGeneration = generation
        fullscreenProbeGeneration &+= 1
        visibilityState.beginFullscreenTransition(generation: generation)

        // 淡出再藏（owner 2026-08-30 的入场/退场动画诉求）。**只有这条空间路径可以淡**：
        // 方向键领先空间切换 ~550ms、三指滑 ~950–1130ms（实测），0.15s 淡出完成时离
        // WindowServer 抓过渡快照还有充足余量；绿键路径领先只有几十 ms，必须维持
        // 同步瞬时 orderOut。handoff 在淡出调度后立即返回，输入不被阻塞。
        // 逻辑态立刻置「已藏」：不然本函数末尾的异步 reconcile 会看到 shouldShow=false、
        // panelsAreVisible=true，直接走硬 orderOut 把淡出绕过去。视觉上的 orderOut 等淡出完。
        panelsAreVisible = false
        lastHideWasForFullscreen = true
        onLogicalVisibilityChanged?(false)
        let fadingPanels = [dockGlassBackgroundPanel, dockPanel, capsulePanel].compactMap { $0 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            for panel in fadingPanels { panel.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 淡出期间预测可能已被取消（超时/终审否决），那时条不该藏——恢复 alpha 即可。
                guard self.fullscreenSpaceIntentGeneration == generation else {
                    for panel in fadingPanels { panel.alphaValue = 1 }
                    return
                }
                self.orderOutPanelsForFullscreenPrediction()
                // 藏好后 alpha 归位：下一次显示（无论哪条路径）不带残值。
                for panel in fadingPanels { panel.alphaValue = 1 }
            }
        })
        fullscreenIntentLogger.notice(
            "space-pending generation=\(generation, privacy: .public) direction=\(direction.rawValue, privacy: .public)"
        )

        // 2s 而不是 1.2s：实测从输入到全屏确认要 1.05s，1.2s 只剩 130ms 余量，
        // 系统稍慢一次就会超时把任务条弹回全屏画面上——正是这个功能要消掉的瑕疵。
        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelFullscreenSpaceArrowIntent(generation: generation, reason: "timeout")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceIntentTimer = timer

        DispatchQueue.main.async { [weak self] in
            guard let self, self.fullscreenSpaceIntentGeneration == generation else { return }
            self.reconcilePanelVisibility()
        }
    }

    private func cancelFullscreenSpaceArrowIntent(generation: UInt64, reason: String) {
        guard fullscreenSpaceIntentGeneration == generation,
              visibilityState.timeoutFullscreenTransition(generation: generation) else {
            return
        }
        clearFullscreenSpaceArrowIntent()
        fullscreenProbeGeneration &+= 1
        fullscreenIntentLogger.notice(
            "space-cancelled reason=\(reason, privacy: .public) generation=\(generation, privacy: .public)"
        )
        reconcilePanelVisibility()
    }

    func clearFullscreenSpaceArrowIntent() {
        fullscreenSpaceIntentGeneration = nil
        fullscreenSpaceIntentTimer?.invalidate()
        fullscreenSpaceIntentTimer = nil
        fullscreenSpaceIntentVerdictTimer?.invalidate()
        fullscreenSpaceIntentVerdictTimer = nil
    }

    /// 空间已经切完，但那一刻的 CG 判定不可信。等和 `FullscreenSpaceHold` 同一个 120ms，
    /// 再用 CG（不行就 AX 兜底）给最终判定；只有最终判定说"不是全屏"才撤销预测。
    private func scheduleFullscreenSpaceIntentVerdict(generation: UInt64) {
        guard fullscreenSpaceIntentVerdictTimer == nil else { return }
        let timer = Timer(
            timeInterval: FullscreenSpaceHoldDecision.postSpaceConfirmationDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resolveFullscreenSpaceArrowIntent(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceIntentVerdictTimer = timer
    }

    private func resolveFullscreenSpaceArrowIntent(generation: UInt64) {
        guard fullscreenSpaceIntentGeneration == generation else { return }
        fullscreenSpaceIntentVerdictTimer = nil
        if checkFullscreenViaCGSync() {
            applyFullscreenVisibility(true, source: "space-intent-delayed-cg")
            return
        }
        triggerAsyncFullscreenCheck(
            isFinalSpaceIntentVerdict: true,
            source: "space-intent-final-ax"
        )
    }

    @discardableResult
    private func beginFullscreenSpaceHold(
        pid: pid_t?,
        confirmationDelay: TimeInterval
    ) -> UInt64? {
        guard FullscreenSpaceHoldDecision.shouldBegin(
            isFullscreen: visibilityState.hideReasons.contains(.fullscreen),
            hasInputIntent: fullscreenIntentTransaction != nil || fullscreenSpaceIntentGeneration != nil
        ) else {
            return nil
        }

        let screenCGFrame = currentPanelScreenCGFrame()
        let hold: FullscreenSpaceHold
        if let current = fullscreenSpaceHold,
           current.pid == pid,
           current.screenCGFrame == screenCGFrame {
            hold = current
        } else {
            fullscreenSpaceHoldGeneration &+= 1
            fullscreenProbeGeneration &+= 1
            hold = FullscreenSpaceHold(
                generation: fullscreenSpaceHoldGeneration,
                pid: pid,
                screenCGFrame: screenCGFrame
            )
            fullscreenSpaceHold = hold
        }
        scheduleFullscreenSpaceHoldConfirmation(
            generation: hold.generation,
            after: confirmationDelay
        )
        return hold.generation
    }

    private func scheduleFullscreenSpaceHoldConfirmation(
        generation: UInt64,
        after delay: TimeInterval
    ) {
        fullscreenSpaceHoldTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.confirmFullscreenSpaceHoldWindowed(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceHoldTimer = timer
    }

    private func confirmFullscreenSpaceHoldWindowed(generation: UInt64) {
        guard let hold = fullscreenSpaceHold,
              hold.generation == generation else {
            return
        }
        guard hold.pid == lastActiveApplicationPID,
              hold.screenCGFrame == currentPanelScreenCGFrame() else {
            finishFullscreenSpaceHold(generation: generation)
            triggerAsyncFullscreenCheck(pid: lastActiveApplicationPID)
            return
        }
        fullscreenSpaceHoldTimer = nil
        // 120ms 时的 CG true 不再是终点：退出全屏方向 CG 滞后 0.4~0.8s（2026-08-30 实测，
        // `Docs/05`），此刻的 true 很可能仍是过渡残影，照它收口就回到「等 5 秒对账」。
        // 一律让终审 AX 定夺——AX 在退出动画开始时就已翻 false（同日实测，比 CG 早），
        // 是这个方向唯一可信的信号。全→全切换的代价是多一次 AX 读、确认晚 ~百 ms，
        // 期间条本来就藏着。CG 读数保留进 source 供取证区分两条路径。
        let cgFullscreen = checkFullscreenViaCGSync()
        triggerAsyncFullscreenCheck(
            pid: hold.pid,
            expectedSpaceHoldGeneration: generation,
            isFinalSpaceHoldWindowedConfirmation: true,
            source: cgFullscreen ? "space-hold-final-ax-cgtrue" : "space-hold-final-ax"
        )
    }

    private func finishFullscreenSpaceHold(generation: UInt64) {
        guard fullscreenSpaceHold?.generation == generation else { return }
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceHoldTimer = nil
        fullscreenSpaceHold = nil
    }

    func cancelFullscreenIntentIfContextChanged(activePID: pid_t? = nil) {
        guard let transaction = fullscreenIntentTransaction else { return }
        let currentPID = activePID ?? lastActiveApplicationPID
        guard currentPID != transaction.pid || currentPanelScreenCGFrame() != transaction.screenCGFrame else {
            return
        }
        cancelFullscreenIntent(generation: transaction.generation, reason: "context-changed")
    }

    private func isFullscreenIntentContextCurrent(_ transaction: FullscreenIntentTransaction) -> Bool {
        NSRunningApplication(processIdentifier: transaction.pid)?.isActive == true
            && currentPanelScreenCGFrame() == transaction.screenCGFrame
    }

    func handleFullscreenIntentContextChange(
        _ change: FullscreenIntentMonitor.ContextChange
    ) {
        if case let .activeApplication(pid) = change {
            lastActiveApplicationPID = pid
        }
        guard let transaction = fullscreenIntentTransaction else { return }
        switch change {
        case let .activeApplication(pid):
            if pid != transaction.pid {
                cancelFullscreenIntent(generation: transaction.generation, reason: "app-changed")
            }
        case .focusedWindow:
            cancelFullscreenIntent(generation: transaction.generation, reason: "focus-changed")
        case let .windowDestroyed(windowID):
            if windowID == nil || windowID == transaction.focusedWindowID {
                cancelFullscreenIntent(generation: transaction.generation, reason: "window-destroyed")
            }
        }
    }

    func currentPanelScreenCGFrame() -> CGRect? {
        guard let panel = dockPanel else { return nil }
        return Self.toCGRect(panelCurrentScreen(panel: panel))
    }

    /// 焦点窗口读不到（pid 为 nil / 无焦点窗口）仍是 `.windowed`——与三态引入前的 false 逐字等价。
    nonisolated private static func detectFullscreenViaAX(pid: pid_t?, screenCGFrame: CGRect) -> FullscreenAXVerdict {
        guard let pid else { return .windowed }
        let reader = AXWindowReader()
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.5)

        guard let focused = reader.elementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement) else {
            return .windowed
        }
        _ = AXUIElementSetMessagingTimeout(focused, 0.5)

        let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: focused, maxAttempts: 1)
        let isAXFullscreen = reader.boolAttribute("AXFullScreen" as CFString, from: focused, maxAttempts: 1) ?? false
        // AX kAXPositionAttribute uses CG coordinates (top-left origin) — matches screenCGFrame directly
        let windowFrame = reader.frame(of: focused, maxAttempts: 1)

        return FullscreenWindowClassifier.classify(
            role: role,
            isAXFullscreen: isAXFullscreen,
            windowFrame: windowFrame,
            screenCGFrame: screenCGFrame
        )
    }

    /// 焦点窗口在别的屏上时，本屏的条问 SkyLight「本屏当前空间是不是原生全屏空间」
    ///（`type == 4`，按显示器隔离、0.13ms/次，`Docs/05`）。读不到 → nil = 「无信息」。
    private func fullscreenVerdictFromSpaceLayout() -> Bool? {
        guard let panel = dockPanel,
              let uuid = DisplayIdentity.uuidString(for: panelCurrentScreen(panel: panel)),
              let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else { return nil }
        return layout.fullscreenSpaceIDs.contains(layout.currentSpaceID)
    }
}
