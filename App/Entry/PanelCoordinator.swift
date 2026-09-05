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

/// 弹窗/抽屉「面板开合 + 内容入场」动效（快出缓停，贴原生 Stacks 手感，owner 2026-07-06）。
/// 任务条宽度/面板 frame 布局动画仍用 DrawerAnimation.duration=0.22，两组时长不得合并（AGENTS）。
enum PopoverAnimation {
    static let openDuration: TimeInterval = 0.18
    static let closeDuration: TimeInterval = 0.13
    /// 强 ease-out：起步快、收尾缓，原生弹出手感。
    static func curve() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
    }
}

@MainActor
final class PanelCoordinator: NSObject {
    /// 面板几何随尺寸档位变，所以这些**不能再是 static**：换档时要跟着 store 走。
    /// `shadowPadding` 例外——它固定 20，视图侧（抽屉、两个弹窗）继续静态引用。
    var layoutMetrics: PanelLayoutMetrics { settingsStore.dockSize.metrics }
    var panelHeight: CGFloat { layoutMetrics.panelHeight }
    var windowHeight: CGFloat { layoutMetrics.windowHeight }
    var capsuleWidth: CGFloat { layoutMetrics.capsuleWidth }
    /// 玻璃背景窗口的圆角。必须与 SwiftUI 侧任务条底板用同一个值，否则窗口模糊会在
    /// 玻璃的圆角外露出方角。两边共同的来源是 `DockShape.panelCornerRadius`。
    /// 五个悬浮面板走不走原生 Liquid Glass —— **单一来源**。
    ///
    /// 判据就是「任务条的玻璃合成建成功了没有」：背景窗口在 `setupDockPanel` 里建，
    /// 抽屉 / 两个弹窗都是按需懒建的，创建时这个值早已确定。五个面板共用同一个判断，
    /// 才不会出现「条是玻璃、紧挨着的胶囊还是毛玻璃」。
    var usesLiquidGlass: Bool { dockGlassBackgroundPanel != nil }

    /// 建一块悬浮面板。**玻璃开着时必须用 `DockLiquidGlassPanel`，五块面板一个都不能漏。**
    ///
    /// Liquid Glass 的「活跃」外观是按**窗口**的 key / main / active 状态判的，而我们所有面板
    /// 都是 `.nonactivatingPanel`、永远不会成为 key —— 用普通 `NonConstrainingPanel` 时玻璃
    /// 退到「非活跃」那一档，渲染成一块几乎不透光的奶白板。`DockLiquidGlassPanel` 覆写那五个
    /// 私有的外观判定，把窗口一直报成活跃。
    ///
    /// 2026-08-17 之前**只有任务条**用了这个子类，于是抽屉 / 胶囊 / 两个弹窗 / 气泡跟它不是
    /// 一种材质（owner 报「抽屉区好像也不是液态玻璃」）。黑 / 白靶窗实测的透光量：
    ///
    /// | | 任务条 | 胶囊 | 抽屉 |
    /// |---|---|---|---|
    /// | 修复前 | 145 | **172** | **170** |
    /// | 修复后 | 145 | 149 | 148 |
    ///
    /// 差 25–27 级 → 收敛到 4 级以内。**别用「同一块背景上看着差不多」当验证**：
    /// 黑白条纹靶上两者都读中灰，我就是这么误判过一次「胶囊和任务条一致」。
    /// 判据必须是**透光量**（同一块面板在纯黑与纯白背景上的读数之差）。
    ///
    /// SwiftUI 侧那两句 `.materialActiveAppearance(.active)` / `.environment(\.appearsActive,)`
    /// **顶不掉这一层**——它们管的是视图环境，窗口状态得在窗口上解决。
    /// 实验开关：`DOCK_PANEL_LEVEL=<raw>` 覆盖三块任务条面板的窗口层级（默认 .floating=3）。
    /// 用途：验证「层级足够高的窗口（系统 Dock=20、菜单栏更高）是否免于被 WindowServer
    /// 烤进桌面滑动的过渡快照」——2026-08-30 连拍实锤了灰罩 = 条被烤进两侧快照后叠加滑动。
    static let panelLevelOverride: NSWindow.Level? = DebugSwitch.panelLevel.value().flatMap(Int.init).map { NSWindow.Level(rawValue: $0) }

