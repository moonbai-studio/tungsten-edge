import AppKit
import Combine
import Foundation
import os

/// 多屏任务条编排层（多屏路线 ③④，2026-09-02）。
///
/// **一个 `PanelCoordinator` = 一块屏上的一整套任务条**（条 / 底板 / 胶囊 / 抽屉 / 弹窗 / 气泡、
/// 可见性状态机、边缘自动隐藏、全屏保持）。①② 下恰好一个单元、跟随设置；③④ 下每块已连接屏
/// 一个 `.fixed` 单元——它的行为就是已验收的「固定到某屏」档。这里只持有**重复一份会出事**的东西：
/// 唯一的全屏意图 tap、唯一的一套鼠标移动监视器、唯一的拖动控制器、角标门控的合并、
/// 以及按屏集合建 / 拆单元的生命周期。
///
/// 不缓存任何屏幕坐标（Docs/28：面板搬家而缓存不跟着搬是多屏 bug 的通用形状）——
/// 每次都从单元的面板坐标现推。
@MainActor
final class TaskbarScreenOrchestrator: NSObject, WindowLiftAvoidanceHost {
    struct Unit {
        /// nil = 跟随设置的唯一单元（①②）；否则该单元固定的 display UUID（③④）。
        let key: String?
        let coordinator: PanelCoordinator
    }

    private(set) var units: [Unit] = []
    let dragController: DragController
    /// 常驻面板的私有空间宿主：整个进程一个（两块屏共用一个空间即可，实测各面板只在自己的屏上显示）。
    let overlaySpaceHost = OverlaySpaceHost.make()

