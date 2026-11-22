import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · 布局：内容宽度订阅、目标 frame 计算与提交、换档、屏幕参数变化。
// 2026-09-05 从 PanelCoordinator.swift 按 extension 拆出，只搬不改。
extension PanelCoordinator {
    // MARK: - Content Width via fittingSize

    func subscribeSnapshotWidth() {
        snapshotWidthSubscription = runtime.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                // `receive(on:)` 这一跳已在快照写入之后，`fittingSize` 会把 SwiftUI 按新快照同步布局一遍，
                // 不必再多推一轮主队列。卡增减（id 集合变了）照旧走窗口动画；只是标签变了、跟随窗开着时
                // 不起动画——那期间内容宽度逐帧变，面板由 `labelFollowTick` 逐帧跟，这里量到的只是中间值。
                let ids = Set(snapshot.orderedWindowIDs)
                let idsChanged = self.lastSnapshotWindowIDs != ids
                self.lastSnapshotWindowIDs = ids
                if idsChanged {
                    self.relayout(animated: true)   // layoutPanels 内含抽屉重定位
                } else if !self.isLabelFollowActive {
                    self.relayout(animated: true)
                }
                // 跟随窗开着且只是标签变了：什么都不做，面板由 `labelFollowTick` 按曲线推。
            }
    }

    func subscribeDrawerStoreWidth() {
        drawerStoreWidthSubscription = drawerStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.syncDrawerOrder()
                    self?.relayout(animated: true)
                }
            }
    }

    /// 拖出即合拢（owner 2026-09-03）：条上那张卡离开 / 回到任务条时投影层剔掉 / 放回它，面板宽度
    /// 要跟着动画。任务条宽度**不再钳**（2026-06-22 → 08-20 两轮的宽度冻结机制随之删除）：
    /// 条宽任何时候都等于此刻渲染内容的宽度，收纳松手时条已经是窄的，胶囊 / 抽屉不再在飞行途中滑动。
    /// 写法同 store 订阅（先 receive(on:) 再 async 一轮，让 SwiftUI 先按新投影布局，`fittingSize` 才是新宽度）。
    func subscribeStripSlotCollapse() {
        stripSlotCollapseSubscription = heightResizePresentation.deferredChanges(from: dragController.$stripSlotCollapsed
            .removeDuplicates()
            .dropFirst())
            .sink { [weak self] _ in
                guard let self else { return }
                // 换档事务里 cancelDrag() 也会走到这里排队一次带动画的布局；用代次吞掉它，
                // 否则会先按新 metrics 动画一次、再被事务的无动画布局跳一次。
                let generation = self.heightResizePresentation.generation
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.layoutChangeActive,
                          generation == self.heightResizePresentation.generation else { return }
                    self.relayout(animated: true)
                }
            }
    }

    /// 抽屉顺序按完整 placement 集合收敛，不按当前可见项裁。即便抽屉没开也同步，
    /// 让隐藏成员下一次启动时回到原来的相对位置。
    private func syncDrawerOrder() {
        let members = AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
        drawerOrderStore.sync(members: members)
    }

    func subscribeMessagingStoreWidth() {
        messagingStoreWidthSubscription = messagingStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)
                }
            }
    }

    func subscribeKeptAppStore() {
        keptAppStoreSubscription = keptAppStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)
                }
            }
    }

    func subscribeRunningApplicationStore() {
        runningApplicationStoreSubscription = runningApplicationStore.$runningBundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
    }

    func subscribeSettings() {
        edgeDelaySubscription = settingsStore.$edgeAutoHideDelay
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcilePanelVisibility()
                self?.onHoverMonitorsNeedReconcile?()  // 边缘隐藏开关变了：监视器是否还有存在的必要
            }
        // 显示位置变化：dwell 作废；切到固定档立即搬到固定屏；监视器与唤醒武装按新档重估。
        // dropFirst——启动路径 setupDockPanel 已消费过持久化的档位。
        taskbarScreenPlacementSubscription = settingsStore.$taskbarScreenPlacement
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cancelHoverSwitch()
                if let home = self.resolvedPinnedScreen(), let panel = self.dockPanel,
                   self.panelCurrentScreen(panel: panel) != home {
                    self.layoutPanels(contentWidth: self.lastDesiredWidth, on: home, animated: false)
                }
                self.onHoverMonitorsNeedReconcile?()
                self.reconcilePanelVisibility()
                // ③↔④ 不重建单元，只换投影层的过滤集合：SwiftUI 重画后没有别的路径回到这里量宽
                //（owner 2026-09-02 首轮验收：切档后条长不变，要再点一下窗口才适应）。等这一轮布局跑完再量。
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // 屏表变了（拔插 / 换主屏）：④ 下渲染集合会变（别的屏的卡落回主屏），同样要重新量宽。
        displayTopologySubscription = displayTopologyStore.$table
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // 中转格显隐会改变任务条内容宽度：只让 chip 消失不重排，面板会停在旧宽度，
        // 胶囊和打开着的抽屉也跟着停在旧位置。relayout 必须等 SwiftUI 这一轮布局跑完
        // （fittingSize 那时才是新值），所以再推一轮主队列。
        showShelfSubscription = settingsStore.$showShelf
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.folderPopupWantsOpen, self.openPopupContent == .shelf { self.closeFolderPopup() }
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        showTrashSubscription = settingsStore.$showTrash
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.folderPopupWantsOpen, self.openPopupContent == .trash { self.closeFolderPopup() }
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        dockPanelHeightSubscription = heightResizePresentation
            .nonInteractiveHeightChanges(from: settingsStore.$dockPanelHeight)
            .sink { [weak self] _ in
                self?.beginPanelHeightChange()
            }
        labelSizingSubscription = heightResizePresentation.deferredChanges(from:
            Publishers.Merge(
                settingsStore.$windowLabelWidth.removeDuplicates().dropFirst().map { _ in () },
                settingsStore.$fixedWindowLabelWidth.removeDuplicates().dropFirst().map { _ in () }
            ))
            .sink { [weak self] in
                guard let self else { return }
                self.beginLayoutChange(.labelWidth)
                self.commitLayoutChange()
                self.endLayoutChange()
            }
    }

    /// A height change is a **transaction**, not a content change: panel height, capsule width
    /// and every chip's size move together, and any animated layout in between puts the three
    /// panels on half-old, half-new geometry.
    ///
    /// Order matters:
    /// 1. Retire everything attached to the old geometry — the drag carrier (sized by the
    ///    height), the drawer (`maxContentHeight` is passed once when it opens; moving only the
    ///    frame clips the content), popups and the tooltip (anchors are stale), and the
    ///    label-width follow (its rest width was measured at the old scale).
    /// 2. `cancelDrag()` queues an **animated** relayout via `subscribeStripSlotCollapse`; the
    ///    generation gate swallows it.
    /// 3. Let SwiftUI lay out once at the new height (`fittingSize` is only then the new width),
    ///    then commit once with no animation. Height changes are instant, never animated.
    ///
    /// Window-lift avoidance needs nothing here: `taskbarTop` derives from `panelHeight` inside
    /// the Equatable `WindowLiftAvoidanceContext`, so the controller's existing restore → re-lift
    /// path runs on its own (frozen during a drag, see `liftContextPanelHeightOverride`).
    func beginPanelHeightChange() {
        beginLayoutChange(.height)
        commitLayoutChange()
        endLayoutChange()
    }

    func tearDownForPanelHeightChange() {
        heightResizePresentation.invalidateQueuedLayouts()
        cancelLabelWidthFollow()
        dragController.cancelDrag()
        dismissWindowTitleTooltip()
        closeFolderPopup(immediately: true)
        if drawerWantsOpen { closeDrawer() }
    }

    // MARK: - Interactive height resize

    /// Broadcast from the orchestrator to **every** unit when any unit's grip starts (`true`) or
    /// ends (`false`) a drag. Not the auto-hide inhibitor: that goes on the dragged unit only
    /// (`beginInteractiveResize`) because an inhibitor also clears an existing auto-hide and
    /// would wake bars other screens had hidden.
    func setInteractiveHeightResizeActive(_ active: Bool) {
        if active { beginLayoutChange(.height) }
        else { commitLayoutChange(); endLayoutChange() }
    }

    func beginLayoutChange(_ kind: TaskbarLayoutKind) {
        guard heightResizePresentation.kind != kind else { return }
        heightResizePresentation.kind = kind
        if kind == .height { liftContextPanelHeightOverride = layoutMetrics.panelHeight }
        tearDownForPanelHeightChange()
        settleRunningFrameAnimation()
        commitLayoutChange()
    }

    func endLayoutChange() {
        if heightResizePresentation.kind == .height { liftContextPanelHeightOverride = nil }
        heightResizePresentation.kind = nil
    }

    func commitLayoutChange() {
        guard layoutChangeActive else { return }
        heightResizePresentation.invalidateQueuedLayouts()
        relayout(animated: false, batched: true)
    }

    /// Grip mouse-down on this unit's bar.
    func beginInteractiveResize(pointer: CGPoint) {
        guard interactiveResize == nil else { return }
        interactiveResizeToken = onInteractiveHeightResizeBegin?()
        interactiveResize = DockHeightDragSession(startHeight: settingsStore.dockPanelHeight.points,
                                                  startPointerY: pointer.y)
        showResizeCursor(at: pointer)
        setAutoHideInhibitor(.interactiveResize, active: true)
        // No orchestrator (tests, tools): still behave as a one-unit session.
        if !interactiveHeightResizeActive { setInteractiveHeightResizeActive(true) }
    }

    /// One drag tick. The glyph follows every event; the height changes only on whole points.
    /// Explicit hosting layout makes the new scale measurable in this same event. Content and
    /// panel geometry are committed together, without an intermediate old-size hosting frame.
    func updateInteractiveResize(pointer: CGPoint) {
        guard let session = interactiveResize else { return }
        showResizeCursor(at: pointer)
        let target = session.height(forPointerY: pointer.y)
        guard target != settingsStore.dockPanelHeight else { return }
        if let onInteractiveHeightResizeUpdate, let token = interactiveResizeToken {
            onInteractiveHeightResizeUpdate(token, target)
        } else {
            settingsStore.setDockPanelHeight(target)
            commitInteractivePanelHeight()
        }
    }

    func commitInteractivePanelHeight() {
        commitLayoutChange()
    }

    func endInteractiveResize() {
        guard interactiveResize != nil else { return }
        interactiveResize = nil
        if let token = interactiveResizeToken { onInteractiveHeightResizeEnd?(token) }
        interactiveResizeToken = nil
        if interactiveHeightResizeActive { setInteractiveHeightResizeActive(false) }
        setAutoHideInhibitor(.interactiveResize, active: false)
    }

    /// End a drag from outside the view tree (topology change, unit rebuild, suspension). Goes
    /// through the grip so the pushed cursor is popped and re-decided; falls back to ending the
    /// session directly when the grip is already gone.
    func cancelInteractiveResize() {
        guard interactiveResize != nil else { return }
        resizeGripController.cancel()
        endInteractiveResize()
    }

    /// Converge a frame animation that is still in flight when a drag begins, so a press that
    /// then holds still (or moves under 1pt, producing no tick) does not leave the old animation
    /// running to its target. Clears `lastCommittedFrames` first: an animation heading for the
    /// same target would otherwise hit `setFrames`' "target unchanged" short-circuit.
    func settleRunningFrameAnimation() {
        guard CACurrentMediaTime() < animatedFramesUntil else { return }
        lastCommittedFrames = []
        relayout(animated: false)
    }

    /// Bar target frame: content width, capped; bar + drawer capsule centered as one group.
    func dockTargetFrame(contentWidth: CGFloat, on screen: NSScreen) -> NSRect {
        PanelGeometry.dockTargetFrame(contentWidth: contentWidth, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// 胶囊目标 frame（贴任务条右边、纵向居中）。只依赖传入的 dock **目标** frame。
    private func capsuleTargetFrame(forDock dockFrame: NSRect, on screen: NSScreen) -> NSRect {
        PanelGeometry.capsuleTargetFrame(forDock: dockFrame, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// 抽屉目标 frame（右边贴胶囊右边、**底边硬锚在胶囊上方、向上长**）。只依赖传入的胶囊 **目标** frame + 抽屉尺寸。
    /// 关键：底边绝不下移——超过上方可用空间就**封顶高度**（内容由 DrawerView 内部滚动），
    /// 绝不靠"把底边往下压"来塞下，否则压到胶囊/任务条（owner 2026-06-21 报图）。
    func drawerTargetFrame(forCapsule capsuleFrame: NSRect, size: CGSize, on screen: NSScreen) -> NSRect {
        // 底部/左右定位使用 screen.frame，切断与原生 Dock visibleFrame 的耦合；
        // 顶部高度仍由 topUsableY 封顶，避免菜单栏和刘海遮挡。
        PanelGeometry.drawerTargetFrame(forCapsule: capsuleFrame, size: size, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// 统一布局入口：算齐三个目标 frame、存好（给 drop zone / 开抽屉读），三面板同组动画到目标。
    /// 开屏/切屏/多屏悬停传 animated:false；内容变化、收纳/移回、抽屉尺寸变化传 animated:true。
    func layoutPanels(contentWidth: CGFloat, on screen: NSScreen, animated: Bool, batched: Bool = false) {
        guard let dock = dockPanel, let capsule = capsulePanel else { return }
        let panelScreenCGFrame = Self.toCGRect(screen)
        if let transaction = fullscreenIntentTransaction,
           transaction.screenCGFrame != panelScreenCGFrame {
            cancelFullscreenIntent(generation: transaction.generation, reason: "panel-screen-changed")
        }
        // First frame is instant (no slide from the initial position); so is every frame while a
        // height drag is active anywhere — the dozen `relayout(animated: true)` callers need no
        // per-site gate.
        let anim = animated && didInitialLayout && !layoutChangeActive
        didInitialLayout = true
        onPanelScreenChanged?()

        let dockT = dockTargetFrame(contentWidth: contentWidth, on: screen)
        // 胶囊（连同按它定位的抽屉）**永远**贴着此刻的条目标帧，拖动中也一样：拖出即合拢让条对称收缩，
        // 胶囊跟着一起动（原生 Dock 同样整条重新居中）。2026-09-03 曾在拖动期把胶囊钉在旧目标帧上——
        // 多屏下每个单元都被钉住，B 条变宽压到胶囊、A 条变窄留大缝（owner 当天报）。不要再加锚定。
        let capsuleT = capsuleTargetFrame(forDock: dockT, on: screen)
        // 任务条目标帧一变（宽度/切屏）就关弹窗——不追动画中的锚点（与原生 Dock 行为一致,保 target-frame 纯度）。
        if dockT != lastDockTargetFrame {
            if folderPopupWantsOpen { closeFolderPopup() }
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        }
        lastDockTargetFrame = dockT
        lastCapsuleTargetFrame = capsuleT

        var pairs: [(NSPanel, NSRect)] = []
        if let background = dockGlassBackgroundPanel {
            dockGlassBackgroundView?.apply(
                cornerRadius: taskbarPlateCornerRadius,
                configuration: DockGlassPresentation.configuration
            )
            // 背景窗口贴着可视底板（内容窗口减掉 20pt 阴影透明边）。
            pairs.append((
                background,
                DockLiquidGlassPanelGeometry.backgroundFrame(
                    for: dockT,
                    shadowPadding: Self.shadowPadding
                )
            ))
        }
        pairs.append((dock, dockT))
        pairs.append((capsule, capsuleT))
        if let drawer = drawerPanel, drawer.isVisible, let hosting = drawerContentHost {
            // Smaller than any plate = not laid out yet, never a size: keep the last good one.
            let fitting = hosting.fittingSize
            if Self.isPlausibleDrawerSize(fitting) { lastDrawerSize = fitting }
            let drawerT = drawerTargetFrame(forCapsule: capsuleT, size: lastDrawerSize, on: screen)
            lastDrawerTargetFrame = drawerT
            pairs.append((drawer, drawerT))
        }
        let commit = setFrames(pairs, animated: anim, batched: batched)
        if drawerWantsOpen { syncDrawerArrow(after: commit) }
    }

    /// 量当前内容宽度后布局（内容变化的统一入口）。
    func relayout(animated: Bool, batched: Bool = false) {
        guard let panel = dockPanel, let hosting = dockContentHost else { return }
        let spanStart = HoverTrace.now(); defer { HoverTrace.span("relayout", since: spanStart) }
        if layoutChangeActive {
            panel.disableScreenUpdatesUntilFlush()
            dockGlassBackgroundPanel?.disableScreenUpdatesUntilFlush()
            capsulePanel?.disableScreenUpdatesUntilFlush()
            hosting.layoutContent()
            capsuleContentHost?.layoutContent()
        }
        // `fittingSize` 是**主线程上把整条任务条同步布局一遍**，不是读一个缓存值。
        // 探针量的就是它 + 宽度到底变没变（没变还跑动画就是纯浪费）。
        let measureStart = CACurrentMediaTime()
        let measured = hosting.fittingSize.width - 2 * Self.shadowPadding
        HoverTrace.relayout(measureMs: CACurrentMediaTime() - measureStart,
                            width: measured,
                            changed: measured != lastDesiredWidth,
                            animated: animated,
                            timing: (isLabelFollowActive ? "follow" : "standard") + ":" + String(stripSurfaceID.suffix(4)))
        lastDesiredWidth = measured
        // 跨面板转正进行中 → 任务条宽度钳在拖动前的值（窗口卡溢出/留空而非改变面板宽度，owner 2026-06-22）；
        // 松手/还原解钳后，下一次 relayout 用真实测量值把任务条变到最终长度。
        layoutPanels(contentWidth: measured, on: panelCurrentScreen(panel: panel), animated: animated,
                     batched: batched || layoutChangeActive)
        if layoutChangeActive {
            panel.layoutIfNeeded()
            capsulePanel?.layoutIfNeeded()
            hosting.layoutContent()
            capsuleContentHost?.layoutContent()
        }
    }

    /// 三面板同一个动画组提交,共用一条时间轴（Codex 二审 P2：避免各跑各的时间轴抖动）。
    ///
    /// **目标 frame 和现状完全一样时直接返回，一帧都不跑。**
    /// 2026-08-17 实测（`DOCK_HOVER_TRACE=1`）：启动后 6 秒里 10 次 `relayout`，其中 **8 次**
    /// 宽度根本没变却仍然 `animated: true`，还有连着 6 次挤在 1.1ms 内。每一次都会启动一组
    /// 窗口尺寸动画，把三个面板"动画"到和现在一模一样的尺寸——**而窗口尺寸动画的每一帧都要
    /// 重画玻璃底板和那圈描边**。测量本身很便宜（`fittingSize` 0.2ms），贵的是这个空动画。
    ///
    /// 判据用**最终 frame 全等**而不是「宽度没变」：换屏、改档位、边缘隐藏都会在宽度不变的
    /// 情况下真的挪动面板，只比宽度会把它们一起吃掉。
    /// `batched`（只有标签跟随的逐帧 tick 传 true）：`display: false`，三个面板的 frame 变化留到这一轮主循环
    /// 末尾和 SwiftUI 内容一起提交——逐个 `display: true` 会各自立刻冲刷，胶囊、底板、内容三者落在不同帧上
    /// （屏幕连拍 2026-09-13：变长途中胶囊贴到了底板边上）。
    /// What `setFrames` did with the frames it was handed.
    enum FrameCommit { case unchanged, instant, animated }

    @discardableResult
    func setFrames(_ pairs: [(NSPanel, NSRect)], animated: Bool, batched: Bool = false) -> FrameCommit {
        // **和上一次的目标比，不和面板的实时 frame 比。**
        // 实时 frame 在动画途中是插值出来的中间值，永远和目标不等——那样这个短路一次都不会命中
        // （实测 0 次）。AGENTS《Menus, Panels, And Screens》早写过同一条：relayout 是目标
        // frame 驱动的，别在动画期间读面板的实时 frame。
        let targets = pairs.map(\.1)
        guard targets != lastCommittedFrames else {
            HoverTrace.framesUnchanged()
            return .unchanged
        }
        lastCommittedFrames = targets
        guard animated else {
            if CACurrentMediaTime() < animatedFramesUntil {
                // An animator group is still flying: a direct `setFrame` gets overwritten by its
                // remaining frames. A zero-duration group replaces the running animation instead.
                animatedFramesUntil = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0
                    for (p, f) in pairs { p.animator().setFrame(f, display: !batched) }
                }
            } else {
                for (p, f) in pairs { p.setFrame(f, display: !batched) }
            }
            if let dock = dockPanel { HoverTrace.width("panel:" + String(stripSurfaceID.suffix(4)), dock.frame.width) }
            return .instant
        }
        animatedFramesUntil = CACurrentMediaTime() + Self.layoutAnimationDuration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.layoutAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (p, f) in pairs { p.animator().setFrame(f, display: true) }
        }
        return .animated
    }

    // MARK: - Label width follow

    var isLabelFollowActive: Bool { labelFollowTimer != nil }

    /// 条内标签变长变短了（`DockStripView.onLabelWidthChange`，在 SwiftUI 那一轮更新里同步调用）。
    /// `starting` = 这次开始动的标签盒的起始宽。跟随窗已开着时只补登记新盒子，起步宽不重量。
    func beginLabelWidthFollow(starting: [String: CGFloat]) {
        guard !layoutChangeActive else { return }
        let now = CACurrentMediaTime()
        if !isLabelFollowActive {
            labelFollowRestWidth = lastDesiredWidth
            labelBoxStart = [:]
            labelBoxLive = [:]
        }
        for (id, from) in starting where labelBoxStart[id] == nil {
            labelBoxStart[id] = from
            labelBoxLive[id] = from
        }
        labelFollowDeadline = now + LabelWidthAnimation.curve.duration + 0.1
        guard labelFollowTimer == nil else { return }
        // 计时器只负责收尾：截止后量一次终值、清状态。逐帧的 frame 由 `labelBoxWidthDidTick` 设。
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard CACurrentMediaTime() >= self.labelFollowDeadline else { return }
            t.invalidate()
            self.labelFollowTimer = nil
            self.labelBoxStart = [:]
            self.labelBoxLive = [:]
            self.relayout(animated: false)   // 收尾量一次终值，吃掉起始宽估算的零点几 pt
        }
        RunLoop.main.add(timer, forMode: .common)
        labelFollowTimer = timer
    }

    /// Drop a follow window in progress (height change): its rest width was measured at the old
    /// scale. The final measurement happens on the caller's instant relayout.
    func cancelLabelWidthFollow() {
        guard isLabelFollowActive else { return }
        labelFollowTimer?.invalidate()
        labelFollowTimer = nil
        labelBoxStart = [:]
        labelBoxLive = [:]
    }

    /// `LabelBoxWidthDriver` 每帧上报：只认跟随窗里登记过的盒子；卡增减那条窗口动画还在飞时不抢。
    /// `batched`：三面板 `display: false`，和本帧的 SwiftUI 内容一起提交。
    func labelBoxWidthDidTick(chipID: String, width: CGFloat) {
        guard !layoutChangeActive else { return }
        guard isLabelFollowActive, labelBoxStart[chipID] != nil, labelBoxLive[chipID] != width else { return }
        labelBoxLive[chipID] = width
        guard CACurrentMediaTime() >= animatedFramesUntil, let panel = dockPanel else { return }
        let delta = labelBoxStart.reduce(CGFloat(0)) { acc, entry in
            acc + ((labelBoxLive[entry.key] ?? entry.value) - entry.value)
        }
        layoutPanels(contentWidth: labelFollowRestWidth + delta,
                     on: panelCurrentScreen(panel: panel), animated: false, batched: true)
    }

    /// 由编排层在 `didChangeScreenParametersNotification` 时转发（它先按屏集合建 / 拆单元，再转给幸存者）。
    /// 跨面板拖动的取消与监视器重估也由编排层做一次，这里不重复。
    func screenParametersChanged() {
        cancelHoverSwitch()
        closeFolderPopup()             // 屏幕参数变了,旧锚点坐标作废
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        guard dockPanel != nil else { return }
        // 固定到某屏：屏幕集合变了先归位（拔固定屏 → 回落主屏；接回 → 搬回去）。
        // 必须在 relayout 之前——relayout 用 panelCurrentScreen 从面板坐标反推所在屏。
        if let home = resolvedPinnedScreen(), let panel = dockPanel,
           panelCurrentScreen(panel: panel) != home {
            layoutPanels(contentWidth: lastDesiredWidth, on: home, animated: false)
        }
        relayout(animated: false)      // 切屏瞬时,不滑
        cancelFullscreenIntentIfContextChanged()
        reconcilePanelVisibility()
    }

    static func screenGeometry(_ screen: NSScreen) -> PanelScreenGeometry {
        PanelScreenGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top)
    }
}