    var taskbarPlateCornerRadius: CGFloat {
        DockShape.panelCornerRadius * settingsStore.dockSize.scale
    }
    static let shadowPadding: CGFloat = PanelLayoutMetrics.shadowPadding

    let runtime: AppRuntime
    let drawerStore: DrawerStore
    let messagingStore: MessagingAppStore
    let badgeStore: BadgeStore
    let stripOrderStore: StripOrderStore
    let drawerOrderStore: DrawerOrderStore
    let settingsStore: AppSettingsStore
    let pinnedFolderStore: PinnedFolderStore
    let folderCoverStore: PinnedFolderCoverStore
    let shelfStore: ShelfStore
    let keptAppStore: KeptAppStore
    let runningApplicationStore: RunningApplicationStore
    let appMembershipController: AppMembershipController
    /// 外部文件移入固定文件夹的唯一执行队列：资格判断与磁盘操作都按投放批次串行。
    let fileDropQueue = DispatchQueue(label: "com.caye.macosdockcc.v2.folder-drop", qos: .userInitiated)
    /// 文件夹 chip / 中转格右键「添加文件夹…」入口（AppDelegate 注入，NSOpenPanel 归它管）。
    var onAddFolder: () -> Void = {}
    /// 右键任务条 / 胶囊时弹出钨极菜单。菜单归 `StatusMenuController` 持有，这里只转发事件——
    /// 正常运行时应用是 `.accessory`（没有菜单栏，也就没有 ⌘,），状态栏图标一旦被挤掉或被刘海挡住，
    /// 这就是打开设置的唯一后路。
    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)?
    var dockPanel: NSPanel?
    var dockGlassBackgroundPanel: NonConstrainingPanel?
    var dockGlassBackgroundView: DockTaskbarLiquidGlassBackgroundView?
    /// 主任务条的 SwiftUI 承载器。窗口 frame 归 PanelCoordinator，内容尺寸只从这里读取。
    var dockContentHost: ManualPanelHost?
    var drawerPanel: NSPanel?
    var capsulePanel: NSPanel?
    /// 胶囊的 SwiftUI 承载器。胶囊宽高固定（`capsuleWidth`），当前没人读它的 `fittingSize`——
    /// 但仍然**强持有**而不是 `_ =` 丢弃：丢弃后只靠视图层级间接留住容器，哪天给
    /// `ManualPanelHost` 加了 `deinit` 清理，胶囊会静默失效。
    var capsuleContentHost: ManualPanelHost?
    /// 抽屉真正承载 SwiftUI 的 hosting view（抽屉 contentView 是普通 NSView 容器,故 fittingSize 要读这个）。
    var drawerContentHost: NSView?
    /// 同一个宿主的带类型引用，给「每次打开只换 rootView」用。**只建一次**（2026-09-04）：
    /// 之前每次打开都现建一棵抽屉视图树 + 同步量尺寸 + 渲染首帧，主线程停顿 55～135ms，
    /// 正压在 0.18s 淡入的开头——owner 报的「抽屉弹开掉帧」主因。关着时它和 ③④ 下
    /// 关着那块屏的抽屉一样继续活着，拖拽回调都先问 `isDrawerOpen()`，不是新状态。
    var drawerHosting: NSHostingView<DrawerRootView>?
    /// 宿主里现在这份 rootView 用的可用高度；没变就连 rootView 都不换，打开时 SwiftUI 一次图更新都不做。
    var drawerHostedMaxContentHeight: CGFloat?
    /// 跨面板拖动（拖卡进抽屉 路线 C）的唯一权威：载体面板 + 鼠标监视器 + 落点收尾都在它里面。
    /// 必须在 setupDockPanel/setupCapsulePanel 之前建好，因为要注入进这两个面板的 hosting。
    /// 跨面板拖动权威。**整个进程只有一个**，由编排层创建、注入给每个单元
    ///（③④ 下 N 条任务条共用：投放区是各单元的并集，载体面板本来就按屏一套）。
    let dragController: DragController
    /// 权限丢失后的挂起态。刻意**不**复用 `visibilityState.hideReasons`——
    /// 那套是给全屏和边缘自动隐藏用的，混进来会让底边唤醒把面板又拉回屏幕。
    var isSuspendedForPermissionLoss = false
    var drawerLocalMonitor: Any?
    var drawerGlobalMonitor: Any?
    // MARK: 文件夹/中转弹窗状态（单面板复用 = 天然「同时只有一个弹窗」）
    /// 共享弹窗当前装的内容：固定文件夹网格或中转网格。
    enum PopupContent: Equatable {
        case folder(path: String)
        case shelf
    }
    var folderPopupPanel: NSPanel?
    /// 弹窗真正承载 SwiftUI 的 hosting view（contentView 是普通 NSView 容器,fittingSize 读这个）。
    var folderPopupContentHost: NSView?
    var popupLocalMonitor: Any?
    var popupGlobalMonitor: Any?
    var lastPopupTargetFrame: NSRect = .zero
    /// 弹窗锚点（chip 可视矩形,屏幕坐标）。click-away 判定要排除它——监视器在 mouseDown 关、
    /// chip 的 onTapGesture 在 mouseUp 又开,不排除锚点则同 chip 点击永远无法收合。
    var popupAnchorVisibleRect: CGRect = .zero
    /// 当前弹窗内容（nil = 没开）。
    var openPopupContent: PopupContent?
    /// 便捷视图：仅当弹窗装的是文件夹时给 path（排序订阅/移除关窗等文件夹专属逻辑用）。
    var openPopupPath: String? {
        if case let .folder(path) = openPopupContent { return path }
        return nil
    }
    /// 弹窗**逻辑**开关态（淡出动画期间面板还可见但逻辑上已关,同 drawerWantsOpen）。
    var folderPopupWantsOpen = false
    var lastPopupSize = CGSize(width: 424, height: 240)
    /// 开窗时刻：入场窗口期（250ms）内的重定位一律瞬时,不与入场淡入叠加出晃动。
    var popupOpenedAt: Date = .distantPast
    /// 弹窗切换/重定位的手搓逐帧插值 timer（按 centerX/bottomY/width/height 插值,取代
    /// NSWindow.animator().setFrame 的原始 x/y/宽/高线性插值——后者没有锚点概念,两个文件夹
    /// frame 相对位置一变,生长方向就随机偏向某个角落,而不是稳定的"贴底、水平居中"）。
    var folderPopupFrameTimer: Timer?
    /// 每次开一个新 tween 就 +1。tick 回调里核对这个 token 再改 frame——
    /// Timer.invalidate() 挡不住"已经 fire、Task 还排在主 actor 队列里没跑到"的那一次回调,
    /// 光 invalidate 不够,得靠 token 让过期的排队任务自己变成 no-op。
    var folderPopupTweenToken: Int = 0
    /// 当前在飞 tween 的目标帧（nil = 没在飞）。双重 defer 的兜底校正常带着**同一个**目标再进来,
    /// 若无脑重启就会打断刚起步的动画、重置时钟(速度突变+总时长变长);目标相同直接放行让它走完。
    var folderPopupTweenTarget: NSRect?
    // MARK: 窗口标题 Tooltip（专属面板，不复用 folderPopupPanel）
    var windowTitleTooltipPanel: NSPanel?
    var windowTitleTooltipRequest: WindowTitleTooltipRequest?
    var windowTitleTooltipSuppressedChipID: String?
    var windowTitleTooltipLingerTimer: Timer?
    /// 只在气泡在屏上时跑的看门狗，见 `startWindowTitleTooltipWatchdog`。
    var windowTitleTooltipWatchdog: Timer?
    var windowTitleTooltipLocalMonitor: Any?
    var windowTitleTooltipGlobalMonitor: Any?
    /// 复用同一棵托管视图：每次悬停新建 `NSHostingView` 会在换 chip 时闪一下，也白付一次构建成本。
    var windowTitleTooltipHosting: NSHostingView<WindowTitleTooltipView>?
    var windowTitleTooltipHost: ManualPanelHost?
    var pinnedFolderStoreSubscription: AnyCancellable?
    var pinnedFolderSortSubscription: AnyCancellable?
    var snapshotWidthSubscription: AnyCancellable?
    var drawerStoreWidthSubscription: AnyCancellable?
    var messagingStoreWidthSubscription: AnyCancellable?
    var keptAppStoreSubscription: AnyCancellable?
    var runningApplicationStoreSubscription: AnyCancellable?
    var dragSpringSubscription: AnyCancellable?
    var dragInhibitorSubscription: AnyCancellable?
    var edgeDelaySubscription: AnyCancellable?
    var taskbarScreenPlacementSubscription: AnyCancellable?
    var displayTopologySubscription: AnyCancellable?
    var showShelfSubscription: AnyCancellable?
    var dockSizeSubscription: AnyCancellable?
    /// 换档事务代次：吞掉换档过程中被其它路径排队的动画布局（见 beginDockSizeChange）。
    var dockSizeChangeGeneration: UInt64 = 0
    /// 抽屉拖回任务条·"松手才变长"：转正进行中冻结任务条宽度，转正态结束（松手落定 / 拖出还原）再 relayout。
    var stripSlotCollapseSubscription: AnyCancellable?
    var springOpenTimer: Timer?
    /// 离开抽屉+胶囊后**延迟收回**的定时器（owner 2026-06-22：要延迟,不要一蹭到任务条就关）。
    var springCloseTimer: Timer?
    /// 本次拖动是否**从任务条发起**。任务条卡进抽屉体会被"转正"成 `.drawer` 来源（见 DragController），
    /// 但弹簧（开/延迟收/重开）整段拖动都该生效,所以认这个、不认实时 source（owner 2026-06-22）。
    var dragOriginatedFromStrip = false
    /// 抽屉**逻辑**开关态（不看 isVisible——淡出动画期间面板还可见但逻辑上已关）。toggle/弹簧/可打断关都看它。
    var drawerWantsOpen = false
    /// 每次 openDrawer() 递增。closeDrawerAfterAction() 捕获当前值，触发时不匹配则丢弃，
    /// 防止旧点击的延迟关闭在抽屉重新打开后误杀新抽屉。
    var drawerActionCloseToken = 0
    /// 这次抽屉是不是**弹簧**(拖动悬停)打开的。若是、且松手时这张卡没进抽屉(又拖回任务条) → 自动收回。
    var drawerSpringOpened = false
    /// 正在拖的 strip 卡 bundleID,松手时用它判断有没有收进抽屉。
    var springDragBundleID: String?
    var lastDesiredWidth: CGFloat = 0
    var lastDrawerSize: CGSize = CGSize(width: 210, height: 60)
    /// 目标 frame 驱动布局：每次 layoutPanels 算齐三个目标并存这里。drop zone 命中、开抽屉定位都读**目标**
    /// 而非 live frame——动画中 live frame 是中途值,会和视觉/逻辑短暂不一致（Codex 二审 P2）。
    /// `setFrames` 上一次真正提交过的目标 frame 序列。用来堵掉「目标没变还重启一遍动画」——
    /// 实测启动 7 秒内有 8 次这种空转，其中 6 次挤在 1.1ms 内，等于把同一组窗口尺寸动画
    /// 连着重启六遍，而它的每一帧都要重画玻璃底板和描边。
    var lastCommittedFrames: [NSRect] = []
    var lastDockTargetFrame: NSRect = .zero
    var lastCapsuleTargetFrame: NSRect = .zero
    var lastDrawerTargetFrame: NSRect = .zero
    /// 首帧布局强制瞬时（面板刚建好,别从初始/原点位置滑过来）。
    var didInitialLayout = false
    let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "dock-panel")
    let fullscreenIntentLogger = Logger(
        subsystem: "com.caye.macosdockcc.v2",
        category: "FullscreenIntent"
    )
    var fullscreenReconcileTimer: Timer?
    var workspaceObserverTokens: [NSObjectProtocol] = []
    /// 编排层持有唯一的 `FullscreenIntentMonitor`（session 事件 tap），把请求路由进来；
    /// 这个标志 = 「路由已接通」，替代原来的 `fullscreenIntentMonitor != nil` 守卫。
    var fullscreenIntentRoutingEnabled = false
    var fullscreenIntentTimeoutTimer: Timer?
    var fullscreenIntentGeneration: UInt64 = 0
    var fullscreenIntentTransaction: FullscreenIntentTransaction?
    var fullscreenProbeGeneration: UInt64 = 0
    var fullscreenSpaceHoldGeneration: UInt64 = 0
    var fullscreenSpaceHold: FullscreenSpaceHold?
    var fullscreenSpaceHoldTimer: Timer?
    /// Control+←/→ 预测隐藏。**默认开**，关掉用 `DOCK_SPACE_INTENT=0`
    ///（判定在 `FullscreenIntentMonitor` 的 `spaceSwitchEnabled`）。与窗口级意图事务共用
    /// `visibilityState` 的 `.fullscreenTransitionPending` 槽位，因此两者互斥、同时只能有一个。
    var fullscreenSpaceIntentGeneration: UInt64?
    var fullscreenSpaceIntentTimer: Timer?
    var fullscreenSpaceIntentVerdictTimer: Timer?
    /// 上一次隐藏是不是因为全屏。是 → 下次揭示走 0.18s 淡入（全屏回归的入场动画）；
    /// 否 → 边缘自动隐藏的唤出保持即时。只在 applyPanelVisibility / 预测隐藏两处写。
    var lastHideWasForFullscreen = false
    /// 「常驻所有桌面」成员资格修复（issue #19）。见 `AllSpacesMembership` 的机制说明。
    /// 关掉用 `DOCK_SPACE_MEMBERSHIP_REPAIR=0`。
    static let spaceMembershipRepairEnabled =
        DebugSwitch.spaceMembershipRepair.isEnabled(in: ProcessInfo.processInfo.environment)
    var spaceMembershipRepairInFlight = false
    var lastActiveApplicationPID: pid_t?
    var visibilityState = PanelVisibilityState()
    var panelsAreVisible = true
    var edgeIdleHideTimer: Timer?
    var edgeWakeTimer: Timer?
    var edgeWakeTargetScreen: NSScreen?
    var edgeWakeRequiresHotZone = true
    /// 编排层持有的鼠标监视器需要重估（边缘隐藏开关 / 显示位置 / 屏幕集合变了）。
    var onHoverMonitorsNeedReconcile: (() -> Void)?
    /// 本单元的面板换了屏（或首次布局）。编排层据此把所有单元的屏集合喂给全屏意图 tap。
    var onPanelScreenChanged: (() -> Void)?
    /// 本单元的逻辑显隐变了（含预测隐藏的快速路径）。编排层做角标门控的「任一可见」合并。
    var onLogicalVisibilityChanged: ((Bool) -> Void)?
    /// 本单元即将打开一个附属面板。编排层据此关掉其他单元的同类面板（同时只开一个抽屉 / 弹窗 / 气泡）。
    var onAccessoryWillOpen: ((PanelCoordinator, AccessoryKind) -> Void)?

    enum AccessoryKind { case drawer, popup, tooltip }

    /// 这个单元被安放在哪（见 `TaskbarUnitPlacement`）。③④ 下每屏一个 `.fixed` 单元。
    let unitPlacement: TaskbarUnitPlacement
    /// 常驻面板的私有空间宿主（整个进程一个，编排层持有）。nil = 开关关 / 符号缺失，
    /// 面板保持 `.canJoinAllSpaces` 老行为。见 `OverlaySpaceHost`。
    let overlaySpaceHost: OverlaySpaceHost?
    /// 本单元那条 strip 在共享 `DragController` 里的表面身份（见 `DragController.activeStripSurfaceID`）。
    let stripSurfaceID = "strip-" + UUID().uuidString
    let displayTopologyStore: DisplayTopologyStore
    /// ③④ 的固定单元知道自己是哪块屏；①② 的跟随单元为 nil（④ 下的按屏过滤对它不生效）。
    var fixedUnitDisplayUUID: String? {
        if case .fixed(let uuid) = unitPlacement { return uuid }
        return nil
    }

    init(placement: TaskbarUnitPlacement,
         dragController: DragController,
         overlaySpaceHost: OverlaySpaceHost?,
         runtime: AppRuntime,
         drawerStore: DrawerStore,
         messagingStore: MessagingAppStore,
         badgeStore: BadgeStore,
         stripOrderStore: StripOrderStore,
         drawerOrderStore: DrawerOrderStore,
         settingsStore: AppSettingsStore,
         pinnedFolderStore: PinnedFolderStore,
         folderCoverStore: PinnedFolderCoverStore,
         shelfStore: ShelfStore,
         keptAppStore: KeptAppStore,
         runningApplicationStore: RunningApplicationStore,
         appMembershipController: AppMembershipController,
         displayTopologyStore: DisplayTopologyStore) {
        self.unitPlacement = placement
        self.dragController = dragController
        self.overlaySpaceHost = overlaySpaceHost
        self.runtime = runtime
        self.drawerStore = drawerStore
        self.messagingStore = messagingStore
        self.badgeStore = badgeStore
        self.stripOrderStore = stripOrderStore
        self.drawerOrderStore = drawerOrderStore
        self.settingsStore = settingsStore
        self.pinnedFolderStore = pinnedFolderStore
        self.folderCoverStore = folderCoverStore
        self.shelfStore = shelfStore
        self.keptAppStore = keptAppStore
        self.runningApplicationStore = runningApplicationStore
        self.appMembershipController = appMembershipController
        self.displayTopologyStore = displayTopologyStore
        super.init()
    }

    func start() {
        setupDockPanel()
        setupCapsulePanel()
        presentInitialPanels()
        pinResidentPanelsIfNeeded()
        prewarmDrawerHost()
        subscribeSnapshotWidth()
        subscribeDrawerStoreWidth()
        subscribeMessagingStoreWidth()
        subscribeKeptAppStore()
        subscribeRunningApplicationStore()
        subscribeDragSpringLoad()
        subscribeDragInhibitor()
        subscribeStripSlotCollapse()
        subscribeSettings()
        subscribePinnedFolderStore()
        setupFullscreenMonitor()
        if Self.hoverVerboseLogging { logScreenMap() }
        // 屏幕参数变化、鼠标监视器、全屏意图 tap 都由编排层统一持有并转发（③④ 多单元共用一份）。
    }

    deinit {
        fullscreenReconcileTimer?.invalidate()
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceIntentTimer?.invalidate()
        fullscreenSpaceIntentVerdictTimer?.invalidate()
        MainActor.assumeIsolated {
            dismissWindowTitleTooltip()
            tearDownTaskbarGlassBackground()
        }
        hoverSwitchTimer?.invalidate()
        edgeIdleHideTimer?.invalidate()
        edgeWakeTimer?.invalidate()
        springOpenTimer?.invalidate()
        springCloseTimer?.invalidate()
        folderPopupFrameTimer?.invalidate()
        workspaceObserverTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func toggleDrawer() {
        if drawerWantsOpen { closeDrawer() } else { openDrawer() }
    }

    /// 权限丢失时把整套面板拆干净并交出所有权（调用方随后置空引用即可）。幂等。
    ///
    /// 这里刻意**不**走「手工列一份摘监视器清单」的路子——漏项风险太高：
    /// `DockStripView` 自己在 `NSViewRepresentable` 里装了力度点击 / 中键监视器，
    /// 只有视图树真被拆掉才会触发 `dismantleNSView` 去摘；而 `deinit` 已经覆盖了
    /// hover 监视器和一整排定时器，那份清单会随新增资源一起被维护。
    /// 所以：拆视图树 → 关面板 → 让调用方释放本对象走 `deinit`。
    ///
    /// 不做对称的 resume：权限恢复后是整个进程重启，没有「恢复运行」这条路径。
    ///
    /// ③④ 下拔掉一块屏也走这里拆那块屏的单元（编排层调）。共享的拖动控制器 / 载体面板
    /// **不在这里收**——那是全进程一份的，由编排层在真正挂起时收一次。
    func tearDown() {
        guard !isSuspendedForPermissionLoss else { return }
        isSuspendedForPermissionLoss = true
        fullscreenIntentRoutingEnabled = false
        if let transaction = fullscreenIntentTransaction {
            cancelFullscreenIntent(generation: transaction.generation, reason: "teardown")
        }
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenIntentTimeoutTimer = nil
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceHoldTimer = nil
        fullscreenSpaceHold = nil
        clearFullscreenSpaceArrowIntent()

        closeDrawer()
        closeFolderPopup(immediately: true)
        dismissWindowTitleTooltip()
        cancelHoverSwitch()
        cancelEdgeWake()
        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil

        // 换掉 contentView 触发 SwiftUI 拆树；单独强持有的 host 要先置空。
        dockContentHost = nil
        capsuleContentHost = nil
        drawerContentHost = nil
        drawerHosting = nil
        drawerHostedMaxContentHeight = nil
        folderPopupContentHost = nil
        windowTitleTooltipHosting = nil
        windowTitleTooltipHost = nil
        tearDownTaskbarGlassBackground()
        for panel in [dockPanel, capsulePanel, drawerPanel, folderPopupPanel, windowTitleTooltipPanel] {
            guard let panel else { continue }
            panel.contentView = NSView()
            panel.orderOut(nil)
            panel.close()
        }
        dockPanel = nil
        capsulePanel = nil
        drawerPanel = nil
        folderPopupPanel = nil
        windowTitleTooltipPanel = nil
        // 面板全拆了，「上次提交过的目标」随之作废——留着会让重建后的第一次布局被误判成
        // 「目标没变」而跳过，条就停在旧几何上。
        lastCommittedFrames = []
    }

    /// 本单元的任务条此刻落在哪块屏（从面板坐标反推）。面板未建时 nil。
    var currentScreen: NSScreen? {
        dockPanel.map { panelCurrentScreen(panel: $0) }
    }

    /// 逻辑显隐（角标门控 / 编排层合并用）。
    var isLogicallyVisible: Bool { panelsAreVisible }

    /// 最大化避让只在钨极常驻且真正可见时取得上下文；一次性返回完整几何，避免切屏时撕裂读取。
    func windowLiftAvoidanceContext() -> WindowLiftAvoidanceContext? {
        guard !settingsStore.edgeAutoHideEnabled,
              visibilityState.isVisible,
              panelsAreVisible,
              let panel = dockPanel else {
            return nil
        }

        let screen = panelCurrentScreen(panel: panel)
        let primaryScreenHeight = Self.quartzPrimaryScreenHeight
        let geometry = WindowLiftAvoidance.Geometry(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            taskbarTop: screen.frame.minY
                + layoutMetrics.bottomGap
                + layoutMetrics.panelHeight
        )
        return WindowLiftAvoidanceContext(
            geometry: geometry,
            screenCGFrame: Self.toCGRect(screen),
            visibleCGFrame: WindowLiftAvoidance.quartzFrame(
                fromAppKit: screen.visibleFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            primaryScreenHeight: primaryScreenHeight
        )
    }

    // MARK: - Drag Controller (拖卡进抽屉 路线 C)——控制器由编排层创建并注入，这里只提供几何

    /// 投放候选区（屏幕坐标），按拖动来源分：
    /// - `.strip` / `.messaging`（任务条卡/消息 chip 找收纳目标）= 胶囊可见内容区 + 8pt 容错（胶囊 frame 含
    ///   shadowPadding=20 透明边，减 20 得 52×52 可见区，再外扩 8 容错，不能更宽——胶囊紧挨任务条，太宽会
    ///   "拖到附近就被收走"）；抽屉打开时叠加抽屉可见内容区。任务条本身不是它们的投放区。
    /// - `.drawer`（抽屉图标找移回目标）= 任务条 dock 面板可见内容区（减 shadowPadding）。
    /// 胶囊的可视帧（屏幕坐标，目标帧优先）。给 `DragController` 的「吸进胶囊」飞行当终点。
    var capsuleVisibleFrame: CGRect? {
        let frame = lastCapsuleTargetFrame != .zero ? lastCapsuleTargetFrame : capsulePanel?.frame
        return frame?.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)
    }

    // MARK: - Window title tooltip

    /// 离开宽限：`.exit` 之后不立刻收，等这么久。**这条是「跟手」的关键。**
    /// 横穿分区分隔线时指针短暂不在任何卡上，立刻 orderOut 就会闪一下；隔壁一发
    /// `.update` 就接管，宽限自然作废。
    ///
    /// **配套的「冷启动延迟」已经删掉了，别再加回来。** 那里曾经留过 0.05s 去抖，
    /// 想的是横扫一排时别每个都闪，实际是反效果：0.05s 正好撞上匀速扫过单个图标的停留时间
    ///（中心间距 42pt，正常划手速度下每格只有几十毫秒），于是大多数格子在计时器到点前就已经
    /// 离开了。原生 Dock 根本没有这个延迟。面板保活之后，换 chip 本来就不闪。
    static let windowTitleTooltipLingerDelay: TimeInterval = 0.09

    // MARK: - 目标 frame 驱动布局
    //
    // Codex 二审根因：动画后若"读上一个面板正在动画的 live frame 来定位下一个"，读到的是动画起点的旧值
    // → 胶囊按旧任务条、抽屉按旧胶囊定位 → 任务条变宽后错位、抽屉与任务条重叠。修法：一次算齐三个**目标**
    // frame（纯函数,互不读 live frame），三面板在**同一个动画组**里各自滑向目标。

    static let layoutAnimationDuration: TimeInterval = DrawerAnimation.duration

    // MARK: - 常驻所有桌面的成员资格修复（issue #19）

    /// 必须在每个桌面上都在的面板。抽屉 / 文件夹弹窗 / 悬停气泡是瞬时面板——下次弹出时
    /// `orderFrontRegardless` 自然落到当前桌面，用户永远不会在别的桌面上等它们，故不参与修复。
    var allSpacesPanels: [NSPanel] {
        [dockGlassBackgroundPanel, dockPanel, capsulePanel].compactMap { $0 }
    }

    func panelCurrentScreen(panel: NSPanel) -> NSScreen {
        // Use the center of the visible content area (inset by shadowPadding) so the 12pt shadow
        // bleed below screen.frame.minY doesn't cause first(where:intersects) to return the wrong
        // adjacent screen in multi-monitor setups (e.g. vertically stacked 3-screen layouts).
        let visualCenter = CGPoint(
            x: panel.frame.midX,
            y: panel.frame.minY + Self.shadowPadding + panelHeight / 2
        )
        return NSScreen.screens.first(where: { $0.frame.contains(visualCenter) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // AppKit frame (bottom-left origin) → CG/Quartz frame (top-left origin of primary screen)
    static func toCGRect(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(
            x: f.minX,
            y: quartzPrimaryScreenHeight - f.maxY,
            width: f.width,
            height: f.height
        )
    }

    /// `NSScreen.main` follows the key window and may be a secondary display. Quartz global
    /// coordinates are anchored to the menu-bar display, which is always the first screen.
    private static var quartzPrimaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    /// `DOCK_FULLSCREEN_SLS_VERDICT=0` → `.notOnThisScreen` 按老口径当 `.windowed`。
    static let slsVerdictEnabled = DebugSwitch.fullscreenSlsVerdict.isEnabled(in: ProcessInfo.processInfo.environment)

    // MARK: - HoverSwitch Diagnostics

    let hoverLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "HoverSwitch")
    static let hoverHotZone: CGFloat = 4.0
    static let hoverSwitchDwell: TimeInterval = 0.35   // 光标驻留热区 ≥ 350ms 才切换，路过不算
    static let hoverVerboseLogging = false
    /// 底边唤醒/自动隐藏的复现诊断（owner 2026-07-16 issue #2 排查）。默认关闭；这里用纯 print()
    /// 而不是 Logger/os_log——沙箱环境读不了 `log show`/`log stream`，只有落到重定向文件里的
    /// print() 能直接读回。AppDelegate 已对 stdout 做行缓冲（`setvbuf(stdout, nil, _IOLBF, 0)`），
    /// 这里不需要额外处理缓冲。
    static let edgeHoverTraceEnabled = DebugSwitch.edgehoverTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    var hoverLastScreenIndex: Int? = nil
    var hoverLastInHotZone: Bool? = nil
    var hoverSwitchTimer: Timer?
    var hoverSwitchTargetScreen: NSScreen? = nil

    /// 任务条显示位置：悬停切屏（底边停留搬 dock）只在「跟随鼠标」档生效。
    /// 编排层指定了屏的单元（③④）恒不切屏——所有屏都有条，没有东西要搬。
    var hoverScreenSwitchingEnabled: Bool {
        switch unitPlacement {
        case .followSettings: return settingsStore.taskbarScreenPlacement.allowsHoverScreenSwitching
        case .fixed: return false
        }
    }

    /// 这个单元要落在哪块屏的 display UUID：`.fixed` 用编排层给的；`.followSettings` 用设置里的固定屏；
    /// 跟随鼠标档为 nil。
    var fixedDisplayUUID: String? {
        switch unitPlacement {
        case .fixed(let uuid): return uuid
        case .followSettings: return settingsStore.taskbarScreenPlacement.pinnedSelection?.uuid
        }
    }

    // MARK: - Frame Helpers

    // 这两个不随档位缩放，保持静态常量。
    private static let outerMargin: CGFloat = PanelLayoutMetrics.tungstenEdge.outerMargin
    private static let capsuleGap: CGFloat = PanelLayoutMetrics.tungstenEdge.capsuleGap

}
