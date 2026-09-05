import AppKit
import Combine
import CoreGraphics
import Foundation
import os

@MainActor
final class DebugRuntimeState: ObservableObject {
    @Published private(set) var feedbackEntriesByWindowID: [String: IntentFeedbackState.Entry] = [:]
    @Published private(set) var observationStatusText: String = "正在启动"

    func setFeedbackEntries(_ entries: [String: IntentFeedbackState.Entry]) {
        guard entries != feedbackEntriesByWindowID else { return }
        feedbackEntriesByWindowID = entries
    }

    func setObservationStatusText(_ text: String) {
        guard text != observationStatusText else { return }
        observationStatusText = text
    }
}

@MainActor
final class AppRuntime: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot = .empty
    @Published private(set) var hasRequiredPermissions: Bool = false
    let debugState: DebugRuntimeState
    /// 乐观状态 overlay（见 OptimisticWindowState 注释）。UI 渲染与 toggle 规划
    /// 优先读这里；快照兑现预测或超时（静默回弹）后清除。
    @Published private(set) var optimisticStatesByWindowID: [String: OptimisticWindowState] = [:]
    /// 「在运行但没窗口」图标的显式住址（多屏 ④：bundleID → display UUID，会话内、不持久化）。
    /// 由跨屏拖动写入；**不放进窗口清单**——清单里可能根本没有这个 app 的条目（零座位的保留应用走
    /// 占位显示），写进清单就落空、卡回主屏（owner 2026-09-02 第四轮）。这个 app 一有真窗口就清掉，
    /// 之后由清单里「窗口最后所在的屏」接管。投影层：显式住址 > 清单里的最后所在屏 > 主屏。
    @Published private(set) var noWindowHomeByBundle: [String: String] = [:]
    private static let displayTraceEnabled = ProcessInfo.processInfo.environment["DOCK_DISPLAY_TRACE"] == "1"
    private let displayTraceLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "display-trace")
    /// 「窗口出现门控」（2026-06-18）：用户从抽屉点击启动的 app，在它拿到真窗口
    /// 之前先记在这里。抽屉据此把它**留在启动区继续弹跳**，不在「进程一出现」就提前
    /// 停跳 / 提前跳进运行区（GUI app 进程就绪 ≠ UI 就绪）。.regular 应用等真窗口；
    /// .accessory 菜单栏 app（Tailscale 类）在进程完成启动且 policy 稳定后放行，
    /// 不被卡住。真窗口出现、确认无窗口能力、启动失败或 20s 超时才清除。
    @Published private(set) var launchingBundleIDs: Set<String> = []

    private struct LaunchProcessIdentity: Equatable {
        let pid: pid_t
        let startTimeSec: Int64
        let startTimeUsec: Int64
    }

    private struct LaunchWindowIdentity: Hashable {
        let chipID: String
        let pid: pid_t
        let startTimeSec: Int64
        let startTimeUsec: Int64
    }

    private struct LaunchSession {
        let bundleID: String
        let token: UInt64
        let startedAt: TimeInterval
        let baselineRealWindows: Set<LaunchWindowIdentity>
        let bundleDeclaresNoWindow: Bool
        var app: NSRunningApplication?
        var processIdentity: LaunchProcessIdentity?
        var openFailed = false
        var policyRecheckTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var lastTraceClassification: String?
    }

    private var launchSessions = LaunchSessionTokenRegistry<LaunchSession>()

    private let tracker: AppTracker
    private let displayTableProvider: @MainActor () -> WindowDisplayAttribution.Table
    private let intentPipeline = IntentPipeline(actionPlanning: LifecycleActionPlanner())
    private let actionExecutor = PlatformActionExecutor()
    private let isAccessibilityTrusted: () -> Bool
    private var snapshotSubscription: AnyCancellable?
    private var feedbackTimer: Timer?
    private var startedAt: Date?
    var onToggleDrawer: (() -> Void)?

    private let debugSnapshotLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "debug-snapshot")
    private let chipProbeLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "ChipProbe")
    private let launchLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "Launch")
    private static let launchTraceEnabled = ProcessInfo.processInfo.environment["DOCK_LAUNCH_TRACE"] == "1"
    private static let chipProbeEnabled = ProcessInfo.processInfo.environment["DOCK_CHIP_PROBE"] == "1"
    /// 最小化沉降门杀开关（默认开）。关掉时既不记 minimize 锚也不 hold，派发路径与旧行为逐位一致。
    private static let settleGateEnabled = ProcessInfo.processInfo.environment["DOCK_MINIMIZE_SETTLE_GATE"] != "0"
    /// 过渡宽限杀开关（默认开）。关掉时兄弟顶替清除回到 2026-08-22 原语义（无过渡豁免）。
    private static let handoffActiveGraceEnabled = ProcessInfo.processInfo.environment["DOCK_HANDOFF_ACTIVE_GRACE"] != "0"
    /// 交接预测杀开关（默认开）。关掉时收起交接不再给接手窗口写乐观 .active 预测。
    private static let handoffActivePredictionEnabled = ProcessInfo.processInfo.environment["DOCK_HANDOFF_ACTIVE_PREDICTION"] != "0"
    private static let launchPolicyRecheckDeadlines: [TimeInterval] = [1.5, 3.0, 5.0]

    init(
        inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog(),
        debugState: DebugRuntimeState? = nil,
        displayTableProvider: @escaping @MainActor () -> WindowDisplayAttribution.Table = {
            DisplayIdentity.attributionTable()
        },
        isAccessibilityTrusted: @escaping () -> Bool = { PermissionService().hasRequiredPermissions() }
    ) {
        tracker = AppTracker(inventoryLog: inventoryLog, displayTableProvider: displayTableProvider)
        self.displayTableProvider = displayTableProvider
        self.debugState = debugState ?? DebugRuntimeState()
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    func start() {
        guard snapshotSubscription == nil else { return }
        startedAt = Date()
        hasRequiredPermissions = isAccessibilityTrusted()
        tracker.start()

        snapshotSubscription = tracker.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSnapshot in
                self?.handleSnapshotUpdate(newSnapshot)
            }

        // 计时器不在这里起：启动瞬间反馈态和乐观态都是空的，没有任何要对账的东西。
        // 它的存亡统一由 updateFeedbackTimer() 决定（见该方法注释）。
        updateFeedbackTimer()
    }

    /// runtime 是否在跑。计时器的重启门就看它——不新增平行的 bool 标志，
    /// 免得两个状态各说各话（`stop()` 会把 subscription 置 nil）。
    private var isRunning: Bool { snapshotSubscription != nil }

    func stop() {
        tracker.stop()
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        for held in heldActionsByWindowID.values { held.workItem.cancel() }
        heldActionsByWindowID.removeAll()
        recentMinimizeDispatchAtByWindowID.removeAll()
        stopLaunchSessions()
    }

    deinit {
        feedbackTimer?.invalidate()
        snapshotSubscription?.cancel()
        for held in heldActionsByWindowID.values { held.workItem.cancel() }
        for entry in launchSessions.currentEntries {
            entry.value.policyRecheckTask?.cancel()
            entry.value.timeoutTask?.cancel()
        }
    }

    func exportDebugSnapshot() {
        do {
            let url = try TaskbarDebugSnapshotExporter.export(snapshot: snapshot)
            debugSnapshotLogger.info("exported debug snapshot path=\(url.path, privacy: .public)")
        } catch {
            debugSnapshotLogger.error("export failed error=\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Actions

    func toggle(windowID: String) { trigger(.toggle(WindowID(rawValue: windowID))) }
    func activate(windowID: String) { trigger(.activate(WindowID(rawValue: windowID))) }
    func minimize(windowID: String) { trigger(.minimize(WindowID(rawValue: windowID))) }
    func hide(windowID: String) { trigger(.hide(WindowID(rawValue: windowID))) }
    func close(windowID: String) { trigger(.close(WindowID(rawValue: windowID))) }
    func quit(windowID: String) { trigger(.quit(WindowID(rawValue: windowID))) }
    func newWindow(windowID: String) { trigger(.newWindow(WindowID(rawValue: windowID))) }

    /// 跨屏投放的分派：真窗口卡 → 搬窗口；`app-*` 兜底卡 / 保留占位（没有窗口可搬）→ 改这个 app
    /// 「无窗口图标住哪块屏」的会话记忆（`AppTracker.noteNoWindowHome`），④ 下那张卡随即换条。
    func handleCrossStripDrop(payload: DragPayload, toDisplayUUID uuid: String) {
        if let item = payload.item, !item.isAppLevelFallback {
            if Self.displayTraceEnabled {
                displayTraceLogger.info("drop window id=\(item.id, privacy: .public) pid=\(item.pid) cg=\(item.cgWindowID ?? 0) from=\(item.displayUUID ?? "nil", privacy: .public) to=\(uuid, privacy: .public)")
            }
            moveWindow(item: item, toDisplayUUID: uuid)
        } else {
            if Self.displayTraceEnabled {
                displayTraceLogger.info("drop no-window bundle=\(payload.bundleID, privacy: .public) id=\(payload.id, privacy: .public) to=\(uuid, privacy: .public)")
            }
            guard !payload.bundleID.isEmpty else { return }
            noWindowHomeByBundle[payload.bundleID] = uuid
            tracker.noteNoWindowHome(bundleID: payload.bundleID, displayUUID: uuid)
        }
    }

    /// 跨屏拖窗（多屏 ③④，owner 2026-09-02）：窗口图标松在另一块屏的任务条上 → 窗口搬到那块屏，
    /// **只搬不置前**。先乐观改清单里的归属键（卡当场跳到目标条），再在动作队列上写 AX 帧
    ///（`AXWindowReader.setFrame`，项目里唯一的几何写入口）；写不成就把键改回去（卡飞回来源条）。
    /// 标签组只搬代表窗口；全屏 / 不可写的窗口就是「写不成」。
    func moveWindow(item: StripItem, toDisplayUUID uuid: String) {
        guard !item.isAppLevelFallback else { return }
        // `item` 是起拖那一刻拍下的；拖动途中座位的当前标签可能换了（切标签 / 顶替），按座位 token
        // （`StripItem.id`）在**此刻**的快照里找现在的 cgWindowID，找不到才用起拖时那个——否则
        // `noteWindowMoved` 找不到座位就整个不搬，卡落地后弹回来源条。
        let liveRecord = snapshot.windows.values.first { $0.groupID == item.id && ($0.cgWindowID ?? 0) != 0 }
        guard let cgWindowID = liveRecord?.cgWindowID ?? item.cgWindowID, cgWindowID != 0 else { return }
        let table = displayTableProvider()
        guard let target = table.displays.first(where: { $0.uuid == uuid }) else { return }
        let source = table.displays.first { $0.uuid == item.displayUUID }
        let pid = pid_t(item.pid)
        let previous = liveRecord?.displayUUID ?? item.displayUUID
        let noted = tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: uuid)
        if Self.displayTraceEnabled {
            displayTraceLogger.info("moveWindow optimistic noted=\(noted) pid=\(pid) cg=\(cgWindowID) to=\(uuid, privacy: .public)")
        }
        guard noted else { return }
        let trace = Self.displayTraceEnabled ? displayTraceLogger : nil
        Self.actionQueue.async { [weak self] in
            let reader = AXWindowReader()
            // AX 里根本找不到这扇窗（关完窗口后赖在 CG 里的离屏 / 幽灵窗口，卡看着就是「有圆点没窗口」）：
            // 没有东西可搬，拖动的含义就是「改住址」——把键钉在目标屏，直到它下次真的在 AX 里可见。
            guard let handle = reader.captureHandle(forPID: pid, cgWindowID: cgWindowID, messagingTimeout: 0.1),
                  let current = reader.frame(of: handle.element, messagingTimeout: 0.1) else {
                trace?.info("moveWindow no AX handle pid=\(pid) cg=\(cgWindowID) → pin untilVisible")
                Task { @MainActor [weak self] in
                    self?.tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: uuid, hold: .untilVisible)
                }
                return
            }
            let frame = WindowDisplayMove.targetFrame(window: current, from: source, to: target)
            // 成败看**回读帧归属到的屏**（`WindowDisplayMove.landedOnTarget`），不按 ±2pt 判：跨屏时 AppKit
            // 常自己修正几 pt，按像素判失败会把已经搬过去的窗口又挪回来。所以不传 `restoreOnFailureTo`，
            // 没到目标屏时自己写回原帧。
            let result = reader.setFrame(frame, for: handle.element,
                                         messagingTimeout: 0.1,
                                         verificationTolerance: 8)
            let landedFrame: CGRect? = {
                if case let .success(actual) = result { return actual }
                return reader.frame(of: handle.element, messagingTimeout: 0.1)
            }()
            if let landedFrame, WindowDisplayMove.landedOnTarget(actual: landedFrame, target: uuid, table: table) {
                trace?.info("moveWindow landed pid=\(pid) cg=\(cgWindowID) frame=\(String(describing: landedFrame), privacy: .public)")
                // 冻结从真正写完这一刻重新起算：乐观写那一刻起的 1.5s 有大半花在两次 AX 往返 + 写帧上，
                // 剩下的不够挡住随后落地的旧位置读。
                Task { @MainActor [weak self] in
                    self?.tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: uuid, hold: .brief)
                }
                return
            }
            trace?.info("moveWindow setFrame failed pid=\(pid) cg=\(cgWindowID) result=\(String(describing: result), privacy: .public) landed=\(String(describing: landedFrame), privacy: .public)")
            _ = reader.setFrame(current, for: handle.element, messagingTimeout: 0.1, verificationTolerance: 8)
            // 写不成：窗口在屏上（用户看得见的真窗口，全屏 / 不可写）→ 回滚，卡飞回来源条；
            // 不在屏上（离屏 / 幽灵）→ 当「改住址」钉死到目标屏。由清单按 on-screen 集合判。
            Task { @MainActor [weak self] in
                guard let self else { return }
                let verdict = self.tracker.resolveFailedWindowMove(pid: pid, cgWindowID: cgWindowID, target: uuid, previous: previous)
                trace?.info("moveWindow failed → \(String(describing: verdict), privacy: .public)")
            }
        }
    }

    // MARK: - Private

    private func trigger(_ intent: UserIntent) {
        // 手感诊断的时间窗起点（默认关，`DOCK_HOVER_TRACE=1`）。没有它，日志里一堆主线程卡顿
        // 不知道该算在谁头上——owner 报的是「点击 / 最小化之后的动作卡」，先得能圈出「之后」。
        HoverTrace.action("\(intent.action)", phase: "begin")
        defer { HoverTrace.action("\(intent.action)", phase: "dispatched") }
        // 同窗口若有被沉降门扣住的动作，任何新 intent 都先取消它（最新意图获胜）。
        cancelHeldAction(for: intent)
        // 可打断（2026-06-13）：显隐类动作不再锁 pending —— 执行本身是几十毫秒的
        // 一次性 AX 调用，没有需要取消的并发；一致性靠乐观 overlay 驱动规划 +
        // 真实快照最终对账。只有 close / quit（窗口会消失）保持锁到确认。
        switch intent.action {
        case .close, .quit:
            guard intentPipeline.canBegin(intent: intent) else { return }
        default:
            break
        }
        let request = intentPipeline.plan(
            intent: intent,
            snapshot: snapshot,
            optimisticStates: optimisticStatesByWindowID
        )

        // ChipProbe: log the planner's actual decision inputs at tap time (main thread, no AX).
        // freshActive = 新建实例即时读（规划用的就是它）；不打滞后的 frontmostApplication，会误导诊断。
        if Self.chipProbeEnabled,
           case .toggle(let wid) = intent,
           let record = snapshot.windows[wid] {
            let runningApp = NSRunningApplication(processIdentifier: record.pid)
            let freshActive = runningApp?.isActive == true
            let optimisticStatus = optimisticStatesByWindowID[wid.rawValue]?.status.rawValue ?? "none"
            chipProbeLogger.info("toggle-planned windowID=\(wid.rawValue, privacy: .public) app=\(runningApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(record.bundleIdentifier ?? "(none)", privacy: .public) recordStatus=\(record.status.rawValue, privacy: .public) optimisticStatus=\(optimisticStatus, privacy: .public) freshActive=\(freshActive, privacy: .public) plannedAction=\(request.kind.rawValue, privacy: .public)")
        }

        if ClickLatencyTrace.isEnabled, let wid = request.windowID?.rawValue {
            let record = snapshot.windows[WindowID(rawValue: wid)]
            ClickLatencyTrace.begin(
                windowID: wid,
                kind: request.kind.rawValue,
                status: record?.status.rawValue ?? "unknown",
                bundleID: record?.bundleIdentifier
            )
        }

        // 还原出身判定用规划时的有效状态（乐观优先），与 planner 的 status 轴同口径。
        let effectiveStatusAtPlan: WindowStatus? = request.windowID.flatMap { wid in
            optimisticStatesByWindowID[wid.rawValue]?.status ?? snapshot.windows[wid]?.status
        }
        applyOptimisticState(for: request, wasMinimizedAtPlan: effectiveStatusAtPlan == .minimized)
        intentPipeline.registerPending(intent: intent, request: request)
        publishFeedbackEntries()
        updateFeedbackTimer()

        routeThroughSettleGate(intent: intent, request: request)
    }

    /// 用户动作的执行队列。并发（保持与旧 `Task.detached` 相同的并行度：连点两下不互相排队），
    /// `.userInitiated`（这是人在等的路径，优先于任何后台盘点）。
    private static let actionQueue = DispatchQueue(
        label: "com.caye.macosdockcc.v2.window-action",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - Minimize Settle Gate

    /// 同窗口连点的「最小化沉降门」（v2,2026-08-25）：刚对某窗口派发过 minimize 时,它的
    /// activate 在这里等**快照确认 `.minimized`**(= 写已落地的证明,人手双击时通常已到,
    /// 感知零延迟)即放行,unminimize 落在 genie 中段反向打断动画;未确认兜底 1.0s 照放。
    /// 安全不靠等待:放行时带 `dispatchPrior` 先验(2.0s 锚窗口)→ 执行层强制走 07-05 v3
    /// 实测安全的还原序、跳过 earlyFocus、封死 app 级兜底,「屏外先切前台」三条提拔路径全堵。
    /// 判定在 `MinimizeSettleGate`(纯函数,有单测)。只门 activate、不门跨 chip。
    private struct HeldAction {
        let intent: UserIntent
        let request: PlatformActionRequest
        /// 这次 hold 锚定的 minimize 派发时刻。hold 存活期间锚不会变：同窗口任何新
        /// intent 都会先取消 hold（最新意图获胜），所以 flush 直接用它重跑判定。
        let anchor: Date
        let generation: UInt64
        var workItem: DispatchWorkItem
    }

    private var recentMinimizeDispatchAtByWindowID: [String: Date] = [:]
    private var heldActionsByWindowID: [String: HeldAction] = [:]
    private var settleGateGeneration: UInt64 = 0

    private func routeThroughSettleGate(intent: UserIntent, request: PlatformActionRequest) {
        guard Self.settleGateEnabled, let windowID = request.windowID?.rawValue else {
            dispatchToExecutor(intent: intent, request: request)
            return
        }
        if request.kind == .minimizeWindow {
            // app-* 卡不产生 minimizeWindow（planner 只给它 hideApp / activateWindow），
            // 前缀判断只是防御。锚只由时间修剪(priorWindow),**绝不因 minimize 执行结果
            // failure 清除**——动画期成功例行被立即回读记成失败(FeedbackTickPolicy 规则
            // 明载),失败清锚会恰在动画中段解除设防。
            if !windowID.hasPrefix("app-") {
                recentMinimizeDispatchAtByWindowID[windowID] = Date()
            }
            dispatchToExecutor(intent: intent, request: request)
            return
        }
        let verdict = MinimizeSettleGate.verdict(
            requestKind: request.kind,
            minimizeDispatchedAt: recentMinimizeDispatchAtByWindowID[windowID],
            snapshotConfirmsMinimized: snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized,
            now: Date()
        )
        switch verdict {
        case .dispatchNow:
            dispatchToExecutor(intent: intent, request: request)
        case .hold(let until):
            ClickLatencyTrace.mark(windowID: windowID, "settleGate", detail: "hold")
            holdAction(intent: intent, request: request, windowID: windowID, until: until)
        }
    }

    private func holdAction(intent: UserIntent, request: PlatformActionRequest, windowID: String, until: Date) {
        guard let anchor = recentMinimizeDispatchAtByWindowID[windowID] else {
            // verdict 只在有锚时返回 hold；走到这里说明状态被并发改动，保守直接派发。
            dispatchToExecutor(intent: intent, request: request)
            return
        }
        settleGateGeneration &+= 1
        let generation = settleGateGeneration
        let workItem = makeFlushWorkItem(windowID: windowID, generation: generation)
        heldActionsByWindowID[windowID] = HeldAction(
            intent: intent, request: request, anchor: anchor, generation: generation, workItem: workItem
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until.timeIntervalSinceNow), execute: workItem)
    }

    private func makeFlushWorkItem(windowID: String, generation: UInt64) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.flushHeldAction(windowID: windowID, generation: generation)
            }
        }
    }

    private func flushHeldAction(windowID: String, generation: UInt64) {
        guard isRunning,
              let held = heldActionsByWindowID[windowID],
              held.generation == generation else { return }
        let verdict = MinimizeSettleGate.verdict(
            requestKind: held.request.kind,
            minimizeDispatchedAt: held.anchor,
            snapshotConfirmsMinimized: snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized,
            now: Date()
        )
        switch verdict {
        case .dispatchNow:
            heldActionsByWindowID.removeValue(forKey: windowID)
            let confirmed = snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized
            ClickLatencyTrace.mark(windowID: windowID, "settleGateFlush", detail: confirmed ? "confirmed" : "cap")
            dispatchToExecutor(intent: held.intent, request: held.request)
        case .hold(let until):
            // 沉降期已过但快照还没确认 → 判定把 deadline 推到硬上限，重排一次即可
            //（deadline 单调不回退，MinimizeSettleGateTests 锁住）。
            held.workItem.cancel()
            let workItem = makeFlushWorkItem(windowID: windowID, generation: generation)
            heldActionsByWindowID[windowID]?.workItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until.timeIntervalSinceNow), execute: workItem)
        }
    }

    /// 快照更新 / 反馈 tick 时重评：快照确认 + 沉降期已过的 held 立即放行，
    /// 不用等 workItem 到点；顺带修剪过期的 minimize 锚。
    private func reevaluateHeldActions(now: Date = Date()) {
        if !recentMinimizeDispatchAtByWindowID.isEmpty {
            // 锚的寿命 = 先验窗口(2.0s,锚的第二职责),不是 hold 上限——v1 用 maxHold 修剪,
            // 访达 887ms 动画期间锚先过期,正是「快速连点仍漏兄弟」的洞之一。
            recentMinimizeDispatchAtByWindowID = recentMinimizeDispatchAtByWindowID.filter {
                now.timeIntervalSince($0.value) < MinimizeSettleGate.priorWindow
            }
        }
        guard !heldActionsByWindowID.isEmpty else { return }
        for (windowID, held) in heldActionsByWindowID {
            let verdict = MinimizeSettleGate.verdict(
                requestKind: held.request.kind,
                minimizeDispatchedAt: held.anchor,
                snapshotConfirmsMinimized: snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized,
                now: now
            )
            guard case .dispatchNow = verdict else { continue }
            held.workItem.cancel()
            heldActionsByWindowID.removeValue(forKey: windowID)
            let confirmed = snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized
            ClickLatencyTrace.mark(windowID: windowID, "settleGateFlush", detail: confirmed ? "confirmed" : "cap")
            dispatchToExecutor(intent: held.intent, request: held.request)
        }
    }

    /// 同窗口新 intent 到来时取消 held（最新意图获胜）。close / quit 需要把从未执行的
    /// held 诚实置 failure，否则它留下的 pending 条目会挡掉 canBegin。其余 intent 的
    /// registerPending 会直接覆盖同 windowID 的反馈条目，无需额外处理。
    private func cancelHeldAction(for intent: UserIntent) {
        guard let held = heldActionsByWindowID.removeValue(forKey: intent.windowID.rawValue) else { return }
        held.workItem.cancel()
        switch intent.action {
        case .close, .quit:
            intentPipeline.registerExecutionResult(intent: held.intent, request: held.request, success: false)
        default:
            break
        }
    }

    /// 把动作交给执行队列。**快照在调用时刻现取**：立即派发时它与 trigger 同一轮
    ///（µs 级新鲜）；被沉降门扣住的动作 flush 时在这里拿到已翻面的新快照，执行层
    /// 才能走 `knownMinimized` 肯定快路径，而不是拿着陈旧快照误入 app 级兜底。
    private func dispatchToExecutor(intent: UserIntent, request: PlatformActionRequest) {
        let executor = actionExecutor
        let capturedSnapshot = snapshot
        // 沉降门先验(v2):主线程读锚表算好随闭包带走——单一咽喉,四个派发口自动一致。
        // activate 且锚在先验窗口(2.0s)内 → 执行层强制走还原分支 + 跳过 earlyFocus +
        // 封死 app 兜底。开关关闭时锚表恒空,先验自然恒 false。
        let forcedMinimizedPrior = request.kind == .activateWindow
            && MinimizeSettleGate.dispatchPrior(
                minimizeDispatchedAt: request.windowID.flatMap { recentMinimizeDispatchAtByWindowID[$0.rawValue] },
                now: Date()
            )
        // **不用 `Task.detached`**（2026-08-11）：那会把用户点击丢进 Swift 协作线程池，而
        // `AppTracker` 的两处后台 AX 读也在同一个池里——事件读每 pid 一发，5 秒补扫更是个
        // **串行 for 循环**（最多 N × 100ms 占住一个池线程）。AX 调用是阻塞式的，本来就不该
        // 占协作线程；点击排在盘点读后面更是白等。改用自己的 `.userInitiated` 并发队列。
        // 收起交接的接手者预测（2026-08-26）：执行层算出交接目标的瞬间回传（早于 minimize
        // 落地），主线程给接手窗口写带过渡宽限的乐观 .active——快照兑现前点它的卡才能正确
        // 规划成收起（「收窗 1 后快点窗 2 收不起来」）。绝不覆盖已存在的乐观条目（用户动作
        // 优先于系统预测）。误预测由顶替清除自愈（真接手者被快照证实即顶掉本预测）。
        let onHandoffActivePrediction: ((WindowID) -> Void)? =
            (request.kind == .minimizeWindow && Self.handoffActivePredictionEnabled)
            ? { [weak self] windowID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.optimisticStatesByWindowID[windowID.rawValue] == nil else { return }
                    // 写入时对当下快照复核：交接判定用的是派发时快照，风暴中可能已过时——
                    // 快照说接手者 minimized/hidden 就不写（写了也会被证伪清除，不如不写）。
                    guard let current = self.snapshot.windows[windowID],
                          current.status != .minimized, current.status != .hidden else { return }
                    self.optimisticStatesByWindowID[windowID.rawValue] = OptimisticWindowState(
                        status: .active, createdAt: Date(), focusHandoffGrace: true, systemPredicted: true
                    )
                }
            }
            : nil
        Self.actionQueue.async { [weak self] in
            // 第一个里程碑就量「派发到真正开始跑」这一段——线程池被后台 AX 读占满时，
            // 用户点击就卡在这里，而这段延迟从末端状态是完全看不出来的。
            ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "execStart")
            let success = executor.execute(
                request,
                snapshot: capturedSnapshot,
                forcedMinimizedPrior: forcedMinimizedPrior,
                onHandoffActivePrediction: onHandoffActivePrediction
            )
            ClickLatencyTrace.end(windowID: request.windowID?.rawValue, success: success)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.intentPipeline.registerExecutionResult(intent: intent, request: request, success: success)
                self.publishFeedbackEntries()
                // 这个回调可能在 stop() 之后才回到主线程；updateFeedbackTimer 里的
                // isRunning 门保证它不会把已经停掉的计时器复活。
                self.updateFeedbackTimer()
            }
        }
    }

    /// 登记并发起一次用户启动。返回 false 表示已有同 bundle 会话，或无法解析 app URL。
    @discardableResult
    func beginLaunch(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty,
              let launchTarget = Self.resolveLaunchTarget(bundleID: bundleID) else {
            launchLogger.warning("launch rejected: app URL missing bundleID=\(bundleID, privacy: .public)")
            traceLaunch("REJECT bid=\(bundleID) reason=no-app-url")
            return false
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let baseline = realWindowIdentities(in: snapshot, bundleID: bundleID)
        let declaresNoWindow = launchTarget.declaresNoWindow
        guard let token = launchSessions.begin(bundleID: bundleID, makeValue: { token in
            LaunchSession(
                bundleID: bundleID,
                token: token,
                startedAt: startedAt,
                baselineRealWindows: baseline,
                bundleDeclaresNoWindow: declaresNoWindow
            )
        }) else {
            traceLaunch("REJECT bid=\(bundleID) reason=session-active")
            return false
        }

        let appURL = launchTarget.url
        let targetPath = AppLaunchTargetDecision.canonicalPath(appURL)
        let configuration = AppLaunchOpenConfiguration.make()
        let createsNewApplicationInstance = configuration.createsNewApplicationInstance
        let allowsRunningApplicationSubstitution = configuration.allowsRunningApplicationSubstitution
        publishLaunching()
        traceLaunch(
            "START bid=\(bundleID) token=\(token) t=\(Self.timeText(startedAt)) baseline=\(baseline.count) "
                + "target=\(Self.traceValue(targetPath)) "
                + "createsNewApplicationInstance=\(createsNewApplicationInstance ? 1 : 0) "
                + "allowsRunningApplicationSubstitution=\(allowsRunningApplicationSubstitution ? 1 : 0)"
        )

        let recheckTask = Task { @MainActor [weak self] in
            for deadline in Self.launchPolicyRecheckDeadlines {
                let wait = max(
                    0,
                    startedAt + deadline - ProcessInfo.processInfo.systemUptime
                )
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                self?.evaluateLaunch(bundleID: bundleID, token: token)
            }
        }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.evaluateLaunch(bundleID: bundleID, token: token)
        }
        let tasksAttached = launchSessions.update(bundleID: bundleID, token: token) { session in
            session.policyRecheckTask = recheckTask
            session.timeoutTask = timeoutTask
        }
        guard tasksAttached else {
            recheckTask.cancel()
            timeoutTask.cancel()
            return false
        }

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] app, error in
            Task { @MainActor [weak self] in
                self?.handleLaunchCompletion(
                    bundleID: bundleID,
                    token: token,
                    targetPath: targetPath,
                    createsNewApplicationInstance: createsNewApplicationInstance,
                    allowsRunningApplicationSubstitution: allowsRunningApplicationSubstitution,
                    app: app,
                    error: error
                )
            }
        }
        return true
    }

    private func handleLaunchCompletion(
        bundleID: String,
        token: UInt64,
        targetPath: String,
        createsNewApplicationInstance: Bool,
        allowsRunningApplicationSubstitution: Bool,
        app: NSRunningApplication?,
        error: Error?
    ) {
        let identity = app.flatMap { Self.processIdentity(pid: $0.processIdentifier) }
        guard launchSessions.update(bundleID: bundleID, token: token, { session in
            session.app = app
            session.processIdentity = identity
            session.openFailed = error != nil
        }) else {
            traceLaunch(
                Self.launchCompletionTrace(
                    prefix: "SUPERSEDED",
                    bundleID: bundleID,
                    token: token,
                    targetPath: targetPath,
                    createsNewApplicationInstance: createsNewApplicationInstance,
                    allowsRunningApplicationSubstitution: allowsRunningApplicationSubstitution,
                    app: app,
                    error: error
                )
            )
            return
        }

        let policy = app.map { Self.activationPolicyText($0.activationPolicy) } ?? "unknown"
        if let error {
            launchLogger.error(
                "openApplication failed bundleID=\(bundleID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        traceLaunch(
            Self.launchCompletionTrace(
                prefix: "OPENED",
                bundleID: bundleID,
                token: token,
                targetPath: targetPath,
                createsNewApplicationInstance: createsNewApplicationInstance,
                allowsRunningApplicationSubstitution: allowsRunningApplicationSubstitution,
                app: app,
                error: error,
                policy: policy
            )
        )
        evaluateLaunch(bundleID: bundleID, token: token)
    }

    private func reconcileLaunchingStates(with newSnapshot: DockSnapshot) {
        guard !launchSessions.bundleIDs.isEmpty else { return }
        for entry in launchSessions.currentEntries {
            evaluateLaunch(bundleID: entry.bundleID, token: entry.token, snapshot: newSnapshot)
        }
    }

    private func evaluateLaunch(
        bundleID: String,
        token: UInt64,
        snapshot suppliedSnapshot: DockSnapshot? = nil
    ) {
        guard let entry = launchSessions.entry(for: bundleID), entry.token == token else {
            traceLaunch("SUPERSEDED bid=\(bundleID) token=\(token)")
            return
        }
        let session = entry.value
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - session.startedAt)
        let currentWindows = realWindowIdentities(
            in: suppliedSnapshot ?? snapshot,
            bundleID: bundleID
        )
        let hasNewRealWindow = LaunchWindowBaselineDecision.hasNewWindow(
            baseline: session.baselineRealWindows,
            current: currentWindows
        )

        let targetPID = session.app?.processIdentifier
        let processObservation: LaunchGateDecision.ProcessObservation? = session.app.map { app in
            let currentIdentity = Self.processIdentity(pid: app.processIdentifier)
            return LaunchGateDecision.ProcessObservation(
                isAlive: ProcessLiveness.isAlive(pid: app.processIdentifier),
                generationMatches: session.processIdentity != nil && currentIdentity == session.processIdentity,
                activationPolicy: Self.launchActivationPolicy(app.activationPolicy),
                isFinishedLaunching: app.isFinishedLaunching,
                bundleDeclaresNoWindow: session.bundleDeclaresNoWindow
            )
        }
        let hasOtherRegularProcess = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .contains { app in
                app.processIdentifier != targetPID
                    && app.activationPolicy == .regular
                    && ProcessLiveness.isAlive(pid: app.processIdentifier)
            }
        let observation = LaunchGateDecision.Observation(
            openFailed: session.openFailed,
            hasNewRealWindow: hasNewRealWindow,
            launchedProcess: processObservation,
            hasOtherRegularProcess: hasOtherRegularProcess,
            elapsed: elapsed
        )
        let verdict = LaunchGateDecision.evaluate(observation)
        traceLaunchEvaluation(
            bundleID: bundleID,
            token: token,
            observation: observation,
            verdict: verdict
        )

        if case .release(let reason) = verdict {
            releaseLaunch(bundleID: bundleID, token: token, reason: reason, elapsed: elapsed)
        }
    }

    private func releaseLaunch(
        bundleID: String,
        token: UInt64,
        reason: LaunchGateDecision.ReleaseReason,
        elapsed: TimeInterval
    ) {
        guard let session = launchSessions.remove(bundleID: bundleID, token: token) else {
            traceLaunch("SUPERSEDED bid=\(bundleID) token=\(token)")
            return
        }
        session.policyRecheckTask?.cancel()
        session.timeoutTask?.cancel()
        publishLaunching()
        traceLaunch(
            "RELEASE bid=\(bundleID) token=\(token) el=\(Self.timeText(elapsed)) "
                + "reason=\(String(describing: reason))"
        )
    }

    private func stopLaunchSessions() {
        let sessions = launchSessions.removeAll()
        for session in sessions {
            session.policyRecheckTask?.cancel()
            session.timeoutTask?.cancel()
        }
        publishLaunching()
    }

    private func publishLaunching() {
        let next = launchSessions.bundleIDs
        if next != launchingBundleIDs {
            launchingBundleIDs = next
        }
    }

    private func realWindowIdentities(
        in snapshot: DockSnapshot,
        bundleID: String
    ) -> Set<LaunchWindowIdentity> {
        Set(StripItem.items(from: snapshot).compactMap { item in
            guard item.bundleIdentifier == bundleID,
                  !item.isAppLevelFallback,
                  ProcessLiveness.isAlive(pid: item.pid),
                  let startTime = ProcessLiveness.startTime(pid: item.pid) else {
                return nil
            }
            return LaunchWindowIdentity(
                chipID: item.id,
                pid: item.pid,
                startTimeSec: Int64(startTime.tv_sec),
                startTimeUsec: Int64(startTime.tv_usec)
            )
        })
    }

    private static func processIdentity(pid: pid_t) -> LaunchProcessIdentity? {
        guard ProcessLiveness.isAlive(pid: pid),
              let startTime = ProcessLiveness.startTime(pid: pid) else {
            return nil
        }
        return LaunchProcessIdentity(
            pid: pid,
            startTimeSec: Int64(startTime.tv_sec),
            startTimeUsec: Int64(startTime.tv_usec)
        )
    }

    private static func launchActivationPolicy(
        _ policy: NSApplication.ActivationPolicy
    ) -> LaunchGateDecision.ActivationPolicy {
        switch policy {
        case .regular: return .regular
        case .accessory: return .accessory
        case .prohibited: return .prohibited
        @unknown default: return .unknown
        }
    }

    private static func activationPolicyText(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }

    private static func bundleDeclaresNoWindow(at appURL: URL) -> Bool {
        guard let info = Bundle(url: appURL)?.infoDictionary else { return false }
        func boolValue(_ key: String) -> Bool {
            if let value = info[key] as? Bool { return value }
            if let value = info[key] as? NSNumber { return value.boolValue }
            if let value = info[key] as? String {
                return ["1", "true", "yes"].contains(value.lowercased())
            }
            return false
        }
        return boolValue("LSUIElement") || boolValue("LSBackgroundOnly")
    }

    private static func resolveLaunchTarget(bundleID: String) -> AppLaunchTargetDecision.Candidate? {
        let workspace = NSWorkspace.shared
        let preferred = workspace.urlForApplication(withBundleIdentifier: bundleID).map {
            AppLaunchTargetDecision.Candidate(
                url: $0,
                declaresNoWindow: bundleDeclaresNoWindow(at: $0)
            )
        }
        let candidates = workspace.urlsForApplications(withBundleIdentifier: bundleID).map {
            AppLaunchTargetDecision.Candidate(
                url: $0,
                declaresNoWindow: bundleDeclaresNoWindow(at: $0)
            )
        }
        return AppLaunchTargetDecision.select(
            launchServicesCandidates: candidates,
            preferred: preferred
        )
    }

    private static func launchCompletionTrace(
        prefix: String,
        bundleID: String,
        token: UInt64,
        targetPath: String,
        createsNewApplicationInstance: Bool,
        allowsRunningApplicationSubstitution: Bool,
        app: NSRunningApplication?,
        error: Error?,
        policy suppliedPolicy: String? = nil
    ) -> String {
        let policy = suppliedPolicy ?? app.map { activationPolicyText($0.activationPolicy) } ?? "unknown"
        let returnedPath = app?.bundleURL.map { canonicalPath in
            AppLaunchTargetDecision.canonicalPath(canonicalPath)
        }
        return "\(prefix) bid=\(bundleID) token=\(token) target=\(traceValue(targetPath)) "
            + "createsNewApplicationInstance=\(createsNewApplicationInstance ? 1 : 0) "
            + "allowsRunningApplicationSubstitution=\(allowsRunningApplicationSubstitution ? 1 : 0) "
            + "pid=\(app.map { String($0.processIdentifier) } ?? "nil") policy=\(policy) "
            + "returned=\(returnedPath.map(traceValue) ?? "nil") "
            + "error=\(error.map { traceValue($0.localizedDescription) } ?? "nil")"
    }

    private static func traceValue(_ value: String) -> String {
        String(reflecting: value)
    }

    private func traceLaunchEvaluation(
        bundleID: String,
        token: UInt64,
        observation: LaunchGateDecision.Observation,
        verdict: LaunchGateDecision.Verdict
    ) {
        guard Self.launchTraceEnabled else { return }
        let process = observation.launchedProcess
        let classification = [
            "fail=\(observation.openFailed ? 1 : 0)",
            "win=\(observation.hasNewRealWindow ? 1 : 0)",
            "alive=\(process.map { $0.isAlive ? 1 : 0 } ?? -1)",
            "gen=\(process.map { $0.generationMatches ? 1 : 0 } ?? -1)",
            "policy=\(process.map { String(describing: $0.activationPolicy) } ?? "unknown")",
            "fin=\(process.map { $0.isFinishedLaunching ? 1 : 0 } ?? -1)",
            "decl=\(process.map { $0.bundleDeclaresNoWindow ? 1 : 0 } ?? -1)",
            "other=\(observation.hasOtherRegularProcess ? 1 : 0)",
            "verdict=\(String(describing: verdict))"
        ].joined(separator: " ")
        guard launchSessions.entry(for: bundleID)?.value.lastTraceClassification != classification else {
            return
        }
        _ = launchSessions.update(bundleID: bundleID, token: token) { session in
            session.lastTraceClassification = classification
        }
        traceLaunch(
            "EVAL bid=\(bundleID) token=\(token) el=\(Self.timeText(observation.elapsed)) \(classification)"
        )
    }

    private func traceLaunch(_ message: String) {
        guard Self.launchTraceEnabled else { return }
        print("[launch] \(message)")
    }

    private static func timeText(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }

    private func handleSnapshotUpdate(_ newSnapshot: DockSnapshot) {
        if snapshot != newSnapshot { snapshot = newSnapshot }
        // 显式住址只管「没窗口」的那段：这个 app 一有真窗口就清掉，之后由清单里「窗口最后所在的屏」接管。
        if !noWindowHomeByBundle.isEmpty {
            for record in newSnapshot.windows.values where record.cgWindowID != nil {
                if let bid = record.bundleIdentifier, noWindowHomeByBundle[bid] != nil {
                    noWindowHomeByBundle.removeValue(forKey: bid)
                }
            }
        }
        reconcileLaunchingStates(with: newSnapshot)
        let trusted = isAccessibilityTrusted()
        if hasRequiredPermissions != trusted { hasRequiredPermissions = trusted }
        intentPipeline.reconcile(with: newSnapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
        reevaluateHeldActions()
        updateFeedbackTimer()
        if let startedAt {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugState.setObservationStatusText(hasRequiredPermissions ? "实时 \(ms)ms" : "仅窗口列表")
            self.startedAt = nil
        }
    }

    private func tickFeedback() {
        intentPipeline.reconcile(with: snapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
        reevaluateHeldActions()
        updateFeedbackTimer()
    }

    /// 把 pipeline 的反馈态投影到独立调试状态——**先比较再写**。
    ///
    /// `@Published` 不做相等性判断，`willSet` 一律通知。调试消费者现在只观察
    /// `DebugRuntimeState`，反馈变化不会再使任务条与抽屉失效。
    /// 同文件的 `reconcileOptimisticStates` 和 `BadgeStore.readOnce` 早就是「先比较再写」，
    /// 只有这条漏了。
    private func publishFeedbackEntries() {
        let next = intentPipeline.feedbackState.entriesByWindowID
        debugState.setFeedbackEntries(next)
    }

    /// 反馈计时器按需运行：只有反馈态或乐观态非空时才需要周期性对账（pending 超时转
    /// failure、结果展示到期清除、乐观态超时静默回弹）。两者都空 = 没有任何会随时间
    /// 变化的东西，一次空转都不该有。
    ///
    /// 时间语义完全不变：仍是 0.5s 周期 + 0.05s tolerance，4s pending / 1.5s 结果展示
    /// 的 retention 也没动——变的只是「没事做的时候不转」。
    private func updateFeedbackTimer() {
        let shouldTick = FeedbackTickPolicy.shouldTick(
            isRunning: isRunning,
            hasFeedbackEntries: !intentPipeline.feedbackState.entriesByWindowID.isEmpty,
            hasOptimisticStates: !optimisticStatesByWindowID.isEmpty
        )
        guard shouldTick else {
            feedbackTimer?.invalidate()
            feedbackTimer = nil
            return
        }
        guard feedbackTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFeedback() }
        }
        timer.tolerance = 0.05
        feedbackTimer = timer
    }

    // MARK: - Optimistic Overlay

    /// 超时上限对齐 pending retention（IntentFeedbackState.FeedbackPhase.pending）。
    private static let optimisticTimeout: TimeInterval = 4.0

    /// 按计划出的动作写预测态。hideApp 只盖被点的那张 chip，同 app 其他窗口
    /// 等快照（v1 接受）。close / quit / newWindow 不写（窗口要消失 / 是别的窗口）。
    private func applyOptimisticState(for request: PlatformActionRequest, wasMinimizedAtPlan: Bool) {
        let state: OptimisticWindowState?
        switch request.kind {
        case .activateWindow:
            state = OptimisticWindowState(status: .active, createdAt: Date(), focusHandoffGrace: wasMinimizedAtPlan)
        case .minimizeWindow:
            state = OptimisticWindowState(status: .minimized, createdAt: Date())
        case .hideApp:
            state = OptimisticWindowState(status: .hidden, createdAt: Date())
        case .closeWindow, .quitApp, .newWindow:
            state = nil
        }
        guard let state, let windowID = request.windowID else { return }
        optimisticStatesByWindowID[windowID.rawValue] = state
    }

    /// 兑现 / 回滚：真实快照达到预测态（或窗口消失）→ 清除；超时没兑现 → 静默
    /// 回弹到真实态（不加额外提示，AX 动作失败本身罕见）。
    private func reconcileOptimisticStates(now: Date = Date()) {
        guard !optimisticStatesByWindowID.isEmpty else { return }
        let next = optimisticStatesByWindowID.filter { windowID, state in
            let cleared: String?
            if now.timeIntervalSince(state.createdAt) > Self.optimisticTimeout {
                cleared = "timeout"
            } else if snapshot.windows[WindowID(rawValue: windowID)] == nil {
                cleared = "window-gone"
            } else if let record = snapshot.windows[WindowID(rawValue: windowID)],
                      Self.optimisticConfirmed(predicted: state.status, actual: record.status) {
                cleared = "confirmed"
            } else if let record = snapshot.windows[WindowID(rawValue: windowID)],
                      OptimisticWindowState.systemPredictionFalsified(state: state, actual: record.status) {
                cleared = "prediction-falsified"
            } else if OptimisticWindowState.supersededByActiveSibling(
                windowID: windowID, state: state, now: now,
                optimisticStates: optimisticStatesByWindowID,
                snapshot: snapshot, handoffGraceEnabled: Self.handoffActiveGraceEnabled
            ) {
                cleared = "superseded-by-active-sibling"
            } else {
                cleared = nil
            }
            if Self.chipProbeEnabled, let cleared {
                chipProbeLogger.info("optimistic-cleared windowID=\(windowID, privacy: .public) predicted=\(state.status.rawValue, privacy: .public) ageMs=\(Int(now.timeIntervalSince(state.createdAt) * 1000), privacy: .public) reason=\(cleared, privacy: .public)")
            }
            return cleared == nil
        }
        if next != optimisticStatesByWindowID {
            optimisticStatesByWindowID = next
        }
    }

    /// 对齐 feedback reconcile 的口径：minimize / hide 可能短暂表现为 disappeared
    ///（Finder 最小化反馈 bug 的教训），也算兑现。
    private static func optimisticConfirmed(predicted: WindowStatus, actual: WindowStatus) -> Bool {
        if predicted == actual { return true }
        if (predicted == .minimized || predicted == .hidden) && actual == .disappeared { return true }
        return false
    }
}
