import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · 抽屉：开合、host 复用、拖动投放区几何、弹簧文件夹自动弹开。
// 2026-09-05 从 PanelCoordinator.swift 按 extension 拆出，只搬不改。
extension PanelCoordinator {
    func openDrawer() {
        guard let mainPanel = dockPanel, capsulePanel != nil else { return }
        onAccessoryWillOpen?(self, .drawer)
        closeFolderPopup()   // the other units close through `onAccessoryWillOpen`; this one is ours
        drawerActionCloseToken += 1  // 旧点击排队的 delayed close 捕获旧 token，不匹配则丢弃
        drawerWantsOpen = true
        setAutoHideInhibitor(.drawerOpen, active: true)
        drawerSpringOpened = false   // 默认手动开；弹簧路径在 springOpenDrawer 里再置 true
        setDrawerRaised(false)       // a reopen mid-fade may still hold the outside drag's level

        let screen = panelCurrentScreen(panel: mainPanel)
        let (capsuleRef, limits) = drawerAnchor(on: screen)

        // 宿主只建一次；之后打开只在可用高度变了才换 rootView。
        // 各阶段打 `HoverTrace.action("drawerOpen")` 标记：打开这一转的主线程停顿由哪段贡献，只有它能分出来。
        HoverTrace.action("drawerOpen", phase: "begin")
        guard let host = ensureDrawerHost(limits: limits) else { return }
        let (panel, hosting) = host
        HoverTrace.action("drawerOpen", phase: "host")
        // Before the first measurement: that render captures the count the columns hold to.
        drawerShowing.begin(plateOnScreen: panel.isVisible)

        // 首帧就位（owner 2026-07-06「不丝滑」主因之一）：orderFront **前**同步量真实尺寸,
        // 首帧即最终大小,不再「旧尺寸弹出→瞬间校正」。量不到合理值退回 lastDrawerSize,
        // 后面的 double-defer 复测仍在,作兜底校正。
        panel.layoutIfNeeded()
        HoverTrace.action("drawerOpen", phase: "layout")
        let sync = hosting.fittingSize
        HoverTrace.action("drawerOpen", phase: "fitting")
        if Self.isPlausibleDrawerSize(sync) {
            lastDrawerSize = sync
        }
        let initialFrame = drawerTargetFrame(forCapsule: capsuleRef, size: lastDrawerSize, on: screen)
        lastDrawerTargetFrame = initialFrame

        panel.setFrame(initialFrame, display: false)
        syncDrawerArrow(after: .instant)
        // The arrow's position was only known with the frame: lay it out before the first show.
        hosting.layoutSubtreeIfNeeded()
        // 打开无动画（owner 2026-09-04，理由见 `DrawerView` 与 `Docs/27`）：直接以 alpha 1 上屏。
        // 淡出中途重开也直接回到 1；`closeDrawer` 的 completion 有 `!drawerWantsOpen` 守卫，不会把它 orderOut。
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        HoverTrace.action("drawerOpen", phase: "ordered")
        pinOverlappingPanelIfNeeded(panel)
        HoverTrace.action("drawerOpen", phase: "shown")
        // 弹出后复测 fittingSize 重新布局（瞬时,刚弹出不滑）——同步量偏差时的兜底校正。
        DispatchQueue.main.async { [weak self] in
            HoverTrace.action("drawerOpen", phase: "turn1")
            DispatchQueue.main.async { [weak self] in
                HoverTrace.action("drawerOpen", phase: "turn2")
                self?.relayout(animated: false)
            }
        }

        // The bar is our own window: its presses, drags and releases all arrive locally.
        drawerLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleDrawerClickAway(event, isLocal: true)
            return event
        }
        drawerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleDrawerClickAway(event, isLocal: false)
        }
    }

    /// 抽屉的定位输入：胶囊**目标** frame（不读 live：用户可能在任务条宽度动画中触发弹簧开抽屉,Codex 二审 P1）
    /// 和网格的行列上限 = 胶囊上方到屏幕上沿放得下多少。超出由网格在底板里滚动,
    /// 绝不靠下压底边来塞下（否则压向胶囊/任务条 = 重叠,Codex 二审第 4 点）。
    /// 顶部上限仍避让菜单栏 / 刘海；底部锚点不避让原生 Dock，避免 Command+Option+D 或侧边 Dock 推动抽屉。
    private func drawerAnchor(on screen: NSScreen) -> (capsuleRef: NSRect, limits: StackGridLayout.Limits) {
        let screenGeometry = Self.screenGeometry(screen)
        let capsuleRef = lastCapsuleTargetFrame == .zero ? (capsulePanel?.frame ?? .zero) : lastCapsuleTargetFrame
        return (capsuleRef, PanelGeometry.drawerGridLimits(forCapsule: capsuleRef, on: screenGeometry, metrics: layoutMetrics))
    }

    /// Smaller than any plate means the host has not laid out yet, never a real size.
    static func isPlausibleDrawerSize(_ size: CGSize) -> Bool { size.width >= 160 && size.height >= 100 }

    /// The drawer's visible part for a window frame: plate plus arrow strip, without the 40pt
    /// transparent border.
    static func drawerPlateFrame(_ panelFrame: NSRect) -> CGRect {
        PanelGeometry.folderPopupPlateFrame(panelFrame: panelFrame)
    }

    // MARK: - Arrow

    /// The single writer of the drawer arrow's offset, keyed on what `setFrames` actually did
    /// with the drawer's frame — never on "layout ran" or the `animated` it was asked for:
    /// - `.animated`: sync from the two panels' live frames now and keep following every tick
    ///   until the animation's end (`animatedFramesUntil`), then land on the target. A plate
    ///   clamped at the screen edge moves against its capsule for the whole animation; writing
    ///   the end value at once takes the arrow up to ~64pt off the capsule.
    /// - `.unchanged`: nothing. Same targets does not mean the running animation is over.
    /// - `.instant`: stop following, write the target.
    /// Live frames here only draw the arrow; no panel is ever positioned from them.
    func syncDrawerArrow(after commit: FrameCommit) {
        switch commit {
        case .unchanged:
            return
        case .instant:
            stopDrawerArrowFollow()
            writeDrawerArrow(live: false)
        case .animated:
            writeDrawerArrow(live: true)
            guard drawerArrowFollowTimer == nil else { return }   // one timer; the deadline is read per tick
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.drawerArrowFollowTimer != nil else { return }
                    if CACurrentMediaTime() >= self.animatedFramesUntil {
                        self.stopDrawerArrowFollow()
                        self.writeDrawerArrow(live: false)
                    } else {
                        self.writeDrawerArrow(live: true)
                    }
                }
            }
            drawerArrowFollowTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopDrawerArrowFollow() {
        drawerArrowFollowTimer?.invalidate()
        drawerArrowFollowTimer = nil
    }

    private func writeDrawerArrow(live: Bool) {
        let capsule = live ? capsulePanel?.frame : lastCapsuleTargetFrame
        let drawer = live ? drawerPanel?.frame : lastDrawerTargetFrame
        guard let capsule, let drawer, capsule != .zero, drawer != .zero else { return }
        let offset = capsule.midX - drawer.midX   // the capsule's visible rect is inset symmetrically
        if drawerArrow.offsetFromCenter != offset { drawerArrow.offsetFromCenter = offset }
    }

    private func makeDrawerRootView(limits: StackGridLayout.Limits) -> DrawerRootView {
        DrawerRootView(limits: limits,
                       arrow: drawerArrow,
                       showing: drawerShowing,
                       // Next main-loop turn: `fittingSize` reads zero inside the SwiftUI update
                       // that reports the new size; `layoutPanels` measures it outside.
                       onPanelSizeChange: { [weak self] _ in
                           DispatchQueue.main.async { [weak self] in
                               guard let self, self.drawerWantsOpen else { return }
                               self.relayout(animated: true)
                           }
                       },
                       usesLiquidGlass: usesLiquidGlass,
                       isDrawerOpen: { [weak self] in self?.drawerPanel?.isVisible == true },
                       onPrimaryAction: { [weak self] in self?.closeDrawerAfterAction() },
                       onExternalDragHover: { [weak self] over in self?.externalDragHover(.drawer, over) },
                       onDropApplications: { [weak self] urls, placement in
                           self?.stashDroppedApplications(urls, placement: placement)
                       },
                       onDropApplicationIDs: { [weak self] ids, placement in
                           self?.stashDroppedApplicationIDs(ids, placement: placement)
                       },
                       runtime: runtime, drawerStore: drawerStore, messagingStore: messagingStore,
                       drawerOrderStore: drawerOrderStore, dragController: dragController,
                       keptAppStore: keptAppStore, runningApplicationStore: runningApplicationStore,
                       appMembershipController: appMembershipController)
    }

    /// 抽屉面板 + SwiftUI 宿主，**只建一次**；之后只在行列上限变了才换 rootView。
    /// 2026-09-04 之前每次打开都现建一棵视图树，主线程停顿 55～135ms 压在淡入开头（弹开掉帧主因）。
    private func ensureDrawerHost(limits: StackGridLayout.Limits) -> (NSPanel, NSHostingView<DrawerRootView>)? {
        if drawerPanel == nil {
            let panel = makeFloatingPanel(
                contentRect: NSRect(origin: .zero, size: lastDrawerSize),
                usesLiquidGlass: usesLiquidGlass
            )
            configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: false)
            drawerPanel = panel
        }
        guard let panel = drawerPanel else { return nil }

        if let hosting = drawerHosting {
            if drawerHostedLimits != limits {
                hosting.rootView = makeDrawerRootView(limits: limits)
                drawerHostedLimits = limits
            }
            return (panel, hosting)
        }

        let hosting = NSHostingView(rootView: makeDrawerRootView(limits: limits))
        drawerHostedLimits = limits
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor

        // 关键：用普通 NSView 当 contentView,hosting 作为子视图自适应填充——**不让 NSHostingView 直接当 contentView**。
        // 否则内容变高时 macOS 会用内容尺寸**顶边锚定、向下撑大**窗口（日志实测 cur(y=24 h=194)、top 恒=218），
        // 我们的布局随后才把它纠正成底边锚定向上长（y=68）——这一前一后打架 = owner 看到的"先向下扩展再上移"
        // 的真因（2026-06-22）。普通 NSView 不把子视图内容尺寸传给窗口,窗口高度只由 layoutPanels/setFrames 控制;
        // fittingSize 改读 hosting（存进 drawerContentHost）。
        let container = NSView(frame: NSRect(origin: .zero, size: lastDrawerSize))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        drawerContentHost = hosting
        drawerHosting = hosting
        return (panel, hosting)
    }

    /// 启动后把抽屉宿主预热出来（不 orderFront、不动任何开合状态），让本次会话**第一次**打开也不用现建。
    /// 排在启动首帧事务之后 1 秒，不碰它。关着的抽屉视图活着不是新状态（③④ 下本来就有），拖拽回调都先问 `isDrawerOpen()`。
    func prewarmDrawerHost() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.isSuspendedForPermissionLoss, self.drawerHosting == nil,
                  let mainPanel = self.dockPanel, self.capsulePanel != nil else { return }
            let anchor = self.drawerAnchor(on: self.panelCurrentScreen(panel: mainPanel))
            guard let host = self.ensureDrawerHost(limits: anchor.limits) else { return }
            let (panel, hosting) = host
            panel.layoutIfNeeded()
            _ = hosting.fittingSize
        }
    }

    /// 抽屉内点击 app 主操作后的延迟关闭。捕获 token，触发时三重确认才关：
    /// 1. token 匹配（排除抽屉在延迟期被重开的情况）；2. 抽屉仍是逻辑打开态；3. 无拖动进行中。
    func closeDrawerAfterAction() {
        let token = drawerActionCloseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  self.drawerActionCloseToken == token,
                  self.drawerWantsOpen,
                  self.dragController.draggingPayload == nil else { return }
            self.closeDrawer()
        }
    }

    /// 可打断淡出关闭：立即摘监视器、动画 alpha→0,completion 里确认仍要关才 orderOut（淡出中又打开则不关）。
    func closeDrawer() {
        guard drawerWantsOpen else { return }
        drawerWantsOpen = false
        setAutoHideInhibitor(.drawerOpen, active: false)
        drawerSpringOpened = false
        if let m = drawerLocalMonitor  { NSEvent.removeMonitor(m); drawerLocalMonitor  = nil }
        if let m = drawerGlobalMonitor { NSEvent.removeMonitor(m); drawerGlobalMonitor = nil }
        drawerBarPress.cancel()
        stopDrawerArrowFollow()
        guard let panel = drawerPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PopoverAnimation.closeDuration
            ctx.timingFunction = PopoverAnimation.curve()
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.drawerWantsOpen else { return }   // 淡出中又开了 → 别 orderOut
                panel.orderOut(nil)
                self.setDrawerRaised(false)
                self.drawerArrow.scrollGeneration &+= 1   // next open starts at the grid's top
                self.drawerShowing.end()
            }
        })
    }

    /// 全屏输入已经被 tap 暂停投递，不能等淡出动画；状态和监视器照常收口后立即移出 WindowServer。
    func closeDrawerImmediately() {
        guard drawerWantsOpen || drawerPanel?.isVisible == true else { return }
        drawerWantsOpen = false
        setAutoHideInhibitor(.drawerOpen, active: false)
        drawerSpringOpened = false
        if let monitor = drawerLocalMonitor {
            NSEvent.removeMonitor(monitor)
            drawerLocalMonitor = nil
        }
        if let monitor = drawerGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            drawerGlobalMonitor = nil
        }
        drawerBarPress.cancel()
        stopDrawerArrowFollow()
        drawerPanel?.alphaValue = 0
        drawerPanel?.orderOut(nil)
        setDrawerRaised(false)
        drawerArrow.scrollGeneration &+= 1
        drawerShowing.end()
    }

    /// Click-away. Rules in `DrawerClickAway`: off the drawer, the bar and the capsule closes on
    /// the press; a secondary click closes anywhere off the plate; a plain left press on the bar
    /// closes on release unless it turned into a drag.
    private func handleDrawerClickAway(_ event: NSEvent, isLocal: Bool) {
        let point = Self.screenPoint(of: event)
        switch event.type {
        case .leftMouseDragged:
            // A chip drag crosses `tapSlop` before it starts, and this sees that very event: the
            // press is void before any spring can open the drawer under it.
            drawerBarPress.moved(to: point)
        case .leftMouseUp:
            guard drawerBarPress.released(at: point),
                  dragController.draggingPayload == nil,
                  drawerWantsOpen else { return }
            closeDrawer()
        default:
            drawerBarPress.cancel()
            guard dragController.draggingPayload == nil else { return }   // 拖动中不误关
            guard let drawer = drawerPanel, drawer.isVisible,
                  let dock   = dockPanel else { return }
            // The plate, not the window: its 40pt transparent border dismisses like any outside click.
            let verdict = DrawerClickAway.verdict(
                at: point, isSecondary: Self.isSecondaryClick(event),
                plate: Self.drawerPlateFrame(drawer.frame),
                barVisible: dock.frame.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding),
                capsule: capsulePanel?.frame ?? .null)
            switch verdict {
            case .ignore:
                break
            case .closeNow:
                closeDrawer()
            case .armBarPress:
                // A global press there went through the bar's clear pixels to another app: no
                // release will reach us, so it keeps the drawer as before.
                if isLocal { drawerBarPress.begin(at: point) }
            }
        }
    }

    /// Right button, or left button with Control — the bar's menu click (`AppMenuFragments`).
    static func isSecondaryClick(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    /// The event's own location in screen coordinates; global events carry it unconverted.
    static func screenPoint(of event: NSEvent) -> CGPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    func dragDropZones(for source: DragSource) -> [CGRect] {
        // 读**目标** frame：动画中 live frame 是中途值,会和视觉/落点短暂错位（Codex 二审 P2）。目标未初始化时退回 live。
        func target(_ stored: NSRect, _ live: NSRect?) -> NSRect? { stored != .zero ? stored : live }
        switch source {
        case .strip, .messaging:
            var zones: [CGRect] = []
            if let c = target(lastCapsuleTargetFrame, capsulePanel?.frame) {
                let inset = Self.shadowPadding - DrawerAppDrop.capsuleTolerance
                zones.append(c.insetBy(dx: inset, dy: inset))
            }
            if let drawer = drawerPanel, drawer.isVisible, let d = target(lastDrawerTargetFrame, drawer.frame) {
                // 抽屉只向上长：投放区**上沿拉到屏幕顶**,只认固定的底边+宽度,不随面板增高/缩短而变。
                // 否则"投放区尺寸→是否插空格→面板增高→投放区尺寸"成反馈环,空格闪烁、面板动画被高频打断
                // 而过冲向下（owner 2026-06-21"先向下扩展再上移"的真因）。
                let inset = Self.drawerPlateFrame(d)   // bottom = arrow tip, 3pt above the bar's top
                // 投放区向上延伸到与抽屉一致的顶部上限：避让菜单栏/刘海，但不避让原生 Dock。
                let top = Self.screenGeometry(panelCurrentScreen(panel: drawer)).topUsableY
                zones.append(CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: max(inset.height, top - inset.minY)))
            }
            return zones
        case .drawer:
            guard let d = target(lastDockTargetFrame, dockPanel?.frame) else { return [] }
            return [d.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)]
        case .folder:
            // 文件夹 chip 无投放区（canExternalDrop=false 本就不会查;区内重排/拖出移除/拖回打开
            // 全在 DockStripView 用 FolderChipDropZone 判定）。与 strip/drawer 收纳语义隔离（评审拍板）。
            return []
        }
    }

    // MARK: - 弹簧文件夹：拖卡悬停胶囊自动弹开抽屉

    /// strip 卡悬在胶囊上（抽屉关着时投放区只有胶囊）约 0.4s → 自动弹开抽屉,之后移进抽屉即接上精确定位;
    /// 不等它开、直接在胶囊松手仍按"收进末尾"。移开/松手取消定时器。
    func subscribeDragSpringLoad() {
        // 订阅 globalLocation（不是 isOverDropZone）——光标回到任务条上不改 isOverDropZone,
        // 必须靠位置才能实时收回抽屉（owner 2026-06-21：拖回任务条即收、再移回胶囊再开）。
        dragSpringSubscription = dragController.pointerMoves
            .combineLatest(dragController.$draggingPayload)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location, payload in
                self?.updateSpringLoad(location: location, payload: payload)
            }
    }

    func subscribeDragInhibitor() {
        dragInhibitorSubscription = dragController.$draggingPayload
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dragging in
                if dragging { self?.dismissWindowTitleTooltip(suppressCurrentUntilExit: true) }
                self?.setAutoHideInhibitor(.dragging, active: dragging)
            }
    }

    /// 视区命中：目标 frame 取可见内容区 + 6pt 迟滞（防胶囊/任务条交界反复横跳）。
    func springZone(_ target: NSRect) -> CGRect {
        target.insetBy(dx: Self.shadowPadding - 6, dy: Self.shadowPadding - 6)
    }

    /// The drawer's spring zone: its plate (the window has a 40pt transparent border, not the
    /// 20pt `springZone` assumes) with the same 6pt hysteresis.
    private func drawerSpringZone() -> CGRect {
        Self.drawerPlateFrame(lastDrawerTargetFrame).insetBy(dx: -6, dy: -6)
    }

    private func updateSpringLoad(location: CGPoint, payload: DragPayload?) {
        // 整段拖动只要从任务条发起就享受弹簧（转正成 .drawer 后仍认这个标记）。消息区 chip 同享：
        // 悬胶囊自动弹开抽屉才有精确收纳落点。
        if let p = payload, p.source == .strip || p.source == .messaging {
            dragOriginatedFromStrip = true; springDragBundleID = p.bundleID
        }

        // 松手兜底：弹簧开的抽屉若没把卡收进抽屉 → 收回。（实时悬停大多已处理,这里兜底。）
        if payload == nil {
            cancelSpringTimers()
            if drawerSpringOpened, let bid = springDragBundleID, !drawerStore.contains(bid) {
                closeDrawer()
            }
            drawerSpringOpened = false
            springDragBundleID = nil
            dragOriginatedFromStrip = false
            return
        }
        // 非任务条发起（纯抽屉内拖动 / 抽屉→任务条移回）不弹簧。
        guard dragOriginatedFromStrip else { cancelSpringTimers(); return }

        let inDrawer  = drawerWantsOpen && lastDrawerTargetFrame != .zero && drawerSpringZone().contains(location)
        let inCapsule = lastCapsuleTargetFrame != .zero && springZone(lastCapsuleTargetFrame).contains(location)

        if inDrawer || inCapsule {
            // 在抽屉或胶囊上 → 取消收回；关着且在胶囊上 → 起开抽屉定时器。
            springCloseTimer?.invalidate(); springCloseTimer = nil
            if !drawerWantsOpen {
                if inCapsule && springOpenTimer == nil { armSpringOpenTimer() }
            } else {
                springOpenTimer?.invalidate(); springOpenTimer = nil      // 已开 → 保持
            }
        } else {
            // 离开抽屉+胶囊（任务条上或空隙）→ 取消未触发的开；开着则**延迟**收回（owner 2026-06-22）。
            springOpenTimer?.invalidate(); springOpenTimer = nil
            if drawerWantsOpen && springCloseTimer == nil { armSpringCloseTimer() }
        }
    }

    func cancelSpringTimers() {
        springOpenTimer?.invalidate(); springOpenTimer = nil
        springCloseTimer?.invalidate(); springCloseTimer = nil
    }

    private func armSpringOpenTimer() {
        // .common 模式：拖动时主 run loop 在事件跟踪模式,scheduledTimer(默认 default) 拖动期间不触发。
        let timer = Timer(timeInterval: ExternalDragSpringLoad.openDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.springOpenDrawer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        springOpenTimer = timer
    }

    /// 离开抽屉+胶囊 ~0.35s 后才收回（短暂蹭过任务条/空隙不收）。到点仍在拖、仍开、仍在外才真关。
    private func armSpringCloseTimer() {
        let timer = Timer(timeInterval: ExternalDragSpringLoad.closeDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.springCloseDrawerIfStillOutside() }
        }
        RunLoop.main.add(timer, forMode: .common)
        springCloseTimer = timer
    }

    private func springCloseDrawerIfStillOutside() {
        springCloseTimer = nil
        guard dragOriginatedFromStrip, drawerWantsOpen else { return }
        let loc = dragController.globalLocation
        let inDrawer  = lastDrawerTargetFrame != .zero && drawerSpringZone().contains(loc)
        let inCapsule = lastCapsuleTargetFrame != .zero && springZone(lastCapsuleTargetFrame).contains(loc)
        guard !inDrawer, !inCapsule else { return }   // 又回到抽屉/胶囊 → 不关
        closeDrawer()
    }

    private func springOpenDrawer() {
        springOpenTimer = nil
        // 到点仍在拖、仍悬胶囊、抽屉仍关 → 弹开。用 dragOriginatedFromStrip + 重测胶囊命中（不用
        // isOverDropZone：转正成 .drawer 后它指的是任务条区,悬胶囊时为 false,会误拦重开。owner 2026-06-22）。
        let loc = dragController.globalLocation
        let inCapsule = lastCapsuleTargetFrame != .zero && springZone(lastCapsuleTargetFrame).contains(loc)
        guard dragController.draggingPayload != nil,
              dragOriginatedFromStrip,
              inCapsule,
              !drawerWantsOpen else { return }
        openDrawer()
        drawerSpringOpened = true   // openDrawer 把它置 false 了,这里标记是弹簧开的
        dragController.bringCarrierToFront()
    }
}
