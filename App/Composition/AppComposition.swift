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
    private lazy var intentPipeline = IntentPipeline(
        actionPlanning: LifecycleActionPlanner(isFinderPersistent: finderAlwaysInDock)
    )
    private lazy var actionExecutor = PlatformActionExecutor(isFinderPersistent: finderAlwaysInDock)
    private let isAccessibilityTrusted: () -> Bool
    /// 访达是否常驻任务条（设置「任务条常驻访达」）。透传给 tracker / planner / executor。
    private let finderAlwaysInDock: () -> Bool
    private var snapshotSubscription: AnyCancellable?
    private var feedbackTimer: Timer?
    private var startedAt: Date?
    var onToggleDrawer: (() -> Void)?

    private let debugSnapshotLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "debug-snapshot")
    private let chipProbeLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "ChipProbe")
    private let launchLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "Launch")
    private static let launchTraceEnabled = ProcessInfo.processInfo.environment["DOCK_LAUNCH_TRACE"] == "1"
    private static let chipProbeEnabled = ProcessInfo.processInfo.environment["DOCK_CHIP_PROBE"] == "1"
    private static let launchPolicyRecheckDeadlines: [TimeInterval] = [1.5, 3.0, 5.0]

    init(
        inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog(),
        debugState: DebugRuntimeState? = nil,
        isAccessibilityTrusted: @escaping () -> Bool = { PermissionService().hasRequiredPermissions() },
        finderAlwaysInDock: @escaping () -> Bool = { true }
    ) {
        tracker = AppTracker(inventoryLog: inventoryLog, isFinderPersistent: finderAlwaysInDock)
        self.debugState = debugState ?? DebugRuntimeState()
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.finderAlwaysInDock = finderAlwaysInDock
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
        stopLaunchSessions()
    }

    /// 「任务条常驻访达」设置变化时主动重算快照：tracker 的周期 reconcile 只在窗口状态
    /// 变化时重建，设置开关不产生窗口事件，不主动刷新会让旧的 Finder 常驻卡一直留着（issue #7）。
    ///
    /// 必须传显式值而不是回读 store：@Published 在 willSet 发值，sink 执行时属性还是旧值
    ///（本次故障根因：sink 收到 false 但闭包读到 true，filter 放行了 Finder 卡）。
    func refreshFinderPersistence(finderAlwaysInDock: Bool) {
        tracker.refreshSnapshotForSettingChange(finderAlwaysInDock: finderAlwaysInDock)
    }

    deinit {
        feedbackTimer?.invalidate()
        snapshotSubscription?.cancel()
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

    // MARK: - Private

    private func trigger(_ intent: UserIntent) {
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
            chipProbeLogger.info("toggle-planned app=\(runningApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(record.bundleIdentifier ?? "(none)", privacy: .public) recordStatus=\(record.status.rawValue, privacy: .public) optimisticStatus=\(optimisticStatus, privacy: .public) freshActive=\(freshActive, privacy: .public) plannedAction=\(request.kind.rawValue, privacy: .public)")
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

        applyOptimisticState(for: request)
        intentPipeline.registerPending(intent: intent, request: request)
        publishFeedbackEntries()
        updateFeedbackTimer()

        let executor = actionExecutor
        let capturedSnapshot = snapshot
        // **不用 `Task.detached`**（2026-08-11）：那会把用户点击丢进 Swift 协作线程池，而
        // `AppTracker` 的两处后台 AX 读也在同一个池里——事件读每 pid 一发，5 秒补扫更是个
        // **串行 for 循环**（最多 N × 100ms 占住一个池线程）。AX 调用是阻塞式的，本来就不该
        // 占协作线程；点击排在盘点读后面更是白等。改用自己的 `.userInitiated` 并发队列。
        Self.actionQueue.async { [weak self] in
            // 第一个里程碑就量「派发到真正开始跑」这一段——线程池被后台 AX 读占满时，
            // 用户点击就卡在这里，而这段延迟从末端状态是完全看不出来的。
            ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "execStart")
            let success = executor.execute(request, snapshot: capturedSnapshot)
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

    /// 用户动作的执行队列。并发（保持与旧 `Task.detached` 相同的并行度：连点两下不互相排队），
    /// `.userInitiated`（这是人在等的路径，优先于任何后台盘点）。
    private static let actionQueue = DispatchQueue(
        label: "com.caye.macosdockcc.v2.window-action",
        qos: .userInitiated,
        attributes: .concurrent
    )

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
        reconcileLaunchingStates(with: newSnapshot)
        let trusted = isAccessibilityTrusted()
        if hasRequiredPermissions != trusted { hasRequiredPermissions = trusted }
        intentPipeline.reconcile(with: newSnapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
        updateFeedbackTimer()
        if startedAt != nil {
            let ms = Int(Date().timeIntervalSince(startedAt!) * 1000)
            debugState.setObservationStatusText(hasRequiredPermissions ? "实时 \(ms)ms" : "仅窗口列表")
            startedAt = nil
        }
    }

    private func tickFeedback() {
        intentPipeline.reconcile(with: snapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
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
    private func applyOptimisticState(for request: PlatformActionRequest) {
        let state: OptimisticWindowState?
        switch request.kind {
        case .activateWindow:
            state = OptimisticWindowState(status: .active, createdAt: Date())
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
            if now.timeIntervalSince(state.createdAt) > Self.optimisticTimeout { return false }
            guard let record = snapshot.windows[WindowID(rawValue: windowID)] else { return false }
            return !Self.optimisticConfirmed(predicted: state.status, actual: record.status)
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

// MARK: - Debug Snapshot Export

private enum TaskbarDebugSnapshotExporter {
    static func export(snapshot: DockSnapshot, generatedAt: Date = Date()) throws -> URL {
        let report = TaskbarDebugReport(snapshot: snapshot, generatedAt: generatedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(report)
        let timestamp = fileTimestamp.string(from: generatedAt)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macos-dock-cc-v2-debug-snapshot-\(timestamp).json")
        let latestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macos-dock-cc-v2-debug-snapshot-latest.json")
        try data.write(to: url, options: .atomic)
        try data.write(to: latestURL, options: .atomic)
        return url
    }

    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private struct TaskbarDebugReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let trackedCount: Int
    let visibleCount: Int
    let cards: [TaskbarDebugCard]
    let duplicateGroups: [TaskbarDebugDuplicateGroup]
    let liveWindows: [TaskbarDebugLiveWindow]

    init(snapshot: DockSnapshot, generatedAt: Date) {
        let records = snapshot.orderedWindowIDs.compactMap { snapshot.windows[$0] }
        let liveWindows = TaskbarDebugLiveWindow.sample(for: records)
        let duplicateGroupsByKey = Dictionary(grouping: records) { record in
            TaskbarDebugReport.duplicateKey(for: record)
        }
        let duplicateKeys = Set(
            duplicateGroupsByKey.compactMap { key, groupedRecords in
                groupedRecords.count > 1 ? key : nil
            }
        )

        self.schemaVersion = 1
        self.generatedAt = generatedAt
        self.trackedCount = records.count
        self.visibleCount = records.filter { $0.status != .disappeared }.count
        self.liveWindows = liveWindows
        self.duplicateGroups = duplicateGroupsByKey
            .compactMap { key, groupedRecords in
                guard groupedRecords.count > 1 else { return nil }
                return TaskbarDebugDuplicateGroup(
                    key: key,
                    count: groupedRecords.count,
                    ids: groupedRecords.map(\.id.rawValue),
                    titles: groupedRecords.map(\.title)
                )
            }
            .sorted { $0.key < $1.key }
        self.cards = records.enumerated().map { index, record in
            TaskbarDebugCard(
                order: index,
                record: record,
                duplicateKey: Self.duplicateKey(for: record),
                isDuplicateCandidate: duplicateKeys.contains(Self.duplicateKey(for: record)),
                liveWindows: liveWindows
            )
        }
    }

    private static func duplicateKey(for record: WindowRecord) -> String {
        let app = record.bundleIdentifier ?? record.appID.rawValue
        return "\(record.pid)|\(app)|\(TaskbarDebugRect.signature(for: record.bounds))"
    }
}

private struct TaskbarDebugCard: Codable {
    let order: Int
    let id: String
    let title: String
    let status: String
    let pid: Int32
    let bundleIdentifier: String?
    let appID: String
    let bounds: TaskbarDebugRect?
    let duplicateKey: String
    let processAlive: Bool
    let liveAXTitleMatches: Int
    let liveAXMinimizedTitleMatches: Int
    let liveAXFrameMatches: Int
    let liveAXTitleFrameMatches: Int
    let liveCGFrameMatches: Int
    let liveCGTitleFrameMatches: Int
    let classification: String

    init(
        order: Int,
        record: WindowRecord,
        duplicateKey: String,
        isDuplicateCandidate: Bool,
        liveWindows: [TaskbarDebugLiveWindow]
    ) {
        let matchingLiveWindows = liveWindows.filter { $0.pid == record.pid }
        let axTitleMatches = Self.titleMatches(record: record, liveWindows: matchingLiveWindows, source: "ax")
        let axMinimizedTitleMatches = axTitleMatches.filter { $0.isMinimized == true }
        let axFrameMatches = Self.frameMatches(record: record, liveWindows: matchingLiveWindows, source: "ax")
        let axTitleFrameMatches = axFrameMatches.filter { Self.titleMatches(record.title, $0.title) }
        let cgFrameMatches = Self.frameMatches(record: record, liveWindows: matchingLiveWindows, source: "cg")
        let cgTitleFrameMatches = cgFrameMatches.filter { Self.titleMatches(record.title, $0.title) }
        let processAlive = ProcessLiveness.isAlive(pid: record.pid)

        self.order = order
        self.id = record.id.rawValue
        self.title = record.title
        self.status = record.status.rawValue
        self.pid = record.pid
        self.bundleIdentifier = record.bundleIdentifier
        self.appID = record.appID.rawValue
        self.bounds = record.bounds.map(TaskbarDebugRect.init)
        self.duplicateKey = duplicateKey
        self.processAlive = processAlive
        self.liveAXTitleMatches = axTitleMatches.count
        self.liveAXMinimizedTitleMatches = axMinimizedTitleMatches.count
        self.liveAXFrameMatches = axFrameMatches.count
        self.liveAXTitleFrameMatches = axTitleFrameMatches.count
        self.liveCGFrameMatches = cgFrameMatches.count
        self.liveCGTitleFrameMatches = cgTitleFrameMatches.count
        self.classification = Self.classification(
            record: record,
            processAlive: processAlive,
            isDuplicateCandidate: isDuplicateCandidate,
            axTitleMatches: axTitleMatches.count,
            axMinimizedTitleMatches: axMinimizedTitleMatches.count,
            axFrameMatches: axFrameMatches.count,
            axTitleFrameMatches: axTitleFrameMatches.count,
            cgFrameMatches: cgFrameMatches.count,
            cgTitleFrameMatches: cgTitleFrameMatches.count
        )
    }

    private static func classification(
        record: WindowRecord,
        processAlive: Bool,
        isDuplicateCandidate: Bool,
        axTitleMatches: Int,
        axMinimizedTitleMatches: Int,
        axFrameMatches: Int,
        axTitleFrameMatches: Int,
        cgFrameMatches: Int,
        cgTitleFrameMatches: Int
    ) -> String {
        if isDuplicateCandidate { return "duplicate-candidate-same-pid-bundle-frame" }
        if !processAlive { return "stale-process-dead" }
        if record.status == .minimized, axFrameMatches > 0 || axMinimizedTitleMatches > 0 {
            return "retained-minimized-ax-present"
        }
        if record.status == .hidden, axFrameMatches > 0 || axTitleMatches == 1 {
            return "retained-hidden-ax-present"
        }
        if axTitleFrameMatches > 0 || cgTitleFrameMatches > 0 { return "live-title-frame-match" }
        if axFrameMatches > 0 || cgFrameMatches > 0 { return "title-drift-candidate" }
        if processAlive { return "missing-live-window-candidate" }
        return "unknown"
    }

    private static func frameMatches(
        record: WindowRecord,
        liveWindows: [TaskbarDebugLiveWindow],
        source: String
    ) -> [TaskbarDebugLiveWindow] {
        guard let bounds = record.bounds else { return [] }
        return liveWindows.filter { liveWindow in
            guard liveWindow.source == source, let liveBounds = liveWindow.bounds else { return false }
            return WindowFrameMatchPolicy.areClose(bounds, liveBounds.cgRect)
        }
    }

    private static func titleMatches(
        record: WindowRecord,
        liveWindows: [TaskbarDebugLiveWindow],
        source: String
    ) -> [TaskbarDebugLiveWindow] {
        liveWindows.filter { $0.source == source && titleMatches(record.title, $0.title) }
    }

    private static func titleMatches(_ lhs: String, _ rhs: String?) -> Bool {
        let lhs = normalizedTitle(lhs)
        let rhs = normalizedTitle(rhs)
        return !lhs.isEmpty && lhs == rhs
    }

    private static func normalizedTitle(_ title: String?) -> String {
        let scalars = title?.unicodeScalars.filter { scalar in
            scalar.value != 0x200B && scalar.value != 0x200C
                && scalar.value != 0x200D && scalar.value != 0x2060
                && scalar.value != 0xFEFF
        } ?? []
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private struct TaskbarDebugDuplicateGroup: Codable {
    let key: String
    let count: Int
    let ids: [String]
    let titles: [String]
}

private struct TaskbarDebugLiveWindow: Codable {
    let source: String
    let pid: Int32
    let bundleIdentifier: String?
    let title: String?
    let bounds: TaskbarDebugRect?
    let isMinimized: Bool?

    static func sample(for records: [WindowRecord]) -> [TaskbarDebugLiveWindow] {
        let pids = Set(records.map(\.pid))
        return sampleAXWindows(for: pids) + sampleCGWindows(for: pids)
    }

    private static func sampleAXWindows(for pids: Set<Int32>) -> [TaskbarDebugLiveWindow] {
        let reader = AXWindowReader()
        return pids.flatMap { pid in
            switch reader.inventoryWindows(forPID: pid, messagingTimeout: 0.10) {
            case let .success(windows):
                let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                return windows.map { window in
                    TaskbarDebugLiveWindow(
                        source: "ax",
                        pid: pid,
                        bundleIdentifier: bundleIdentifier,
                        title: window.title,
                        bounds: window.bounds.map(TaskbarDebugRect.init),
                        isMinimized: window.isMinimized
                    )
                }
            case .unread:
                return []
            }
        }
    }

    private static func sampleCGWindows(for pids: Set<Int32>) -> [TaskbarDebugLiveWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        return rawList.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else { return nil }
            let title = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bounds = (info[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }

            return TaskbarDebugLiveWindow(
                source: "cg",
                pid: pid,
                bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                title: title?.isEmpty == false ? title : nil,
                bounds: bounds.map(TaskbarDebugRect.init),
                isMinimized: false
            )
        }
    }
}

private struct TaskbarDebugRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    static func signature(for rect: CGRect?) -> String {
        guard let rect else { return "no-frame" }
        return "\(Int(rect.origin.x.rounded())):\(Int(rect.origin.y.rounded())):\(Int(rect.width.rounded())):\(Int(rect.height.rounded()))"
    }
}
