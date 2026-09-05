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
    private var panelHeight: CGFloat { layoutMetrics.panelHeight }
    private var windowHeight: CGFloat { layoutMetrics.windowHeight }
    private var capsuleWidth: CGFloat { layoutMetrics.capsuleWidth }
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
    private static let panelLevelOverride: NSWindow.Level? = DebugSwitch.panelLevel.value().flatMap(Int.init).map { NSWindow.Level(rawValue: $0) }

    /// `usesLiquidGlass` 由调用方显式传：`setupDockPanel` 里玻璃底板刚建好、还没赋给
    /// `dockGlassBackgroundPanel`，此时读计算属性会错判成「无玻璃」建出普通面板。
    func makeFloatingPanel(contentRect: NSRect, usesLiquidGlass: Bool) -> NonConstrainingPanel {
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        return usesLiquidGlass
            ? DockLiquidGlassPanel(contentRect: contentRect, styleMask: styleMask,
                                   backing: .buffered, defer: false)
            : NonConstrainingPanel(contentRect: contentRect, styleMask: styleMask,
                                   backing: .buffered, defer: false)
    }

    /// 六块面板共用的窗口配置（2026-09-05 从六处逐字相同的复制收拢）。**顺序承重**：
    /// `isFloatingPanel = true` 会把 `level` 重置回 `.floating`，实验层级覆盖必须排在它之后；
    /// 只有三块常驻面板（任务条 / 玻璃底板 / 胶囊）吃 `DOCK_PANEL_LEVEL` 覆盖，抽屉 / 弹窗 / 气泡不吃。
    /// `PanelCollectionBehavior.standard` 的赋值点就此只剩这里和 issue #19 的修复循环。
    func configurePanel(_ panel: NSPanel, backgroundColor: NSColor, appliesLevelOverride: Bool) {
        panel.level = .floating
        panel.collectionBehavior = PanelCollectionBehavior.standard
        panel.isFloatingPanel = true
        if appliesLevelOverride, let level = Self.panelLevelOverride { panel.level = level }
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = backgroundColor
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
    }

    private var taskbarPlateCornerRadius: CGFloat {
        DockShape.panelCornerRadius * settingsStore.dockSize.scale
    }
    static let shadowPadding: CGFloat = PanelLayoutMetrics.shadowPadding

    private let runtime: AppRuntime
    private let drawerStore: DrawerStore
    private let messagingStore: MessagingAppStore
    private let badgeStore: BadgeStore
    private let stripOrderStore: StripOrderStore
    private let drawerOrderStore: DrawerOrderStore
    let settingsStore: AppSettingsStore
    let pinnedFolderStore: PinnedFolderStore
    let folderCoverStore: PinnedFolderCoverStore
    let shelfStore: ShelfStore
    private let keptAppStore: KeptAppStore
    private let runningApplicationStore: RunningApplicationStore
    private let appMembershipController: AppMembershipController
    /// 外部文件移入固定文件夹的唯一执行队列：资格判断与磁盘操作都按投放批次串行。
    private let fileDropQueue = DispatchQueue(label: "com.caye.macosdockcc.v2.folder-drop", qos: .userInitiated)
    /// 文件夹 chip / 中转格右键「添加文件夹…」入口（AppDelegate 注入，NSOpenPanel 归它管）。
    var onAddFolder: () -> Void = {}
    /// 右键任务条 / 胶囊时弹出钨极菜单。菜单归 `StatusMenuController` 持有，这里只转发事件——
    /// 正常运行时应用是 `.accessory`（没有菜单栏，也就没有 ⌘,），状态栏图标一旦被挤掉或被刘海挡住，
    /// 这就是打开设置的唯一后路。
    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)?
    var dockPanel: NSPanel?
    var dockGlassBackgroundPanel: NonConstrainingPanel?
    private var dockGlassBackgroundView: DockTaskbarLiquidGlassBackgroundView?
    /// 主任务条的 SwiftUI 承载器。窗口 frame 归 PanelCoordinator，内容尺寸只从这里读取。
    private var dockContentHost: ManualPanelHost?
    var drawerPanel: NSPanel?
    var capsulePanel: NSPanel?
    /// 胶囊的 SwiftUI 承载器。胶囊宽高固定（`capsuleWidth`），当前没人读它的 `fittingSize`——
    /// 但仍然**强持有**而不是 `_ =` 丢弃：丢弃后只靠视图层级间接留住容器，哪天给
    /// `ManualPanelHost` 加了 `deinit` 清理，胶囊会静默失效。
    private var capsuleContentHost: ManualPanelHost?
    /// 抽屉真正承载 SwiftUI 的 hosting view（抽屉 contentView 是普通 NSView 容器,故 fittingSize 要读这个）。
    private var drawerContentHost: NSView?
    /// 同一个宿主的带类型引用，给「每次打开只换 rootView」用。**只建一次**（2026-09-04）：
    /// 之前每次打开都现建一棵抽屉视图树 + 同步量尺寸 + 渲染首帧，主线程停顿 55～135ms，
    /// 正压在 0.18s 淡入的开头——owner 报的「抽屉弹开掉帧」主因。关着时它和 ③④ 下
    /// 关着那块屏的抽屉一样继续活着，拖拽回调都先问 `isDrawerOpen()`，不是新状态。
    private var drawerHosting: NSHostingView<DrawerRootView>?
    /// 宿主里现在这份 rootView 用的可用高度；没变就连 rootView 都不换，打开时 SwiftUI 一次图更新都不做。
    private var drawerHostedMaxContentHeight: CGFloat?
    /// 跨面板拖动（拖卡进抽屉 路线 C）的唯一权威：载体面板 + 鼠标监视器 + 落点收尾都在它里面。
    /// 必须在 setupDockPanel/setupCapsulePanel 之前建好，因为要注入进这两个面板的 hosting。
    /// 跨面板拖动权威。**整个进程只有一个**，由编排层创建、注入给每个单元
    ///（③④ 下 N 条任务条共用：投放区是各单元的并集，载体面板本来就按屏一套）。
    let dragController: DragController
    /// 权限丢失后的挂起态。刻意**不**复用 `visibilityState.hideReasons`——
    /// 那套是给全屏和边缘自动隐藏用的，混进来会让底边唤醒把面板又拉回屏幕。
    var isSuspendedForPermissionLoss = false
    private var drawerLocalMonitor: Any?
    private var drawerGlobalMonitor: Any?
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
    private var snapshotWidthSubscription: AnyCancellable?
    private var drawerStoreWidthSubscription: AnyCancellable?
    private var messagingStoreWidthSubscription: AnyCancellable?
    private var keptAppStoreSubscription: AnyCancellable?
    private var runningApplicationStoreSubscription: AnyCancellable?
    private var dragSpringSubscription: AnyCancellable?
    private var dragInhibitorSubscription: AnyCancellable?
    private var edgeDelaySubscription: AnyCancellable?
    private var taskbarScreenPlacementSubscription: AnyCancellable?
    private var displayTopologySubscription: AnyCancellable?
    private var showShelfSubscription: AnyCancellable?
    private var dockSizeSubscription: AnyCancellable?
    /// 换档事务代次：吞掉换档过程中被其它路径排队的动画布局（见 beginDockSizeChange）。
    private var dockSizeChangeGeneration: UInt64 = 0
    /// 抽屉拖回任务条·"松手才变长"：转正进行中冻结任务条宽度，转正态结束（松手落定 / 拖出还原）再 relayout。
    private var stripSlotCollapseSubscription: AnyCancellable?
    private var springOpenTimer: Timer?
    /// 离开抽屉+胶囊后**延迟收回**的定时器（owner 2026-06-22：要延迟,不要一蹭到任务条就关）。
    private var springCloseTimer: Timer?
    /// 本次拖动是否**从任务条发起**。任务条卡进抽屉体会被"转正"成 `.drawer` 来源（见 DragController），
    /// 但弹簧（开/延迟收/重开）整段拖动都该生效,所以认这个、不认实时 source（owner 2026-06-22）。
    private var dragOriginatedFromStrip = false
    /// 抽屉**逻辑**开关态（不看 isVisible——淡出动画期间面板还可见但逻辑上已关）。toggle/弹簧/可打断关都看它。
    var drawerWantsOpen = false
    /// 每次 openDrawer() 递增。closeDrawerAfterAction() 捕获当前值，触发时不匹配则丢弃，
    /// 防止旧点击的延迟关闭在抽屉重新打开后误杀新抽屉。
    private var drawerActionCloseToken = 0
    /// 这次抽屉是不是**弹簧**(拖动悬停)打开的。若是、且松手时这张卡没进抽屉(又拖回任务条) → 自动收回。
    private var drawerSpringOpened = false
    /// 正在拖的 strip 卡 bundleID,松手时用它判断有没有收进抽屉。
    private var springDragBundleID: String?
    private var lastDesiredWidth: CGFloat = 0
    private var lastDrawerSize: CGSize = CGSize(width: 210, height: 60)
    /// 目标 frame 驱动布局：每次 layoutPanels 算齐三个目标并存这里。drop zone 命中、开抽屉定位都读**目标**
    /// 而非 live frame——动画中 live frame 是中途值,会和视觉/逻辑短暂不一致（Codex 二审 P2）。
    /// `setFrames` 上一次真正提交过的目标 frame 序列。用来堵掉「目标没变还重启一遍动画」——
    /// 实测启动 7 秒内有 8 次这种空转，其中 6 次挤在 1.1ms 内，等于把同一组窗口尺寸动画
    /// 连着重启六遍，而它的每一帧都要重画玻璃底板和描边。
    private var lastCommittedFrames: [NSRect] = []
    private var lastDockTargetFrame: NSRect = .zero
    private var lastCapsuleTargetFrame: NSRect = .zero
    private var lastDrawerTargetFrame: NSRect = .zero
    /// 首帧布局强制瞬时（面板刚建好,别从初始/原点位置滑过来）。
    private var didInitialLayout = false
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
    private var edgeWakeTimer: Timer?
    private var edgeWakeTargetScreen: NSScreen?
    private var edgeWakeRequiresHotZone = true
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
    private let stripSurfaceID = "strip-" + UUID().uuidString
    private let displayTopologyStore: DisplayTopologyStore
    /// ③④ 的固定单元知道自己是哪块屏；①② 的跟随单元为 nil（④ 下的按屏过滤对它不生效）。
    private var fixedUnitDisplayUUID: String? {
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

    private func openDrawer() {
        guard let mainPanel = dockPanel, capsulePanel != nil else { return }
        onAccessoryWillOpen?(self, .drawer)
        drawerActionCloseToken += 1  // 旧点击排队的 delayed close 捕获旧 token，不匹配则丢弃
        drawerWantsOpen = true
        setAutoHideInhibitor(.drawerOpen, active: true)
        drawerSpringOpened = false   // 默认手动开；弹簧路径在 springOpenDrawer 里再置 true

        let screen = panelCurrentScreen(panel: mainPanel)
        let (capsuleRef, maxContentHeight) = drawerAnchor(on: screen)

        // 宿主只建一次；之后打开只在可用高度变了才换 rootView。
        // 各阶段打 `HoverTrace.action("drawerOpen")` 标记：打开这一转的主线程停顿由哪段贡献，只有它能分出来。
        HoverTrace.action("drawerOpen", phase: "begin")
        guard let host = ensureDrawerHost(maxContentHeight: maxContentHeight) else { return }
        let (panel, hosting) = host
        HoverTrace.action("drawerOpen", phase: "host")

        // 首帧就位（owner 2026-07-06「不丝滑」主因之一）：orderFront **前**同步量真实尺寸,
        // 首帧即最终大小,不再「旧尺寸弹出→瞬间校正」。量不到合理值退回 lastDrawerSize,
        // 后面的 double-defer 复测仍在,作兜底校正。
        panel.layoutIfNeeded()
        HoverTrace.action("drawerOpen", phase: "layout")
        let sync = hosting.fittingSize
        HoverTrace.action("drawerOpen", phase: "fitting")
        if sync.width >= 60, sync.height >= 60 {
            lastDrawerSize = sync
        }
        let initialFrame = drawerTargetFrame(forCapsule: capsuleRef, size: lastDrawerSize, on: screen)
        lastDrawerTargetFrame = initialFrame

        panel.setFrame(initialFrame, display: false)
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

        drawerLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.dismissDrawerIfOutside()
            return event
        }
        drawerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dismissDrawerIfOutside()
        }
    }

    /// 抽屉的定位输入：胶囊**目标** frame（不读 live：用户可能在任务条宽度动画中触发弹簧开抽屉,Codex 二审 P1）
    /// 和抽屉最大内容高度 = 胶囊上方锚点 → 屏幕上沿的可用高度。超出由 DrawerView 内部滚动,
    /// 绝不靠下压底边来塞下（否则压向胶囊/任务条 = 重叠,Codex 二审第 4 点）。
    /// 顶部上限仍避让菜单栏 / 刘海；底部锚点不避让原生 Dock，避免 Command+Option+D 或侧边 Dock 推动抽屉。
    private func drawerAnchor(on screen: NSScreen) -> (capsuleRef: NSRect, maxContentHeight: CGFloat) {
        let screenGeometry = Self.screenGeometry(screen)
        let capsuleRef = lastCapsuleTargetFrame == .zero ? (capsulePanel?.frame ?? .zero) : lastCapsuleTargetFrame
        return (capsuleRef, PanelGeometry.maxDrawerContentHeight(forCapsule: capsuleRef, on: screenGeometry))
    }

    private func makeDrawerRootView(maxContentHeight: CGFloat) -> DrawerRootView {
        DrawerRootView(maxContentHeight: maxContentHeight,
                       usesLiquidGlass: usesLiquidGlass,
                       isDrawerOpen: { [weak self] in self?.drawerPanel?.isVisible == true },
                       onPrimaryAction: { [weak self] in self?.closeDrawerAfterAction() },
                       runtime: runtime, drawerStore: drawerStore, messagingStore: messagingStore,
                       drawerOrderStore: drawerOrderStore, dragController: dragController,
                       keptAppStore: keptAppStore, runningApplicationStore: runningApplicationStore,
                       appMembershipController: appMembershipController)
    }

    /// 抽屉面板 + SwiftUI 宿主，**只建一次**；之后只在可用高度变了才换 rootView。
    /// 2026-09-04 之前每次打开都现建一棵视图树，主线程停顿 55～135ms 压在淡入开头（弹开掉帧主因）。
    private func ensureDrawerHost(maxContentHeight: CGFloat) -> (NSPanel, NSHostingView<DrawerRootView>)? {
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
            if drawerHostedMaxContentHeight != maxContentHeight {
                hosting.rootView = makeDrawerRootView(maxContentHeight: maxContentHeight)
                drawerHostedMaxContentHeight = maxContentHeight
            }
            return (panel, hosting)
        }

        let hosting = NSHostingView(rootView: makeDrawerRootView(maxContentHeight: maxContentHeight))
        drawerHostedMaxContentHeight = maxContentHeight
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
    private func prewarmDrawerHost() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.isSuspendedForPermissionLoss, self.drawerHosting == nil,
                  let mainPanel = self.dockPanel, self.capsulePanel != nil else { return }
            let anchor = self.drawerAnchor(on: self.panelCurrentScreen(panel: mainPanel))
            guard let host = self.ensureDrawerHost(maxContentHeight: anchor.maxContentHeight) else { return }
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
        guard let panel = drawerPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PopoverAnimation.closeDuration
            ctx.timingFunction = PopoverAnimation.curve()
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.drawerWantsOpen else { return }   // 淡出中又开了 → 别 orderOut
                panel.orderOut(nil)
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
        drawerPanel?.alphaValue = 0
        drawerPanel?.orderOut(nil)
    }

    private func dismissDrawerIfOutside() {
        guard dragController.draggingPayload == nil else { return }   // 拖动中不误关
        guard let drawer = drawerPanel, drawer.isVisible,
              let dock   = dockPanel else { return }
        let mouse = NSEvent.mouseLocation
        guard !drawer.frame.contains(mouse),
              !dock.frame.contains(mouse),
              !(capsulePanel?.frame.contains(mouse) ?? false) else { return }
        closeDrawer()
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

    func dragDropZones(for source: DragSource) -> [CGRect] {
        // 读**目标** frame：动画中 live frame 是中途值,会和视觉/落点短暂错位（Codex 二审 P2）。目标未初始化时退回 live。
        func target(_ stored: NSRect, _ live: NSRect?) -> NSRect? { stored != .zero ? stored : live }
        switch source {
        case .strip, .messaging:
            var zones: [CGRect] = []
            if let c = target(lastCapsuleTargetFrame, capsulePanel?.frame) {
                zones.append(c.insetBy(dx: Self.shadowPadding - 8, dy: Self.shadowPadding - 8))
            }
            if let drawer = drawerPanel, drawer.isVisible, let d = target(lastDrawerTargetFrame, drawer.frame) {
                // 抽屉只向上长：投放区**上沿拉到屏幕顶**,只认固定的底边+宽度,不随面板增高/缩短而变。
                // 否则"投放区尺寸→是否插空格→面板增高→投放区尺寸"成反馈环,空格闪烁、面板动画被高频打断
                // 而过冲向下（owner 2026-06-21"先向下扩展再上移"的真因）。
                let inset = d.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)
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
    private func subscribeDragSpringLoad() {
        // 订阅 globalLocation（不是 isOverDropZone）——光标回到任务条上不改 isOverDropZone,
        // 必须靠位置才能实时收回抽屉（owner 2026-06-21：拖回任务条即收、再移回胶囊再开）。
        dragSpringSubscription = dragController.pointerMoves
            .combineLatest(dragController.$draggingPayload)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location, payload in
                self?.updateSpringLoad(location: location, payload: payload)
            }
    }

    private func subscribeDragInhibitor() {
        dragInhibitorSubscription = dragController.$draggingPayload
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dragging in
                if dragging { self?.dismissWindowTitleTooltip(suppressCurrentUntilExit: true) }
                self?.setAutoHideInhibitor(.dragging, active: dragging)
            }
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

    /// 视区命中：目标 frame 取可见内容区 + 6pt 迟滞（防胶囊/任务条交界反复横跳）。
    private func springZone(_ target: NSRect) -> CGRect {
        target.insetBy(dx: Self.shadowPadding - 6, dy: Self.shadowPadding - 6)
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
        let screen = resolvedPinnedScreen() ?? NSScreen.main ?? NSScreen.screens[0]
        let s = screen.frame
        let legacyInitialFrame = NSRect(
            x: s.minX,
            y: s.minY + layoutMetrics.bottomGap - Self.shadowPadding,
            width: s.width,
            height: windowHeight
        )

        let glassBackground = makeTaskbarGlassBackground(contentPanelFrame: legacyInitialFrame)
        let usesLiquidGlass = glassBackground != nil

        // 内容窗口**始终**用含 20pt 阴影透明边的 frame，玻璃态也不例外：落地阴影住在那里，
        // 而且投放区/弹簧区/「鼠标还在条上」这些判定全都按「窗口 frame 减 shadowPadding」
        // 换算（`dragDropZones` / `springZone` / `isMouseOutsideInteractivePanels`）。
        // 缩窗口会让这一整批坐标一起错位。
        let panel = makeFloatingPanel(contentRect: legacyInitialFrame, usesLiquidGlass: usesLiquidGlass)
        configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: true)

        let hosting = NSHostingView(rootView: DockStripView(
            usesLiquidGlass: usesLiquidGlass,
            stripSurfaceID: stripSurfaceID,
            displayUUID: fixedUnitDisplayUUID,
            onFolderPopupToggle: { [weak self] path, anchorRect in
                self?.toggleFolderPopup(path: path, anchorVisibleRect: anchorRect)
            },
            onShelfPopupToggle: { [weak self] anchorRect in
                self?.toggleShelfPopup(anchorVisibleRect: anchorRect)
            },
            onAddFolder: { [weak self] in self?.onAddFolder() },
            onMoveExternalFiles: { [weak self] urls, path in
                self?.moveExternalFiles(urls, into: path)
            },
            onWindowTitleTooltipEvent: { [weak self] event in
                self?.handleWindowTitleTooltipEvent(event)
            },
            onRequestTaskbarMenu: { [weak self] event, view in
                self?.onRequestTaskbarMenu?(event, view)
            }
        ).environmentObject(runtime).environmentObject(drawerStore).environmentObject(messagingStore).environmentObject(badgeStore).environmentObject(stripOrderStore).environmentObject(pinnedFolderStore).environmentObject(folderCoverStore).environmentObject(shelfStore).environmentObject(dragController).environmentObject(keptAppStore).environmentObject(runningApplicationStore).environmentObject(appMembershipController).environmentObject(settingsStore).environmentObject(displayTopologyStore))
        hosting.autoresizingMask = [.width, .height]
        // Prevent NSHostingView from adding its own opaque background over the blur
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        dockContentHost = ManualPanelHost(contentView: hosting, in: panel)
        dockPanel = panel

        if let (backgroundPanel, backgroundView) = glassBackground {
            dockGlassBackgroundPanel = backgroundPanel
            dockGlassBackgroundView = backgroundView
        }
    }

    private func makeTaskbarGlassBackground(
        contentPanelFrame: NSRect
    ) -> (NonConstrainingPanel, DockTaskbarLiquidGlassBackgroundView)? {
        guard DockGlassPresentation.shouldAttemptTaskbarComposite else { return nil }

        let configuration = DockGlassPresentation.configuration
        let backgroundFrame = DockLiquidGlassPanelGeometry.backgroundFrame(
            for: contentPanelFrame,
            shadowPadding: Self.shadowPadding
        )
        guard backgroundFrame.width > 0, backgroundFrame.height > 0 else { return nil }

        let panel = NonConstrainingPanel(
            contentRect: backgroundFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel(panel, backgroundColor: .clear, appliesLevelOverride: true)
        panel.ignoresMouseEvents = true
        // 下面的失败分支会 close() 一个从未 order in 过的窗口；NSWindow 默认 close 即释放，
        // 而这里还持有着强引用。
        panel.isReleasedWhenClosed = false

        let backgroundView = DockTaskbarLiquidGlassBackgroundView(
            frame: NSRect(origin: .zero, size: backgroundFrame.size),
            cornerRadius: taskbarPlateCornerRadius,
            configuration: configuration
        )
        backgroundView.autoresizingMask = [.width, .height]
        panel.contentView = backgroundView

        let blurRadius = UInt32(configuration.windowBlurRadius.rounded())
        guard TEDockGlassSetWindowBackgroundBlurRadius(panel.windowNumber, blurRadius) else {
            panel.contentView = nil
            panel.close()
            return nil
        }
        return (panel, backgroundView)
    }

    private func tearDownTaskbarGlassBackground() {
        guard let background = dockGlassBackgroundPanel else { return }
        _ = TEDockGlassSetWindowBackgroundBlurRadius(background.windowNumber, 0)
        background.contentView = nil
        background.orderOut(nil)
        background.close()
        dockGlassBackgroundView = nil
        dockGlassBackgroundPanel = nil
    }

    private func orderDockSurfaceFront() {
        let ordering = DockLiquidGlassPanelLifecyclePlan.ordering(
            isCompositeActive: dockGlassBackgroundPanel != nil,
            shouldShow: true
        )
        for role in ordering {
            switch role {
            case .background:
                dockGlassBackgroundPanel?.orderFrontRegardless()
            case .content:
                dockPanel?.orderFrontRegardless()
            }
        }
        if let background = dockGlassBackgroundPanel, let dock = dockPanel {
            background.order(.below, relativeTo: dock.windowNumber)
        }
    }

    func orderDockSurfaceOut() {
        let ordering = DockLiquidGlassPanelLifecyclePlan.ordering(
            isCompositeActive: dockGlassBackgroundPanel != nil,
            shouldShow: false
        )
        for role in ordering {
            switch role {
            case .background:
                dockGlassBackgroundPanel?.orderOut(nil)
            case .content:
                dockPanel?.orderOut(nil)
            }
        }
    }

    private func moveExternalFiles(_ urls: [URL], into path: String) {
        let destination = URL(fileURLWithPath: path, isDirectory: true)
        fileDropQueue.async {
            let eligible = FolderDropPlan.eligibleSources(urls, destination: destination)
            guard !eligible.isEmpty else { return }
            let result = FileMover().move(eligible, into: destination)
            guard result.hasIssues else { return }
            DispatchQueue.main.async { NSSound.beep() }
        }
    }

    private func setupCapsulePanel() {
        let panel = makeFloatingPanel(
            contentRect: NSRect(origin: .zero,
                                size: CGSize(width: capsuleWidth + Self.shadowPadding * 2,
                                             height: capsuleWidth + Self.shadowPadding * 2)),
            usesLiquidGlass: usesLiquidGlass
        )
        configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: true)
        let hosting = NSHostingView(rootView:
            DrawerCapsuleButton(
                onRequestTaskbarMenu: { [weak self] event, view in
                    self?.onRequestTaskbarMenu?(event, view)
                },
                usesLiquidGlass: usesLiquidGlass,
                action: { [weak self] in self?.toggleDrawer() }
            )
                .environmentObject(runtime)
                .environmentObject(drawerStore)
                .environmentObject(messagingStore)
                .environmentObject(keptAppStore)
                .environmentObject(runningApplicationStore)
                .environmentObject(drawerOrderStore)
                .environmentObject(dragController)
                .environmentObject(settingsStore)
        )
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        capsuleContentHost = ManualPanelHost(contentView: hosting, in: panel)
        capsulePanel = panel
    }

    /// 两个常驻面板先在隐藏态完成 SwiftUI 布局和目标 frame 提交，再一起显示。
    /// 这样首个可见 frame 已经是业务几何，不给 HostingView 的自然尺寸留下窗口级中间态。
    private func presentInitialPanels() {
        guard let dock = dockPanel, let capsule = capsulePanel else { return }
        dock.layoutIfNeeded()
        capsule.layoutIfNeeded()
        relayout(animated: false)
        orderDockSurfaceFront()
        capsule.orderFrontRegardless()
    }

    // MARK: - Content Width via fittingSize

    private func subscribeSnapshotWidth() {
        snapshotWidthSubscription = runtime.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Defer one run-loop cycle so SwiftUI finishes layout before we read fittingSize
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)   // layoutPanels 内含抽屉重定位；转正期间 relayout 内部钳住宽度
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

    /// 拖出即合拢（owner 2026-09-03）：条上那张卡离开 / 回到任务条时投影层剔掉 / 放回它，面板宽度
    /// 要跟着动画。任务条宽度**不再钳**（2026-06-22 → 08-20 两轮的宽度冻结机制随之删除）：
    /// 条宽任何时候都等于此刻渲染内容的宽度，收纳松手时条已经是窄的，胶囊 / 抽屉不再在飞行途中滑动。
    /// 写法同 store 订阅（先 receive(on:) 再 async 一轮，让 SwiftUI 先按新投影布局，`fittingSize` 才是新宽度）。
    private func subscribeStripSlotCollapse() {
        stripSlotCollapseSubscription = dragController.$stripSlotCollapsed
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // 换档事务里 cancelDrag() 也会走到这里排队一次带动画的布局；用代次吞掉它，
                // 否则会先按新 metrics 动画一次、再被事务的无动画布局跳一次。
                let generation = self.dockSizeChangeGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.dockSizeChangeGeneration else { return }
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

    private func subscribeMessagingStoreWidth() {
        messagingStoreWidthSubscription = messagingStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)
                }
            }
    }

    private func subscribeKeptAppStore() {
        keptAppStoreSubscription = keptAppStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)
                }
            }
    }

    private func subscribeRunningApplicationStore() {
        runningApplicationStoreSubscription = runningApplicationStore.$runningBundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
    }

    private func subscribeSettings() {
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
        dockSizeSubscription = settingsStore.$dockSize
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.beginDockSizeChange() }
    }

    /// 换档是一次**事务**，不是普通的内容变化：面板高度、胶囊宽度、条内每个 chip 的尺寸同时变，
    /// 中途任何一次动画布局都会把三个面板摆到半新半旧的几何上。
    ///
    /// 顺序是有讲究的：
    /// 1. 先收掉所有依附在旧几何上的东西——拖动载体（尺寸随档位）、抽屉（`maxContentHeight`
    ///    是开抽屉时一次性传进根视图的，只挪外框会裁掉内容）、弹窗与 tooltip（锚点已作废）。
    /// 2. `cancelDrag()` 会经 `subscribeStripSlotCollapse` 排队一次**带动画**的 relayout，
    ///    用 generation 门控把它吞掉，否则先按新 metrics 动画一次、再瞬时跳一次。
    /// 3. 等 SwiftUI 用新档位跑完一轮布局（`fittingSize` 那时才是新宽度），再一次性无动画提交。
    ///    换档是瞬时的，不做过渡动画。
    ///
    /// 最大化避让不需要在这里做任何事：`taskbarTop` 由 `panelHeight` 算出、在 Equatable 的
    /// `WindowLiftAvoidanceContext` 里，档位一变 `reconcileContext` 就走既有的还原→重抬路径。
    func beginDockSizeChange() {
        dockSizeChangeGeneration &+= 1
        let generation = dockSizeChangeGeneration

        dragController.cancelDrag()
        dismissWindowTitleTooltip()
        closeFolderPopup(immediately: true)
        if drawerWantsOpen { closeDrawer() }

        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.dockSizeChangeGeneration else { return }
            self.relayout(animated: false)
        }
    }

    // MARK: - 目标 frame 驱动布局
    //
    // Codex 二审根因：动画后若"读上一个面板正在动画的 live frame 来定位下一个"，读到的是动画起点的旧值
    // → 胶囊按旧任务条、抽屉按旧胶囊定位 → 任务条变宽后错位、抽屉与任务条重叠。修法：一次算齐三个**目标**
    // frame（纯函数,互不读 live frame），三面板在**同一个动画组**里各自滑向目标。

    static let layoutAnimationDuration: TimeInterval = DrawerAnimation.duration

    /// 任务条目标 frame（按内容宽度、居中、限宽）。
    private func dockTargetFrame(contentWidth: CGFloat, on screen: NSScreen) -> NSRect {
        PanelGeometry.dockTargetFrame(contentWidth: contentWidth, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// 胶囊目标 frame（贴任务条右边、纵向居中）。只依赖传入的 dock **目标** frame。
    private func capsuleTargetFrame(forDock dockFrame: NSRect, on screen: NSScreen) -> NSRect {
        PanelGeometry.capsuleTargetFrame(forDock: dockFrame, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// 抽屉目标 frame（右边贴胶囊右边、**底边硬锚在胶囊上方、向上长**）。只依赖传入的胶囊 **目标** frame + 抽屉尺寸。
    /// 关键：底边绝不下移——超过上方可用空间就**封顶高度**（内容由 DrawerView 内部滚动），
    /// 绝不靠"把底边往下压"来塞下，否则压到胶囊/任务条（owner 2026-06-21 报图）。
    private func drawerTargetFrame(forCapsule capsuleFrame: NSRect, size: CGSize, on screen: NSScreen) -> NSRect {
        // 底部/左右定位使用 screen.frame，切断与原生 Dock visibleFrame 的耦合；
        // 顶部高度仍由 topUsableY 封顶，避免菜单栏和刘海遮挡。
        PanelGeometry.drawerTargetFrame(forCapsule: capsuleFrame, size: size, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// 统一布局入口：算齐三个目标 frame、存好（给 drop zone / 开抽屉读），三面板同组动画到目标。
    /// 开屏/切屏/多屏悬停传 animated:false；内容变化、收纳/移回、抽屉尺寸变化传 animated:true。
    private func layoutPanels(contentWidth: CGFloat, on screen: NSScreen, animated: Bool) {
        guard let dock = dockPanel, let capsule = capsulePanel else { return }
        let panelScreenCGFrame = Self.toCGRect(screen)
        if let transaction = fullscreenIntentTransaction,
           transaction.screenCGFrame != panelScreenCGFrame {
            cancelFullscreenIntent(generation: transaction.generation, reason: "panel-screen-changed")
        }
        let anim = animated && didInitialLayout   // 首帧瞬时,别从初始位置滑过来
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
    func relayout(animated: Bool) {
        guard let panel = dockPanel, let hosting = dockContentHost else { return }
        // `fittingSize` 是**主线程上把整条任务条同步布局一遍**，不是读一个缓存值。
        // 探针量的就是它 + 宽度到底变没变（没变还跑动画就是纯浪费）。
        let measureStart = CACurrentMediaTime()
        let measured = hosting.fittingSize.width - 2 * Self.shadowPadding
        HoverTrace.relayout(measureMs: CACurrentMediaTime() - measureStart,
                            width: measured,
                            changed: measured != lastDesiredWidth,
                            animated: animated)
        lastDesiredWidth = measured
        // 跨面板转正进行中 → 任务条宽度钳在拖动前的值（窗口卡溢出/留空而非改变面板宽度，owner 2026-06-22）；
        // 松手/还原解钳后，下一次 relayout 用真实测量值把任务条变到最终长度。
        layoutPanels(contentWidth: measured, on: panelCurrentScreen(panel: panel), animated: animated)
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
    private func setFrames(_ pairs: [(NSPanel, NSRect)], animated: Bool) {
        // **和上一次的目标比，不和面板的实时 frame 比。**
        // 实时 frame 在动画途中是插值出来的中间值，永远和目标不等——那样这个短路一次都不会命中
        // （实测 0 次）。AGENTS《Menus, Panels, And Screens》早写过同一条：relayout 是目标
        // frame 驱动的，别在动画期间读面板的实时 frame。
        let targets = pairs.map(\.1)
        guard targets != lastCommittedFrames else {
            HoverTrace.framesUnchanged()
            return
        }
        lastCommittedFrames = targets
        guard animated else { for (p, f) in pairs { p.setFrame(f, display: true) }; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.layoutAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (p, f) in pairs { p.animator().setFrame(f, display: true) }
        }
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

    private let hoverLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "HoverSwitch")
    private static let hoverHotZone: CGFloat = 4.0
    private static let hoverSwitchDwell: TimeInterval = 0.35   // 光标驻留热区 ≥ 350ms 才切换，路过不算
    private static let hoverVerboseLogging = false
    /// 底边唤醒/自动隐藏的复现诊断（owner 2026-07-16 issue #2 排查）。默认关闭；这里用纯 print()
    /// 而不是 Logger/os_log——沙箱环境读不了 `log show`/`log stream`，只有落到重定向文件里的
    /// print() 能直接读回。AppDelegate 已对 stdout 做行缓冲（`setvbuf(stdout, nil, _IOLBF, 0)`），
    /// 这里不需要额外处理缓冲。
    static let edgeHoverTraceEnabled = DebugSwitch.edgehoverTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private var hoverLastScreenIndex: Int? = nil
    private var hoverLastInHotZone: Bool? = nil
    private var hoverSwitchTimer: Timer?
    private var hoverSwitchTargetScreen: NSScreen? = nil

    /// 任务条显示位置：悬停切屏（底边停留搬 dock）只在「跟随鼠标」档生效。
    /// 编排层指定了屏的单元（③④）恒不切屏——所有屏都有条，没有东西要搬。
    private var hoverScreenSwitchingEnabled: Bool {
        switch unitPlacement {
        case .followSettings: return settingsStore.taskbarScreenPlacement.allowsHoverScreenSwitching
        case .fixed: return false
        }
    }

    /// 这个单元要落在哪块屏的 display UUID：`.fixed` 用编排层给的；`.followSettings` 用设置里的固定屏；
    /// 跟随鼠标档为 nil。
    private var fixedDisplayUUID: String? {
        switch unitPlacement {
        case .fixed(let uuid): return uuid
        case .followSettings: return settingsStore.taskbarScreenPlacement.pinnedSelection?.uuid
        }
    }

    /// 固定档下把 display UUID 解析成当前的 NSScreen（固定屏缺席回落主屏 / 首屏）；
    /// 跟随鼠标档返回 nil。刻意**无持久运行态**：每次屏幕参数 / 设置变化都重解析一遍，
    /// 固定的屏一接回来自然搬回去，不需要任何「记住上次在哪」的状态机。
    /// ③④ 的 `.fixed` 单元同样走这里：屏刚拔掉、编排层还没来得及拆它的那一瞬回落主屏，不会飞到 nil。
    private func resolvedPinnedScreen() -> NSScreen? {
        guard let pinnedUUID = fixedDisplayUUID else { return nil }
        let screens = NSScreen.screens
        let outcome = TaskbarScreenResolution.resolve(
            pinnedUUID: pinnedUUID,
            screenUUIDs: screens.map { DisplayIdentity.uuidString(for: $0) },
            mainIndex: NSScreen.main.flatMap { screens.firstIndex(of: $0) }
        )
        switch outcome {
        case .matched(let index), .fallback(let index):
            return screens[index]
        case nil:
            return nil
        }
    }

    // 鼠标移动监视器（安装 / 节流 / 菜单跟踪期间挂起）整体在编排层 `TaskbarScreenOrchestrator`：
    // 全进程一套，回调转发给每个单元的 `pollMousePosition()`。单元只保留探测与武装逻辑。

    private func logScreenMap() {
        let screens = NSScreen.screens
        for (i, screen) in screens.enumerated() {
            let f = screen.frame
            let vf = screen.visibleFrame
            hoverLogger.info("screen-map index=\(i, privacy: .public) name=\(screen.localizedName, privacy: .public) frame=(\(f.minX, privacy: .public),\(f.minY, privacy: .public),\(f.width, privacy: .public),\(f.height, privacy: .public)) visibleFrame=(\(vf.minX, privacy: .public),\(vf.minY, privacy: .public),\(vf.width, privacy: .public),\(vf.height, privacy: .public)) isMain=\(screen == NSScreen.main, privacy: .public) isScreens0=\(i == 0, privacy: .public)")
        }
    }

    /// 每次（节流后的）鼠标移动都进这里，由编排层转发。别的屏上的移动在 `handleBottomEdgeProbe` 廉价早退。
    func pollMousePosition() {
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

        handleBottomEdgeProbe(screen: curScreen, inHotZone: inHotZone)
        updateEdgeIdleTimerFromMouse()

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

    }

    func cancelHoverSwitch() {
        hoverSwitchTimer?.invalidate()
        hoverSwitchTimer = nil
        hoverSwitchTargetScreen = nil
    }

    private func commitHoverSwitch() {
        hoverSwitchTimer = nil
        // 保险：350ms dwell 窗口内设置可能翻到固定档，武装时的判定已过期。
        guard hoverScreenSwitchingEnabled else {
            hoverSwitchTargetScreen = nil
            return
        }
        guard let targetScreen = hoverSwitchTargetScreen, let panel = dockPanel else {
            hoverSwitchTargetScreen = nil
            return
        }
        hoverSwitchTargetScreen = nil
        // Confirm the cursor is still on the target screen (it may have left within the last poll gap).
        guard targetScreen.frame.contains(NSEvent.mouseLocation) else { return }
        let panelScreen = panelCurrentScreen(panel: panel)
        guard targetScreen != panelScreen else { return }   // panel already moved (e.g. screenParametersChanged)
        let screens = NSScreen.screens
        let fromIdx = screens.firstIndex(of: panelScreen).map { "\($0)" } ?? "?"
        let toIdx = screens.firstIndex(of: targetScreen).map { "\($0)" } ?? "?"
        let actualWidth = PanelGeometry.dockTargetFrame(
            contentWidth: lastDesiredWidth,
            on: Self.screenGeometry(targetScreen),
            metrics: layoutMetrics
        ).width - Self.shadowPadding * 2
        closeFolderPopup()   // 切屏后旧锚点在旧屏,弹窗收起
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        layoutPanels(contentWidth: lastDesiredWidth, on: targetScreen, animated: false)
        hoverLogger.info("switch toScreen=\(toIdx, privacy: .public) name=\(targetScreen.localizedName, privacy: .public) actualWidth=\(actualWidth, privacy: .public) fromScreen=\(fromIdx, privacy: .public)")
        armEdgeWakeIfNeeded(on: targetScreen, requiresHotZone: false)
    }

    private func handleBottomEdgeProbe(screen: NSScreen?, inHotZone: Bool) {
        guard let screen, let panel = dockPanel else {
            cancelHoverSwitch()
            cancelEdgeWake()
            return
        }

        let panelScreen = panelCurrentScreen(panel: panel)
        if screen != panelScreen {
            // 固定到某屏：别的屏的底边热区什么都不武装——dwell 计时器根本不该起。
            guard hoverScreenSwitchingEnabled else {
                cancelEdgeWake()
                cancelHoverSwitch()
                return
            }
            cancelEdgeWake()
            if hoverSwitchTargetScreen == screen {
                return
            }
            if inHotZone {
                hoverSwitchTimer?.invalidate()
                hoverSwitchTargetScreen = screen
                let timer = Timer(timeInterval: Self.hoverSwitchDwell, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.commitHoverSwitch() }
                }
                RunLoop.main.add(timer, forMode: .common)
                hoverSwitchTimer = timer
            } else {
                cancelHoverSwitch()
            }
            return
        }

        cancelHoverSwitch()
        if inHotZone {
            armEdgeWakeIfNeeded(on: screen)
        } else if edgeWakeTargetScreen == screen, edgeWakeRequiresHotZone {
            cancelEdgeWake()
        }
    }

    /// 钨极菜单开着时停掉边缘自动隐藏，否则空闲计时照跑、任务条会从菜单底下缩掉。
    func setTaskbarMenuOpen(_ open: Bool) {
        setAutoHideInhibitor(.taskbarMenuOpen, active: open)
    }

    func setAutoHideInhibitor(_ inhibitor: EdgeAutoHideInhibitor, active: Bool) {
        let before = visibilityState
        visibilityState.setInhibitor(inhibitor, active: active)
        if visibilityState != before { reconcilePanelVisibility() }
    }

    func reconcilePanelVisibility() {
        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil

        let edgeDelay = settingsStore.edgeAutoHideDelay
        let edgeEnabled = edgeDelay != AppSettingsStore.neverHideDelay
        visibilityState.reconcileEdgeAutoHide(isEnabled: edgeEnabled)

        if edgeDelay == AppSettingsStore.neverHideDelay {
            cancelEdgeWake()
        } else if visibilityState.autoHideInhibitors.isEmpty,
                  !visibilityState.hideReasons.contains(.fullscreen),
                  !visibilityState.hideReasons.contains(.fullscreenTransitionPending) {
            if visibilityState.hideReasons.contains(.edgeAutoHide) {
                if EdgeAutoHideRuntimeRules.canArmWake(state: visibilityState, delay: edgeDelay),
                   let screen = screenContainingMouse(),
                   isMouseInBottomHotZone(on: screen) {
                    armEdgeWakeIfNeeded(on: screen)
                }
            } else if EdgeAutoHideRuntimeRules.canArmIdleHide(state: visibilityState, delay: edgeDelay),
                      isMouseOutsideInteractivePanels() {
                armEdgeIdleHideTimer()
            }
        } else {
            cancelEdgeWake()
        }

        applyPanelVisibility()
    }

    private func updateEdgeIdleTimerFromMouse() {
        guard EdgeAutoHideRuntimeRules.canArmIdleHide(state: visibilityState, delay: settingsStore.edgeAutoHideDelay) else { return }

        if isMouseOutsideInteractivePanels() {
            if edgeIdleHideTimer == nil {
                armEdgeIdleHideTimer()
            }
        } else {
            edgeIdleHideTimer?.invalidate()
            edgeIdleHideTimer = nil
        }
    }

    private func armEdgeIdleHideTimer() {
        guard let interval = EdgeAutoHideRuntimeRules.idleHideInterval(for: settingsStore.edgeAutoHideDelay) else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.edgeIdleHideTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeIdleHideTimer = timer
    }

    private func edgeIdleHideTimerFired() {
        edgeIdleHideTimer = nil
        guard EdgeAutoHideRuntimeRules.canArmIdleHide(state: visibilityState, delay: settingsStore.edgeAutoHideDelay),
              isMouseOutsideInteractivePanels() else { return }
        visibilityState.setEdgeAutoHidden(true)
        reconcilePanelVisibility()
    }

    private func armEdgeWakeIfNeeded(on screen: NSScreen, requiresHotZone: Bool = true) {
        // 固定到某屏：唤醒探测只认**面板实际所在的屏**（不是存的固定屏——固定屏被拔、
        // 条落在回退屏时，回退屏照常唤醒）。这里是所有武装路径的单一咽喉，
        // 包括 reconcilePanelVisibility 里按 screenContainingMouse() 的那条。
        if !hoverScreenSwitchingEnabled,
           let panel = dockPanel, panelCurrentScreen(panel: panel) != screen {
            return
        }
        guard EdgeAutoHideRuntimeRules.canArmWake(state: visibilityState, delay: settingsStore.edgeAutoHideDelay) else { return }
        if edgeWakeTargetScreen == screen,
           edgeWakeTimer != nil,
           edgeWakeRequiresHotZone == requiresHotZone { return }
        cancelEdgeWake()
        edgeWakeTargetScreen = screen
        edgeWakeRequiresHotZone = requiresHotZone
        let timer = Timer(timeInterval: settingsStore.edgeAutoHideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.edgeWakeTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeWakeTimer = timer
    }

    private func edgeWakeTimerFired() {
        edgeWakeTimer = nil
        guard let screen = edgeWakeTargetScreen,
              edgeWakeShouldStillFire(on: screen),
              EdgeAutoHideRuntimeRules.canArmWake(state: visibilityState, delay: settingsStore.edgeAutoHideDelay) else {
            edgeWakeTargetScreen = nil
            edgeWakeRequiresHotZone = true
            return
        }
        edgeWakeTargetScreen = nil
        edgeWakeRequiresHotZone = true
        // 顺带搬屏只属于跟随鼠标档；固定档下武装已被上面的咽喉拦住，这里再挡一道
        // arm 与 fire 之间屏幕集合变化的漂移。
        if hoverScreenSwitchingEnabled, let panel = dockPanel, panelCurrentScreen(panel: panel) != screen {
            layoutPanels(contentWidth: lastDesiredWidth, on: screen, animated: false)
        }
        visibilityState.setEdgeAutoHidden(false)
        reconcilePanelVisibility()
    }

    func cancelEdgeWake() {
        edgeWakeTimer?.invalidate()
        edgeWakeTimer = nil
        edgeWakeTargetScreen = nil
        edgeWakeRequiresHotZone = true
    }

    private func edgeWakeShouldStillFire(on screen: NSScreen) -> Bool {
        if edgeWakeRequiresHotZone {
            return isMouseInBottomHotZone(on: screen)
        }
        return screen.frame.contains(NSEvent.mouseLocation)
    }

    func applyPanelVisibility() {
        guard !isSuspendedForPermissionLoss else { return }
        let shouldShow = visibilityState.isVisible
        guard shouldShow != panelsAreVisible else { return }
        panelsAreVisible = shouldShow
        // 角标轮询的零感知门控跟着任务条逻辑显隐走（编排层按「任一单元可见」合并）；恢复时 BadgeStore 会立即读一次。
        onLogicalVisibilityChanged?(shouldShow)
        if Self.edgeHoverTraceEnabled { logEdgeHoverTrace(shouldShow: shouldShow) }
        if shouldShow {
            // 全屏之后的回归淡入（owner 2026-08-30：硬弹出 vs 原生的入场动画）。
            // 只给「因全屏藏过」的揭示做，边缘自动隐藏的唤出保持原来的即时手感。
            let fadeIn = lastHideWasForFullscreen
            lastHideWasForFullscreen = false
            let fadingPanels = [dockGlassBackgroundPanel, dockPanel, capsulePanel].compactMap { $0 }
            if fadeIn { for panel in fadingPanels { panel.alphaValue = 0 } }
            orderDockSurfaceFront()
            capsulePanel?.orderFrontRegardless()
            if drawerWantsOpen { drawerPanel?.orderFrontRegardless() }
            // 实测 orderOut/orderFront 不掉私有空间成员资格，这里只是一次读回；掉了才真的补。
            pinResidentPanelsIfNeeded()
            if fadeIn {
                NSAnimationContext.runAnimationGroup { ctx in
                    // 0.32s + ease-out（owner 2026-08-31「淡入再缓一些、更柔和」）：
                    // 前半段就明显可见（感知上更及时），收尾轻。淡出维持 0.15s 不动。
                    ctx.duration = 0.32
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    for panel in fadingPanels { panel.animator().alphaValue = 1 }
                }
            }
            // 藏起来的这段时间里可能有全屏空间被销毁，系统会顺手把面板从别的桌面上摘掉
            // （issue #19）。健康时这里只是一次 SkyLight 读，不做任何事。
            repairAllSpacesMembershipIfNeeded()
        } else {
            lastHideWasForFullscreen = visibilityState.hideReasons.contains(.fullscreen)
            if lastHideWasForFullscreen { closeDrawer() }
            closeFolderPopup()
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            orderDockSurfaceOut()
            capsulePanel?.orderOut(nil)
            // 淡入若被中途打断，alpha 可能停在半路；藏着的时候归 1，下次显示不带残值。
            for panel in [dockGlassBackgroundPanel, dockPanel, capsulePanel] { panel?.alphaValue = 1 }
        }
    }

    /// `DOCK_EDGEHOVER_TRACE=1` 时每次实际 SHOW/HIDE 切换打一行：单调时钟（`CACurrentMediaTime`，
    /// 不受墙钟调整影响，用于量切换间隔）+ 鼠标坐标 + 是否在底边热区 + 是否在任务条/胶囊矩形内 +
    /// 当前唤醒延迟设置——足够从这一行日志本身看出"为什么"切换，而不只是"切换了"。
    private func logEdgeHoverTrace(shouldShow: Bool) {
        let mouse = NSEvent.mouseLocation
        let inHotZone = dockPanel.map { isMouseInBottomHotZone(on: panelCurrentScreen(panel: $0)) } ?? false
        let inPanelRect = (dockPanel?.frame.contains(mouse) ?? false) || (capsulePanel?.frame.contains(mouse) ?? false)
        print(String(
            format: "[edgehover] %@ t=%.4f mouse=(%.1f,%.1f) hotZone=%@ panelRect=%@ delay=%.2f reasons=%@",
            shouldShow ? "SHOW" : "HIDE",
            CACurrentMediaTime(),
            mouse.x, mouse.y,
            inHotZone ? "1" : "0",
            inPanelRect ? "1" : "0",
            settingsStore.edgeAutoHideDelay,
            "\(visibilityState.hideReasons)"
        ))
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    private func isMouseInBottomHotZone(on screen: NSScreen) -> Bool {
        let mouse = NSEvent.mouseLocation
        guard screen.frame.contains(mouse) else { return false }
        return mouse.y - screen.frame.minY <= Self.hoverHotZone
    }

    private func isMouseOutsideInteractivePanels() -> Bool {
        let mouse = NSEvent.mouseLocation
        if let dock = dockPanel, dock.frame.contains(mouse) { return false }
        if let capsule = capsulePanel, capsule.frame.contains(mouse) { return false }
        if drawerWantsOpen, let drawer = drawerPanel, drawer.frame.contains(mouse) { return false }
        if folderPopupWantsOpen, let popup = folderPopupPanel, popup.frame.contains(mouse) { return false }
        // 唤醒热区贯穿整条屏幕底边，比居中的任务条/胶囊窄矩形宽得多；停在热区内但任务条范围外
        // 若判"已离开"会立刻武装 idle-hide，与刚触发的唤醒反复打架（唤醒→隐藏→唤醒…闪烁）。
        // 只在有限唤醒延迟下才压住——999/-1 两种模式没有这种打架，不该额外改变行为（见规则注释）。
        if EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: settingsStore.edgeAutoHideDelay),
           let dock = dockPanel, isMouseInBottomHotZone(on: panelCurrentScreen(panel: dock)) {
            return false
        }
        return true
    }

    // MARK: - Frame Helpers

    // 这两个不随档位缩放，保持静态常量。
    private static let outerMargin: CGFloat = PanelLayoutMetrics.tungstenEdge.outerMargin
    private static let capsuleGap: CGFloat = PanelLayoutMetrics.tungstenEdge.capsuleGap

    static func screenGeometry(_ screen: NSScreen) -> PanelScreenGeometry {
        PanelScreenGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top)
    }
}