    private let runtime: AppRuntime
    private let drawerStore: DrawerStore
    private let messagingStore: MessagingAppStore
    private let badgeStore: BadgeStore
    private let stripOrderStore: StripOrderStore
    private let drawerOrderStore: DrawerOrderStore
    private let settingsStore: AppSettingsStore
    private let pinnedFolderStore: PinnedFolderStore
    private let folderCoverStore: PinnedFolderCoverStore
    private let shelfStore: ShelfStore
    private let keptAppStore: KeptAppStore
    private let runningApplicationStore: RunningApplicationStore
    private let appMembershipController: AppMembershipController
    private let displayTopologyStore: DisplayTopologyStore
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "taskbar-screens")

    var onAddFolder: () -> Void = {} {
        didSet { units.forEach { $0.coordinator.onAddFolder = onAddFolder } }
    }
    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)? {
        didSet { units.forEach { $0.coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu } }
    }

    private var started = false
    private var isSuspended = false
    private var placementSubscription: AnyCancellable?
    private var fullscreenIntentEnabledSubscription: AnyCancellable?
    private var fullscreenIntentMonitor: FullscreenIntentMonitor?

    // MARK: 鼠标移动监视器（从 PanelCoordinator 抬上来，逐字保留语义）
    private var hoverLocalMouseMonitor: Any?
    private var hoverGlobalMouseMonitor: Any?
    private var hoverPollThrottle = HoverPollThrottle(minInterval: 1.0 / 30.0)
    /// 菜单跟踪深度（子菜单会嵌套），0 = 当前没有菜单在跟踪。
    private var menuTrackingDepth = 0
    /// 菜单开着期间的底边探测（owner 2026-09-02：状态栏菜单里调完滑块不关菜单、鼠标到底边叫不醒条）。
    /// 监视器摘掉是为了菜单不粘滞——任何全局事件监视器在事件跟踪模式下都会拖慢送达；而
    /// `.common` 模式的 Timer 不拦事件、菜单跟踪期间照常触发，用它代替监视器跑 `pollMousePosition`。
    private var menuTrackingPollTimer: Timer?
    private static let menuHoverSuspensionEnabled = ProcessInfo.processInfo.environment["DOCK_MENU_HOVER_SUSPEND"] != "0"
    /// 监视器按需化 + 节流（DOCK_HOVER_MONITOR_LEAN=0 回退为常驻 + 每事件全量处理）。
    private static let hoverMonitorLeanEnabled = ProcessInfo.processInfo.environment["DOCK_HOVER_MONITOR_LEAN"] != "0"

    init(runtime: AppRuntime,
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
        self.dragController = DragController(
            drawerStore: drawerStore,
            messagingStore: messagingStore,
            keptAppStore: keptAppStore,
            dropZonesProvider: { [weak dragHost] source in dragHost?.dragDropZones(for: source) ?? [] },
            // 一块屏一套载体面板（`DragController.CarrierSurface`），按指针所在屏切换——
            // 「显示器具有单独的空间」下一个窗口只属于一块屏，铺并集反而在另一块屏上画不出来。
            screensProvider: { NSScreen.screens },
            // 松在胶囊上收纳时图标吸进这里（鼠标所在屏那个单元的胶囊可视帧）。
            stashTargetProvider: { [weak dragHost] in dragHost?.stashTargetFrame }
        )
        super.init()
        dragHost.owner = self
        wireDragController()
    }

    deinit {
        MainActor.assumeIsolated {
            removeHoverMouseMonitorsOnly()
        }
        menuTrackingPollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// `DragController` 在 `super.init()` 之前创建，闭包不能捕获 self——借一个小代理转发。
    @MainActor
    private final class DragHost {
        weak var owner: TaskbarScreenOrchestrator?
        func dragDropZones(for source: DragSource) -> [CGRect] {
            owner?.units.flatMap { $0.coordinator.dragDropZones(for: source) } ?? []
        }
        var stashTargetFrame: CGRect? {
            guard let owner else { return nil }
            return (owner.unitContainingMouse() ?? owner.units.first)?.coordinator.capsuleVisibleFrame
        }
    }
    private let dragHost = DragHost()

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        rebuildUnits(reason: "start")
        // 载体面板提前建好，别让用户的第一次拖动付那 20ms + 一次 39ms 主线程卡顿
        // （理由与实测见 `DragController.prewarmCarrier`）。**排到下一轮 run loop**：
        // 启动是一整笔首帧事务，不能往里塞额外的 SwiftUI 布局。
        DispatchQueue.main.async { [weak dragController] in
            dragController?.prewarmCarrier()
        }
        observeMenuTracking()
        reconcileHoverMouseMonitors()
        reconcileFullscreenIntentMonitor()
        placementSubscription = settingsStore.$taskbarScreenPlacement
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.rebuildUnits(reason: "placement")
                self.reconcileHoverMouseMonitors()
            }
        fullscreenIntentEnabledSubscription = settingsStore.$fullscreenIntentEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileFullscreenIntentMonitor() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// 权限丢失：拆掉全部单元与共享件。不做对称的 resume（权限恢复后是整个进程重启）。
    func suspendAndRelease() {
        guard !isSuspended else { return }
        isSuspended = true
        // 先回滚未提交的跨面板拖拽事务，再拆监视器；常驻的载体面板也要显式收掉。
        dragController.cancelDrag()
        dragController.closeCarrierSurfaces()
        removeHoverMouseMonitors()
        stopMenuTrackingPoll()
        fullscreenIntentMonitor?.stop()
        fullscreenIntentMonitor = nil
        for unit in units {
            unit.coordinator.setFullscreenIntentRouting(enabled: false)
            unit.coordinator.tearDown()
        }
        units = []
        placementSubscription = nil
        fullscreenIntentEnabledSubscription = nil
        NotificationCenter.default.removeObserver(self)
    }

    func toggleDrawer() {
        (unitContainingMouse() ?? units.first)?.coordinator.toggleDrawer()
    }

    func setTaskbarMenuOpen(_ open: Bool) {
        units.forEach { $0.coordinator.setTaskbarMenuOpen(open) }
    }

    // MARK: - 单元集合

    private var connectedDisplayUUIDs: [String] {
        NSScreen.screens.compactMap { DisplayIdentity.uuidString(for: $0) }
    }

    /// 按当前设置与屏集合建 / 拆单元。目标 key 列表没变就什么都不做（幂等，可在任何通知里调）。
    private func rebuildUnits(reason: String) {
        guard started, !isSuspended else { return }
        let desired = TaskbarDisplaySet.desiredUnitKeys(
            placement: settingsStore.taskbarScreenPlacement,
            connectedKeys: connectedDisplayUUIDs
        )
        let current = units.map(\.key)
        guard desired != current else { return }
        let desiredSet = Set(desired.map { $0 ?? "" })
        var survivors: [String?: Unit] = [:]
        for unit in units {
            if desiredSet.contains(unit.key ?? "") {
                survivors[unit.key] = unit
            } else {
                unit.coordinator.setFullscreenIntentRouting(enabled: false)
                unit.coordinator.tearDown()
            }
        }
        units = desired.map { key in survivors[key] ?? makeUnit(key: key) }
        logger.info("units rebuilt reason=\(reason, privacy: .public) count=\(self.units.count, privacy: .public)")
        pushPanelScreensToIntentMonitor()
        reconcileBadgeGate()
    }

    private func makeUnit(key: String?) -> Unit {
        let placement: TaskbarUnitPlacement = key.map { .fixed(displayUUID: $0) } ?? .followSettings
        let coordinator = PanelCoordinator(
            placement: placement,
            dragController: dragController,
            overlaySpaceHost: overlaySpaceHost,
            runtime: runtime,
            drawerStore: drawerStore,
            messagingStore: messagingStore,
            badgeStore: badgeStore,
            stripOrderStore: stripOrderStore,
            drawerOrderStore: drawerOrderStore,
            settingsStore: settingsStore,
            pinnedFolderStore: pinnedFolderStore,
            folderCoverStore: folderCoverStore,
            shelfStore: shelfStore,
            keptAppStore: keptAppStore,
            runningApplicationStore: runningApplicationStore,
            appMembershipController: appMembershipController,
            displayTopologyStore: displayTopologyStore
        )
        coordinator.onAddFolder = onAddFolder
        coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu
        coordinator.onHoverMonitorsNeedReconcile = { [weak self] in self?.reconcileHoverMouseMonitors() }
        coordinator.onPanelScreenChanged = { [weak self] in self?.pushPanelScreensToIntentMonitor() }
        coordinator.onLogicalVisibilityChanged = { [weak self] _ in self?.reconcileBadgeGate() }
        coordinator.onAccessoryWillOpen = { [weak self] unit, kind in
            self?.closeAccessories(exceptFor: unit, opening: kind)
        }
        coordinator.start()
        coordinator.setFullscreenIntentRouting(enabled: fullscreenIntentMonitor != nil)
        return Unit(key: key, coordinator: coordinator)
    }

    private func unitContainingMouse() -> Unit? {
        let mouse = NSEvent.mouseLocation
        return units.first { $0.coordinator.currentScreen?.frame.contains(mouse) == true }
    }

    private func unit(forDisplayUUID uuid: String) -> Unit? {
        if let unit = units.first(where: { $0.key == uuid }) { return unit }
        // ①② 的唯一单元 key 为 nil：按它此刻所在的屏匹配。
        return units.first { unit in
            unit.coordinator.currentScreen.flatMap { DisplayIdentity.uuidString(for: $0) } == uuid
        }
    }

    @objc private func screenParametersChanged() {
        dragController.cancelDrag()   // 切屏/分辨率变 → 取消进行中的跨面板拖动，免得载体留在旧屏坐标
        // 先按屏集合建 / 拆（③④），再转给幸存者各自归位 / 重布局。
        rebuildUnits(reason: "screens")
        units.forEach { $0.coordinator.screenParametersChanged() }
        pushPanelScreensToIntentMonitor()
        reconcileHoverMouseMonitors()  // 屏幕数量变了：单屏↔多屏切换监视器是否还有存在的必要
    }

    /// 同时只开一个抽屉 / 弹窗 / 气泡：某单元要开时关掉其他单元的。
    /// 抽屉与弹窗互斥（同一层级的附属面板）；气泡只跟气泡互斥（悬停不该收掉别的屏上开着的抽屉）。
    private func closeAccessories(exceptFor unit: PanelCoordinator, opening kind: PanelCoordinator.AccessoryKind) {
        for other in units where other.coordinator !== unit {
            switch kind {
            case .drawer, .popup:
                other.coordinator.closeDrawer()
                other.coordinator.closeFolderPopup()
                other.coordinator.dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            case .tooltip:
                other.coordinator.dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            }
        }
    }

    /// 角标轮询门控：任一单元逻辑可见即可见。
    private func reconcileBadgeGate() {
        badgeStore.setTaskbarVisible(units.contains { $0.coordinator.isLogicallyVisible })
    }

    // MARK: - 最大化避让宿主

    /// 每个常驻且可见的单元一份（③④ 下每块屏各自避让；某块屏的条藏着就不抬那块屏的窗）。
    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext] {
        units.compactMap { $0.coordinator.windowLiftAvoidanceContext() }
    }

    // MARK: - 拖动控制器接线（store 级副作用）

    private func wireDragController() {
        // 文件夹 chip 拖动落定：几何由 DockStripView 写入 DragController，最终 mouseUp/轮询兜底在
        // endDrag 里回调到这里执行副作用。保持 .folder 与 strip/drawer 收纳语义隔离。
        dragController.onFolderDragEnded = { [pinnedFolderStore] path, zone in
            switch zone {
            case .folderZone:
                break
            case .outsideStrip:
                pinnedFolderStore.remove(path)
            case .liveZone:
                pinnedFolderStore.remove(path)
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
        // 抽屉拖回任务条·精确落点：成功松手落定时清顺序层的外部块暂存追踪（boundIDs 已是正常成员、留任务条）。
        dragController.onDrawerToStripCommitted = { [stripOrderStore] _ in
            stripOrderStore.commitExternalBlock()
        }
        // 抽屉拖回任务条·异常取消（cancelDrag）：回滚顺序层的外部块暂存（删 boundIDs + 清 absentSince + 清暂存）。
        dragController.onDrawerToStripCancelled = { [stripOrderStore] in
            stripOrderStore.cancelExternalBlock()
        }
        // 抽屉图标落进任务条（精确落点 + 降级路径都触发）→ 关闭抽屉（关着的单元是空操作）。
        dragController.onDrawerToStripCompleted = { [weak self] _ in
            self?.units.forEach { $0.coordinator.closeDrawerAfterAction() }
        }
        // 跨屏投放（③④）：卡松在另一块屏的任务条上 → 窗口搬到那块屏（只搬不置前）/ 无窗口图标改住那块屏。
        // 载体面板每屏一块、常驻最上层；任务条钉进私有空间后桌面空间的窗口不论 level 都被压在它下面，
        // 载体也得钉进同一空间（理由见 `DragController.pinCarrierWindows`）。
        dragController.pinCarrierWindows = { [weak self] numbers in
            guard let host = self?.overlaySpaceHost else { return }
            _ = host.pin(windowNumbers: numbers)
        }
        dragController.onCrossStripDrop = { [runtime] payload, displayUUID in
            runtime.handleCrossStripDrop(payload: payload, toDisplayUUID: displayUUID)
        }
    }

    // MARK: - 全屏意图 tap（全进程唯一）

    private func reconcileFullscreenIntentMonitor() {
        let enabled = FullscreenIntentDecision.isEnabled(
            settingEnabled: settingsStore.fullscreenIntentEnabled,
            environment: ProcessInfo.processInfo.environment
        )
        guard enabled, !isSuspended else {
            fullscreenIntentMonitor?.stop()
            fullscreenIntentMonitor = nil
            units.forEach { $0.coordinator.setFullscreenIntentRouting(enabled: false) }
            return
        }
        guard fullscreenIntentMonitor == nil else { return }
        let monitor = FullscreenIntentMonitor(
            // 广播：每个单元用自己的 screenCGFrame 守卫决定动不动手——一块屏进全屏只藏那块屏的条。
            onIntent: { [weak self] request in
                self?.units.forEach { $0.coordinator.beginFullscreenIntent(request) }
            },
            // 空间切换按显示器发生：tap 已定位到那块屏，路由给它的单元；找不到就按鼠标所在屏兜底。
            onSpaceSwitchIntent: { [weak self] direction, displayUUID in
                guard let self else { return }
                let target = self.unit(forDisplayUUID: displayUUID) ?? self.unitContainingMouse() ?? self.units.first
                target?.coordinator.beginFullscreenSpaceIntent(direction: direction)
            },
            onContextChange: { [weak self] change in
                self?.units.forEach { $0.coordinator.handleFullscreenIntentContextChange(change) }
            }
        )
        fullscreenIntentMonitor = monitor
        monitor.updatePanelScreens(currentPanelScreenCGFrames)
        monitor.start()
        units.forEach { $0.coordinator.setFullscreenIntentRouting(enabled: true) }
    }

    private var currentPanelScreenCGFrames: Set<CGRect> {
        Set(units.compactMap { $0.coordinator.currentPanelScreenCGFrame() })
    }

    private func pushPanelScreensToIntentMonitor() {
        fullscreenIntentMonitor?.updatePanelScreens(currentPanelScreenCGFrames)
    }

    // MARK: - 鼠标移动监视器（全进程一套，转发给每个单元）

    /// 鼠标移动监视器只服务两件事：**多屏悬停切换**（单屏无对象；固定到某屏 / 所有屏都显示时也无对象）与
    /// **边缘自动隐藏**（没开就没有计时对象）。都不成立时干脆不装——「指针每动一下进一次回调」
    /// 的常驻成本归零；屏幕数或设置变化时重新评估（诊断开关 DOCK_EDGEHOVER_TRACE=1 强制常驻）。
    private var hoverMonitorsNeeded: Bool {
        guard Self.hoverMonitorLeanEnabled else { return true }
        return (NSScreen.screens.count > 1 && settingsStore.taskbarScreenPlacement.allowsHoverScreenSwitching)
            || settingsStore.edgeAutoHideEnabled
            || PanelCoordinator.edgeHoverTraceEnabled
    }

    private func reconcileHoverMouseMonitors() {
        guard started, !isSuspended else { return }
        guard menuTrackingDepth == 0 else { return }   // 菜单跟踪期间由挂起逻辑接管
        if hoverMonitorsNeeded {
            installHoverMouseMonitors()
            pollAllUnits()
        } else {
            removeHoverMouseMonitors()
        }
    }

    /// 任何一个钨极菜单开着时统一办两件事。用 `NSMenu` 的应用级跟踪通知，一处覆盖全部菜单
    /// （图标 / 抽屉 / 文件夹 / 胶囊 / 状态栏）；子菜单会让通知嵌套，所以按深度计数。
    ///
    /// 1. **挂上「别自动隐藏」的保险**。菜单弹在任务条上方，鼠标一往上够菜单项，对边缘自动隐藏
    ///    就算离开了任务条，0.2s 空闲计时照跑把条缩掉；而菜单是挂在条上那个图标的视图上的，
    ///    条一没菜单跟着一起没（issue #42：右键图标后鼠标移到「新建窗口」上菜单就消失、点不着）。
    ///    保险本身 2026-08-04 就有，但当时只接在状态栏那一个菜单上（`StatusMenuController`），
    ///    图标菜单一直漏着。
    /// 2. **摘掉鼠标移动监视器**（owner 2026-08-04 报「菜单里两个选项之间来回晃有粘滞感」）。
    ///    `addGlobalMonitorForEvents` 在系统底层是一个事件拦截器；钨极自己弹菜单时主循环切进事件跟踪模式，
    ///    拦截器的处理入口在该模式下不被服务，每个鼠标移动事件都要等到超时才继续送达——菜单高亮慢半拍。
    ///
    /// **`DOCK_MENU_HOVER_SUSPEND=0` 只关第 2 件**——它是那个手感优化的杀开关。通知注册本身
    /// 必须无条件进行，否则关掉手感优化会连带把 #42 那个保险也关掉。
    private func observeMenuTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidBegin),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    @objc private func menuTrackingDidBegin() {
        menuTrackingDepth += 1
        guard menuTrackingDepth == 1 else { return }
        setTaskbarMenuOpen(true)
        guard Self.menuHoverSuspensionEnabled else { return }
        removeHoverMouseMonitorsOnly()
        startMenuTrackingPollIfNeeded()
    }

    @objc private func menuTrackingDidEnd() {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
        guard menuTrackingDepth == 0 else { return }
        setTaskbarMenuOpen(false)
        stopMenuTrackingPoll()
        // 装回来（若仍需要）并立刻补一次判断——摘掉的这段时间里鼠标可能已经跨屏或离开热区。
        reconcileHoverMouseMonitors()
    }

    /// 菜单开着时用 `.common` 模式定时器代替监视器做底边探测（≤30Hz，与监视器节流同频）。
    /// 只在监视器本来就该在的情形下跑；菜单一关即停、监视器装回。
    private func startMenuTrackingPollIfNeeded() {
        guard menuTrackingPollTimer == nil, started, !isSuspended, hoverMonitorsNeeded else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAllUnits() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuTrackingPollTimer = timer
    }

    private func stopMenuTrackingPoll() {
        menuTrackingPollTimer?.invalidate()
        menuTrackingPollTimer = nil
    }

    private func installHoverMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // 监视器回调在安装线程（主线程）送达，assumeIsolated 免去每事件一次 Task 分配。
        if hoverLocalMouseMonitor == nil {
            hoverLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.hoverPollEventArrived() }
                return event
            }
        }
        if hoverGlobalMouseMonitor == nil {
            hoverGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverPollEventArrived() }
            }
        }
    }

    /// 每个鼠标移动事件都进这里（移动时可达上百 Hz）。节流到 ≤30Hz：悬停切换要 350ms 驻留、
    /// 边缘唤醒对 33ms 无感；窗口内恰好停住的最后一个位置由 trailing 收尾补判，不丢热区进出。
    private func hoverPollEventArrived() {
        guard Self.hoverMonitorLeanEnabled else {
            // 旧行为原样：每事件经一次主线程 Task 跳转后全量处理。
            Task { @MainActor [weak self] in self?.pollAllUnits() }
            return
        }
        switch hoverPollThrottle.eventArrived(now: CACurrentMediaTime()) {
        case .run:
            pollAllUnits()
        case .scheduleTrailing(let after):
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hoverPollThrottle.trailingFired(now: CACurrentMediaTime())
                    self.pollAllUnits()
                }
            }
        case .drop:
            break
        }
    }

    private func pollAllUnits() {
        units.forEach { $0.coordinator.pollMousePosition() }
    }

    /// 只摘监视器，**不碰**唤醒/切屏状态——那些由 `removeHoverMouseMonitors` 在真正拆除时负责。
    /// 菜单开着的这一两秒里把 `cancelEdgeWake()` 一起做掉的话，隐藏状态下打开状态栏菜单
    /// 会顺手取消掉正在武装的底边唤醒，属于额外的行为改动。
    private func removeHoverMouseMonitorsOnly() {
        if let monitor = hoverLocalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            hoverLocalMouseMonitor = nil
        }
        if let monitor = hoverGlobalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            hoverGlobalMouseMonitor = nil
        }
    }

    private func removeHoverMouseMonitors() {
        removeHoverMouseMonitorsOnly()
        hoverPollThrottle.reset()
        for unit in units {
            unit.coordinator.cancelHoverSwitch()
            unit.coordinator.cancelEdgeWake()
        }
    }
}
