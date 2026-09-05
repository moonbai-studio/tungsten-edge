import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

struct AppEntry {
    let pid: pid_t
    let bundleIdentifier: String?
    let appName: String
    let activationPolicy: NSApplication.ActivationPolicy
    let executablePath: String?
    var windowsByID: [CGWindowID: WindowEntry]
    var windowOrder: [CGWindowID]
    var isHidden: Bool
    /// 影子标签池：上一轮対账时「在 CG 全列表(本 pid, layer 0)、却不在 AXWindows」的窗口 id——
    /// order-out 后台标签独有的签名（真窗口不管可见/最小化/隐藏/其它 Space 都始终在 AXWindows 里）。
    /// Pass B 折叠判定第二级用它兜住「成员历史被 dock 重启清零」的缺口；每轮从活信号重建，
    /// 不依赖持久化。判定用上一轮的池（最小化爆发瞬间所有标签涌进 AX，本轮现算会是空的）。
    var shadowTabCgIDs: Set<CGWindowID> = []
    /// 这个 app 的窗口最后在哪块屏（display UUID）。窗口全关后「在运行但没窗口」的兜底卡落在这儿
    ///（多屏 ④：有圆点的图标只在一条上，owner 2026-09-02）；把那张卡拖到另一块屏的条上也写这里
    ///（`noteNoWindowHome`）。会话内记忆，不持久化；nil → 投影层落主屏。
    var lastWindowDisplayUUID: String? = nil
}

/// 一个**物理窗口座位**（单座位模型）。`cgWindowID` 是它**当前**的可见标签（= 动作落点），会随
/// 切标签而变；`token` 是座位的稳定身份，一旦分配**永不变**（即使 activeCgID 被顶替）——这就是
/// 切标签/最小化时卡片不跳不裂的根。后台标签【不】单独占座位。
struct WindowEntry {
    var cgWindowID: CGWindowID   // 当前可见标签的 cgID（动作落点），切标签时被顶替
    let token: String            // 物理座位稳定身份（tabgrp-<pid>-<种子cgID>），永不变
    var title: String
    var bounds: CGRect?
    var isMinimized: Bool
    var isFocused: Bool
    /// min/隐藏保留分支里的 AX 连续缺席起始时刻。
    /// 只喂给幽灵座位自愈判定（PhantomSeatDecision，五门槛），重新在 AX 出现随 make() 自然清零。
    var minAbsentSince: Date? = nil
    /// 仅用于诊断：与 `minAbsentSince` 同时置位/清除，标识一次连续 AX 缺席 episode。
    /// 不参与座位签名、折叠或自愈判断。
    var absenceEpisodeID: UUID? = nil
    /// 这个座位是否曾以 min=false 出现在 AX 里（座位延续时继承）。真窗口几乎必然可见过；
    /// 幽灵座位（折叠失手时从 min=true 爆发候选裂出来的）永远是 false——自愈判定的头号门槛，
    /// 同时保护 Safari 式「一最小化就整个离开 AX」的真窗口不被自愈误删。
    var everSeenVisible: Bool = false
    /// 曾经当过这个座位 activeCgID 的标签（切标签被顶替时记入；折叠成功且归属唯一时也学习记入）。
    /// 标签创建即成为活跃标签 ⇒ 每个后台标签都在所属座位历史里。Pass B 折叠优先按此成员关系
    /// 判定，与几何、min 标志无关——豁免「窗口移动/缩放后后台标签 AX 几何过时」与「min 滞后
    /// 竞态」两类折叠失效（分裂 bug 根治）。防 cgID 复用误折叠：真销毁(tombstone)时全局清除、
    /// 每轮对账与 CG 全列表求交集；拽出(tear-out)被赶走的标签【不】记入（它是独立窗口了）。
    var formerCgIDs: Set<CGWindowID> = []
    /// 窗口在哪块屏（display UUID，粗粒度归属键，`WindowDisplayAttribution`）。**只在座位可见时更新**
    /// （AX 读到 min=false 且 app 未隐藏；5s tick 的 CG bounds 遍历；屏参数变化时按已存帧重算），
    /// 最小化 / ⌘H 期间冻结在最后可见的屏（多屏 ④「最小化的卡留在原屏」）。进 `seatSignature`，
    /// **坐标本身永不进指纹**——否则每移动一像素都重建整条。
    var displayUUID: String? = nil
    /// 跨屏拖窗的乐观更新后**冻结**归属键：AX 写帧还在动作队列上飞，这期间落地的读（前台
    /// 轮询 / tick 的 CG 遍历）看到的还是旧位置，不冻结就会把卡弹回来源屏再跳回去。
    /// `.distantFuture` = 钉死到它下次在 AX 里可见为止（AX 拿不到句柄、搬不动的离屏 / 幽灵窗口：
    /// 拖到别的条上就当「改住址」，CG 里那份旧坐标不作数）。
    var displayUUIDHoldUntil: Date? = nil
}

protocol AppTrackerProcessProviding: Sendable {
    func isAlive(pid: pid_t) -> Bool
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity
}

struct LiveAppTrackerProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool {
        ProcessLiveness.isAlive(pid: pid)
    }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        let start = ProcessLiveness.startTime(pid: pid)
        return ScanAdmissionDecision.ProcessIdentity(
            pid: pid,
            startTimeSec: start.map { Int64($0.tv_sec) },
            startTimeUsec: start.map { $0.tv_usec },
            bundleID: bundleID
        )
    }
}

