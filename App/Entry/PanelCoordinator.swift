import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

/// 抽屉相关动画的共享时长，AppKit（面板 frame / alpha）和 SwiftUI（内容 scale/网格重排）都用它，
/// 让"面板尺寸滑动"和"内容内部动画"同时长、不错拍（Codex：v1 选面板为主 + 内容同参数）。
enum DrawerAnimation {
    static let duration: TimeInterval = 0.22
}

@MainActor
final class PanelCoordinator: NSObject {
    static let panelHeight: CGFloat = 52
    static let shadowPadding: CGFloat = 20
    static let windowHeight: CGFloat = 92 // 52 + 20*2

    private let runtime: AppRuntime
    private let drawerStore: DrawerStore
    private let messagingStore: MessagingAppStore
    private let launchFavoriteStore: LaunchFavoriteStore
    private let badgeStore: BadgeStore
    private let stripOrderStore: StripOrderStore
    private let drawerOrderStore: DrawerOrderStore
    private var dockPanel: NSPanel?
    private var drawerPanel: NSPanel?
    private var capsulePanel: NSPanel?
    /// 抽屉真正承载 SwiftUI 的 hosting view（抽屉 contentView 是普通 NSView 容器,故 fittingSize 要读这个）。
    private var drawerContentHost: NSView?
    /// 跨面板拖动（拖卡进抽屉 路线 C）的唯一权威：载体面板 + 鼠标监视器 + 落点收尾都在它里面。
    /// 必须在 setupDockPanel/setupCapsulePanel 之前建好，因为要注入进这两个面板的 hosting。
    private var dragController: DragController!
    private var drawerLocalMonitor: Any?
    private var drawerGlobalMonitor: Any?
    private var snapshotWidthSubscription: AnyCancellable?
    private var drawerStoreWidthSubscription: AnyCancellable?
    private var messagingStoreWidthSubscription: AnyCancellable?
    private var launchFavoriteStoreSubscription: AnyCancellable?
    private var dragSpringSubscription: AnyCancellable?
    private var springOpenTimer: Timer?
    /// 离开抽屉+胶囊后**延迟收回**的定时器（owner 2026-06-22：要延迟,不要一蹭到任务条就关）。
    private var springCloseTimer: Timer?
    /// 本次拖动是否**从任务条发起**。任务条卡进抽屉体会被"转正"成 `.drawer` 来源（见 DragController），
    /// 但弹簧（开/延迟收/重开）整段拖动都该生效,所以认这个、不认实时 source（owner 2026-06-22）。
    private var dragOriginatedFromStrip = false
    /// 抽屉**逻辑**开关态（不看 isVisible——淡出动画期间面板还可见但逻辑上已关）。toggle/弹簧/可打断关都看它。
    private var drawerWantsOpen = false
    /// 这次抽屉是不是**弹簧**(拖动悬停)打开的。若是、且松手时这张卡没进抽屉(又拖回任务条) → 自动收回。
    private var drawerSpringOpened = false
    /// 正在拖的 strip 卡 bundleID,松手时用它判断有没有收进抽屉。
    private var springDragBundleID: String?
    private var lastDesiredWidth: CGFloat = 0
    private var lastDrawerSize: CGSize = CGSize(width: 210, height: 60)
    /// 目标 frame 驱动布局：每次 layoutPanels 算齐三个目标并存这里。drop zone 命中、开抽屉定位都读**目标**
    /// 而非 live frame——动画中 live frame 是中途值,会和视觉/逻辑短暂不一致（Codex 二审 P2）。
    private var lastDockTargetFrame: NSRect = .zero
    private var lastCapsuleTargetFrame: NSRect = .zero
    private var lastDrawerTargetFrame: NSRect = .zero
    /// 首帧布局强制瞬时（面板刚建好,别从初始/原点位置滑过来）。
    private var didInitialLayout = false
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "dock-panel")

    private var isHiddenForFullscreen = false
    private var fullscreenReconcileTimer: Timer?

    init(runtime: AppRuntime, drawerStore: DrawerStore, messagingStore: MessagingAppStore, launchFavoriteStore: LaunchFavoriteStore, badgeStore: BadgeStore, stripOrderStore: StripOrderStore, drawerOrderStore: DrawerOrderStore) {
        self.runtime = runtime
        self.drawerStore = drawerStore
        self.messagingStore = messagingStore
        self.launchFavoriteStore = launchFavoriteStore
        self.badgeStore = badgeStore
        self.stripOrderStore = stripOrderStore
        self.drawerOrderStore = drawerOrderStore
        super.init()
    }

    func start() {
        setupDragController()
        setupDockPanel()
        setupCapsulePanel()
        subscribeSnapshotWidth()
        subscribeDrawerStoreWidth()
        subscribeMessagingStoreWidth()
        subscribeLaunchFavoriteStore()
        subscribeDragSpringLoad()
        setupFullscreenMonitor()
        setupHoverDiagnostics()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        fullscreenReconcileTimer?.invalidate()
        hoverPollTimer?.invalidate()
        springOpenTimer?.invalidate()
        springCloseTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func toggleDrawer() {
        if drawerWantsOpen { closeDrawer() } else { openDrawer() }
    }

    private func openDrawer() {
        guard let mainPanel = dockPanel, capsulePanel != nil else { return }
        drawerWantsOpen = true
        drawerSpringOpened = false   // 默认手动开；弹簧路径在 springOpenDrawer 里再置 true

        if drawerPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: lastDrawerSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.isFloatingPanel = true
            panel.isMovable = false
            panel.isOpaque = false
            panel.backgroundColor = NSColor(white: 1.0, alpha: 0.0)
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            drawerPanel = panel
        }
        guard let panel = drawerPanel else { return }

        let screen = panelCurrentScreen(panel: mainPanel)
        let vf = screen.visibleFrame
        // 用胶囊**目标** frame 定位（不读 live：用户可能在任务条宽度动画中触发弹簧开抽屉,Codex 二审 P1）。
        let capsuleRef = lastCapsuleTargetFrame == .zero ? (capsulePanel?.frame ?? .zero) : lastCapsuleTargetFrame
        // 抽屉最大内容高度 = 胶囊上方锚点 → 屏幕上沿的可用高度。超出由 DrawerView 内部滚动,
        // 绝不靠下压底边来塞下（否则压向胶囊/任务条 = 重叠,Codex 二审第 4 点）。
        let drawerBottomY = capsuleRef.maxY - Self.shadowPadding + 8
        let maxContentHeight = max(120, (vf.maxY - drawerBottomY) - 2 * Self.shadowPadding)

        // 每次打开都换一份新内容视图 → DrawerView 的 onAppear 重新触发淡入缩放,并拿到当前 maxContentHeight。
        let hosting = NSHostingView(rootView: DrawerView(maxContentHeight: maxContentHeight)
            .environmentObject(runtime).environmentObject(drawerStore).environmentObject(messagingStore)
            .environmentObject(launchFavoriteStore).environmentObject(drawerOrderStore).environmentObject(dragController))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor

        let initialFrame = drawerTargetFrame(forCapsule: capsuleRef, size: lastDrawerSize, on: screen)
        lastDrawerTargetFrame = initialFrame

        // 关键：用普通 NSView 当 contentView,hosting 作为子视图自适应填充——**不让 NSHostingView 直接当 contentView**。
        // 否则内容变高时 macOS 会用内容尺寸**顶边锚定、向下撑大**窗口（日志实测 cur(y=24 h=194)、top 恒=218），
        // 我们的布局随后才把它纠正成底边锚定向上长（y=68）——这一前一后打架 = owner 看到的"先向下扩展再上移"
        // 的真因（2026-06-22）。普通 NSView 不把子视图内容尺寸传给窗口,窗口高度只由 layoutPanels/setFrames 控制;
        // fittingSize 改读 hosting（存进 drawerContentHost）。
        let container = NSView(frame: NSRect(origin: .zero, size: initialFrame.size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        drawerContentHost = hosting

        panel.setFrame(initialFrame, display: false)
        if !panel.isVisible { panel.alphaValue = 0 }   // 重开中途若仍可见,从当前 alpha 续上,不跳回 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DrawerAnimation.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
        }
        // 弹出后量真实 fittingSize 重新布局（瞬时,刚弹出不滑）。
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.relayout(animated: false)
            }
        }

        drawerLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.dismissDrawerIfOutside()
            return event
        }
        drawerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dismissDrawerIfOutside()
        }
    }

    /// 可打断淡出关闭：立即摘监视器、动画 alpha→0,completion 里确认仍要关才 orderOut（淡出中又打开则不关）。
    private func closeDrawer() {
        guard drawerWantsOpen else { return }
        drawerWantsOpen = false
        drawerSpringOpened = false
        if let m = drawerLocalMonitor  { NSEvent.removeMonitor(m); drawerLocalMonitor  = nil }
        if let m = drawerGlobalMonitor { NSEvent.removeMonitor(m); drawerGlobalMonitor = nil }
        guard let panel = drawerPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DrawerAnimation.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.drawerWantsOpen else { return }   // 淡出中又开了 → 别 orderOut
            panel.orderOut(nil)
        })
    }

    private func dismissDrawerIfOutside() {
        guard let drawer = drawerPanel, drawer.isVisible,
              let dock   = dockPanel else { return }
        let mouse = NSEvent.mouseLocation
        guard !drawer.frame.contains(mouse),
              !dock.frame.contains(mouse),
              !(capsulePanel?.frame.contains(mouse) ?? false) else { return }
        closeDrawer()
    }

    // MARK: - Drag Controller (拖卡进抽屉 路线 C)

    private func setupDragController() {
        dragController = DragController(
            drawerStore: drawerStore,
            dropZonesProvider: { [weak self] source in self?.dragDropZones(for: source) ?? [] },
            screenProvider: { [weak self] in self?.carrierTargetScreen() ?? (NSScreen.main ?? NSScreen.screens[0]) },
            carrierFactory: { [runtime = self.runtime,
                               drawerStore = self.drawerStore,
                               messagingStore = self.messagingStore,
                               launchFavoriteStore = self.launchFavoriteStore] controller in
                NSHostingView(rootView: DragCarrierView(controller: controller)
                    .environmentObject(runtime)
                    .environmentObject(drawerStore)
                    .environmentObject(messagingStore)
                    .environmentObject(launchFavoriteStore))
            }
        )
    }

    /// 投放候选区（屏幕坐标），按拖动来源分：
    /// - `.strip`（任务条卡找收纳目标）= 胶囊可见内容区 + 8pt 容错（胶囊 frame 含 shadowPadding=20
    ///   透明边，减 20 得 52×52 可见区，再外扩 8 容错，不能更宽——胶囊紧挨任务条，太宽会"拖到附近就被收走"）；
    ///   抽屉打开时叠加抽屉可见内容区。
    /// - `.drawer`（抽屉图标找移回目标）= 任务条 dock 面板可见内容区（减 shadowPadding）。
    private func dragDropZones(for source: DragSource) -> [CGRect] {
        // 读**目标** frame：动画中 live frame 是中途值,会和视觉/落点短暂错位（Codex 二审 P2）。目标未初始化时退回 live。
        func target(_ stored: NSRect, _ live: NSRect?) -> NSRect? { stored != .zero ? stored : live }
        switch source {
        case .strip:
            var zones: [CGRect] = []
            if let c = target(lastCapsuleTargetFrame, capsulePanel?.frame) {
                zones.append(c.insetBy(dx: Self.shadowPadding - 8, dy: Self.shadowPadding - 8))
            }
            if let drawer = drawerPanel, drawer.isVisible, let d = target(lastDrawerTargetFrame, drawer.frame) {
                // 抽屉只向上长：投放区**上沿拉到屏幕顶**,只认固定的底边+宽度,不随面板增高/缩短而变。
                // 否则"投放区尺寸→是否插空格→面板增高→投放区尺寸"成反馈环,空格闪烁、面板动画被高频打断
                // 而过冲向下（owner 2026-06-21"先向下扩展再上移"的真因）。
                let inset = d.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)
                let top = panelCurrentScreen(panel: drawer).visibleFrame.maxY
                zones.append(CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: max(inset.height, top - inset.minY)))
            }
            return zones
        case .drawer:
            guard let d = target(lastDockTargetFrame, dockPanel?.frame) else { return [] }
            return [d.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)]
        }
    }

    private func carrierTargetScreen() -> NSScreen {
        if let dock = dockPanel { return panelCurrentScreen(panel: dock) }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - 弹簧文件夹：拖卡悬停胶囊自动弹开抽屉

    /// strip 卡悬在胶囊上（抽屉关着时投放区只有胶囊）约 0.4s → 自动弹开抽屉,之后移进抽屉即接上精确定位;
    /// 不等它开、直接在胶囊松手仍按"收进末尾"。移开/松手取消定时器。
    private func subscribeDragSpringLoad() {
        // 订阅 globalLocation（不是 isOverDropZone）——光标回到任务条上不改 isOverDropZone,
        // 必须靠位置才能实时收回抽屉（owner 2026-06-21：拖回任务条即收、再移回胶囊再开）。
        dragSpringSubscription = dragController.$globalLocation
            .combineLatest(dragController.$draggingPayload)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location, payload in
                self?.updateSpringLoad(location: location, payload: payload)
            }
    }

    /// 视区命中：目标 frame 取可见内容区 + 6pt 迟滞（防胶囊/任务条交界反复横跳）。
    private func springZone(_ target: NSRect) -> CGRect {
        target.insetBy(dx: Self.shadowPadding - 6, dy: Self.shadowPadding - 6)
    }

    private func updateSpringLoad(location: CGPoint, payload: DragPayload?) {
        // 整段拖动只要从任务条发起就享受弹簧（转正成 .drawer 后仍认这个标记）。
        if let p = payload, p.source == .strip { dragOriginatedFromStrip = true; springDragBundleID = p.bundleID }

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

        let inDrawer  = drawerWantsOpen && lastDrawerTargetFrame != .zero && springZone(lastDrawerTargetFrame).contains(location)
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

    private func cancelSpringTimers() {
        springOpenTimer?.invalidate(); springOpenTimer = nil
        springCloseTimer?.invalidate(); springCloseTimer = nil
    }

    private func armSpringOpenTimer() {
        // .common 模式：拖动时主 run loop 在事件跟踪模式,scheduledTimer(默认 default) 拖动期间不触发。
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.springOpenDrawer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        springOpenTimer = timer
    }

    /// 离开抽屉+胶囊 ~0.35s 后才收回（短暂蹭过任务条/空隙不收）。到点仍在拖、仍开、仍在外才真关。
    private func armSpringCloseTimer() {
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.springCloseDrawerIfStillOutside() }
        }
        RunLoop.main.add(timer, forMode: .common)
        springCloseTimer = timer
    }

    private func springCloseDrawerIfStillOutside() {
        springCloseTimer = nil
        guard dragOriginatedFromStrip, drawerWantsOpen else { return }
        let loc = dragController.globalLocation
        let inDrawer  = lastDrawerTargetFrame != .zero && springZone(lastDrawerTargetFrame).contains(loc)
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

    private func setupDockPanel() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let s = screen.frame

        let panel = NSPanel(
            contentRect: NSRect(x: s.minX, y: s.minY + Self.bottomGap - Self.shadowPadding, width: s.width, height: Self.windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 1.0, alpha: 0.0)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: DockStripView().environmentObject(runtime).environmentObject(drawerStore).environmentObject(messagingStore).environmentObject(launchFavoriteStore).environmentObject(badgeStore).environmentObject(stripOrderStore).environmentObject(dragController))
        hosting.autoresizingMask = [.width, .height]
        // Prevent NSHostingView from adding its own opaque background over the blur
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        panel.contentView = hosting
        panel.orderFrontRegardless()
        dockPanel = panel
    }

    private func setupCapsulePanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: Self.capsuleWidth + Self.shadowPadding * 2, height: Self.capsuleWidth + Self.shadowPadding * 2)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 1.0, alpha: 0.0)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        let hosting = NSHostingView(rootView:
            DrawerCapsuleButton { [weak self] in self?.toggleDrawer() }
                .environmentObject(runtime)
                .environmentObject(drawerStore)
                .environmentObject(dragController)
        )
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        panel.contentView = hosting
        panel.orderFrontRegardless()
        capsulePanel = panel
    }

    // MARK: - Content Width via fittingSize

    private func subscribeSnapshotWidth() {
        snapshotWidthSubscription = runtime.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Defer one run-loop cycle so SwiftUI finishes layout before we read fittingSize
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)   // layoutPanels 内含抽屉重定位
                }
            }
    }

    private func subscribeDrawerStoreWidth() {
        drawerStoreWidthSubscription = drawerStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.syncDrawerOrder()
                    self?.relayout(animated: true)
                }
            }
    }

    /// 抽屉显示顺序层按成员全集（收纳 ∪ 固定）收敛。收纳/固定名单任一变化都同步一次，
    /// 即便抽屉没开也要同步——这样新收纳的 app 进来时已在顺序末尾就位，不丢已排好的相对序。
    private func syncDrawerOrder() {
        let members = drawerStore.bundleIDs + launchFavoriteStore.bundleIDs.filter { !drawerStore.contains($0) }
        drawerOrderStore.sync(members: members)
    }

    private func subscribeMessagingStoreWidth() {
        messagingStoreWidthSubscription = messagingStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)
                }
            }
    }

    /// Launch favorites never change the strip's content (a favorite stays on the
    /// strip while running) — relayout 的任务条宽度会算成同值（dock/胶囊动画 no-op），只有打开的抽屉尺寸会变。
    private func subscribeLaunchFavoriteStore() {
        launchFavoriteStoreSubscription = launchFavoriteStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.syncDrawerOrder()
                    self?.relayout(animated: true)
                }
            }
    }

    // MARK: - 目标 frame 驱动布局
    //
    // Codex 二审根因：动画后若"读上一个面板正在动画的 live frame 来定位下一个"，读到的是动画起点的旧值
    // → 胶囊按旧任务条、抽屉按旧胶囊定位 → 任务条变宽后错位、抽屉与任务条重叠。修法：一次算齐三个**目标**
    // frame（纯函数,互不读 live frame），三面板在**同一个动画组**里各自滑向目标。

    private static let layoutAnimationDuration: TimeInterval = DrawerAnimation.duration

    /// 任务条目标 frame（按内容宽度、居中、限宽）。
    private func dockTargetFrame(contentWidth: CGFloat, on screen: NSScreen) -> NSRect {
        let maxWidth = screen.visibleFrame.width - 2 * (Self.outerMargin + Self.capsuleGap + Self.capsuleWidth)
        let panelWidth = max(min(contentWidth, maxWidth), 120)
        return centeredPanelFrame(panelWidth: panelWidth, screen: screen)
    }

    /// 胶囊目标 frame（贴任务条右边、纵向居中）。只依赖传入的 dock **目标** frame。
    private func capsuleTargetFrame(forDock dockFrame: NSRect, on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let rawX = dockFrame.maxX - Self.shadowPadding + Self.capsuleGap
        let rawY = dockFrame.minY + Self.shadowPadding + (Self.panelHeight - Self.capsuleWidth) / 2
        let clampedX = min(max(rawX, vf.minX), vf.maxX - Self.capsuleWidth)
        let clampedY = min(max(rawY, vf.minY), vf.maxY - Self.capsuleWidth)
        return NSRect(x: clampedX - Self.shadowPadding, y: clampedY - Self.shadowPadding,
                      width: Self.capsuleWidth + Self.shadowPadding * 2, height: Self.capsuleWidth + Self.shadowPadding * 2)
    }

    /// 抽屉目标 frame（右边贴胶囊右边、**底边硬锚在胶囊上方、向上长**）。只依赖传入的胶囊 **目标** frame + 抽屉尺寸。
    /// 关键：底边绝不下移——超过上方可用空间就**封顶高度**（内容由 DrawerView 内部滚动），
    /// 绝不靠"把底边往下压"来塞下，否则压到胶囊/任务条（owner 2026-06-21 报图）。
    private func drawerTargetFrame(forCapsule capsuleFrame: NSRect, size: CGSize, on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let bottom = max(capsuleFrame.maxY - Self.shadowPadding + 8, vf.minY)   // 底边锚点,固定不动
        let height = min(size.height, max(120, vf.maxY - bottom))               // 超出上方可用空间 → 封顶
        let rawX = capsuleFrame.maxX - size.width
        let clampedX = min(max(rawX, vf.minX), vf.maxX - size.width)
        return NSRect(x: clampedX, y: bottom, width: size.width, height: height)
    }

    /// 统一布局入口：算齐三个目标 frame、存好（给 drop zone / 开抽屉读），三面板同组动画到目标。
    /// 开屏/切屏/多屏悬停传 animated:false；内容变化、收纳/移回、抽屉尺寸变化传 animated:true。
    private func layoutPanels(contentWidth: CGFloat, on screen: NSScreen, animated: Bool) {
        guard let dock = dockPanel, let capsule = capsulePanel else { return }
        let anim = animated && didInitialLayout   // 首帧瞬时,别从初始位置滑过来
        didInitialLayout = true

        let dockT = dockTargetFrame(contentWidth: contentWidth, on: screen)
        let capsuleT = capsuleTargetFrame(forDock: dockT, on: screen)
        lastDockTargetFrame = dockT
        lastCapsuleTargetFrame = capsuleT

        var pairs: [(NSPanel, NSRect)] = [(dock, dockT), (capsule, capsuleT)]
        if let drawer = drawerPanel, drawer.isVisible, let hosting = drawerContentHost {
            let fitting = hosting.fittingSize
            let drawerSize = CGSize(width: max(fitting.width, 60), height: max(fitting.height, 60))
            lastDrawerSize = drawerSize
            let drawerT = drawerTargetFrame(forCapsule: capsuleT, size: drawerSize, on: screen)
            lastDrawerTargetFrame = drawerT
            pairs.append((drawer, drawerT))
        }
        setFrames(pairs, animated: anim)
    }

    /// 量当前内容宽度后布局（内容变化的统一入口）。
    private func relayout(animated: Bool) {
        guard let panel = dockPanel, let hosting = panel.contentView else { return }
        let contentWidth = hosting.fittingSize.width - 2 * Self.shadowPadding
        lastDesiredWidth = contentWidth
        layoutPanels(contentWidth: contentWidth, on: panelCurrentScreen(panel: panel), animated: animated)
    }

    /// 三面板同一个动画组提交,共用一条时间轴（Codex 二审 P2：避免各跑各的时间轴抖动）。
    private func setFrames(_ pairs: [(NSPanel, NSRect)], animated: Bool) {
        guard animated else { for (p, f) in pairs { p.setFrame(f, display: true) }; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.layoutAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (p, f) in pairs { p.animator().setFrame(f, display: true) }
        }
    }

    @objc private func screenParametersChanged() {
        dragController?.cancelDrag()   // 切屏/分辨率变 → 取消进行中的跨面板拖动，免得载体留在旧屏坐标
        guard dockPanel != nil else { return }
        relayout(animated: false)      // 切屏瞬时,不滑
        if NSScreen.screens.count > 1 {
            startHoverPollTimer()
        } else {
            stopHoverPollTimer()
        }
    }

    // MARK: - Fullscreen Monitor

    private func setupFullscreenMonitor() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleSpaceChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleAppActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        fullscreenReconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fullscreenReconcileIfNeeded() }
        }
        fullscreenReconcileTimer?.tolerance = 0.5
    }

    @objc private func handleSpaceChange() {
        // Sync CG check: fires before the panel has a chance to appear, no AX = no main-thread risk
        let cgFullscreen = checkFullscreenViaCGSync()
        applyFullscreenVisibility(cgFullscreen)
        // Async AX secondary check: catches edge cases CG misses (e.g. games on a non-zero layer)
        triggerAsyncFullscreenCheck()
    }

    @objc private func handleAppActivated() {
        triggerAsyncFullscreenCheck()
    }

    // MARK: - Sync CG fullscreen probe (main thread only, no AX)

    private func checkFullscreenViaCGSync() -> Bool {
        guard let panel = dockPanel else { return false }
        let screen = panelCurrentScreen(panel: panel)
        let screenCGFrame = Self.toCGRect(screen)
        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ourPID else { continue }
            guard let dict = info[kCGWindowBounds as String] as? [String: Any],
                  let cgBounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            // Only consider windows on the panel's screen (must overlap significantly)
            guard cgBounds.intersects(screenCGFrame), cgBounds.width > screenCGFrame.width * 0.7 else { continue }
            // Frontmost matching window found — check if it fills the screen
            let t: CGFloat = 8
            return abs(cgBounds.width  - screenCGFrame.width)  < t
                && abs(cgBounds.height - screenCGFrame.height) < t
                && abs(cgBounds.minX   - screenCGFrame.minX)   < t
                && abs(cgBounds.minY   - screenCGFrame.minY)   < t
        }
        return false
    }

    // MARK: - Async AX fullscreen probe (secondary / fallback)

    private func triggerAsyncFullscreenCheck() {
        guard let panel = dockPanel else { return }
        // Convert to CG coords on main thread; AX kAXPositionAttribute also uses CG (top-left origin)
        let screenCGFrame = Self.toCGRect(panelCurrentScreen(panel: panel))
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task.detached { [weak self] in
            let fullscreen = Self.detectFullscreenViaAX(pid: frontPID, screenCGFrame: screenCGFrame)
            await MainActor.run { [weak self] in self?.applyFullscreenVisibility(fullscreen) }
        }
    }

    private func fullscreenReconcileIfNeeded() {
        guard isHiddenForFullscreen else { return }
        triggerAsyncFullscreenCheck()
    }

    private func applyFullscreenVisibility(_ isFullscreen: Bool) {
        guard isFullscreen != isHiddenForFullscreen else { return }
        isHiddenForFullscreen = isFullscreen
        guard let panel = dockPanel else { return }
        if isFullscreen {
            panel.orderOut(nil)
            logger.info("[fullscreen] panel hidden")
        } else {
            panel.orderFront(nil)
            logger.info("[fullscreen] panel restored")
        }
    }

    private func panelCurrentScreen(panel: NSPanel) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // AppKit frame (bottom-left origin) → CG/Quartz frame (top-left origin of primary screen)
    private static func toCGRect(_ screen: NSScreen) -> CGRect {
        let primaryH = NSScreen.main?.frame.height ?? 0
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
    }

    nonisolated private static func detectFullscreenViaAX(pid: pid_t?, screenCGFrame: CGRect) -> Bool {
        guard let pid else { return false }
        let reader = AXWindowReader()
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.5)

        guard let focused = reader.elementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement) else {
            return false
        }
        _ = AXUIElementSetMessagingTimeout(focused, 0.5)

        let isAXFullscreen = reader.boolAttribute("AXFullScreen" as CFString, from: focused, maxAttempts: 1) ?? false
        // AX kAXPositionAttribute uses CG coordinates (top-left origin) — matches screenCGFrame directly
        let windowFrame = reader.frame(of: focused, maxAttempts: 1)

        if isAXFullscreen {
            guard let wf = windowFrame else { return true }
            return wf.intersects(screenCGFrame) && wf.width > screenCGFrame.width * 0.7
        }

        // Fallback: frame ≈ full screen (games / HTML5 that skip the AXFullScreen flag)
        if let wf = windowFrame {
            let t: CGFloat = 8
            return abs(wf.width  - screenCGFrame.width)  < t
                && abs(wf.height - screenCGFrame.height) < t
                && abs(wf.minX   - screenCGFrame.minX)   < t
                && abs(wf.minY   - screenCGFrame.minY)   < t
        }

        return false
    }

    // MARK: - HoverSwitch Diagnostics

    private let hoverLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "HoverSwitch")
    private static let hoverHotZone: CGFloat = 4.0
    private static let hoverVerboseLogging = false
    private var hoverPollTimer: Timer?
    private var hoverLastScreenIndex: Int? = nil
    private var hoverLastInHotZone: Bool? = nil

    private func setupHoverDiagnostics() {
        if Self.hoverVerboseLogging { logScreenMap() }
        guard NSScreen.screens.count > 1 else { return }
        startHoverPollTimer()
    }

    private func startHoverPollTimer() {
        guard hoverPollTimer == nil else { return }
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollMousePosition() }
        }
        hoverPollTimer?.tolerance = 0.01
    }

    private func stopHoverPollTimer() {
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
    }

    private func logScreenMap() {
        let screens = NSScreen.screens
        for (i, screen) in screens.enumerated() {
            let f = screen.frame
            let vf = screen.visibleFrame
            hoverLogger.info("screen-map index=\(i, privacy: .public) name=\(screen.localizedName, privacy: .public) frame=(\(f.minX, privacy: .public),\(f.minY, privacy: .public),\(f.width, privacy: .public),\(f.height, privacy: .public)) visibleFrame=(\(vf.minX, privacy: .public),\(vf.minY, privacy: .public),\(vf.width, privacy: .public),\(vf.height, privacy: .public)) isMain=\(screen == NSScreen.main, privacy: .public) isScreens0=\(i == 0, privacy: .public)")
        }
    }

    private func pollMousePosition() {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens

        var curScreenIdx: Int? = nil
        var curScreen: NSScreen? = nil
        for (i, s) in screens.enumerated() {
            if s.frame.contains(mouse) { curScreenIdx = i; curScreen = s; break }
        }

        let dyFromBottom: CGFloat
        let inHotZone: Bool
        if let s = curScreen {
            dyFromBottom = mouse.y - s.frame.minY
            inHotZone = dyFromBottom <= Self.hoverHotZone
        } else {
            dyFromBottom = -1
            inHotZone = false
        }

        guard curScreenIdx != hoverLastScreenIndex || inHotZone != hoverLastInHotZone else { return }
        hoverLastScreenIndex = curScreenIdx
        hoverLastInHotZone = inHotZone

        if Self.hoverVerboseLogging {
            let panelScreenIdx = dockPanel.map { p -> String in
                let ps = panelCurrentScreen(panel: p)
                return screens.firstIndex(of: ps).map { "\($0)" } ?? "?"
            } ?? "nil"
            if let s = curScreen, let idx = curScreenIdx {
                let f = s.frame
                let vf = s.visibleFrame
                hoverLogger.info("cursor screen=\(idx, privacy: .public) name=\(s.localizedName, privacy: .public) mouse=(\(mouse.x, privacy: .public),\(mouse.y, privacy: .public)) frame=(\(f.minX, privacy: .public),\(f.minY, privacy: .public),\(f.width, privacy: .public),\(f.height, privacy: .public)) visibleFrame=(\(vf.minX, privacy: .public),\(vf.minY, privacy: .public),\(vf.width, privacy: .public),\(vf.height, privacy: .public)) dyFromBottom=\(dyFromBottom, privacy: .public) inHotZone=\(inHotZone, privacy: .public) panelScreen=\(panelScreenIdx, privacy: .public)")
            } else {
                hoverLogger.info("cursor screen=none mouse=(\(mouse.x, privacy: .public),\(mouse.y, privacy: .public)) dyFromBottom=none inHotZone=false panelScreen=\(panelScreenIdx, privacy: .public)")
            }
        }

        // Hover switch: cursor just entered hot zone of a different screen → move panel there
        if inHotZone, let targetScreen = curScreen, let panel = dockPanel {
            let panelScreen = panelCurrentScreen(panel: panel)
            if targetScreen != panelScreen {
                let fromIdx = screens.firstIndex(of: panelScreen).map { "\($0)" } ?? "?"
                let toIdx = screens.firstIndex(of: targetScreen).map { "\($0)" } ?? "?"
                let actualWidth = max(min(lastDesiredWidth, targetScreen.visibleFrame.width - 2 * Self.outerMargin), 120)
                layoutPanels(contentWidth: lastDesiredWidth, on: targetScreen, animated: false)   // 多屏切换瞬时
                hoverLogger.info("switch toScreen=\(toIdx, privacy: .public) name=\(targetScreen.localizedName, privacy: .public) actualWidth=\(actualWidth, privacy: .public) fromScreen=\(fromIdx, privacy: .public)")
            }
        }
    }

    // MARK: - Frame Helpers

    private static let bottomGap: CGFloat = 8
    private static let outerMargin: CGFloat = 12
    private static let capsuleWidth: CGFloat = 52
    private static let capsuleGap: CGFloat = 8

    private func centeredPanelFrame(panelWidth: CGFloat, screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let x = vf.minX + (vf.width - panelWidth) / 2
        return NSRect(x: x - Self.shadowPadding, y: screen.frame.minY + Self.bottomGap - Self.shadowPadding, width: panelWidth + Self.shadowPadding * 2, height: Self.windowHeight)
    }
}