@MainActor
final class AppTracker: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot = .empty

    private var apps: [pid_t: AppEntry] = [:]
    private var appOrder: [pid_t] = []
    private var observers: [pid_t: AppWindowObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var reconcileTimer: Timer?
    private var frontmostPollTimer: Timer?
    private var isScanningCandidates = false
    /// 动作路径用的 AX 元素旁路缓存。写在这里（盘点读本来就拿着元素），读在
    /// `PlatformActionExecutor`。刻意不进 `DockSnapshot`，理由见 `AXElementCache`。
    private let elementCache = AXElementCache.shared
    private var destroyedCGIDs: [CGWindowID: Date] = [:]
    private static let tombstoneTTL: TimeInterval = 3.0
    /// 幽灵座位自愈门槛：min 保留的座位 AX 连续缺席多久后才允许进入 PhantomSeatDecision 判定
    /// （还要过 everSeenVisible / CG 在场 / AX 读健康 / 有 AX 在场兄弟座位 四道门）。
    private static let phantomReapGrace: TimeInterval = 10.0

    /// 上次重建快照时的 CG on-screen 集合。前台轮询据此发现「切标签」——AX 可能完全不报，
    /// 但 on-screen 集合会即时变化，变了就重建（标签组可见标签随之即时更新）。
    private var lastOnScreenCGIDs: Set<CGWindowID> = []

    /// 物理座位 token 的全局自增序号。保证每个新座位拿到唯一 token（绝不从会复用的 cgID 派生）。
    private var nextSeatSerial: Int = 0

    private struct ShadowPoolDiagnosticState {
        var initialized = false
        var updateWasSkipped = false
        var lastSuccessfulRoundID: UInt64?
    }

    private var nextInventoryRoundID: UInt64 = 0
    private var reconcileOrdinalsByPID: [pid_t: UInt64] = [:]
    private var lastReconcileAtByPID: [pid_t: Date] = [:]
    private var shadowPoolDiagnosticsByPID: [pid_t: ShadowPoolDiagnosticState] = [:]
    private var heldLogDeduplicator = InventoryPhantomHeldDeduplicator()

    private struct PendingEventRead {
        let token: UInt64
        let mutationGeneration: UInt64
        let identity: ScanAdmissionDecision.ProcessIdentity
        let source: InventoryReconcileSource
    }

    private var nextEventReadToken: UInt64 = 0
    private var pendingEventReads: [pid_t: PendingEventRead] = [:]
    private var trailingEventSources: [pid_t: InventoryReconcileSource] = [:]
    private var mutationGenerations: [pid_t: UInt64] = [:]

    private let reader: any AppTrackerWindowReading
    private let processProvider: any AppTrackerProcessProviding
    private let cgSnapshotProvider: @Sendable () -> AppTrackerCGWindowSnapshot
    private let onScreenWindowIDsProvider: @Sendable () -> Set<CGWindowID>
    private let eventAXAsyncEnabled: Bool
    /// 周期对账（5s tick）的 AX 读超时。默认 100ms、限时后台批量读；nil（DOCK_RECONCILE_AX_TIMEOUT_MS=0）
    /// 回退旧路径：主线程逐 pid 不限时同步读。DOCK_EVENT_AX_ASYNC=0 的同步兼容路径同样走旧路径。
    private let periodicReconcileTimeout: TimeInterval?
    /// 周期对账跳读门控（DOCK_RECONCILE_SKIP=0 关闭）。只作用于批读路径；旧同步路径不受影响。
    private let reconcileSkipEnabled: Bool
    private let uptimeProvider: () -> TimeInterval
    /// 在场屏幕表（`DisplayTopologyStore` 那张），屏参数变化时刷新缓存；测试注入固定表。
    private let displayTableProvider: @MainActor () -> WindowDisplayAttribution.Table
    private var displayTable: WindowDisplayAttribution.Table
    private var screenParametersObserver: NSObjectProtocol?

    /// 跳读门控的 per-pid 状态。由**任何来源**的成功全读在 reconcileSeats 尾部刷新
    ///（前台 pid 因 2Hz 前台轮询天然常新、可被周期 tick 跳过）；AX/workspace 事件置脏。
    private struct ReconcileGateState {
        var lastCGIDs: Set<CGWindowID>
        var lastFullReadUptime: TimeInterval
        var dirty: Bool
        var lastReadWasUnread: Bool
        var lastRoundChanged: Bool
    }

    private var gateStates: [pid_t: ReconcileGateState] = [:]

    /// 前台 app 的事件缓存。`NSWorkspace.frontmostApplication` 每次读都是一趟同步 LS XPC
    /// （改造前：前台轮询 2Hz + 每次 rebuildSnapshot 再各一趟——2026-08-22 真空闲归因里剩余
    /// LS 开销的主源）。didActivate 通知维护（对**所有**激活生效，不限 regular，缓存必须反映
    /// 真实前台）；5s reconcile 用一次真实查询自愈，错过通知的最坏错位 ≤5s，且激活高亮的
    /// 正确性只依赖 rebuildSnapshot 时的取值，事后一定被下一次激活/自愈纠正。
    /// DOCK_FRONTMOST_CACHE=0 回退为每次真实查询。
    private let frontmostCacheEnabled: Bool
    private var cachedFrontmostPID: pid_t?

    /// 事件读路径的 CG 全表复用门控（DOCK_CG_SNAPSHOT_REUSE=0 关闭）。决策与顺序硬规则见
    /// `CGSnapshotReuseDecision`；缓存只被事件读路径的**现拍**刷新（复用轮不刷新年龄，否则
    /// 年龄上限失效），5s reconcile 的批量路径不读不写它。
    private let cgSnapshotReuseEnabled: Bool
    /// 全局事件代数：任何 AX/workspace 事件（markReconcileGateDirty、app 增删）都递增。
    /// 缓存记录拍摄时的代数，代数变了 → 下一次事件读现拍。全局而非 per-pid 是刻意保守。
    private var cgEventGeneration: UInt64 = 0
    private var cachedCGSnapshot: AppTrackerCGWindowSnapshot?
    private var cachedCGProbeIDs: Set<CGWindowID>?
    private var cachedCGAtUptime: TimeInterval = -.infinity
    private var cachedCGGeneration: UInt64 = 0

    /// 补扫探测门控（DOCK_SCAN_GATE=0 关闭）状态。memo 只记「无合格窗口」的结论；
    /// dirty 由 workspace 启动通知置位；慢速全扫每 60s 兜一次门控漏洞。
    private let scanGateEnabled: Bool
    private var scanMemos: [pid_t: ScanProbeGateDecision.Memo] = [:]
    private var scanDirtyPIDs: Set<pid_t> = []
    private var lastFullScanUptime: TimeInterval?
    /// 补扫候选名单缓存（pid + bundleID）。`NSWorkspace.runningApplications` 的属性访问
    /// （processIdentifier / bundleIdentifier / isTerminated…）**每个 app 都是一次同步
    /// LaunchServices XPC**——2026-08-22 真空闲归因里它是补扫成本的大头（118/142 样本），
    /// 应用越多越贵。名单只在成员可能变化时重建（启动/退出/收编置脏 + 60s 慢扫兜底），
    /// 安静 tick 完全不碰 NSWorkspace；候选活性用 ProcessLiveness、身份用探测时代际重查兜底。
    private var scanCandidateCache: [(pid: pid_t, bundleID: String?)]?
    #if DEBUG
    /// 测试专用：fixture pid 建不出真 AXObserver，跳读门控的 observerActive 判据用它覆盖。
    private var observerActiveOverridesForTesting: [pid_t: Bool] = [:]
    #endif
    private let windowEligibility = AppTrackerWindowEligibility()
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "app-tracker")
    private let inventoryLog: WindowInventoryAnomalyLog

    init(
        inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog(),
        reader: any AppTrackerWindowReading = AXWindowReader(),
        processProvider: any AppTrackerProcessProviding = LiveAppTrackerProcessProvider(),
        cgSnapshotProvider: @escaping @Sendable () -> AppTrackerCGWindowSnapshot = {
            AppTrackerCGWindowSnapshot.capture()
        },
        onScreenWindowIDsProvider: @escaping @Sendable () -> Set<CGWindowID> = {
            AppTrackerCGWindowSnapshot.captureOnScreenWindowIDs()
        },
        eventAXAsyncEnabled: Bool = ProcessInfo.processInfo.environment["DOCK_EVENT_AX_ASYNC"] != "0",
        periodicAXTimeoutMS: Int = Int(ProcessInfo.processInfo.environment["DOCK_RECONCILE_AX_TIMEOUT_MS"] ?? "") ?? 100,
        reconcileSkipEnabled: Bool = ProcessInfo.processInfo.environment["DOCK_RECONCILE_SKIP"] != "0",
        scanGateEnabled: Bool = ProcessInfo.processInfo.environment["DOCK_SCAN_GATE"] != "0",
        frontmostCacheEnabled: Bool = ProcessInfo.processInfo.environment["DOCK_FRONTMOST_CACHE"] != "0",
        cgSnapshotReuseEnabled: Bool = ProcessInfo.processInfo.environment["DOCK_CG_SNAPSHOT_REUSE"] != "0",
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        displayTableProvider: @escaping @MainActor () -> WindowDisplayAttribution.Table = { .empty }
    ) {
        self.inventoryLog = inventoryLog
        self.displayTableProvider = displayTableProvider
        self.displayTable = displayTableProvider()
        self.reader = reader
        self.processProvider = processProvider
        self.cgSnapshotProvider = cgSnapshotProvider
        self.onScreenWindowIDsProvider = onScreenWindowIDsProvider
        self.eventAXAsyncEnabled = eventAXAsyncEnabled
        self.periodicReconcileTimeout = periodicAXTimeoutMS > 0 ? TimeInterval(periodicAXTimeoutMS) / 1000.0 : nil
        self.reconcileSkipEnabled = reconcileSkipEnabled
        self.scanGateEnabled = scanGateEnabled
        self.frontmostCacheEnabled = frontmostCacheEnabled
        self.cgSnapshotReuseEnabled = cgSnapshotReuseEnabled
        self.uptimeProvider = uptimeProvider
    }

    func start() {
        guard workspaceObservers.isEmpty else { return }
        let info = Bundle.main.infoDictionary
        inventoryLog.record(.sessionStart(InventorySessionStartPayload(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            processID: ProcessInfo.processInfo.processIdentifier,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )))
        // 通知先订阅再 seed：seed 期间的启动/退出事件不再漏（addApp 有 apps[pid] == nil guard，重复准入安全）。
        subscribeWorkspaceNotifications()
        // 屏参数变化：跳一拍再刷，让 `DisplayTopologyStore` 的同步观察者先把表换好。
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenParametersChanged() }
        }
        displayTable = displayTableProvider()
        seedRunningApps()
        startReconcileTimer()
        startFrontmostPollTimer()
        // seed 后补扫四轮：挂死 app 在 seed 限时读里会被跳过，补扫用 inventoryWindows 限时读逐步收入。
        for delay in [0.5, 1.0, 2.0, 4.0] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.scanNonAdmittedApps()
            }
        }
    }

    func stop() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        frontmostPollTimer?.invalidate()
        frontmostPollTimer = nil
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        for obs in observers.values { obs.stop() }
        observers.removeAll()
        apps.removeAll()
        appOrder.removeAll()
        destroyedCGIDs.removeAll()
        reconcileOrdinalsByPID.removeAll()
        lastReconcileAtByPID.removeAll()
        shadowPoolDiagnosticsByPID.removeAll()
        heldLogDeduplicator.removeAll()
        pendingEventReads.removeAll()
        trailingEventSources.removeAll()
        mutationGenerations.removeAll()
        gateStates.removeAll()
        scanMemos.removeAll()
        scanDirtyPIDs.removeAll()
        lastFullScanUptime = nil
        scanCandidateCache = nil
        cachedFrontmostPID = nil
        snapshot = .empty
        inventoryLog.flush()
    }

    // MARK: - Tombstone

    private func isTombstoned(_ cgID: CGWindowID) -> Bool {
        guard let removedAt = destroyedCGIDs[cgID] else { return false }
        return Date().timeIntervalSince(removedAt) <= Self.tombstoneTTL
    }

    private func purgeStaleTombstones() {
        let now = Date()
        destroyedCGIDs = destroyedCGIDs.filter { _, date in
            now.timeIntervalSince(date) <= Self.tombstoneTTL
        }
    }

    /// cgID 会被系统复用：窗口真销毁时立刻从所有座位历史(formerCgIDs)和影子标签池里清除该
    /// cgID，防止它复用到新窗口后被成员/影子池折叠误吸。跨 pid 清（cgID 全局唯一、复用不认进程）。
    private func purgeFromSeatHistories(_ cgID: CGWindowID) {
        for pid in appOrder {
            guard var app = apps[pid] else { continue }
            var touched = false
            if app.shadowTabCgIDs.remove(cgID) != nil { touched = true }
            for wid in app.windowOrder where app.windowsByID[wid]?.formerCgIDs.contains(cgID) == true {
                app.windowsByID[wid]?.formerCgIDs.remove(cgID)
                touched = true
            }
            if touched { apps[pid] = app }
        }
    }

    /// 「同 pid + 逐像素相同 frame」键。物理座位据此认领"切标签顶替"的新当前标签：同一物理窗口的
    /// 各标签 frame 完全一致，新当前标签会出现在座位当前的 frame 上。
    private func frameKey(_ pid: pid_t, _ bounds: CGRect?) -> String? {
        guard let b = bounds else { return nil }
        return "\(pid)|\(Int(b.origin.x.rounded())):\(Int(b.origin.y.rounded())):\(Int(b.size.width.rounded())):\(Int(b.size.height.rounded()))"
    }

    /// 物理座位对账（单座位模型 · 拽标签根治 step 1）。把一个 app 当前的 AX 合格窗口收敛成
    /// 「一个物理窗口 = 一个座位」。座位锚在 frame、token 一旦分配不随当前标签 cgID 变：
    /// - **切标签**：旧 activeCgID 离开 AX、新 cgID 在同 frame 顶上 → 座位原地换 activeCgID，token 不变（卡不跳）。
    /// - **拖当前标签出去**：旧 activeCgID 移到新 frame、另一标签在旧 frame 顶上 → 座位留旧 frame 换新标签，
    ///   旧 activeCgID 被「赶出」成新座位（拽出分卡）。
    /// - **最小化/后台无人顶替**：CG 还在就保座位标最小化，CG 没了才删（Safari 最小化不丢卡）。
    /// - 后台标签【不】单独留座位。同 frame 有多个老座位（窗口重叠）时不顶替、宁可新建，避免误并。
    /// 返回 true 表示座位集合或关键属性变了（调用方据此决定是否重建快照）。
    @discardableResult
    private func reconcileSeats(
        pid: pid_t,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        now: Date,
        source: InventoryReconcileSource,
        preloadedEligible: [AXWindowSnapshot]? = nil,
        preloadedReadOutcome: InventoryAXReadOutcome? = nil,
        preloadedReadMode: InventoryReconcileReadMode? = nil
    ) -> Bool {
        guard var app = apps[pid] else { return false }
        let cgIDs = cgSnapshot.allWindowIDs
        let onScreenCGIDs = cgSnapshot.onScreenWindowIDs
        let cgPidIDs = cgSnapshot.windowIDsByPID[pid] ?? []
        // 影子标签池按【上一轮】的快照判定：最小化爆发瞬间所有标签涌进 AX，本轮现算池子会是空的。
        let shadowPool = app.shadowTabCgIDs
        let eligible: [AXWindowSnapshot]
        let axReadOutcome: InventoryAXReadOutcome
        if let preloaded = preloadedEligible {
            eligible = preloaded
            axReadOutcome = preloadedReadOutcome ?? .success(count: preloaded.count)
        } else {
            switch reader.windowReadResult(forPID: pid) {
            case .success(let windows):
                axReadOutcome = .success(count: windows.count)
                eligible = windows.filter {
                    isEligible(
                        $0,
                        application: eligibilityApplication(for: app),
                        cgSnapshot: cgSnapshot
                    )
                }
            case .unread(let error):
                axReadOutcome = .unread(errorCode: error.rawValue)
                eligible = []
            }
        }
        if axReadOutcome.kind == .unread {
            // An unread AX round is unknown, never evidence of absence. In particular it must not
            // start grace periods, update the shadow-tab pool, or advance phantom healing.
            inventoryLog.record(.reconcileUnread(InventoryReconcileUnreadPayload(
                pid: pid,
                bundleID: app.bundleIdentifier,
                source: source,
                readMode: preloadedReadMode ?? .untimed,
                usedPreloadedAX: preloadedEligible != nil,
                errorCode: axReadOutcome.errorCode ?? AXError.failure.rawValue
            )))
            gateStates[pid]?.lastReadWasUnread = true
            return false
        }
        let reconcileContext = inventoryLog.isEnabled
            ? inventoryReconcileContext(
                pid: pid,
                source: source,
                now: now,
                usedPreloadedAX: preloadedEligible != nil,
                axReadOutcome: axReadOutcome
            )
            : nil
        func fk(_ b: CGRect?) -> String? { frameKey(pid, b) }

        var eligibleByCgID: [CGWindowID: AXWindowSnapshot] = [:]
        for s in eligible { if let c = s.cgWindowID { eligibleByCgID[c] = s } }

        // 顺手把 AX 元素喂给动作路径的旁路缓存（见 `AXElementCache` 的注释）。这里是唯一的写入点：
        // 这一轮已经过了 `.unread` 早退闸，元素是真读到的。**不因为某个 cgID 这轮没出现在 AX 里就删**
        // ——Safari 系窗口最小化后会整个离开 AXWindows，那正是缓存最该发挥作用的时刻。出列只认
        // CG 全列表（下面那行 retain）、destroy 通知和进程消失。
        if AXElementCache.isEnabled {
            for (c, s) in eligibleByCgID { elementCache.store(pid: pid, cgWindowID: c, element: s.element) }
            elementCache.retain(pid: pid, liveCGWindowIDs: cgIDs)
        }

        let before = seatSignature(app)
        var usedEligible: Set<CGWindowID> = []
        var newOrder: [CGWindowID] = []
        var newByID: [CGWindowID: WindowEntry] = [:]
        func place(_ e: WindowEntry) { newOrder.append(e.cgWindowID); newByID[e.cgWindowID] = e }
        // history = 座位延续时继承的「曾任活跃标签」集合。与 CG 全列表求交集：真关掉的标签
        // 随之出列，防 cgID 复用后被误折叠进旧座位。wasEverVisible = 座位此前是否可见过（延续时
        // 继承）；本次以 min=false 现身也算——幽灵座位永远凑不齐这个标记（自愈判定的头号门槛）。
        func make(token: String, _ s: AXWindowSnapshot, previousTitle: String? = nil,
                  history: Set<CGWindowID> = [], wasEverVisible: Bool = false,
                  previousDisplayUUID: String? = nil, previousHoldUntil: Date? = nil) -> WindowEntry {
            // 归属键只在可见时跟着帧走；最小化 / 隐藏沿用上一座位的值（冻结在最后可见的屏）；
            // 跨屏拖窗的乐观键在冻结期内也不动；钉死的（`.distantFuture`）要等这次 AX 真读到可见帧才放开。
            let visible = !s.isMinimized && !app.isHidden
            let fresh = visible ? WindowDisplayAttribution.displayUUID(for: s.bounds, table: displayTable) : nil
            let sticky = previousHoldUntil == .distantFuture
            let held = !sticky && (previousHoldUntil.map { $0 > now } ?? false)
            let displayUUID: String?
            let holdUntil: Date?
            if sticky {
                displayUUID = fresh ?? previousDisplayUUID
                holdUntil = fresh == nil ? previousHoldUntil : nil
            } else if held {
                displayUUID = previousDisplayUUID
                holdUntil = previousHoldUntil
            } else {
                displayUUID = fresh ?? previousDisplayUUID
                holdUntil = nil
            }
            return WindowEntry(cgWindowID: s.cgWindowID!, token: token,
                               title: s.titleRead.resolvedTitle(previousTitle: previousTitle),
                               bounds: s.bounds, isMinimized: s.isMinimized, isFocused: s.isFocusedWindow,
                               everSeenVisible: wasEverVisible || !s.isMinimized,
                               formerCgIDs: history.subtracting([s.cgWindowID!]).intersection(cgIDs),
                               displayUUID: displayUUID,
                               displayUUIDHoldUntil: holdUntil)
        }
        // 某 frame 当前有几个老座位认领（>1 = 窗口重叠歧义，切标签顶替时跳过，保守不误并）
        func seatsAtFrame(_ key: String) -> Int {
            app.windowOrder.filter { fk(app.windowsByID[$0]?.bounds) == key }.count
        }

        // 当前 activeCgID 仍在 AX 里的座位数——幽灵自愈的「兄弟座位在场」门槛（幽灵自己缺席，天然不计入）。
        let axPresentSeatCount = app.windowOrder.filter { eligibleByCgID[$0] != nil }.count
        var healedSeats: [(cgID: CGWindowID, token: String, episodeID: UUID)] = []
        var releasedSeats: [(seat: WindowEntry, reason: InventorySeatReleasedReason)] = []
        var tearOutCgIDs: Set<CGWindowID> = []

        // Pass A：每个老座位尝试延续
        for cgID in app.windowOrder {
            guard var seat = app.windowsByID[cgID] else { continue }
            let X = seat.cgWindowID
            let seatKey = fk(seat.bounds)
            if let snapX = eligibleByCgID[X], !usedEligible.contains(X) {
                if inventoryLog.isEnabled, let episodeID = seat.absenceEpisodeID {
                    heldLogDeduplicator.clear(pid: pid, seatToken: seat.token, episodeID: episodeID)
                }
                InventoryAbsenceEpisode.clear(
                    absentSince: &seat.minAbsentSince,
                    episodeID: &seat.absenceEpisodeID
                )
                // X 仍可见。检查「拖当前标签出去」：X 移到了新 frame，旧 frame 上来了别的合格窗口 Y。
                // **跨屏搬窗冻结期内不撕**（`displayUUIDHoldUntil` 有效 / 钉死）：那次移帧是我们自己写的，
                // 座位必须跟着 X 走——否则座位留在旧帧改认 Y、还继承刚写成目标屏的键和冻结，X 落到 Pass B
                // 新建座位：两张卡都在目标条，冻结一过旧座位又跳回来源屏（owner 2026-09-03，多标签访达）。
                let moveHeld = seat.displayUUIDHoldUntil.map { $0 == .distantFuture || $0 > now } ?? false
                if let seatKey, fk(snapX.bounds) != seatKey, !moveHeld,
                   let Y = eligible.first(where: { s in
                       guard let c = s.cgWindowID, c != X, !usedEligible.contains(c) else { return false }
                       return fk(s.bounds) == seatKey
                   }), let yc = Y.cgWindowID {
                    // 座位留旧 frame、顶替成 Y，token 不变。X 被赶出成独立窗口 → 【不】记入历史
                    place(make(token: seat.token, Y, history: seat.formerCgIDs,
                               wasEverVisible: seat.everSeenVisible,
                               previousDisplayUUID: seat.displayUUID,
                               previousHoldUntil: seat.displayUUIDHoldUntil))
                    usedEligible.insert(yc)
                    observers[pid]?.registerWindow(Y.element, cgWindowID: yc)   // 接手新 activeCgID 必须订阅，理由见下面顶替分支
                    tearOutCgIDs.insert(X)
                    // X 不标 used → 落到 Pass B 成新座位（被赶出去的当前标签）
                } else {
                    // 普通：跟着 X（frame 可移动）
                    if case .unread(let error) = snapX.titleRead, let reconcileContext {
                        inventoryLog.record(.titleHeld(InventoryTitleHeldPayload(
                            context: reconcileContext,
                            pid: pid,
                            bundleID: app.bundleIdentifier,
                            seatToken: seat.token,
                            activeCgID: X,
                            errorCode: error.rawValue
                        )))
                    }
                    place(make(token: seat.token, snapX, previousTitle: seat.title,
                               history: seat.formerCgIDs,
                               wasEverVisible: seat.everSeenVisible,
                               previousDisplayUUID: seat.displayUUID,
                               previousHoldUntil: seat.displayUUIDHoldUntil))
                    usedEligible.insert(X)
                }
            } else {
                // X 离开 AX：旧 frame 有没有新当前标签顶上 → 切标签
                if let seatKey, seatsAtFrame(seatKey) == 1,
                   let Y = eligible.first(where: { s in
                       guard let c = s.cgWindowID, !usedEligible.contains(c), app.windowsByID[c] == nil else { return false }
                       return fk(s.bounds) == seatKey
                   }), let yc = Y.cgWindowID {
                    if inventoryLog.isEnabled, let episodeID = seat.absenceEpisodeID {
                        heldLogDeduplicator.clear(pid: pid, seatToken: seat.token, episodeID: episodeID)
                    }
                    InventoryAbsenceEpisode.clear(
                        absentSince: &seat.minAbsentSince,
                        episodeID: &seat.absenceEpisodeID
                    )
                    // 顶替，token 不变 → 卡不跳。X 是切走的后台标签 → 记入历史（关标签有
                    // tombstone / 已离开 CG，make 的交集会把真关掉的挡在门外）
                    var history = seat.formerCgIDs
                    if !isTombstoned(X) { history.insert(X) }
                    place(make(token: seat.token, Y, history: history,
                               wasEverVisible: seat.everSeenVisible,
                               previousDisplayUUID: seat.displayUUID,
                               previousHoldUntil: seat.displayUUIDHoldUntil))
                    usedEligible.insert(yc)
                    // 接手的 Y 必须在这里订阅每窗口通知（destroy/min/demin/title 只在接手 activeCgID 的三处订阅：新建座位、顶替、拖出替换）。
                    // 否则 Y 关掉时没有 destroy 通知 → 没有 tombstone；Ghostty 关掉的窗口还赖在 CG 全列表里，
                    // 座位会走「仍在 CG」保留分支永久留下幽灵卡（2026-08-23 最小化标签组关最后一个标签实测）。
                    observers[pid]?.registerWindow(Y.element, cgWindowID: yc)
                } else if cgIDs.contains(X) && !isTombstoned(X) {
                    // X 离开 AX 但仍在 CG。区分「最小化/隐藏(保座位)」vs「关窗后窗口赖在 CG(该删)」:
                    // 信号 = 离开 AX 前最后一次是不是 min(最小化会先经 Miniaturized 通知标 min；关窗不会)。
                    seat.formerCgIDs.formIntersection(cgIDs)   // 历史防复用：出 CG 即出列
                    if seat.isMinimized || app.isHidden {
                        InventoryAbsenceEpisode.beginIfNeeded(
                            absentSince: &seat.minAbsentSince,
                            episodeID: &seat.absenceEpisodeID,
                            now: now
                        )
                        let absentFor = now.timeIntervalSince(seat.minAbsentSince ?? now)
                        let evaluation = PhantomSeatDecision.evaluate(
                            everSeenVisible: seat.everSeenVisible,
                            axAbsentFor: absentFor,
                            threshold: Self.phantomReapGrace,
                            cgStillPresent: true,
                            axReadSawWindows: !eligible.isEmpty,
                            axPresentSiblingCount: axPresentSeatCount
                        )
                        // 幽灵座位自愈：从未可见过 + AX 连续缺席够久 + app 没挂死 + 有 AX 在场
                        // 兄弟座位 → 判定为折叠失手裂出来的幽灵，释放（不 place）。真最小化/隐藏
                        // 的窗口过不了 everSeenVisible 或兄弟门槛，照旧无限期保座位。
                        if evaluation.shouldRelease, let episodeID = seat.absenceEpisodeID {
                            healedSeats.append((X, seat.token, episodeID))
                            releasedSeats.append((seat, .phantomHealed))
                            if inventoryLog.isEnabled {
                                heldLogDeduplicator.clear(
                                    pid: pid, seatToken: seat.token, episodeID: episodeID
                                )
                            }
                        } else {
                            if let reconcileContext,
                               absentFor >= Self.phantomReapGrace,
                               let episodeID = seat.absenceEpisodeID,
                               heldLogDeduplicator.shouldRecord(
                                   pid: pid,
                                   seatToken: seat.token,
                                   episodeID: episodeID,
                                   reasons: evaluation.holdReasons
                               ) {
                                inventoryLog.record(.phantomHeld(InventoryPhantomHeldPayload(
                                    context: reconcileContext,
                                    pid: pid,
                                    bundleID: app.bundleIdentifier,
                                    seatToken: seat.token,
                                    activeCgID: X,
                                    absenceEpisodeID: episodeID,
                                    holdReasons: evaluation.holdReasons.map(\.rawValue).sorted(),
                                    appHidden: app.isHidden,
                                    everSeenVisible: seat.everSeenVisible,
                                    absentForMs: Int((absentFor * 1_000).rounded()),
                                    thresholdMs: Int((Self.phantomReapGrace * 1_000).rounded()),
                                    eligibleWindowCount: eligible.count,
                                    axPresentSiblingCount: axPresentSeatCount,
                                    bounds: seat.bounds.map(InventoryLogRect.init)
                                )))
                            }
                            seat.isFocused = false
                            place(seat)                   // 真最小化(Safari 离开 AX)/ 应用隐藏 → 保座位
                        }
                    } else {
                        seat.isFocused = false
                        // AX 成功不代表窗口清单完整。只要 CG 仍确认当前 activeCgID 存在且没有
                        // destroy tombstone，就保留原座位；AX 缺席永远不能自行证明窗口已关闭。
                        place(seat)
                    }
                } else {
                    // 连 CG 都没了 → 真关闭，丢弃。
                    releasedSeats.append((seat, .leftCGList))
                }
            }
        }

        // Pass B：没被认领的合格窗口 → 新座位（新窗口 / 被赶出去的当前标签）。
        // token 用全局自增序号,【绝不从 cgID 派生】——cgID 会被复用,从它派生会撞车（实测:旧座位
        // 种子=68、activeCgID 已换成 60,后来 68 独立成窗又生成同名 token → 两座位撞一张卡）。
        // **最小化折叠**：最小化一个多标签窗口时,Ghostty 会把该窗口的【所有标签】一下子都暴露成
        // AX 窗口(平时只暴露当前标签)。它们都 min=true——是同一个(已最小化)窗口的后台标签,折叠进
        // 已落座的座位,不另建座位（否则有几个标签就裂几张卡）。
        // 判定三级(TabFoldDecision)：成员关系(曾任该座位活跃标签,与几何无关) → frame 精确匹配
        // → 尺寸兜底(同宽高+屏幕外,救"窗口移动后后台标签 AX 坐标过时")。折叠且归属唯一时把
        // 候选记入座位历史(成员学习),下次折叠不再依赖几何。
        // 非 min 的同 frame 窗口是"两个独立窗口重叠"的合法场景,照常各自建座位。
        var placedForFold: [TabFoldDecision.PlacedSeat] = newOrder.compactMap { id in
            guard let e = newByID[id] else { return nil }
            return TabFoldDecision.PlacedSeat(activeCgID: e.cgWindowID, bounds: e.bounds,
                                              isMinimized: e.isMinimized, formerCgIDs: e.formerCgIDs)
        }
        for s in eligible {
            guard let c = s.cgWindowID, !usedEligible.contains(c), newByID[c] == nil else { continue }
            let verdict = TabFoldDecision.verdict(
                candidateCgID: c,
                candidateBounds: s.bounds,
                candidateIsMinimized: s.isMinimized,
                candidateIsOnScreen: onScreenCGIDs.contains(c),
                candidateIsKnownShadow: shadowPool.contains(c),
                placedSeats: placedForFold,
                frameKey: fk
            )
            switch verdict {
            case .fold(let owner, _):
                usedEligible.insert(c)   // 后台标签 → 折叠进已有座位,不另建
                if let owner { newByID[owner]?.formerCgIDs.insert(c) }   // 成员学习
            case .newSeat:
                let hadPlacedSeat = !placedForFold.isEmpty
                if s.isMinimized, !placedForFold.isEmpty {
                    // 诊断（常驻）：min=true 候选在已有落座座位时四级判定全失败走到新建座位 =
                    // 潜在分裂点，dump 全部判定输入抓现场。placed 为空（seed 时本就最小化的
                    // 独立窗口）是正确新建，不打。正常路径零输出——别再当遗留清掉。
                    let cand = s.bounds.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "nil"
                    let placedDesc = placedForFold.map { p in
                        let b = p.bounds.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "nil"
                        return "(cg=\(p.activeCgID) min=\(p.isMinimized) b=[\(b)] hist=\(p.formerCgIDs.sorted()))"
                    }.joined(separator: " ")
                    print("[tabfold] 分裂点 pid=\(pid) 为 min 窗口新建座位 cg=\(c) b=[\(cand)] onScreen=\(onScreenCGIDs.contains(c)) shadow=\(shadowPool.contains(c)) pool=\(shadowPool.count) placed=\(placedDesc)")
                }
                nextSeatSerial += 1
                let entry = make(token: "tabgrp-\(pid)-s\(nextSeatSerial)", s)
                if let reconcileContext {
                    let isOnScreen = onScreenCGIDs.contains(c)
                    let creationReason = InventorySeatCreationReason.classify(
                        hasPlacedSeat: hadPlacedSeat,
                        isTearOut: tearOutCgIDs.contains(c),
                        isMinimized: s.isMinimized,
                        isOnScreen: isOnScreen
                    )
                    let relations: [InventorySeatRelation] = newOrder.compactMap { id in
                        guard let existing = newByID[id] else { return nil }
                        let exactFrame = fk(existing.bounds) != nil && fk(existing.bounds) == fk(s.bounds)
                        let nearbyFrame: Bool
                        if let lhs = existing.bounds, let rhs = s.bounds {
                            nearbyFrame = WindowFrameMatchPolicy.areClose(lhs, rhs)
                        } else {
                            nearbyFrame = false
                        }
                        let sizeMatches: Bool
                        if let lhs = existing.bounds, let rhs = s.bounds {
                            sizeMatches = abs(lhs.width - rhs.width) < 3 && abs(lhs.height - rhs.height) < 3
                        } else {
                            sizeMatches = false
                        }
                        return InventorySeatRelation(
                            seatToken: existing.token,
                            activeCgID: existing.cgWindowID,
                            isMinimized: existing.isMinimized,
                            everSeenVisible: existing.everSeenVisible,
                            bounds: existing.bounds.map(InventoryLogRect.init),
                            formerCgIDs: existing.formerCgIDs.sorted(),
                            formerContainsCandidate: existing.formerCgIDs.contains(c),
                            normalizedTitleMatches: WindowInventoryDiagnosticRelations.normalizedTitlesMatch(
                                existing.title, s.title
                            ),
                            exactFrameMatches: exactFrame,
                            nearbyFrameMatches: nearbyFrame,
                            sizeMatches: sizeMatches
                        )
                    }
                    inventoryLog.record(.seatCreated(InventorySeatCreatedPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        seatToken: entry.token,
                        activeCgID: c,
                        creationReason: creationReason,
                        isMinimized: s.isMinimized,
                        isOnScreen: isOnScreen,
                        isFocused: s.isFocusedWindow,
                        appHidden: app.isHidden,
                        bounds: s.bounds.map(InventoryLogRect.init),
                        candidateKnownShadow: shadowPool.contains(c),
                        eligibleWindowCount: eligible.count,
                        minimizedEligibleCount: eligible.filter(\.isMinimized).count,
                        onScreenEligibleCount: eligible.compactMap(\.cgWindowID).filter {
                            onScreenCGIDs.contains($0)
                        }.count,
                        cgWindowCount: cgPidIDs.count,
                        eligibleCgIDs: eligible.compactMap(\.cgWindowID).sorted(),
                        cgWindowIDs: cgPidIDs.sorted(),
                        shadowPool: shadowPool.sorted(),
                        existingSeats: relations
                    )))
                }
                place(entry)
                observers[pid]?.registerWindow(s.element, cgWindowID: c)
                placedForFold.append(TabFoldDecision.PlacedSeat(activeCgID: entry.cgWindowID, bounds: entry.bounds,
                                                                isMinimized: entry.isMinimized, formerCgIDs: entry.formerCgIDs))
            }
        }

        // 幽灵自愈归档：恰有唯一 AX 在场座位时把释放的 cgID 记入其历史（下次爆发按成员秒折），
        // 多座位歧义则不学习——释放的 id 反正会回到影子池，照样被池挡住。
        if !healedSeats.isEmpty {
            let axPresentPlaced = newOrder.filter { eligibleByCgID[$0] != nil }
            let ownerCandidates = axPresentPlaced.compactMap { cgID -> InventoryPhantomOwner? in
                guard let token = newByID[cgID]?.token else { return nil }
                return InventoryPhantomOwner(seatToken: token, activeCgID: cgID)
            }
            let owner = InventoryPhantomOwnerResolution.uniqueOwner(from: ownerCandidates)
            for healed in healedSeats {
                if let owner {
                    newByID[owner.activeCgID]?.formerCgIDs.insert(healed.cgID)
                }
                if let reconcileContext {
                    inventoryLog.record(.phantomHealed(InventoryPhantomHealedPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        releasedSeatToken: healed.token,
                        releasedActiveCgID: healed.cgID,
                        absenceEpisodeID: healed.episodeID,
                        ownerSeatToken: owner?.seatToken,
                        ownerActiveCgID: owner?.activeCgID,
                        ownerCandidateCount: ownerCandidates.count
                    )))
                }
                let ownerDescription = owner.map { String($0.activeCgID) } ?? "无(歧义)"
                print("[tabheal] 自愈 pid=\(pid) 释放幽灵座位 cg=\(healed.cgID) 归入=\(ownerDescription)")
            }
        }

        for released in releasedSeats {
            let snapshot = inventorySeatReleaseSnapshot(app: app, seats: [released.seat])
            for payload in InventorySeatReleasePlan.payloads(
                for: snapshot,
                reason: released.reason,
                context: reconcileContext
            ) {
                inventoryLog.record(.seatReleased(payload))
            }
        }

        // 影子标签池滚动到下一轮（本轮判定用的是旧池）。健康门槛：AX 一个窗口都没读到而 CG
        // 还有（app 挂死/AX 读失败）→ 本轮不动池子。规则：出 CG（真关闭）→ 出池；以 min=false
        // 现身 AX（活跃标签/真可见窗口/拽出标签）→ 出池；在 CG 却不在 AX 且不是在座 activeCgID
        // （min 保留的 Safari 式真窗口、grace 暂留座位不入池，防座位丢失后被误折叠）→ 入池。
        // min=true 现身 AX 的不出池——那正是最小化爆发时刻，池子要撑住整个最小化期。
        let shouldUpdateShadowPool = !eligible.isEmpty || cgPidIDs.isEmpty
        if shouldUpdateShadowPool {
            var pool = app.shadowTabCgIDs
            pool.formIntersection(cgPidIDs)
            for s in eligible { if let c = s.cgWindowID, !s.isMinimized { pool.remove(c) } }
            pool.formUnion(cgPidIDs.subtracting(eligibleByCgID.keys).subtracting(newOrder))
            app.shadowTabCgIDs = pool

            if let reconcileContext {
                var diagnostic = shadowPoolDiagnosticsByPID[pid] ?? ShadowPoolDiagnosticState()
                func recordShadowPool(_ status: InventoryShadowPoolStatus) {
                    inventoryLog.record(.shadowPoolState(InventoryShadowPoolPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        status: status,
                        previousSuccessfulRoundID: diagnostic.lastSuccessfulRoundID,
                        before: shadowPool.sorted(),
                        after: pool.sorted(),
                        added: pool.subtracting(shadowPool).sorted(),
                        removed: shadowPool.subtracting(pool).sorted(),
                        eligibleWindowCount: eligible.count,
                        cgWindowCount: cgPidIDs.count
                    )))
                }
                if !diagnostic.initialized {
                    recordShadowPool(.initialized)
                }
                if diagnostic.updateWasSkipped {
                    recordShadowPool(.resumed)
                } else if diagnostic.initialized, pool != shadowPool {
                    recordShadowPool(.changed)
                }
                diagnostic.initialized = true
                diagnostic.updateWasSkipped = false
                diagnostic.lastSuccessfulRoundID = reconcileContext.roundID
                shadowPoolDiagnosticsByPID[pid] = diagnostic
            }
        } else if let reconcileContext {
            var diagnostic = shadowPoolDiagnosticsByPID[pid] ?? ShadowPoolDiagnosticState()
            if !diagnostic.updateWasSkipped {
                inventoryLog.record(.shadowPoolState(InventoryShadowPoolPayload(
                    context: reconcileContext,
                    pid: pid,
                    bundleID: app.bundleIdentifier,
                    status: .updateSkipped,
                    previousSuccessfulRoundID: diagnostic.lastSuccessfulRoundID,
                    before: shadowPool.sorted(),
                    after: shadowPool.sorted(),
                    added: [],
                    removed: [],
                    eligibleWindowCount: eligible.count,
                    cgWindowCount: cgPidIDs.count
                )))
            }
            diagnostic.updateWasSkipped = true
            shadowPoolDiagnosticsByPID[pid] = diagnostic
        }

        app.windowOrder = newOrder
        app.windowsByID = newByID
        apps[pid] = app
        let changed = seatSignature(app) != before
        gateStates[pid] = ReconcileGateState(
            lastCGIDs: cgPidIDs,
            lastFullReadUptime: uptimeProvider(),
            dirty: false,
            lastReadWasUnread: false,
            lastRoundChanged: changed || app.shadowTabCgIDs != shadowPool
        )
        return changed
    }

    private func inventoryReconcileContext(
        pid: pid_t,
        source: InventoryReconcileSource,
        now: Date,
        usedPreloadedAX: Bool,
        axReadOutcome: InventoryAXReadOutcome
    ) -> InventoryReconcileContext {
        nextInventoryRoundID += 1
        let ordinal = (reconcileOrdinalsByPID[pid] ?? 0) + 1
        let gapMs = lastReconcileAtByPID[pid].map {
            max(0, Int((now.timeIntervalSince($0) * 1_000).rounded()))
        }
        reconcileOrdinalsByPID[pid] = ordinal
        lastReconcileAtByPID[pid] = now
        return InventoryReconcileContext(
            roundID: nextInventoryRoundID,
            appReconcileOrdinal: ordinal,
            source: source,
            gapMs: gapMs,
            usedPreloadedAX: usedPreloadedAX,
            axReadOutcome: axReadOutcome
        )
    }

    private func clearInventoryDiagnostics(pid: pid_t) {
        reconcileOrdinalsByPID.removeValue(forKey: pid)
        lastReconcileAtByPID.removeValue(forKey: pid)
        shadowPoolDiagnosticsByPID.removeValue(forKey: pid)
        heldLogDeduplicator.removeAll(pid: pid)
    }

    private func inventorySeatReleaseSnapshot(
        app: AppEntry,
        seats: [WindowEntry]? = nil
    ) -> InventorySeatReleaseSnapshot {
        let selected = seats ?? app.windowOrder.compactMap { app.windowsByID[$0] }
        return InventorySeatReleaseSnapshot(
            pid: app.pid,
            bundleID: app.bundleIdentifier,
            appHidden: app.isHidden,
            seats: selected.map { entry in
                InventorySeatReleaseSnapshot.Seat(
                    seatToken: entry.token,
                    activeCgID: entry.cgWindowID,
                    isMinimized: entry.isMinimized,
                    isFocused: entry.isFocused,
                    everSeenVisible: entry.everSeenVisible,
                    bounds: entry.bounds
                )
            }
        )
    }

    private func recordProcessGoneSeats(app: AppEntry) {
        let snapshot = inventorySeatReleaseSnapshot(app: app)
        for payload in InventorySeatReleasePlan.processGonePayloads(for: snapshot) {
            inventoryLog.record(.seatReleased(payload))
        }
    }

    /// 座位集合的轻量指纹（顺序 + token + 标题 + 最小化/焦点 + 所在屏），用来判断这次对账有没有实际变化。
    /// 所在屏是粗粒度的 display UUID；**坐标本身永不进指纹**。
    private func seatSignature(_ app: AppEntry) -> String {
        app.windowOrder.map { id -> String in
            let e = app.windowsByID[id]
            return "\(id):\(e?.token ?? ""):\(e?.title ?? ""):\(e?.isMinimized == true ? 1 : 0):\(e?.isFocused == true ? 1 : 0):\(e?.displayUUID ?? "")"
        }.joined(separator: "|")
    }

    // MARK: - Display attribution（多屏 ④）

    /// 5s tick：按 CG bounds 给**所有**可见座位重算所在屏——覆盖被跳读门控跳过、没有 AX 读的 pid
    /// （非前台 app 的窗口被挪到另一块屏，最多 5s 换屏）。只改归属键，**不碰 `bounds`**（那是 AX 帧，
    /// `frameKey` / `seatsAtFrame` 靠它）、不碰跳读门控状态。CG 读不到 / 不沾任何屏 → 保留旧键。
    private func refreshDisplayAttributionFromCG(_ cgSnapshot: AppTrackerCGWindowSnapshot) -> Bool {
        guard !cgSnapshot.boundsByWindowID.isEmpty, !displayTable.displays.isEmpty else { return false }
        let now = Date()
        var changed = false
        for pid in appOrder {
            guard let app = apps[pid], !app.isHidden else { continue }
            for cgID in app.windowOrder {
                guard let seat = app.windowsByID[cgID], !seat.isMinimized,
                      !(seat.displayUUIDHoldUntil.map { $0 > now } ?? false),
                      let rect = cgSnapshot.boundsByWindowID[cgID],
                      let key = WindowDisplayAttribution.displayUUID(for: rect, table: displayTable),
                      key != seat.displayUUID else { continue }
                apps[pid]?.windowsByID[cgID]?.displayUUID = key
                changed = true
            }
        }
        return changed
    }

    /// 屏参数变化（拔插 / 换主屏 / 排列变）：换屏表，可见座位按已存 AX 帧重算；算不出的保留旧键
    /// （投影层会把指向已拔屏的键落到主屏）。不读 AX、不拍 CG。
    private func handleScreenParametersChanged() {
        displayTable = displayTableProvider()
        let now = Date()
        var changed = false
        for pid in appOrder {
            guard let app = apps[pid], !app.isHidden else { continue }
            for cgID in app.windowOrder {
                guard let seat = app.windowsByID[cgID], !seat.isMinimized,
                      !(seat.displayUUIDHoldUntil.map { $0 > now } ?? false),
                      let key = WindowDisplayAttribution.displayUUID(for: seat.bounds, table: displayTable),
                      key != seat.displayUUID else { continue }
                apps[pid]?.windowsByID[cgID]?.displayUUID = key
                changed = true
            }
        }
        if changed { rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs) }
    }

    /// 跨屏拖窗（`AppRuntime.moveWindow`）的乐观更新：用户动作直接写归属键并发布，卡当场跳到目标条，
    /// 不等下一次读。`.brief` 冻结 `displayMoveHold` 这么久（AX 写帧在动作队列上飞，期间落地的读还看着旧位置）；
    /// `.untilVisible` 钉死到它下次在 AX 里可见（AX 拿不到句柄的离屏 / 幽灵窗口：拖动 = 改住址）；
    /// 写失败由调用方用旧键 `.none` 回滚（真值随后由 AX / CG 读校正）。只认在册座位。
    static let displayMoveHold: TimeInterval = 1.5

    enum DisplayKeyHold { case none, brief, untilVisible }

    /// 「在运行但没窗口」的兜底卡 / 运行中的保留占位被拖到另一块屏的条上：这个 bundle 下所有进程的
    /// 「窗口最后在哪块屏」都改成那块屏并发布（同一 bundle 的兜底卡只有一张，按 bundle 记才不会换 pid 就丢）。
    func noteNoWindowHome(bundleID: String, displayUUID: String) {
        guard !bundleID.isEmpty else { return }
        var changed = false
        var matched = 0
        for pid in appOrder where apps[pid]?.bundleIdentifier == bundleID {
            matched += 1
            guard apps[pid]?.lastWindowDisplayUUID != displayUUID else { continue }
            apps[pid]?.lastWindowDisplayUUID = displayUUID
            changed = true
        }
        if Self.displayTraceEnabled {
            displayTraceLogger.info("noteNoWindowHome bundle=\(bundleID, privacy: .public) to=\(displayUUID, privacy: .public) matchedPIDs=\(matched) changed=\(changed)")
        }
        if changed { rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs) }
    }

    /// 跨屏拖窗的 AX 写帧失败后的裁决：窗口此刻在屏上（用户看得见的真窗口）→ 回滚到来源屏；
    /// 不在屏上（离屏 / 幽灵座位）→ 没东西可搬，当「改住址」钉死到目标屏。
    enum FailedMoveVerdict: Equatable { case rolledBack, pinnedToTarget, seatGone }

    @discardableResult
    func resolveFailedWindowMove(pid: pid_t, cgWindowID: CGWindowID, target: String, previous: String?) -> FailedMoveVerdict {
        guard apps[pid]?.windowsByID[cgWindowID] != nil else { return .seatGone }
        if lastOnScreenCGIDs.contains(cgWindowID) {
            noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: previous, hold: .none)
            return .rolledBack
        }
        noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: target, hold: .untilVisible)
        return .pinnedToTarget
    }

    private static let displayTraceEnabled = ProcessInfo.processInfo.environment["DOCK_DISPLAY_TRACE"] == "1"
    private let displayTraceLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "display-trace")

    @discardableResult
    func noteWindowMoved(pid: pid_t, cgWindowID: CGWindowID, displayUUID: String?, hold: DisplayKeyHold = .brief) -> Bool {
        guard let seat = apps[pid]?.windowsByID[cgWindowID] else { return false }
        let holdUntil: Date?
        switch hold {
        case .none: holdUntil = nil
        case .brief: holdUntil = Date().addingTimeInterval(Self.displayMoveHold)
        case .untilVisible: holdUntil = .distantFuture
        }
        apps[pid]?.windowsByID[cgWindowID]?.displayUUIDHoldUntil = holdUntil
        if Self.displayTraceEnabled {
            displayTraceLogger.info("noteWindowMoved pid=\(pid) cg=\(cgWindowID) \(seat.displayUUID ?? "nil", privacy: .public) → \(displayUUID ?? "nil", privacy: .public) hold=\(String(describing: hold), privacy: .public)")
        }
        guard seat.displayUUID != displayUUID else { return true }
        apps[pid]?.windowsByID[cgWindowID]?.displayUUID = displayUUID
        rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs)
        return true
    }

    // MARK: - Seed

    private func seedRunningApps() {
        let seedStart = Date()
        // 环境变量 DOCK_SEED_AX_TIMEOUT_MS：0 = 回退旧无超时读；其他值覆盖毫秒数；缺省 100ms。
        let timeoutMS = ProcessInfo.processInfo.environment["DOCK_SEED_AX_TIMEOUT_MS"]
        let useTimeout: Bool
        var messagingTimeout: TimeInterval = 0.1
        if let ms = timeoutMS, let val = Int(ms) {
            if val == 0 {
                useTimeout = false
            } else {
                useTimeout = true
                messagingTimeout = TimeInterval(val) / 1000.0
            }
        } else {
            useTimeout = true
        }

        var admittedCount = 0
        var unreadList: [String] = []
        let cgSnapshot = cgSnapshotProvider()

        for app in NSWorkspace.shared.runningApplications {
            guard isRegularNonSelf(app) else { continue }
            let pid = app.processIdentifier
            let bid = app.bundleIdentifier
            let eligibilityApplication = eligibilityApplication(for: app)
            let probeIdentity = inventoryLog.isEnabled ? processIdentity(pid: pid, bundleID: bid) : nil

            // 限时探测：挂死 app 第一条 AX 消息即超时 → .unread → 跳过，交给补扫。
            let result: AXWindowReadResult
            if useTimeout {
                result = reader.inventoryWindows(forPID: pid, messagingTimeout: messagingTimeout)
            } else {
                // Keep legacy untimed/two-attempt behavior while preserving `.unread` for diagnostics.
                result = reader.windowReadResult(forPID: pid)
            }

            let probedEligible: [AXWindowSnapshot]
            let inventoryReadOutcome: InventoryAXReadOutcome
            switch result {
            case .success(let snaps):
                probedEligible = snaps.filter {
                    isEligible($0, application: eligibilityApplication, cgSnapshot: cgSnapshot)
                }
                inventoryReadOutcome = .success(count: snaps.count)
            case .unread(let error):
                probedEligible = []
                inventoryReadOutcome = .unread(errorCode: error.rawValue)
                unreadList.append(app.localizedName ?? bid ?? "\(pid)")
            }

            let seedVerdict: InventoryAdmissionProbeVerdict
            if FinderWindowRules.isFinder(bundleIdentifier: bid) {
                seedVerdict = .admitFinderPersistent
            } else if case .unread = result {
                seedVerdict = .skipUnread
            } else if probedEligible.isEmpty {
                seedVerdict = .skipNoEligible
            } else {
                seedVerdict = .admit
            }
            if let probeIdentity {
                recordAdmissionProbe(
                    source: .seed,
                    identity: probeIdentity,
                    readMode: useTimeout ? .timed : .untimed,
                    messagingTimeoutMs: useTimeout ? Int((messagingTimeout * 1_000).rounded()) : nil,
                    maxAttempts: useTimeout ? 1 : 2,
                    result: result,
                    eligibleWindowCount: result.isSuccess ? probedEligible.count : nil,
                    verdict: seedVerdict
                )
            }

            if FinderWindowRules.isFinder(bundleIdentifier: bid) {
                // Finder 始终占坑：unread 就先空窗口占位（槽位常驻，通知/reconcile 随后补）。
                addApp(app, enumerateImmediately: false)
                reconcileSeats(
                    pid: pid,
                    cgSnapshot: cgSnapshot,
                    now: Date(),
                    source: .seed,
                    preloadedEligible: probedEligible,
                    preloadedReadOutcome: inventoryReadOutcome,
                    preloadedReadMode: useTimeout ? .timed : .untimed
                )
                admittedCount += 1
                continue
            }

            if !probedEligible.isEmpty {
                addApp(app, enumerateImmediately: false)
                reconcileSeats(
                    pid: pid,
                    cgSnapshot: cgSnapshot,
                    now: Date(),
                    source: .seed,
                    preloadedEligible: probedEligible,
                    preloadedReadOutcome: inventoryReadOutcome,
                    preloadedReadMode: useTimeout ? .timed : .untimed
                )
                admittedCount += 1
            }
        }

        rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs)

        let elapsed = Date().timeIntervalSince(seedStart)
        logger.info("seed done: \(admittedCount) admitted, \(unreadList.count) unread [\(unreadList.joined(separator: ", "))], elapsed=\(String(format: "%.2f", elapsed))s")
    }

    // MARK: - Workspace Notifications

    private func subscribeWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.handleAppLaunched(app) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppTerminated(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppHidden(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppUnhidden(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                // 前台缓存对所有激活生效（accessory/自身也占前台）；handleAppActivated 里
                // 的 regular 过滤只管准入，不管前台事实。
                self?.cachedFrontmostPID = pid
                self?.handleAppActivated(app)
            }
        })
    }

    // MARK: - Workspace Handlers

    private func handleAppLaunched(_ app: NSRunningApplication) {
        guard isRegularNonSelf(app) else { return }
        scanDirtyPIDs.insert(app.processIdentifier)
        scanCandidateCache = nil
        if FinderWindowRules.isFinder(bundleIdentifier: app.bundleIdentifier) {
            // Remove any stale Finder entry left over from a quit/relaunch cycle,
            // then add the fresh entry with the new pid.
            if let stalePID = appOrder.first(where: {
                FinderWindowRules.isFinder(bundleIdentifier: apps[$0]?.bundleIdentifier)
            }), stalePID != app.processIdentifier {
                observers[stalePID]?.stop()
                observers.removeValue(forKey: stalePID)
                apps.removeValue(forKey: stalePID)
                appOrder.removeAll { $0 == stalePID }
                clearInventoryDiagnostics(pid: stalePID)
                gateStates.removeValue(forKey: stalePID)
                invalidateEventReads(pid: stalePID)
                elementCache.removeAll(pid: stalePID)
            }
            addApp(app, enumerateImmediately: true)
            rebuildSnapshot()
            return
        }
        scheduleRetryAdmission(app: app, delays: [0.2, 0.5, 1.0, 2.0])
    }

    private func handleAppActivated(_ app: NSRunningApplication) {
        guard isRegularNonSelf(app) else { return }
        guard apps[app.processIdentifier] == nil else {
            markReconcileGateDirty(pid: app.processIdentifier)
            rebuildSnapshot()  // frontmost changed → active highlight update
            return
        }
        addApp(app, enumerateImmediately: true)
        rebuildSnapshot()
    }

    private func handleAppTerminated(pid: pid_t) {
        cgEventGeneration &+= 1
        invalidateEventReads(pid: pid)
        observers[pid]?.stop()
        observers.removeValue(forKey: pid)
        if let app = apps[pid] { recordProcessGoneSeats(app: app) }
        clearInventoryDiagnostics(pid: pid)
        gateStates.removeValue(forKey: pid)
        scanMemos.removeValue(forKey: pid)
        scanDirtyPIDs.remove(pid)
        scanCandidateCache = nil

        // Finder relaunches immediately via launchd. Keep the entry (no windows) so the chip
        // stays visible during the gap. handleAppLaunched will replace this stale entry with
        // the new pid when Finder comes back up.
        if FinderWindowRules.isFinder(bundleIdentifier: apps[pid]?.bundleIdentifier) {
            apps[pid]?.windowsByID = [:]
            apps[pid]?.windowOrder = []
            rebuildSnapshot()
            return
        }

        apps.removeValue(forKey: pid)
        appOrder.removeAll { $0 == pid }
        elementCache.removeAll(pid: pid)
        rebuildSnapshot()
    }

    private func handleAppHidden(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        apps[pid]?.isHidden = true
        rebuildSnapshot()
    }

    private func handleAppUnhidden(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        apps[pid]?.isHidden = false
        rebuildSnapshot()
    }

    // MARK: - App Management

    private func addApp(
        _ app: NSRunningApplication,
        enumerateImmediately: Bool,
        source: InventoryReconcileSource = .initialEnumeration
    ) {
        let pid = app.processIdentifier
        guard apps[pid] == nil else { return }
        cgEventGeneration &+= 1

        apps[pid] = AppEntry(
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "\(pid)",
            activationPolicy: app.activationPolicy,
            executablePath: app.executableURL?.path,
            windowsByID: [:],
            windowOrder: [],
            isHidden: app.isHidden
        )
        appOrder.append(pid)
        mutationGenerations[pid, default: 0] &+= 1
        scanMemos.removeValue(forKey: pid)
        scanDirtyPIDs.remove(pid)
        scanCandidateCache = nil

        if AXIsProcessTrusted() {
            let obs = AppWindowObserver(pid: pid)
            obs.onWindowCreated = { [weak self] pid in self?.handleWindowCreated(pid: pid) }
            obs.onWindowDestroyed = { [weak self] pid, cgID in self?.handleWindowDestroyed(pid: pid, cgWindowID: cgID) }
            obs.onWindowMinimized = { [weak self] pid, cgID in self?.handleWindowMinimized(pid: pid, cgWindowID: cgID) }
            obs.onWindowDeminiaturized = { [weak self] pid, cgID in self?.handleWindowDeminiaturized(pid: pid, cgWindowID: cgID) }
            obs.onFocusedWindowChanged = { [weak self] pid in self?.handleFocusedWindowChanged(pid: pid) }
            obs.onTitleChanged = { [weak self] pid, cgID in self?.handleTitleChanged(pid: pid, cgWindowID: cgID) }
            obs.start()
            observers[pid] = obs
        }

        if enumerateImmediately {
            enumerateWindows(for: pid, source: source)
        }
    }

    private func scheduleRetryAdmission(app: NSRunningApplication, delays: [TimeInterval]) {
        let pid = app.processIdentifier
        for delay in delays {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                if self.apps[pid] != nil {
                    self.enumerateWindows(for: pid, source: .initialEnumeration)
                    return
                }
                guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return }
                let windows = self.reader.windows(forPID: pid)
                let cgSnapshot = self.cgSnapshotProvider()
                let eligibilityApplication = self.eligibilityApplication(for: app)
                let hasEligible = windows.contains {
                    self.isEligible($0, application: eligibilityApplication, cgSnapshot: cgSnapshot)
                }
                if hasEligible {
                    self.addApp(app, enumerateImmediately: true)
                    self.rebuildSnapshot()
                }
            }
        }
    }

    // MARK: - Window Enumeration

    private func enumerateWindows(for pid: pid_t, source: InventoryReconcileSource) {
        guard apps[pid] != nil else { return }
        let cgSnapshot = cgSnapshotProvider()
        if reconcileSeats(pid: pid, cgSnapshot: cgSnapshot, now: Date(), source: source) {
            rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs)
        }
    }

    private func isEligible(
        _ snap: AXWindowSnapshot,
        application: AppTrackerWindowEligibility.Application,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) -> Bool {
        let alpha = snap.cgWindowID.flatMap { cgSnapshot.alphaByWindowID[$0] }
        return windowEligibility.isEligible(
            title: snap.title,
            role: snap.role,
            subrole: snap.subrole,
            bounds: snap.bounds,
            alpha: alpha,
            application: application
        )
    }

    private func eligibilityApplication(for app: AppEntry) -> AppTrackerWindowEligibility.Application {
        AppTrackerWindowEligibility.Application(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.appName,
            activationPolicy: app.activationPolicy,
            executablePath: app.executablePath
        )
    }

    private func eligibilityApplication(for app: NSRunningApplication) -> AppTrackerWindowEligibility.Application {
        AppTrackerWindowEligibility.Application(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "\(app.processIdentifier)",
            activationPolicy: app.activationPolicy,
            executablePath: app.executableURL?.path
        )
    }

    // MARK: - AX Event Handlers

    private func handleWindowCreated(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        scheduleEventRead(pid: pid, source: .windowCreated)
    }

    private func handleWindowDestroyed(pid: pid_t, cgWindowID: CGWindowID) {
        guard apps[pid] != nil else { return }
        markReconcileGateDirty(pid: pid)
        invalidateEventReads(pid: pid)
        destroyedCGIDs[cgWindowID] = Date()
        purgeFromSeatHistories(cgWindowID)
        // 真关掉了才删元素缓存。destroy 通知可能早于 CG 全列表更新，所以这里显式删一次，
        // 不等下面 reconcileSeats 里的 CG 求交。
        elementCache.remove(pid: pid, cgWindowID: cgWindowID)
        // 不直接删座位：若这是某标签窗口的当前标签被关、而同一物理窗口还有别的标签顶上，
        // reconcileSeats 会让座位原地换 activeCgID、保住 token（卡不闪不换身份）。整窗关掉则真删。
        // 对账走限时后台事件读（同 created / focus / title）：以前这里在主 actor 上直接
        // `reconcileSeats` 走不限时读，被关窗口的 App 若正卡住，任务条主线程最长冻 ~12s。
        scheduleEventRead(pid: pid, source: .windowDestroyed)
    }

    private func handleWindowMinimized(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        invalidateEventReads(pid: pid)
        apps[pid]?.windowsByID[cgWindowID]?.isMinimized = true
        apps[pid]?.windowsByID[cgWindowID]?.isFocused = false
        rebuildSnapshot()
    }

    private func handleWindowDeminiaturized(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        invalidateEventReads(pid: pid)
        apps[pid]?.windowsByID[cgWindowID]?.isMinimized = false
        rebuildSnapshot()
    }

    private func handleFocusedWindowChanged(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        scheduleEventRead(pid: pid, source: .focusChanged)
    }

    private func handleTitleChanged(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        scheduleEventRead(pid: pid, source: .titleChanged)
    }

    private func markReconcileGateDirty(pid: pid_t) {
        gateStates[pid]?.dirty = true
        cgEventGeneration &+= 1
    }

    private func invalidateEventReads(pid: pid_t) {
        mutationGenerations[pid, default: 0] &+= 1
        trailingEventSources.removeValue(forKey: pid)
    }

    private func scheduleEventRead(pid: pid_t, source: InventoryReconcileSource) {
        guard apps[pid] != nil else { return }
        guard eventAXAsyncEnabled else {
            enumerateWindows(for: pid, source: source)
            return
        }
        if pendingEventReads[pid] != nil {
            // Coalesce any burst while a read is in flight into exactly one read using the latest
            // event source. Completion consumes and clears this slot before starting it.
            trailingEventSources[pid] = source
            return
        }

        nextEventReadToken &+= 1
        let request = PendingEventRead(
            token: nextEventReadToken,
            mutationGeneration: mutationGenerations[pid, default: 0],
            identity: processIdentity(pid: pid, bundleID: apps[pid]?.bundleIdentifier),
            source: source
        )
        pendingEventReads[pid] = request
        let reader = self.reader
        let cgSnapshotProvider = self.cgSnapshotProvider
        let probeProvider = self.onScreenWindowIDsProvider
        let ticket = makeCGSnapshotReuseTicket(pid: pid)

        Task.detached { [weak self] in
            let result = reader.inventoryWindows(forPID: pid, messagingTimeout: 0.1)
            // 顺序硬规则：先探针、后全拍（理由见 CGSnapshotReuseDecision 头注释）。
            let acquisition: CGSnapshotAcquisition
            switch CGSnapshotReuseDecision.preVerdict(ticket.input) {
            case .captureWithoutProbe:
                acquisition = CGSnapshotAcquisition(
                    snapshot: cgSnapshotProvider(), probeIDs: nil, fresh: true, ticket: ticket
                )
            case .captureAndPrime:
                let probe = probeProvider()
                acquisition = CGSnapshotAcquisition(
                    snapshot: cgSnapshotProvider(), probeIDs: probe, fresh: true, ticket: ticket
                )
            case .probeThenCompare:
                let probe = probeProvider()
                switch CGSnapshotReuseDecision.probeVerdict(
                    probe: probe, cachedProbe: ticket.cachedProbeIDs ?? []
                ) {
                case .reuse:
                    acquisition = CGSnapshotAcquisition(
                        // preVerdict 已保证 hasCache；防御性兜底走现拍。
                        snapshot: ticket.cachedSnapshot ?? cgSnapshotProvider(),
                        probeIDs: probe, fresh: false, ticket: ticket
                    )
                case .captureAndPrime:
                    acquisition = CGSnapshotAcquisition(
                        snapshot: cgSnapshotProvider(), probeIDs: probe, fresh: true, ticket: ticket
                    )
                }
            }
            await MainActor.run { [weak self] in
                self?.noteCGSnapshotAcquisition(acquisition)
                self?.completeEventRead(
                    pid: pid,
                    request: request,
                    result: result,
                    cgSnapshot: acquisition.snapshot
                )
            }
        }
    }

    /// 后台事件读带回的 CG 表来源：现拍（含同轮探针，用于把缓存链接上）或复用缓存。
    private struct CGSnapshotAcquisition: Sendable {
        let snapshot: AppTrackerCGWindowSnapshot
        let probeIDs: Set<CGWindowID>?
        let fresh: Bool
        let ticket: CGSnapshotReuseTicket
    }

    /// 主线程组票：静态判据在这里定格（年龄用组票时刻算，后台读的耗时余量已计入
    /// `defaultMaxCacheAge`）。缓存快照/探针集随票带走，后台任务不回头读主线程状态。
    private struct CGSnapshotReuseTicket: Sendable {
        let input: CGSnapshotReuseDecision.Input
        let cachedSnapshot: AppTrackerCGWindowSnapshot?
        let cachedProbeIDs: Set<CGWindowID>?
        let uptime: TimeInterval
        let generation: UInt64
    }

    private func makeCGSnapshotReuseTicket(pid: pid_t) -> CGSnapshotReuseTicket {
        let now = uptimeProvider()
        let app = apps[pid]
        let input = CGSnapshotReuseDecision.Input(
            reuseEnabled: cgSnapshotReuseEnabled,
            hasCache: cachedCGSnapshot != nil && cachedCGProbeIDs != nil,
            cachedCaptureFailed: cachedCGSnapshot?.captureFailed ?? true,
            cacheAge: now - cachedCGAtUptime,
            generationMatches: cachedCGGeneration == cgEventGeneration,
            hasAbsenceClock: app?.windowOrder.contains {
                app?.windowsByID[$0]?.minAbsentSince != nil
            } ?? false,
            hasPhantomCandidate: app?.windowOrder.contains {
                app?.windowsByID[$0]?.everSeenVisible == false
            } ?? false,
            observerActive: observerActive(pid: pid)
        )
        return CGSnapshotReuseTicket(
            input: input,
            cachedSnapshot: cachedCGSnapshot,
            cachedProbeIDs: cachedCGProbeIDs,
            uptime: now,
            generation: cgEventGeneration
        )
    }

    /// 只有**现拍**刷新缓存（复用轮不刷新——刷了年龄上限就失效）。乱序落地用组票时刻挡：
    /// 旧票的现拍不覆盖新缓存。代数记组票时刻的值：期间来了事件则缓存代数落后 → 下轮现拍，保守。
    private func noteCGSnapshotAcquisition(_ acquisition: CGSnapshotAcquisition) {
        guard cgSnapshotReuseEnabled, acquisition.fresh,
              let probe = acquisition.probeIDs,
              acquisition.ticket.uptime >= cachedCGAtUptime else { return }
        cachedCGSnapshot = acquisition.snapshot
        cachedCGProbeIDs = probe
        cachedCGAtUptime = acquisition.ticket.uptime
        cachedCGGeneration = acquisition.ticket.generation
    }

    private enum EventReadLanding {
        case staleToken                  // token 已被 invalidate/顶替：整次落地作废（trailing 由新在途读负责）
        case skipped                     // token 吻合已消费，但代际/进程身份不符 → 不动任何状态
        case reconciled(seatsChanged: Bool)
    }

    /// 落地一次后台限时读的公共核心：校验并消费 pending token，过 mutation 代际与进程身份检查后
    /// 跑 reconcileSeats。**不**重建快照、**不**消费 trailing——单发路径（事件/前台轮询）要叠加
    /// on-screen 强刷，批量路径（周期对账）整批只重建一次，各自在外面收尾。
    private func landEventRead(
        pid: pid_t,
        request: PendingEventRead,
        result: AXWindowReadResult,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) -> EventReadLanding {
        guard pendingEventReads[pid]?.token == request.token else { return .staleToken }
        pendingEventReads.removeValue(forKey: pid)

        let currentIdentity = apps[pid].map {
            processIdentity(pid: pid, bundleID: $0.bundleIdentifier)
        }
        guard mutationGenerations[pid, default: 0] == request.mutationGeneration,
              currentIdentity.map({
                  ScanAdmissionDecision.ProcessIdentity.matches(probed: request.identity, current: $0)
              }) == true,
              let app = apps[pid] else { return .skipped }

        let readOutcome: InventoryAXReadOutcome
        let eligible: [AXWindowSnapshot]
        switch result {
        case .success(let windows):
            readOutcome = .success(count: windows.count)
            let application = eligibilityApplication(for: app)
            eligible = windows.filter {
                isEligible($0, application: application, cgSnapshot: cgSnapshot)
            }
        case .unread(let error):
            readOutcome = .unread(errorCode: error.rawValue)
            eligible = []
        }
        let seatsChanged = reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(),
            source: request.source,
            preloadedEligible: eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: .timed
        )
        return .reconciled(seatsChanged: seatsChanged)
    }

    private func completeEventRead(
        pid: pid_t,
        request: PendingEventRead,
        result: AXWindowReadResult,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) {
        switch landEventRead(pid: pid, request: request, result: result, cgSnapshot: cgSnapshot) {
        case .staleToken:
            return
        case .skipped:
            break
        case .reconciled(let seatsChanged):
            let onScreenChanged = request.source == .frontmostPoll
                && cgSnapshot.onScreenWindowIDs != lastOnScreenCGIDs
            if seatsChanged || onScreenChanged {
                rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs)
            }
        }
        consumeTrailingEventRead(pid: pid)
    }

    private func consumeTrailingEventRead(pid: pid_t) {
        if let trailingSource = trailingEventSources.removeValue(forKey: pid), apps[pid] != nil {
            scheduleEventRead(pid: pid, source: trailingSource)
        }
    }

    // MARK: - Reconcile

    private func startReconcileTimer() {
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        reconcileTimer?.tolerance = 0.5
    }

    // 前台快轮询：原生标签组（如 Ghostty）切标签时 AX 可能完全不报，且 min 误报滞后数秒。
    // 真相在 CG on-screen 集合——切标签时它即时变化。对前台 app 以 0.5s 检测：on-screen 变了
    //（切了标签）就重建，标签组可见标签随之即时更新。同时顺带补 AX 标题/焦点。前台是非跟踪
    // app 时整个 tick 直接退出（无人值守测量因此可能整段失活——每臂必须记录并固定前台 app）。
    // 安静 tick 的 CG 全表由 CGSnapshotReuseDecision 门控复用，AX 读照常。
    private func startFrontmostPollTimer() {
        frontmostPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollFrontmostApp() }
        }
        frontmostPollTimer?.tolerance = 0.05
    }

    private func currentFrontmostPID() -> pid_t? {
        guard frontmostCacheEnabled else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        if let cached = cachedFrontmostPID { return cached }
        let live = NSWorkspace.shared.frontmostApplication?.processIdentifier
        cachedFrontmostPID = live
        return live
    }

    /// 5s 一次的真实查询自愈（reconcile tick 里调）。live 为 nil（瞬态无前台）时保留旧值。
    private func refreshFrontmostCache() {
        guard frontmostCacheEnabled else { return }
        if let live = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            cachedFrontmostPID = live
        }
    }

    private func pollFrontmostApp() {
        guard AXIsProcessTrusted() else { return }
        guard let pid = currentFrontmostPID(), apps[pid] != nil else { return }

        scheduleFrontmostPoll(pid: pid)
    }

    private func scheduleFrontmostPoll(pid: pid_t) {
        guard apps[pid] != nil else { return }

        // Keep the 0.5s cadence, but never perform the full AXWindows read on the main actor.
        // Slow frontmost apps previously blocked SwiftUI animation for 200-400ms every tick.
        if eventAXAsyncEnabled {
            scheduleEventRead(pid: pid, source: .frontmostPoll)
            return
        }

        // 单座位模型下：标签窗口切标签 = 座位 activeCgID 被顶替，reconcileSeats 即时收敛。
        // 前台 app 每 0.5s 跑一次,切标签/最小化/拽出都能秒级反映(不再依赖 AX 事件可靠性)。
        let cgSnapshot = cgSnapshotProvider()
        var changed = reconcileSeats(pid: pid, cgSnapshot: cgSnapshot, now: Date(), source: .frontmostPoll)
        // on-screen 变了(切了标签)也强制刷新一次,兜住座位指纹没变但可见标签换了的边角。
        let onScreen = cgSnapshot.onScreenWindowIDs
        if onScreen != lastOnScreenCGIDs { changed = true }
        if changed { rebuildSnapshot(onScreenCGIDs: onScreen) }
    }

    private func reconcile() {
        guard AXIsProcessTrusted() else { return }
        purgeStaleTombstones()
        refreshFrontmostCache()
        let now = Date()
        var changed = false

        // Remove entries for processes that no longer exist. This handles multi-process apps where
        // didTerminateApplicationNotification fires for the host pid while the window was tracked
        // under a different pid — the workspace notification removes the wrong entry and the
        // tracked pid's app entry stays indefinitely.
        var deadPIDs: [pid_t] = []
        for pid in appOrder {
            if !processProvider.isAlive(pid: pid) {
                // Finder's entry is intentionally kept alive across quit/relaunch cycles
                // (handleAppTerminated clears windows but preserves the slot).
                if FinderWindowRules.isFinder(bundleIdentifier: apps[pid]?.bundleIdentifier) { continue }
                deadPIDs.append(pid)
                logger.info("reconcile: pid=\(pid) no longer exists (POSIX kill(0) == ESRCH), removing stale entry")
            }
        }
        for pid in deadPIDs {
            // 批量删除 AppEntry 前，按 windowOrder 为每个 seat 写一条 seatReleased(.processGone)。
            // 该路径没有本轮 AX/CG 采样，也没有 InventoryReconcileContext——只有内存中已有的座位状态，
            // 绝不伪造未采样字段为 0/false。日志身份用稳定的 pid + seatToken。
            if let app = apps[pid] { recordProcessGoneSeats(app: app) }
            observers[pid]?.stop()
            observers.removeValue(forKey: pid)
            apps.removeValue(forKey: pid)
            appOrder.removeAll { $0 == pid }
            clearInventoryDiagnostics(pid: pid)
            gateStates.removeValue(forKey: pid)
            invalidateEventReads(pid: pid)
            elementCache.removeAll(pid: pid)
            changed = true
        }

        // Snapshot CG window state once for the entire reconcile pass.
        let cgSnapshot = cgSnapshotProvider()
        // 多屏 ④：所有可见座位按本轮 CG bounds 换屏（跳读的 pid 也覆盖到）。
        if !cgSnapshot.captureFailed, refreshDisplayAttributionFromCG(cgSnapshot) { changed = true }

        if let timeout = periodicReconcileTimeout, eventAXAsyncEnabled {
            // 死进程清扫的删除立即上屏，不等批读落地。
            if changed { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
            schedulePeriodicBatchRead(cgSnapshot: cgSnapshot, timeout: timeout)
        } else {
            // 旧路径（DOCK_RECONCILE_AX_TIMEOUT_MS=0 或 DOCK_EVENT_AX_ASYNC=0）：主线程逐 pid 不限时同步读。
            for pid in appOrder {
                if reconcileSeats(pid: pid, cgSnapshot: cgSnapshot, now: now, source: .periodicReconcile) { changed = true }
            }
            if changed { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
        }
        scanNonAdmittedApps(cgSnapshot: cgSnapshot)
    }

    /// 周期对账的批量后台读：已有在途读的 pid 跳过（其落地自带更新数据），其余批量注册
    /// pending token 后在**一个** detached task 里串行限时读，整批一次落地、至多一次重建。
    /// 批读在途期间到达的 AX 事件照常并入 trailing（单 pid 单在途不变）；下一 tick 里
    /// 尚未落地的 pid 因 pending 存在被跳过，天然不堆积。
    private func schedulePeriodicBatchRead(cgSnapshot: AppTrackerCGWindowSnapshot, timeout: TimeInterval) {
        var batch: [(pid: pid_t, request: PendingEventRead)] = []
        for pid in appOrder {
            guard pendingEventReads[pid] == nil, let app = apps[pid] else { continue }
            if reconcileSkipEnabled, shouldSkipPeriodicRead(pid: pid, app: app, cgSnapshot: cgSnapshot) {
                continue
            }
            nextEventReadToken &+= 1
            let request = PendingEventRead(
                token: nextEventReadToken,
                mutationGeneration: mutationGenerations[pid, default: 0],
                identity: processIdentity(pid: pid, bundleID: app.bundleIdentifier),
                source: .periodicReconcile
            )
            pendingEventReads[pid] = request
            batch.append((pid, request))
        }
        guard !batch.isEmpty else { return }
        let reader = self.reader

        Task.detached { [weak self] in
            var results: [(pid: pid_t, request: PendingEventRead, result: AXWindowReadResult)] = []
            for entry in batch {
                results.append((
                    entry.pid,
                    entry.request,
                    reader.inventoryWindows(forPID: entry.pid, messagingTimeout: timeout)
                ))
            }
            let landed = results
            await MainActor.run { [weak self] in
                self?.completePeriodicBatch(landed, cgSnapshot: cgSnapshot)
            }
        }
    }

    /// 静默跳读判定（纯决策：PeriodicReconcileSkipDecision，八个条件全过才跳）。
    /// 跳过 = 本轮不为该 pid 排 AX 读；所有状态保持不推进（与 `.unread` 同语义）。
    private func shouldSkipPeriodicRead(
        pid: pid_t,
        app: AppEntry,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) -> Bool {
        let gate = gateStates[pid]
        let input = PeriodicReconcileSkipDecision.Input(
            captureFailed: cgSnapshot.captureFailed,
            currentCGIDs: cgSnapshot.windowIDsByPID[pid] ?? [],
            lastObservedCGIDs: gate?.lastCGIDs,
            dirtySinceLastRead: gate?.dirty ?? true,
            hasAbsenceClock: app.windowOrder.contains { app.windowsByID[$0]?.minAbsentSince != nil },
            hasPhantomCandidate: app.windowOrder.contains { app.windowsByID[$0]?.everSeenVisible == false },
            lastReadWasUnread: gate?.lastReadWasUnread ?? true,
            lastRoundChanged: gate?.lastRoundChanged ?? true,
            observerActive: observerActive(pid: pid),
            uptimeSinceLastFullRead: gate.map { uptimeProvider() - $0.lastFullReadUptime } ?? .infinity
        )
        return PeriodicReconcileSkipDecision.verdict(input) == .skip
    }

    private func observerActive(pid: pid_t) -> Bool {
        #if DEBUG
        if let override = observerActiveOverridesForTesting[pid] { return override }
        #endif
        return observers[pid]?.isActive ?? false
    }

    private func completePeriodicBatch(
        _ results: [(pid: pid_t, request: PendingEventRead, result: AXWindowReadResult)],
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) {
        var changed = false
        var landedPIDs: [pid_t] = []
        for entry in results {
            switch landEventRead(pid: entry.pid, request: entry.request, result: entry.result, cgSnapshot: cgSnapshot) {
            case .staleToken:
                continue
            case .skipped:
                landedPIDs.append(entry.pid)
            case .reconciled(let seatsChanged):
                if seatsChanged { changed = true }
                landedPIDs.append(entry.pid)
            }
        }
        if changed { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
        for pid in landedPIDs { consumeTrailingEventRead(pid: pid) }
    }

    /// `cgSnapshot`：reconcile tick 把当轮 CG 捕获传进来 → 走探测门控（CG 在场判据 + 记忆）并
    /// 复用该捕获做收编；传 nil（启动后的四轮补扫）→ 完全绕过门控与记忆，收编时自拍快照——
    /// 与改造前逐位一致。
    private func scanNonAdmittedApps(cgSnapshot: AppTrackerCGWindowSnapshot? = nil) {
        guard !isScanningCandidates else { return }
        var slowFullScanDue = false
        if cgSnapshot != nil, scanGateEnabled {
            let uptime = uptimeProvider()
            slowFullScanDue = lastFullScanUptime.map {
                uptime - $0 >= ScanProbeGateDecision.defaultFullScanInterval
            } ?? true
            if slowFullScanDue { lastFullScanUptime = uptime }
        }
        // 候选连同**探测时刻的进程代际**一起带走：后台探测期间 pid 可能被复用，回调必须能认出换人。
        let candidates: [(pid: pid_t, identity: ScanAdmissionDecision.ProcessIdentity)]
        if let cgSnapshot, scanGateEnabled {
            // 门控路径：候选名单走缓存（见 scanCandidateCache 注释），失效或慢扫到期才重新
            // 枚举 NSWorkspace。缓存里的过期项（已收编 / 已死）逐 tick 廉价过滤掉。
            if scanCandidateCache == nil || slowFullScanDue {
                scanCandidateCache = enumerateScanCandidates()
            }
            candidates = (scanCandidateCache ?? []).compactMap { entry in
                guard apps[entry.pid] == nil, processProvider.isAlive(pid: entry.pid) else { return nil }
                let identity = processIdentity(pid: entry.pid, bundleID: entry.bundleID)
                let verdict = ScanProbeGateDecision.verdict(.init(
                    captureFailed: cgSnapshot.captureFailed,
                    cgWindowIDs: cgSnapshot.windowIDsByPID[entry.pid] ?? [],
                    memo: scanMemos[entry.pid],
                    currentIdentity: identity,
                    workspaceDirty: scanDirtyPIDs.contains(entry.pid),
                    slowFullScanDue: slowFullScanDue
                ))
                guard case .probe = verdict else { return nil }
                scanDirtyPIDs.remove(entry.pid)
                return (entry.pid, identity)
            }
        } else {
            // 旁路（启动补扫轮 / DOCK_SCAN_GATE=0）：与改造前逐位一致，现场全量枚举。
            candidates = NSWorkspace.shared.runningApplications.compactMap { app in
                let pid = app.processIdentifier
                guard isRegularNonSelf(app), !app.isTerminated, apps[pid] == nil else { return nil }
                scanDirtyPIDs.remove(pid)
                return (pid, processIdentity(pid: pid, bundleID: app.bundleIdentifier))
            }
        }
        guard !candidates.isEmpty else { return }

        isScanningCandidates = true
        let reader = self.reader

        Task.detached { [weak self] in
            // 后台只做 AX 读（限时 100ms，挂死 App 不拖主线程）。eligible 过滤放主线程：它依赖
            // 实例属性 eligibilityPolicy，且只是对已读字段的纯计算，零 AX 往返。
            let probeStart = DispatchTime.now().uptimeNanoseconds
            var probed: [(pid: pid_t, identity: ScanAdmissionDecision.ProcessIdentity, result: AXWindowReadResult)] = []
            for candidate in candidates {
                probed.append((
                    candidate.pid,
                    candidate.identity,
                    reader.inventoryWindows(forPID: candidate.pid, messagingTimeout: 0.1)
                ))
            }
            let results = probed
            let probeElapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - probeStart) / 1_000_000_000

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isScanningCandidates = false
                self.admitScannedApps(results, tickSnapshot: cgSnapshot, probeElapsed: probeElapsed)
            }
        }
    }

    /// 一次真实的 NSWorkspace 枚举（每 app 属性访问都是同步 LS XPC，别在安静 tick 调它）。
    private func enumerateScanCandidates() -> [(pid: pid_t, bundleID: String?)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            let pid = app.processIdentifier
            guard isRegularNonSelf(app), !app.isTerminated, apps[pid] == nil else { return nil }
            return (pid, app.bundleIdentifier)
        }
    }

    /// 补扫收编。三条硬规则（都在 `ScanAdmissionDecision` 里被单测锁住）：
    /// 准入看 **eligible 过滤后**的集合（原始 AX 列表非空 ≠ 有可上任务栏的窗口，误收会留下永久
    /// `app-*` 卡）；探测结果**必须复用**（禁止再来一次无超时 AX 读，那正是 100ms 限时探测要
    /// 避开的主线程阻塞）；进程态与进程代际在主线程回调里**重查**（pid 可能已被复用）。
    private func admitScannedApps(
        _ probed: [(pid: pid_t, identity: ScanAdmissionDecision.ProcessIdentity, result: AXWindowReadResult)],
        tickSnapshot: AppTrackerCGWindowSnapshot? = nil,
        probeElapsed: TimeInterval = .infinity
    ) {
        guard !probed.isEmpty else { return }
        // 复用 reconcile tick 的 CG 捕获（省掉每 5 秒的第二张全表）。探测拖太久（>1s，挂死 app
        // 排队超时）或没带快照（启动补扫轮）时现拍一张；代际重查（ScanAdmissionDecision.verdict）
        // 继续兜「快照瞬间陈旧」的正确性——与 seed 用同一张快照探测+收编是同一个既有先例。
        let cgSnapshot: AppTrackerCGWindowSnapshot
        if let tickSnapshot, probeElapsed <= 1.0 {
            cgSnapshot = tickSnapshot
        } else {
            cgSnapshot = cgSnapshotProvider()
        }
        var admitted = false

        for entry in probed {
            guard let app = NSRunningApplication(processIdentifier: entry.pid) else {
                scanMemos.removeValue(forKey: entry.pid)
                recordAdmissionProbe(
                    source: .scan,
                    identity: entry.identity,
                    readMode: .timed,
                    messagingTimeoutMs: 100,
                    maxAttempts: 1,
                    result: entry.result,
                    eligibleWindowCount: nil,
                    verdict: .skipProcessUnavailable
                )
                continue
            }
            let bundleID = app.bundleIdentifier
            let eligibilityApplication = eligibilityApplication(for: app)

            let rawWindows: [AXWindowSnapshot]?
            let readOutcome: InventoryAXReadOutcome
            switch entry.result {
            case .success(let snaps):
                rawWindows = snaps
                readOutcome = .success(count: snaps.count)
            case .unread(let error):
                rawWindows = nil
                readOutcome = .unread(errorCode: error.rawValue)
            }

            let prepared = ScanAdmissionDecision.prepare(rawWindows: rawWindows) {
                isEligible($0, application: eligibilityApplication, cgSnapshot: cgSnapshot)
            }
            let verdict = ScanAdmissionDecision.verdict(
                prepared,
                probedIdentity: entry.identity,
                currentIdentity: processIdentity(pid: entry.pid, bundleID: bundleID),
                isRegularNonSelf: isRegularNonSelf(app),
                isTerminated: app.isTerminated,
                alreadyTracked: apps[entry.pid] != nil
            )
            recordAdmissionProbe(
                source: .scan,
                identity: entry.identity,
                readMode: .timed,
                messagingTimeoutMs: 100,
                maxAttempts: 1,
                result: entry.result,
                eligibleWindowCount: prepared.readFailed ? nil : prepared.eligible.count,
                verdict: inventoryAdmissionVerdict(verdict)
            )
            // 记忆只收「确认无合格窗口」的结论（.unread 永不记忆，挂死 app 保持 5s 重试）；
            // 其它结论一律清掉旧记忆。
            if verdict == .skipNoEligible {
                scanMemos[entry.pid] = ScanProbeGateDecision.Memo(
                    identity: entry.identity,
                    lastCGIDs: cgSnapshot.windowIDsByPID[entry.pid] ?? [],
                    verdictWasNoEligible: true
                )
            } else {
                scanMemos.removeValue(forKey: entry.pid)
            }
            guard verdict == .admit else { continue }

            admit(app: app, prepared: prepared, readOutcome: readOutcome, cgSnapshot: cgSnapshot)
            admitted = true
        }

        if admitted { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
    }

    /// 落地一次补扫收编。只接受 `Prepared`——原始 AX 列表不进入这个作用域，从作用域上杜绝
    /// 把未过滤的数组喂给 `reconcileSeats`。
    private func admit(
        app: NSRunningApplication,
        prepared: ScanAdmissionDecision.Prepared<AXWindowSnapshot>,
        readOutcome: InventoryAXReadOutcome,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) {
        let pid = app.processIdentifier
        addApp(app, enumerateImmediately: false)
        reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(),
            source: .initialEnumeration,
            preloadedEligible: prepared.eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: .timed
        )
        logger.info("scan: admitted pid=\(pid) (\(app.localizedName ?? app.bundleIdentifier ?? "?"))")
    }

    private func processIdentity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        processProvider.identity(pid: pid, bundleID: bundleID)
    }

    private func recordAdmissionProbe(
        source: InventoryAdmissionProbeSource,
        identity: ScanAdmissionDecision.ProcessIdentity,
        readMode: InventoryAdmissionReadMode,
        messagingTimeoutMs: Int?,
        maxAttempts: Int,
        result: AXWindowReadResult,
        eligibleWindowCount: Int?,
        verdict: InventoryAdmissionProbeVerdict
    ) {
        guard inventoryLog.isEnabled else { return }
        let readResult: InventoryAdmissionProbeReadResult
        let errorCode: Int32?
        let rawWindowCount: Int?
        switch result {
        case .success(let windows):
            readResult = .success
            errorCode = nil
            rawWindowCount = windows.count
        case .unread(let error):
            readResult = .unread
            errorCode = error.rawValue
            rawWindowCount = nil
        }
        inventoryLog.record(.admissionProbe(InventoryAdmissionProbePayload(
            source: source,
            pid: identity.pid,
            bundleID: identity.bundleID,
            processStartTimeSec: identity.startTimeSec,
            processStartTimeUsec: identity.startTimeUsec,
            readMode: readMode,
            messagingTimeoutMs: messagingTimeoutMs,
            maxAttempts: maxAttempts,
            readResult: readResult,
            errorCode: errorCode,
            rawWindowCount: rawWindowCount,
            eligibleWindowCount: eligibleWindowCount,
            verdict: verdict
        )))
    }

    private func inventoryAdmissionVerdict(
        _ verdict: ScanAdmissionDecision.Verdict
    ) -> InventoryAdmissionProbeVerdict {
        switch verdict {
        case .admit: return .admit
        case .skipNotRegular: return .skipNotRegular
        case .skipTerminated: return .skipTerminated
        case .skipAlreadyTracked: return .skipAlreadyTracked
        case .skipIdentityMismatch: return .skipIdentityMismatch
        case .skipUnread: return .skipUnread
        case .skipNoEligible: return .skipNoEligible
        }
    }

    // MARK: - Snapshot Building

    private func rebuildSnapshot(onScreenCGIDs: Set<CGWindowID>? = nil) {
        // Read frontmost PID once; passed to windowStatus to determine active highlight
        let frontmostPID = currentFrontmostPID()
        lastOnScreenCGIDs = onScreenCGIDs ?? onScreenWindowIDsProvider()

        var windows: [WindowID: WindowRecord] = [:]
        var orderedWindowIDs: [WindowID] = []
        let fallbackByPID = Dictionary(uniqueKeysWithValues: AppFallbackChipDecision.fallbacks(
            for: appOrder.compactMap { pid in
                apps[pid].map { app in
                    AppFallbackChipDecision.Process(
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        appName: app.appName,
                        hasSeats: !app.windowOrder.isEmpty,
                        isFrontmost: pid == frontmostPID
                    )
                }
            }
        ).map { ($0.pid, $0) })

        // 记住每个 app 的窗口最后在哪块屏：有座位时跟着第一个有归属键的座位走，没座位时保留。
        for pid in appOrder {
            guard let app = apps[pid],
                  let home = app.windowOrder.compactMap({ app.windowsByID[$0]?.displayUUID }).first,
                  home != app.lastWindowDisplayUUID else { continue }
            apps[pid]?.lastWindowDisplayUUID = home
        }

        for pid in appOrder {
            guard let app = apps[pid] else { continue }

            if app.windowOrder.isEmpty {
                guard let fallback = fallbackByPID[pid] else { continue }
                let id = WindowID(rawValue: fallback.windowID)
                windows[id] = WindowRecord(
                    id: id,
                    appID: AppID(rawValue: app.bundleIdentifier ?? app.appName),
                    pid: pid,
                    bundleIdentifier: app.bundleIdentifier,
                    title: app.appName,
                    bounds: nil,
                    status: app.isHidden ? .hidden : .inactive,
                    isOnDesktop: pid == frontmostPID,
                    groupID: id.rawValue,   // 兜底卡自成一组，永不并入别人
                    displayUUID: app.lastWindowDisplayUUID
                )
                orderedWindowIDs.append(id)
            } else {
                // 单座位模型：一个座位 = 一个物理窗口 = 一张卡。卡片稳定身份 = 座位 token（不随
                // 当前标签 cgID 变）；动作落点 = 当前 activeCgID。可见性直接用座位状态（当前标签
                // 离开 AX 即被新标签顶替，不会留陈旧 min；真最小化座位标 isMinimized）。
                for cgID in app.windowOrder {
                    guard let seat = app.windowsByID[cgID] else { continue }
                    let id = WindowID(rawValue: "cgw-\(cgID)")
                    windows[id] = WindowRecord(
                        id: id,
                        appID: AppID(rawValue: app.bundleIdentifier ?? app.appName),
                        pid: pid,
                        bundleIdentifier: app.bundleIdentifier,
                        title: seat.title,
                        bounds: seat.bounds,
                        status: windowStatus(isHidden: app.isHidden, isMinimized: seat.isMinimized, isFocused: seat.isFocused, pid: pid, frontmostPID: frontmostPID),
                        cgWindowID: cgID,
                        isOnDesktop: !seat.isMinimized && !app.isHidden,
                        groupID: seat.token,
                        displayUUID: seat.displayUUID
                    )
                    orderedWindowIDs.append(id)
                }
            }
        }

        let next = DockSnapshot(windows: windows, orderedWindowIDs: orderedWindowIDs)
        guard next != snapshot else { return }
        snapshot = next
    }

    private func windowStatus(isHidden: Bool, isMinimized: Bool, isFocused: Bool, pid: pid_t, frontmostPID: pid_t?) -> WindowStatus {
        if isHidden { return .hidden }
        if isMinimized { return .minimized }
        if isFocused && pid == frontmostPID { return .active }
        return .inactive
    }

    private func isRegularNonSelf(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular &&
        app.bundleIdentifier != DockWindowEligibilityPolicy.selfBundleIdentifier
    }

    #if DEBUG
    // MARK: - Deterministic inventory fixtures

    func installFixtureForTesting(_ app: AppEntry) {
        apps[app.pid] = app
        if !appOrder.contains(app.pid) { appOrder.append(app.pid) }
        mutationGenerations[app.pid, default: 0] &+= 1
    }

    func fixtureAppForTesting(pid: pid_t) -> AppEntry? {
        apps[pid]
    }

    @discardableResult
    func reconcileFixtureForTesting(
        pid: pid_t,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        now: Date,
        eligible: [AXWindowSnapshot],
        readOutcome: InventoryAXReadOutcome,
        readMode: InventoryReconcileReadMode = .timed
    ) -> Bool {
        reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: now,
            source: .periodicReconcile,
            preloadedEligible: eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: readMode
        )
    }

    func scheduleEventReadForTesting(pid: pid_t, source: InventoryReconcileSource) {
        scheduleEventRead(pid: pid, source: source)
    }

    func scheduleFrontmostPollForTesting(pid: pid_t) {
        scheduleFrontmostPoll(pid: pid)
    }

    func minimizeForTesting(pid: pid_t, cgWindowID: CGWindowID) {
        handleWindowMinimized(pid: pid, cgWindowID: cgWindowID)
    }

    func destroyForTesting(pid: pid_t, cgWindowID: CGWindowID) {
        handleWindowDestroyed(pid: pid, cgWindowID: cgWindowID)
    }

    func rebuildSnapshotForTesting(onScreenCGIDs: Set<CGWindowID> = []) {
        rebuildSnapshot(onScreenCGIDs: onScreenCGIDs)
    }

    @discardableResult
    func refreshDisplayAttributionFromCGForTesting(cgSnapshot: AppTrackerCGWindowSnapshot) -> Bool {
        refreshDisplayAttributionFromCG(cgSnapshot)
    }

    func screenParametersChangedForTesting() {
        handleScreenParametersChanged()
    }

    func hasPendingEventReadForTesting(pid: pid_t) -> Bool {
        pendingEventReads[pid] != nil || trailingEventSources[pid] != nil
    }

    func setFrontmostPIDForTesting(_ pid: pid_t?) {
        cachedFrontmostPID = pid
    }

    /// CG 复用门控的缓存状态（fresh 落地后非 nil）。
    func cgSnapshotCacheForTesting() -> (probeIDs: Set<CGWindowID>, atUptime: TimeInterval)? {
        guard cachedCGSnapshot != nil, let probe = cachedCGProbeIDs else { return nil }
        return (probe, cachedCGAtUptime)
    }

    func bumpCGEventGenerationForTesting() {
        cgEventGeneration &+= 1
    }

    func setObserverActiveForTesting(pid: pid_t, active: Bool) {
        observerActiveOverridesForTesting[pid] = active
    }

    func runPeriodicBatchForTesting(
        cgSnapshot: AppTrackerCGWindowSnapshot,
        timeoutOverride: TimeInterval? = nil
    ) {
        schedulePeriodicBatchRead(
            cgSnapshot: cgSnapshot,
            timeout: timeoutOverride ?? periodicReconcileTimeout ?? 0.1
        )
    }
    #endif
}
