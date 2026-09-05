import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

private let windowLiftAXMessagingTimeout: TimeInterval = 0.1

struct WindowLiftCGCandidate: Equatable {
    let key: WindowLiftAvoidance.WindowKey
    let quartzFrame: CGRect
}

struct WindowLiftCGScanResult {
    /// 每块屏（按传入的 `screenCGFrames` 下标）各自的前台大窗候选；没有的屏不在字典里。
    let candidatesByScreenIndex: [Int: WindowLiftCGCandidate]
    let onScreenFrames: [WindowLiftAvoidance.WindowKey: CGRect]
    let liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?
}

/// 避让宿主：给出「哪些屏有一条常驻且可见的任务条」的几何，每屏一份（③④ 下由编排层汇总各单元）。
@MainActor
protocol WindowLiftAvoidanceHost: AnyObject {
    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext]
}

enum WindowLiftCGWindowProbe {
    static func frontmostLargeWindow(
        on screenCGFrame: CGRect,
        excludingPID selfPID: pid_t
    ) -> WindowLiftCGCandidate? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return frontmostLargeWindow(in: list, on: screenCGFrame, excludingPID: selfPID)
    }

    static func capture(
        on screenCGFrames: [CGRect],
        excludingPID selfPID: pid_t,
        includeLiveWindowKeys: Bool
    ) -> WindowLiftCGScanResult {
        let onScreenList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var onScreenFrames: [WindowLiftAvoidance.WindowKey: CGRect] = [:]
        for info in onScreenList {
            guard let key = windowKey(in: info),
                  let bounds = windowBounds(in: info) else { continue }
            onScreenFrames[key] = bounds
        }

        let liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?
        if includeLiveWindowKeys,
           let fullList = CGWindowListCopyWindowInfo(
               [.optionAll, .excludeDesktopElements],
               kCGNullWindowID
           ) as? [[String: Any]] {
            liveWindowKeys = Set(fullList.compactMap(windowKey(in:)))
        } else {
            liveWindowKeys = nil
        }

        // 一次 CG 全表，每块屏各跑一遍同一个过滤（0.7 宽度门与全屏探测共享，不放松）。
        var candidates: [Int: WindowLiftCGCandidate] = [:]
        for (index, frame) in screenCGFrames.enumerated() {
            if let candidate = frontmostLargeWindow(in: onScreenList, on: frame, excludingPID: selfPID) {
                candidates[index] = candidate
            }
        }
        return WindowLiftCGScanResult(
            candidatesByScreenIndex: candidates,
            onScreenFrames: onScreenFrames,
            liveWindowKeys: liveWindowKeys
        )
    }

    static func liveWindowKeys() -> Set<WindowLiftAvoidance.WindowKey>? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return Set(list.compactMap(windowKey(in:)))
    }

    static func frames(
        for keys: Set<WindowLiftAvoidance.WindowKey>
    ) -> [WindowLiftAvoidance.WindowKey: CGRect] {
        guard !keys.isEmpty else { return [:] }

        var frames: [WindowLiftAvoidance.WindowKey: CGRect] = [:]
        for key in keys {
            guard let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenAboveWindow, .optionIncludingWindow, .excludeDesktopElements],
                key.cgWindowID
            ) as? [[String: Any]],
                  let info = list.first(where: { windowKey(in: $0) == key }),
                  let bounds = windowBounds(in: info) else {
                continue
            }
            frames[key] = bounds
        }
        return frames
    }

    static func frame(for key: WindowLiftAvoidance.WindowKey) -> CGRect? {
        frames(for: [key])[key]
    }

    private static func frontmostLargeWindow(
        in list: [[String: Any]],
        on screenCGFrame: CGRect,
        excludingPID selfPID: pid_t
    ) -> WindowLiftCGCandidate? {
        for info in list {
            guard number(in: info, key: kCGWindowLayer)?.intValue == 0,
                  let key = windowKey(in: info),
                  key.pid != selfPID,
                  let bounds = windowBounds(in: info),
                  bounds.intersects(screenCGFrame),
                  bounds.width > screenCGFrame.width * 0.7,
                  bounds.width >= 80,
                  bounds.height >= 40,
                  (number(in: info, key: kCGWindowAlpha)?.doubleValue ?? 1) > 0 else {
                continue
            }
            return WindowLiftCGCandidate(key: key, quartzFrame: bounds)
        }
        return nil
    }

    private static func windowKey(in info: [String: Any]) -> WindowLiftAvoidance.WindowKey? {
        guard let pid = number(in: info, key: kCGWindowOwnerPID)?.int32Value,
              let windowID = number(in: info, key: kCGWindowNumber)?.uint32Value,
              windowID != 0 else {
            return nil
        }
        return WindowLiftAvoidance.WindowKey(pid: pid, cgWindowID: windowID)
    }

    private static func windowBounds(in info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private static func number(in info: [String: Any], key: CFString) -> NSNumber? {
        info[key as String] as? NSNumber
    }
}

@MainActor
final class WindowLiftAvoidanceController {
    private struct ManagedFrames {
        let nativeAppKit: CGRect
        let targetAppKit: CGRect
        let nativeQuartz: CGRect
        let targetQuartz: CGRect
        let primaryScreenHeight: CGFloat
    }

    private enum ValidationStage: String {
        case candidateMoved
        case handleUnavailable
        case roleUnavailable
        case unsupportedRole
        case fullscreen
        case minimized
        case frameUnavailable
        case frameMismatch
        case capabilityUnavailable
        case sizeNotSettable
    }

    private enum ValidationOutcome {
        case ready(AXWindowHandle)
        case transient(ValidationStage)
        case unsupported(ValidationStage)
    }

    private struct WriteAnomaly {
        let reason: AXWindowFrameWriteFailure
        let rollback: AXWindowFrameRollbackResult
        let decision: WindowLiftAvoidance.AnimationWriteFailureDecision
        let progress: Double
    }

    private enum OperationOutcome {
        case completed(CGRect, reliftCount: Int, anomalies: [WriteAnomaly])
        case externalFrame(CGRect, anomalies: [WriteAnomaly])
        case reliftLimitReached(CGRect, reliftCount: Int, anomalies: [WriteAnomaly])
        case failed(
            reason: AXWindowFrameWriteFailure,
            rollback: AXWindowFrameRollbackResult,
            progress: Double,
            reliftCount: Int,
            anomalies: [WriteAnomaly]
        )
        case transientValidation(ValidationStage)
        case unsupportedValidation(ValidationStage)
        case cancelled
    }

    private static let trackedProbeInterval = WindowLiftAvoidance.trackedSessionProbeInterval

    private weak var host: WindowLiftAvoidanceHost?
    private let logger = Logger(
        subsystem: "com.caye.macosdockcc.v2",
        category: "WindowLiftAvoidance"
    )
    private var pollTimer: Timer?
    private var pollTimerInterval: TimeInterval?
    private var eventPollTimer: Timer?
    private var eventPollCoalescer = WindowLiftAvoidance.EventPollCoalescer()
    private var scanTask: Task<Void, Never>?
    private var trackedProbeTimer: Timer?
    private var trackedProbeTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var writeTasks: [WindowLiftAvoidance.WindowKey: Task<Void, Never>] = [:]
    private var writeDrainTasks: [
        WindowLiftAvoidance.WindowKey: [Task<Void, Never>]
    ] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var geometryObserver: FrontmostWindowGeometryObserver?
    private var states: [WindowLiftAvoidance.WindowKey: WindowLiftAvoidance.SessionState] = [:]
    private var managedFrames: [WindowLiftAvoidance.WindowKey: ManagedFrames] = [:]
    private var suppressedFrames: [WindowLiftAvoidance.WindowKey: ManagedFrames] = [:]
    private var observationWatermarks: [WindowLiftAvoidance.WindowKey: UInt64] = [:]
    private var validationGenerations: [WindowLiftAvoidance.WindowKey: UInt64] = [:]
    private var lastTraceClassifications: [
        WindowLiftAvoidance.WindowKey: WindowLiftAvoidance.FrameClassification
    ] = [:]
    /// 宿主上一次给出的上下文集合（每屏一份）。集合一变 = 还原全部已抬窗口、重扫（今天换屏行为的推广）。
    private var lastContexts: [WindowLiftAvoidanceContext] = []
    /// 每个会话归属的那块屏的上下文（多屏下各会话不同屏）。随 `states` 增删，探测时按它分别处理。
    private var sessionContexts: [WindowLiftAvoidance.WindowKey: WindowLiftAvoidanceContext] = [:]
    private var nextGeneration: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    private var trackedProbeGeneration: UInt64 = 0
    private var restoreGeneration: UInt64 = 0
    private var scanInFlight = false
    private var usesAnimatedLift = false
    private var traceEnabled = false
    private var periodicPollCount: UInt64 = 0
    private var eventPollCount: UInt64 = 0
    private var trailingEventPollCount: UInt64 = 0
    private var isEnabled = false
    /// 用户设置（菜单「最大化窗口避开任务条」）。**默认关**，由 `AppDelegate` 起步时按
    /// 持久化值灌一次、之后订阅同步。放在控制器自己身上而不是只在调用方拦——
    /// `endPermissionUncertainty()` 内部会调 `start()`，只在外面拦的话一次权限抖动
    /// 就能把用户关掉的功能重新打开。
    private var isEnabledBySetting = false

    /// 冻结期间：只丢任务引用，绝不动 `states` / `managedFrames` / `suppressedFrames` /
    /// `pendingRestorations`。撤权之后 AX 写不动窗口，这时候清掉快照等于永久丢失还原能力。
    private var isPermissionFrozen = false
    private var freezeGeneration: UInt64 = 0
    /// 待还原窗口归控制器所有：还原成功一项才移除。以前这批数据是拷进局部变量
    /// 再交给 detached task 的，中途失权时新的冻结机制根本接管不到。
    private var pendingRestorations: [WindowLiftAvoidance.WindowKey: ManagedFrames] = [:]
    /// 入列时的进程启动时间，用来在长时间冻结后识别 pid 复用。
    private var pendingRestorationStartTimes: [WindowLiftAvoidance.WindowKey: timeval] = [:]
    /// 被取消但还没跑完的写任务。取消的 AX 调用没法半路打断，恢复前必须排空，
    /// 否则迟到的 rollback 会盖掉还原结果。
    private var pendingDrains: [Task<Void, Never>] = []
    private let isTrustedProbe: () -> Bool

    private enum RestoreOutcome: Equatable {
        /// 已还原、或已确认不需要还原（用户动过、窗口没了、pid 被复用）。
        case handled
        /// 这一轮够不着（多半是还没拿到辅助功能权限），留着下次再还。
        case unreachable
    }

    init(host: WindowLiftAvoidanceHost, isTrustedProbe: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.host = host
        self.isTrustedProbe = isTrustedProbe
    }

    // MARK: - 权限冻结

    /// 权限第一次读不到时调用。用户界面此刻还没有任何变化，但快照必须立刻锁住。
    func beginPermissionUncertainty() {
        enterFreeze(reason: "permissionUncertain")
    }

    /// 误报路径：权限又读到了。**分级解冻**——先排空旧 writer、提升代次拒绝迟到回调、
    /// 按当前情况收敛被冻结的会话，最后才恢复轮询。直接清冻结位会留下一个
    /// writer 已死、却永远不会重新发起写入的 `.writing` 会话（纯 reducer 对后续观察
    /// 只更新代次），那个窗口就再也不动了。
    func endPermissionUncertainty() {
        guard isPermissionFrozen else { return }
        freezeGeneration &+= 1
        let generation = freezeGeneration
        let drains = pendingDrains
        pendingDrains.removeAll()

        Task { @MainActor [weak self] in
            for task in drains { await task.value }
            guard let self, self.freezeGeneration == generation, self.isPermissionFrozen else { return }
            self.isPermissionFrozen = false
            self.convergeFrozenSessions()
            self.start()
        }
    }

    /// 权限刚刚恢复、准备重启进程之前调用：排空 → 解冻 → 还原 → 等还原跑完。
    func restoreAndStopForPermissionRecovery() async {
        freezeGeneration &+= 1
        let drains = pendingDrains
        pendingDrains.removeAll()
        for task in drains { await task.value }

        isPermissionFrozen = false
        stop()
        while let task = restoreTask {
            await task.value
        }
    }

    private func enterFreeze(reason: String) {
        guard !isPermissionFrozen else { return }
        isPermissionFrozen = true
        // 已经排进主队列的 poll() 只看这个字段，必须一并关掉。
        isEnabled = false
        freezeGeneration &+= 1
        pollTimer?.invalidate()
        pollTimer = nil
        pollTimerInterval = nil
        resetEventPolling()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        stopTrackedProbe()
        geometryObserver?.stop()
        geometryObserver = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        for task in writeTasks.values {
            task.cancel()
            pendingDrains.append(task)
        }
        for tasks in writeDrainTasks.values { pendingDrains.append(contentsOf: tasks) }
        writeTasks.removeAll()
        writeDrainTasks.removeAll()

        logger.notice("""
            lift frozen reason=\(reason, privacy: .public) \
            sessions=\(self.states.count, privacy: .public) \
            pending=\(self.pendingRestorations.count, privacy: .public)
            """)
    }

    /// 解冻收敛：writer 已经被取消的 `.writing` 会话不可能自己走完，就地清掉。
    /// 用 `suppressUntilNative` 清，免得下一轮把「已经被抬起的位置」当成原生位置再抬一次。
    private func convergeFrozenSessions() {
        let stalled = states.compactMap { key, state -> WindowLiftAvoidance.WindowKey? in
            if case .writing = state { return key }
            return nil
        }
        for key in stalled {
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: "permissionUnfreeze",
                suppressUntilNative: true
            )
        }
    }

    /// 冻结期间禁止一切会抹掉会话数据的操作。
    private func canMutateSessions() -> Bool { !isPermissionFrozen }

    /// 破坏性入口的统一闸门，顺手做一次**静默**的受信自检（绝不带 prompt）。
    ///
    /// 快照保护必须是控制器自己的事：看门狗 5 秒采样一次；只要有会话、抑制帧或还原任务，
    /// 这里仍保持 0.2 秒轮询。1 秒慢档只在没有任何快照要保护的空闲期启用。
    /// 撤权之后到看门狗看见第一次 false 之间那 0–5 秒里，只要用户切一次屏，
    /// `reconcileContext` 就会先清掉快照再去还原——而此刻 AX 已经写不动了。
    private func ensureTrustedOrFreeze() -> Bool {
        if isPermissionFrozen { return false }
        guard isTrustedProbe() else {
            enterFreeze(reason: "selfCheck")
            return false
        }
        return true
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    /// 用户设置的开关。关 → `stop()`（顺带把已抬起的窗口还原回原生尺寸）；
    /// 开 → 重新起轮询。
    ///
    /// 冻结期间不重新起：`enterFreeze` 已经把 workspace 观察者拆了、`isEnabled` 清了，
    /// 这时候 `start()` 只会挂一个空转定时器并装回冻结期不该有的观察者。解冻时
    /// `endPermissionUncertainty()` 自己会调 `start()`，那条路径现在也认这个标志位。
    func setEnabledBySetting(_ enabled: Bool) {
        guard isEnabledBySetting != enabled else { return }
        isEnabledBySetting = enabled
        if enabled {
            guard !isPermissionFrozen else { return }
            start()
        } else {
            stop()
        }
    }

    func start(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !isEnabled else { return }
        guard isEnabledBySetting else { return }
        guard DebugSwitch.windowLift.isEnabled(in: environment) else {
            logger.info("window lift disabled by DOCK_WINDOW_LIFT=0")
            return
        }

        isEnabled = true
        usesAnimatedLift = DebugSwitch.windowLiftAnim.isEnabled(in: environment)
        traceEnabled = DebugSwitch.windowLiftTrace.isEnabled(in: environment)
        periodicPollCount = 0
        eventPollCount = 0
        trailingEventPollCount = 0
        subscribeWorkspaceNotifications()

        let geometryObserver = FrontmostWindowGeometryObserver()
        geometryObserver.onEvent = { [weak self] _ in
            self?.requestEventPoll()
        }
        self.geometryObserver = geometryObserver
        let initialPID = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?
            .processIdentifier
        geometryObserver.start(pid: initialPID)

        updatePollTimerLifecycle()
        poll()
        if traceEnabled {
            logger.info("window lift trace started animated=\(self.usesAnimatedLift, privacy: .public)")
        }
    }

    func stop() {
        // 冻结之后 isEnabled 和 pollTimer 都已经清掉，只看这两个条件会让 stop() 空转、
        // 待还原的窗口永远回不去——所以还得看有没有欠着的还原。
        guard isEnabled || pollTimer != nil || geometryObserver != nil
            || !states.isEmpty || !pendingRestorations.isEmpty else { return }
        tracePollSummary(reason: "stop")
        isEnabled = false
        pollTimer?.invalidate()
        pollTimer = nil
        pollTimerInterval = nil
        resetEventPolling()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        stopTrackedProbe()
        geometryObserver?.stop()
        geometryObserver = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        restoreSettledWindowsAndClearSessions()
        lastContexts = []
        sessionContexts.removeAll()
    }

    func stopAndRestore() async {
        stop()
        while let task = restoreTask {
            await task.value
        }
    }

    private func subscribeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activePID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelWrites(except: activePID)
                self.geometryObserver?.activate(pid: activePID)
                self.requestEventPoll()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor [weak self] in
                guard let self, let pid else { return }
                self.removeStates(forPID: pid)
            }
        })
    }

    private func hostContexts() -> [WindowLiftAvoidanceContext] {
        host?.windowLiftAvoidanceContexts() ?? []
    }

    private func poll() {
        guard isEnabled, ensureTrustedOrFreeze() else { return }
        let contexts = hostContexts()
        reconcileContexts(contexts)
        guard !contexts.isEmpty, !scanInFlight, restoreTask == nil else { return }

        scanInFlight = true
        scanGeneration &+= 1
        let generation = scanGeneration
        nextGeneration &+= 1
        let observationGeneration = nextGeneration
        let tracked = !states.isEmpty || !suppressedFrames.isEmpty
        let selfPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let screenCGFrames = contexts.map(\.screenCGFrame)
        scanTask = Task.detached { [weak self] in
            let result = WindowLiftCGWindowProbe.capture(
                on: screenCGFrames,
                excludingPID: selfPID,
                includeLiveWindowKeys: tracked
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.handleScanResult(
                    result,
                    contexts: contexts,
                    scanGeneration: generation,
                    observationGeneration: observationGeneration
                )
            }
        }
    }

    private func updatePollTimerLifecycle() {
        guard isEnabled else {
            pollTimer?.invalidate()
            pollTimer = nil
            pollTimerInterval = nil
            return
        }

        let interval = WindowLiftAvoidance.PollCadence.interval(
            hasSessions: !states.isEmpty,
            hasSuppressedFrames: !suppressedFrames.isEmpty,
            isRestoring: restoreTask != nil
        )
        guard pollTimer == nil || pollTimerInterval != interval else { return }

        let previousInterval = pollTimerInterval
        if traceEnabled, let previous = previousInterval {
            logger.info(
                "lift trace cadence from=\(previous, privacy: .public) to=\(interval, privacy: .public)"
            )
        }
        pollTimer?.invalidate()
        resetEventPolling()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.periodicPollCount &+= 1
                self.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollTimerInterval = interval

        // The old fixed 0.2s timer always supplied one more convergence scan after a
        // transient validation/session clear. Preserve that behavior when dropping to idle.
        if previousInterval == WindowLiftAvoidance.globalDetectionInterval,
           interval == WindowLiftAvoidance.PollCadence.idleInterval {
            Task { @MainActor [weak self] in self?.requestEventPoll() }
        }
    }

    private var usesFastPollCadence: Bool {
        pollTimerInterval == WindowLiftAvoidance.globalDetectionInterval
    }

    private func requestEventPoll() {
        guard isEnabled, !usesFastPollCadence else { return }
        let action = eventPollCoalescer.request(
            at: ProcessInfo.processInfo.systemUptime,
            scanInFlight: scanInFlight
        )
        performEventPollAction(action, trailing: false)
    }

    private func finishEventPollAfterScan() {
        guard isEnabled, !usesFastPollCadence else { return }
        let action = eventPollCoalescer.scanCompleted(
            at: ProcessInfo.processInfo.systemUptime
        )
        performEventPollAction(action, trailing: true)
    }

    private func performEventPollAction(
        _ action: WindowLiftAvoidance.EventPollCoalescer.Action,
        trailing: Bool
    ) {
        switch action {
        case .none:
            break
        case .start:
            eventPollTimer?.invalidate()
            eventPollTimer = nil
            if trailing {
                trailingEventPollCount &+= 1
            } else {
                eventPollCount &+= 1
            }
            poll()
        case .schedule(let delay):
            guard eventPollTimer == nil else { return }
            let timer = Timer(timeInterval: max(0, delay), repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.eventPollTimer = nil
                    let action = self.eventPollCoalescer.cooldownFired(
                        at: ProcessInfo.processInfo.systemUptime,
                        scanInFlight: self.scanInFlight
                    )
                    self.performEventPollAction(action, trailing: true)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            eventPollTimer = timer
        }
    }

    private func resetEventPolling() {
        eventPollTimer?.invalidate()
        eventPollTimer = nil
        eventPollCoalescer.reset()
    }

    private func tracePollSummary(reason: String) {
        guard traceEnabled else { return }
        logger.info(
            "lift trace poll-summary reason=\(reason, privacy: .public) periodic=\(self.periodicPollCount, privacy: .public) event=\(self.eventPollCount, privacy: .public) trailing=\(self.trailingEventPollCount, privacy: .public)"
        )
    }

    private func updateTrackedProbeLifecycle() {
        guard isEnabled, !states.isEmpty, restoreTask == nil else {
            stopTrackedProbe()
            return
        }
        guard trackedProbeTimer == nil else { return }

        let timer = Timer(timeInterval: Self.trackedProbeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.probeTrackedFrames() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackedProbeTimer = timer
    }

    private func stopTrackedProbe() {
        trackedProbeTimer?.invalidate()
        trackedProbeTimer = nil
        trackedProbeGeneration &+= 1
        trackedProbeTask?.cancel()
        trackedProbeTask = nil
    }

    private func probeTrackedFrames() {
        guard isEnabled,
              restoreTask == nil,
              trackedProbeTask == nil,
              !lastContexts.isEmpty else {
            updateTrackedProbeLifecycle()
            return
        }
        let contexts = lastContexts
        guard hostContexts() == contexts else {
            stopTrackedProbe()
            return
        }

        sessionContexts = sessionContexts.filter { states[$0.key] != nil }
        let keys = Set(states.keys)
        guard !keys.isEmpty else {
            updateTrackedProbeLifecycle()
            return
        }

        trackedProbeGeneration &+= 1
        let generation = trackedProbeGeneration
        nextGeneration &+= 1
        let observationGeneration = nextGeneration
        trackedProbeTask = Task.detached { [weak self] in
            let frames = WindowLiftCGWindowProbe.frames(for: keys)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.handleTrackedProbeResult(
                    frames,
                    contexts: contexts,
                    probeGeneration: generation,
                    observationGeneration: observationGeneration
                )
            }
        }
    }

    private func handleTrackedProbeResult(
        _ quartzFrames: [WindowLiftAvoidance.WindowKey: CGRect],
        contexts: [WindowLiftAvoidanceContext],
        probeGeneration: UInt64,
        observationGeneration: UInt64
    ) {
        guard probeGeneration == trackedProbeGeneration else { return }
        trackedProbeTask = nil
        guard hostContexts() == contexts else {
            stopTrackedProbe()
            return
        }

        for (key, quartzFrame) in quartzFrames {
            // 会话归属的屏必须仍在集合里；不在（那块屏的条藏了 / 拔了）的由 reconcileContexts 已整体还原。
            guard let context = sessionContexts[key], contexts.contains(context) else { continue }
            _ = handleTrackedObservation(
                quartzFrame,
                for: key,
                context: context,
                observationGeneration: observationGeneration
            )
        }
        updateTrackedProbeLifecycle()
    }

    @discardableResult
    private func handleTrackedObservation(
        _ quartzFrame: CGRect,
        for key: WindowLiftAvoidance.WindowKey,
        context: WindowLiftAvoidanceContext,
        observationGeneration: UInt64
    ) -> Bool {
        guard let state = states[key], let frames = managedFrames[key] else { return false }
        guard acceptObservation(for: key, generation: observationGeneration) else { return true }

        let appKitFrame = WindowLiftAvoidance.appKitFrame(
            fromQuartz: quartzFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        let classification = WindowLiftAvoidance.frameClassification(
            of: appKitFrame,
            nativeFrame: frames.nativeAppKit,
            targetFrame: frames.targetAppKit
        )
        traceClassification(classification, for: key)

        if case let .writing(attempt) = state,
           validationGenerations[key] == attempt.generation,
           classification == .external {
            // The bounded CG/AX confirmation owns zoom-tail movement until it either stabilizes or
            // returns candidateMoved. No AX write has happened yet, so never suppress this frame.
            return true
        }

        if case .lifted = state, classification == .native {
            guard NSRunningApplication(processIdentifier: key.pid)?.isActive == true,
                  hostContexts().contains(context) else {
                return true
            }
        }

        let transition = WindowLiftAvoidance.reduce(
            state: state,
            event: .nonMaximizedObserved(
                generation: observationGeneration,
                at: ProcessInfo.processInfo.systemUptime,
                frame: appKitFrame
            )
        )
        let candidate = WindowLiftCGCandidate(
            key: key,
            quartzFrame: WindowLiftAvoidance.quartzFrame(
                fromAppKit: appKitFrame,
                primaryScreenHeight: context.primaryScreenHeight
            )
        )
        apply(
            transition,
            for: candidate,
            context: context,
            operationGeneration: observationGeneration
        )
        return true
    }

    /// 上下文**集合**一变（某块屏的条显隐 / 换档 / 拔插屏）→ 还原全部已抬窗口、下一轮重扫（≤0.2s 重抬）。
    /// 这是单屏时代「换屏即还原」行为的推广；按屏做增量还原留待有人报「另一块屏的窗口跟着跳」时再做。
    private func reconcileContexts(_ contexts: [WindowLiftAvoidanceContext]) {
        guard canMutateSessions() else { return }
        guard contexts != lastContexts else { return }
        observationWatermarks.removeAll()
        suppressedFrames.removeAll()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        updatePollTimerLifecycle()

        if !lastContexts.isEmpty {
            restoreSettledWindowsAndClearSessions()
        }
        lastContexts = contexts
    }

    private func handleScanResult(
        _ result: WindowLiftCGScanResult,
        contexts: [WindowLiftAvoidanceContext],
        scanGeneration: UInt64,
        observationGeneration: UInt64
    ) {
        guard scanGeneration == self.scanGeneration else { return }
        scanTask = nil
        scanInFlight = false
        defer { finishEventPollAfterScan() }
        // 已经排队的扫描回调也要过闸门：光给几个清理函数加 guard 挡不住在飞的工作。
        guard canMutateSessions() else { return }
        guard hostContexts() == contexts else { return }

        if let liveWindowKeys = result.liveWindowKeys {
            pruneDeadWindowStates(
                liveWindowKeys: liveWindowKeys,
                observationGeneration: observationGeneration
            )
        }
        let reconciledKeys = reconcileTrackedFrames(
            result.onScreenFrames,
            contexts: contexts,
            observationGeneration: observationGeneration
        )

        // 每块屏各自的候选；跨屏窗口只归面积主体所在的那块屏。只有前台 app 的窗口会抬，
        // 所以按屏序取第一个能过全部闸的候选即可。
        let screenCGFrames = contexts.map(\.screenCGFrame)
        for (index, context) in contexts.enumerated() {
            guard let candidate = result.candidatesByScreenIndex[index],
                  WindowLiftAvoidance.owningContextIndex(for: candidate.quartzFrame, screenCGFrames: screenCGFrames) == index,
                  !reconciledKeys.contains(candidate.key) else { continue }
            if handleScanCandidate(
                candidate,
                context: context,
                observationGeneration: observationGeneration
            ) {
                return
            }
        }
    }

    /// 返回 true = 这个候选已被处理（抬起或已在会话里），后面的屏不用再看。
    private func handleScanCandidate(
        _ candidate: WindowLiftCGCandidate,
        context: WindowLiftAvoidanceContext,
        observationGeneration: UInt64
    ) -> Bool {
        guard acceptObservation(
            for: candidate.key,
            generation: observationGeneration
        ) else {
            return false
        }
        let appKitFrame = WindowLiftAvoidance.appKitFrame(
            fromQuartz: candidate.quartzFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        if let suppressed = suppressedFrames[candidate.key] {
            let classification = WindowLiftAvoidance.frameClassification(
                of: appKitFrame,
                nativeFrame: suppressed.nativeAppKit,
                targetFrame: suppressed.targetAppKit
            )
            traceClassification(classification, for: candidate.key)
            guard classification == .native else { return false }
            suppressedFrames.removeValue(forKey: candidate.key)
            updatePollTimerLifecycle()
            if traceEnabled {
                logger.info(
                    "lift trace suppression cleared pid=\(candidate.key.pid, privacy: .public) wid=\(candidate.key.cgWindowID, privacy: .public)"
                )
            }
        }
        guard context.geometry.fillsVisibleFrame(appKitFrame),
              let targetFrame = context.geometry.adjustedFrame(for: appKitFrame),
              let app = NSRunningApplication(processIdentifier: candidate.key.pid),
              app.isActive,
              !app.isTerminated,
              app.activationPolicy == .regular || app.activationPolicy == .accessory else {
            return false
        }

        let operationGeneration = observationGeneration
        let transition = WindowLiftAvoidance.reduce(
            state: states[candidate.key] ?? .idle,
            event: .maximizedDetected(
                generation: operationGeneration,
                at: ProcessInfo.processInfo.systemUptime,
                nativeFrame: appKitFrame,
                targetFrame: targetFrame
            )
        )
        apply(
            transition,
            for: candidate,
            context: context,
            operationGeneration: operationGeneration
        )
        return true
    }

    private func reconcileTrackedFrames(
        _ quartzFrames: [WindowLiftAvoidance.WindowKey: CGRect],
        contexts: [WindowLiftAvoidanceContext],
        observationGeneration: UInt64
    ) -> Set<WindowLiftAvoidance.WindowKey> {
        var reconciled: Set<WindowLiftAvoidance.WindowKey> = []
        for key in Array(states.keys) {
            guard let quartzFrame = quartzFrames[key],
                  let context = sessionContexts[key], contexts.contains(context) else { continue }
            if handleTrackedObservation(
                quartzFrame,
                for: key,
                context: context,
                observationGeneration: observationGeneration
            ) {
                reconciled.insert(key)
            }
        }
        return reconciled
    }

    private func acceptObservation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64
    ) -> Bool {
        guard generation > (observationWatermarks[key] ?? 0) else { return false }
        observationWatermarks[key] = generation
        return true
    }

    private func apply(
        _ transition: WindowLiftAvoidance.Transition,
        for candidate: WindowLiftCGCandidate,
        context: WindowLiftAvoidanceContext,
        operationGeneration: UInt64
    ) {
        sessionContexts[candidate.key] = context
        if transition.action == .clear {
            clearManagedSession(
                for: candidate.key,
                cancelWriter: true,
                reason: "reducerClear",
                suppressUntilNative: true
            )
            return
        }
        store(transition.state, for: candidate.key)
        switch transition.action {
        case .none:
            break
        case .clear:
            break
        case let .abandon(reason):
            logger.error(
                "lift abandoned pid=\(candidate.key.pid, privacy: .public) wid=\(candidate.key.cgWindowID, privacy: .public) reason=\(String(describing: reason), privacy: .public)"
            )
        case let .write(targetFrame, rollbackFrame, generation, isRelift):
            guard generation == operationGeneration else { return }
            beginWrite(
                candidate: candidate,
                nativeFrame: rollbackFrame,
                targetFrame: targetFrame,
                context: context,
                generation: generation,
                isRelift: isRelift
            )
        }
    }

    private func beginWrite(
        candidate: WindowLiftCGCandidate,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        context: WindowLiftAvoidanceContext,
        generation: UInt64,
        isRelift: Bool
    ) {
        let key = candidate.key
        guard case let .writing(attempt) = states[key],
              attempt.generation == generation else {
            return
        }
        let nativeQuartz = WindowLiftAvoidance.quartzFrame(
            fromAppKit: nativeFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        let targetQuartz = WindowLiftAvoidance.quartzFrame(
            fromAppKit: targetFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        managedFrames[key] = ManagedFrames(
            nativeAppKit: nativeFrame,
            targetAppKit: targetFrame,
            nativeQuartz: nativeQuartz,
            targetQuartz: targetQuartz,
            primaryScreenHeight: context.primaryScreenHeight
        )
        validationGenerations[key] = generation

        let animate = usesAnimatedLift
        let reader = AXWindowReader()
        var drains = writeDrainTasks.removeValue(forKey: key) ?? []
        if let previousWriter = writeTasks.removeValue(forKey: key) {
            previousWriter.cancel()
            drains.append(previousWriter)
        }
        let task = Task.detached { [weak self] in
            for drain in drains {
                await drain.value
            }
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let mayBegin = await MainActor.run { [weak self] in
                self?.canContinueOperation(
                    for: key,
                    generation: generation,
                    context: context
                ) ?? false
            }
            guard mayBegin, !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let detectedAt = ProcessInfo.processInfo.systemUptime
            let validation = await Self.validatedHandle(
                reader: reader,
                candidate: candidate,
                detectedAt: detectedAt
            )
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let handle: AXWindowHandle
            switch validation {
            case let .ready(validatedHandle):
                handle = validatedHandle
            case let .transient(stage):
                await MainActor.run { [weak self] in
                    self?.finishOperation(
                        for: key,
                        generation: generation,
                        outcome: .transientValidation(stage)
                    )
                }
                return
            case let .unsupported(stage):
                await MainActor.run { [weak self] in
                    self?.finishOperation(
                        for: key,
                        generation: generation,
                        outcome: .unsupportedValidation(stage)
                    )
                }
                return
            }

            let mayContinue = await MainActor.run { [weak self] in
                self?.canBeginAXWrite(
                    for: key,
                    generation: generation,
                    context: context
                ) ?? false
            }
            guard mayContinue, !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let outcome = await Self.write(
                reader: reader,
                element: handle.element,
                nativeFrame: nativeQuartz,
                targetFrame: targetQuartz,
                animated: animate,
                initialReliftCount: attempt.reliftCount,
                primaryScreenHeight: context.primaryScreenHeight
            )
            await MainActor.run { [weak self] in
                self?.finishOperation(for: key, generation: generation, outcome: outcome)
            }
        }
        writeTasks[key] = task
        if isRelift {
            logger.notice(
                "lift relift begin pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) count=\(attempt.reliftCount, privacy: .public)"
            )
        } else if traceEnabled {
            logger.info(
                "lift trace begin pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) generation=\(generation, privacy: .public) animated=\(animate, privacy: .public)"
            )
        }
        updateTrackedProbeLifecycle()
    }

    nonisolated private static func validatedHandle(
        reader: AXWindowReader,
        candidate: WindowLiftCGCandidate,
        detectedAt: TimeInterval
    ) async -> ValidationOutcome {
        let schedule = WindowLiftAvoidance.PollSchedule.standard
        var lastTransientStage: ValidationStage = .handleUnavailable

        for index in schedule.deadlines.indices {
            guard !Task.isCancelled else { return .transient(lastTransientStage) }
            let elapsed = ProcessInfo.processInfo.systemUptime - detectedAt
            if let delay = schedule.remainingDelay(for: index, elapsed: elapsed), delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return .transient(lastTransientStage) }
            guard let confirmedCGFrame = WindowLiftCGWindowProbe.frame(for: candidate.key) else {
                lastTransientStage = .candidateMoved
                continue
            }
            guard let handle = reader.captureHandle(
                forPID: candidate.key.pid,
                cgWindowID: candidate.key.cgWindowID,
                messagingTimeout: windowLiftAXMessagingTimeout
            ) else {
                lastTransientStage = .handleUnavailable
                continue
            }

            let element = handle.element
            guard let role = reader.stringAttribute(
                kAXRoleAttribute as CFString,
                from: element,
                maxAttempts: 1
            ) else {
                lastTransientStage = .roleUnavailable
                continue
            }
            guard role == (kAXWindowRole as String) else { return .unsupported(.unsupportedRole) }
            if reader.boolAttribute("AXFullScreen" as CFString, from: element, maxAttempts: 1) == true {
                guard index == schedule.deadlines.index(before: schedule.deadlines.endIndex) else {
                    lastTransientStage = .fullscreen
                    continue
                }
                return .unsupported(.fullscreen)
            }
            if reader.boolAttribute(
                kAXMinimizedAttribute as CFString,
                from: element,
                maxAttempts: 1
            ) == true {
                guard index == schedule.deadlines.index(before: schedule.deadlines.endIndex) else {
                    lastTransientStage = .minimized
                    continue
                }
                return .unsupported(.minimized)
            }
            guard let confirmedAXFrame = reader.frame(
                of: element,
                messagingTimeout: windowLiftAXMessagingTimeout
            ) else {
                lastTransientStage = .frameUnavailable
                continue
            }

            switch reader.frameSettableStatus(
                of: element,
                messagingTimeout: windowLiftAXMessagingTimeout
            ).size {
            case .settable:
                break
            case .notSettable:
                return .unsupported(.sizeNotSettable)
            case .unread:
                lastTransientStage = .capabilityUnavailable
                continue
            }

            guard WindowLiftAvoidance.samplesAreStable(
                initialCGFrame: candidate.quartzFrame,
                confirmedCGFrame: confirmedCGFrame,
                confirmedAXFrame: confirmedAXFrame
            ) else {
                lastTransientStage = WindowLiftAvoidance.samplesAreStable(
                    confirmedCGFrame,
                    comparedTo: candidate.quartzFrame
                ) ? .frameMismatch : .candidateMoved
                continue
            }

            // The zero-deadline pass only captures the first synchronized sample. A write may
            // start once a later (≥100ms) confirmation fully agrees with the detected frame.
            // 早期采样的抖动不再一票否决整轮（旧行为逼出整整一个 0.2s 重扫周期）：
            // 写循环的停滞/轨迹判定已能安全吸收残余移动。
            guard index > schedule.deadlines.startIndex else {
                lastTransientStage = .frameMismatch
                continue
            }
            return .ready(handle)
        }
        return .transient(lastTransientStage)
    }

    nonisolated private static func write(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        animated: Bool,
        initialReliftCount: Int,
        primaryScreenHeight: CGFloat
    ) async -> OperationOutcome {
        if !animated {
            let result = reader.setSize(
                targetFrame.size,
                for: element,
                messagingTimeout: windowLiftAXMessagingTimeout,
                verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                onlyIfCurrentMatches: nativeFrame,
                restoreOnFailureTo: nil
            )
            if Task.isCancelled {
                if case let .success(actualFrame) = result {
                    rollbackCancelledWrite(
                        reader: reader,
                        element: element,
                        nativeFrame: nativeFrame,
                        attemptedFrame: actualFrame
                    )
                }
                return .cancelled
            }
            switch result {
            case let .success(actualFrame):
                return completedOrRolledBack(
                    reader: reader,
                    element: element,
                    actualFrame: actualFrame,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: initialReliftCount,
                    anomalies: [],
                    primaryScreenHeight: primaryScreenHeight
                )

            case let .failure(reason, rollback):
                let decision = animationFailureDecision(
                    for: reason,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: initialReliftCount,
                    lastAcknowledgedFrame: nativeFrame,
                    primaryScreenHeight: primaryScreenHeight
                )
                let anomaly = WriteAnomaly(
                    reason: reason,
                    rollback: rollback,
                    decision: decision,
                    progress: 1
                )
                switch decision {
                case let .complete(actualFrame):
                    return completedOrRolledBack(
                        reader: reader,
                        element: element,
                        actualFrame: actualFrame,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: initialReliftCount,
                        anomalies: [anomaly],
                        primaryScreenHeight: primaryScreenHeight
                    )
                case let .continueFromActual(actualFrame):
                    // 停滞：写入可能尚未被窗口应用（1x 屏迟到应用）。等一拍再确认一次，
                    // 仍未到位才清会话交还给下一轮扫描。
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if !Task.isCancelled,
                       let settledFrame = reader.frame(
                           of: element,
                           messagingTimeout: windowLiftAXMessagingTimeout
                       ),
                       WindowLiftAvoidance.framesMatch(settledFrame, targetFrame) {
                        return .completed(settledFrame, reliftCount: initialReliftCount, anomalies: [anomaly])
                    }
                    return .externalFrame(actualFrame, anomalies: [anomaly])
                case let .clearSession(frame),
                     let .restartFromNative(frame, _):
                    // Instant mode owns exactly one AX write. A mismatch that did not mutate the
                    // window clears this attempt and lets the next CG observation start cleanly.
                    return .externalFrame(frame, anomalies: [anomaly])
                case let .reliftLimitReached(frame, count):
                    return .reliftLimitReached(
                        frame,
                        reliftCount: count,
                        anomalies: [anomaly]
                    )
                case .abandonWriteFailed:
                    return .failed(
                        reason: reason,
                        rollback: rollback,
                        progress: 1,
                        reliftCount: initialReliftCount,
                        anomalies: [anomaly]
                    )
                }
            }
        }

        let frameInterval = 1.0 / WindowLiftAvoidance.animationFramesPerSecond
        var segmentStartFrame = nativeFrame
        var segmentProgressStart = 0.0
        let animationStartedAt = ProcessInfo.processInfo.systemUptime
        var nextDeadline = animationStartedAt + frameInterval
        var expectedFrame = nativeFrame
        var reliftCount = initialReliftCount
        var anomalies: [WriteAnomaly] = []
        // 最终帧允许有限次停滞重试：慢应用屏上写入生效晚于回读。
        var finalStallRetries = 0
        let maxFinalStallRetries = 3

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            let animationElapsed = now - animationStartedAt
            if animationElapsed >= WindowLiftAvoidance.animationDuration {
                let result = reader.setSize(
                    targetFrame.size,
                    for: element,
                    messagingTimeout: windowLiftAXMessagingTimeout,
                    verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                    onlyIfCurrentMatches: expectedFrame,
                    restoreOnFailureTo: nil
                )
                if Task.isCancelled {
                    if case let .success(actualFrame) = result {
                        rollbackCancelledWrite(
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            attemptedFrame: actualFrame
                        )
                    }
                    return .cancelled
                }
                switch result {
                case let .success(actualFrame):
                    return completedOrRolledBack(
                        reader: reader,
                        element: element,
                        actualFrame: actualFrame,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: reliftCount,
                        anomalies: anomalies,
                        primaryScreenHeight: primaryScreenHeight
                    )

                case let .failure(reason, rollback):
                    let decision = animationFailureDecision(
                        for: reason,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: reliftCount,
                        lastAcknowledgedFrame: expectedFrame,
                        primaryScreenHeight: primaryScreenHeight
                    )
                    switch decision {
                    case let .complete(actualFrame):
                        return completedOrRolledBack(
                            reader: reader,
                            element: element,
                            actualFrame: actualFrame,
                            nativeFrame: nativeFrame,
                            targetFrame: targetFrame,
                            reliftCount: reliftCount,
                            anomalies: anomalies,
                            primaryScreenHeight: primaryScreenHeight
                        )
                    case let .continueFromActual(actualFrame):
                        // 最终帧停滞/轨迹内：等一拍重写，有限次后才判失败。
                        if finalStallRetries < maxFinalStallRetries {
                            finalStallRetries += 1
                            expectedFrame = actualFrame
                            try? await Task.sleep(
                                nanoseconds: UInt64(frameInterval * 1_000_000_000)
                            )
                            continue
                        }
                        let anomaly = WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        )
                        recordBounded(anomaly, in: &anomalies)
                        let finalRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: actualFrame
                        )
                        return .failed(
                            reason: reason,
                            rollback: finalRollback,
                            progress: 1,
                            reliftCount: reliftCount,
                            anomalies: anomalies
                        )
                    case let .clearSession(frame):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        return .externalFrame(frame, anomalies: anomalies)
                    case let .restartFromNative(frame, nextReliftCount):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        let safeRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: frame
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: 1,
                            reliftCount: nextReliftCount,
                            anomalies: anomalies
                        )
                    case let .reliftLimitReached(frame, count):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        return .reliftLimitReached(frame, reliftCount: count, anomalies: anomalies)
                    case .abandonWriteFailed:
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        let safeRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: expectedFrame
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: 1,
                            reliftCount: reliftCount,
                            anomalies: anomalies
                        )
                    }
                }
            }

            let sleepDuration = max(0, nextDeadline - now)
            if sleepDuration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
            }
            guard !Task.isCancelled else {
                rollbackCancelledWrite(
                    reader: reader,
                    element: element,
                    nativeFrame: nativeFrame,
                    attemptedFrame: expectedFrame
                )
                return .cancelled
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - animationStartedAt
            guard elapsed < WindowLiftAvoidance.animationDuration else { continue }
            let overallProgress = max(0, elapsed / WindowLiftAvoidance.animationDuration)
            let progress = WindowLiftAvoidance.rebasedAnimationProgress(
                overallProgress,
                startingAt: segmentProgressStart
            )
            let attemptedFrame = monotonicAttemptedFrame(
                scheduled: WindowLiftAvoidance.interpolatedFrame(
                    from: segmentStartFrame,
                    to: targetFrame,
                    progress: progress
                ),
                current: expectedFrame,
                target: targetFrame
            )
            // 尺寸取整：1x 屏只能表示整数点，小数请求会被取整/忽略，撞上 2pt 验证容差。
            let attemptedSize = CGSize(
                width: attemptedFrame.width.rounded(),
                height: attemptedFrame.height.rounded()
            )
            let result = reader.setSize(
                attemptedSize,
                for: element,
                messagingTimeout: windowLiftAXMessagingTimeout,
                verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                onlyIfCurrentMatches: expectedFrame,
                restoreOnFailureTo: nil
            )
            if Task.isCancelled {
                if case let .success(actualFrame) = result {
                    rollbackCancelledWrite(
                        reader: reader,
                        element: element,
                        nativeFrame: nativeFrame,
                        attemptedFrame: actualFrame
                    )
                }
                return .cancelled
            }
            switch result {
            case let .success(actualFrame):
                expectedFrame = actualFrame
                guard !Task.isCancelled else {
                    rollbackCancelledWrite(
                        reader: reader,
                        element: element,
                        nativeFrame: nativeFrame,
                        attemptedFrame: actualFrame
                    )
                    return .cancelled
                }
            case let .failure(reason, rollback):
                let decision = animationFailureDecision(
                    for: reason,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: reliftCount,
                    lastAcknowledgedFrame: expectedFrame,
                    primaryScreenHeight: primaryScreenHeight
                )
                if case let .continueFromActual(actualFrame) = decision {
                    // 停滞或轨迹内自愈：不算异常，进度表下一帧自然补上步长。
                    expectedFrame = actualFrame
                } else {
                    let anomaly = WriteAnomaly(
                        reason: reason,
                        rollback: rollback,
                        decision: decision,
                        progress: overallProgress
                    )
                    recordBounded(anomaly, in: &anomalies)
                    switch decision {
                    case let .complete(actualFrame):
                        return completedOrRolledBack(
                            reader: reader,
                            element: element,
                            actualFrame: actualFrame,
                            nativeFrame: nativeFrame,
                            targetFrame: targetFrame,
                            reliftCount: reliftCount,
                            anomalies: anomalies,
                            primaryScreenHeight: primaryScreenHeight
                        )
                    case .continueFromActual:
                        break
                    case let .clearSession(frame):
                        return .externalFrame(frame, anomalies: anomalies)
                    case let .restartFromNative(frame, nextReliftCount):
                        segmentStartFrame = frame
                        expectedFrame = frame
                        reliftCount = nextReliftCount
                        segmentProgressStart = overallProgress
                        continue
                    case let .reliftLimitReached(frame, count):
                        return .reliftLimitReached(frame, reliftCount: count, anomalies: anomalies)
                    case .abandonWriteFailed:
                        let safeRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: expectedFrame
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: overallProgress,
                            reliftCount: reliftCount,
                            anomalies: anomalies
                        )
                    }
                }
            }

            let elapsedAfterWrite = max(
                0,
                ProcessInfo.processInfo.systemUptime - animationStartedAt
            )
            let completedSlots = floor(elapsedAfterWrite / frameInterval)
            nextDeadline = animationStartedAt + (completedSlots + 1) * frameInterval
        }
    }

    nonisolated private static func completedOrRolledBack(
        reader: AXWindowReader,
        element: AXUIElement,
        actualFrame: CGRect,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        anomalies: [WriteAnomaly],
        primaryScreenHeight: CGFloat
    ) -> OperationOutcome {
        let actualAppKit = WindowLiftAvoidance.appKitFrame(
            fromQuartz: actualFrame,
            primaryScreenHeight: primaryScreenHeight
        )
        let targetAppKit = WindowLiftAvoidance.appKitFrame(
            fromQuartz: targetFrame,
            primaryScreenHeight: primaryScreenHeight
        )
        guard !WindowLiftAvoidance.framesMatch(
            actualAppKit,
            targetAppKit,
            tolerance: WindowLiftAvoidance.verificationTolerance
        ) else {
            return .completed(actualFrame, reliftCount: reliftCount, anomalies: anomalies)
        }

        let reason = AXWindowFrameWriteFailure.verificationMismatch(
            expected: targetFrame,
            actual: actualFrame
        )
        let rollback = rollbackManagedFrame(
            reader: reader,
            element: element,
            nativeFrame: nativeFrame,
            currentFrame: actualFrame
        )
        var finalAnomalies = anomalies
        recordBounded(
            WriteAnomaly(
                reason: reason,
                rollback: rollback,
                decision: .abandonWriteFailed,
                progress: 1
            ),
            in: &finalAnomalies
        )
        return .failed(
            reason: reason,
            rollback: rollback,
            progress: 1,
            reliftCount: reliftCount,
            anomalies: finalAnomalies
        )
    }

    nonisolated private static func animationFailureDecision(
        for reason: AXWindowFrameWriteFailure,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        lastAcknowledgedFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> WindowLiftAvoidance.AnimationWriteFailureDecision {
        let failure: WindowLiftAvoidance.AnimationWriteFailure
        switch reason {
        // verificationMismatch 同样携带真实 actual：慢应用屏（1x 外接屏）上写后立刻回读
        // 常拿到旧值，按 terminal 处理会在第一帧 ~2pt 缓动步长上必然放弃。
        case let .initialFrameMismatch(_, actualFrame),
             let .verificationMismatch(_, actualFrame):
            failure = .initialFrameMismatch(actualFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: actualFrame,
                primaryScreenHeight: primaryScreenHeight
            ))
        default:
            failure = .terminalWriteFailure
        }
        let appKitDecision = WindowLiftAvoidance.animationWriteFailureDecision(
            failure,
            nativeFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: nativeFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            targetFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: targetFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            reliftCount: reliftCount,
            lastAcknowledgedFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: lastAcknowledgedFrame,
                primaryScreenHeight: primaryScreenHeight
            )
        )
        func quartz(_ frame: CGRect) -> CGRect {
            WindowLiftAvoidance.quartzFrame(
                fromAppKit: frame,
                primaryScreenHeight: primaryScreenHeight
            )
        }
        switch appKitDecision {
        case let .complete(frame):
            return .complete(actualFrame: quartz(frame))
        case let .continueFromActual(frame):
            return .continueFromActual(actualFrame: quartz(frame))
        case let .clearSession(frame):
            return .clearSession(preservingFrame: quartz(frame))
        case let .restartFromNative(frame, nextReliftCount):
            return .restartFromNative(
                nativeFrame: quartz(frame),
                nextReliftCount: nextReliftCount
            )
        case let .reliftLimitReached(frame, count):
            return .reliftLimitReached(
                actualFrame: quartz(frame),
                reliftCount: count
            )
        case .abandonWriteFailed:
            return .abandonWriteFailed
        }
    }

    nonisolated private static func recordBounded(
        _ anomaly: WriteAnomaly,
        in anomalies: inout [WriteAnomaly]
    ) {
        if anomalies.count < 4 {
            anomalies.append(anomaly)
        } else {
            // Keep the beginning of the episode and always preserve the newest decision/result.
            anomalies[anomalies.count - 1] = anomaly
        }
    }

    /// A recovered trajectory mismatch may already be ahead of the elapsed-time sample. Do not
    /// grow the window back toward the native frame while the schedule catches up.
    nonisolated private static func monotonicAttemptedFrame(
        scheduled: CGRect,
        current: CGRect,
        target: CGRect
    ) -> CGRect {
        func component(_ scheduled: CGFloat, _ current: CGFloat, _ target: CGFloat) -> CGFloat {
            if target < current { return max(target, min(scheduled, current)) }
            if target > current { return min(target, max(scheduled, current)) }
            return target
        }
        return CGRect(
            origin: scheduled.origin,
            size: CGSize(
                width: component(scheduled.width, current.width, target.width),
                height: component(scheduled.height, current.height, target.height)
            )
        )
    }

    nonisolated private static func rollbackManagedFrame(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        currentFrame: CGRect
    ) -> AXWindowFrameRollbackResult {
        switch reader.setFrame(
            nativeFrame,
            for: element,
            messagingTimeout: windowLiftAXMessagingTimeout,
            verificationTolerance: WindowLiftAvoidance.verificationTolerance,
            onlyIfCurrentMatches: currentFrame,
            restoreOnFailureTo: currentFrame
        ) {
        case let .success(actualFrame):
            return .restored(actualFrame: actualFrame)
        case let .failure(reason, _):
            return .failed(
                reason: reason,
                actualFrame: reader.frame(
                    of: element,
                    messagingTimeout: windowLiftAXMessagingTimeout
                )
            )
        }
    }

    nonisolated private static func rollbackAfterAnimationFailure(
        _ rollback: AXWindowFrameRollbackResult,
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        currentManagedFrame: CGRect
    ) -> AXWindowFrameRollbackResult {
        guard rollback == .notRequested,
              !WindowLiftAvoidance.framesMatch(currentManagedFrame, nativeFrame) else {
            return rollback
        }
        return rollbackManagedFrame(
            reader: reader,
            element: element,
            nativeFrame: nativeFrame,
            currentFrame: currentManagedFrame
        )
    }

    nonisolated private static func rollbackCancelledWrite(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        attemptedFrame: CGRect
    ) {
        let currentFrame = reader.frame(of: element, messagingTimeout: windowLiftAXMessagingTimeout)
        guard case let .restore(frame) = WindowLiftAvoidance.rollbackDecision(
            originalFrame: nativeFrame,
            attemptedFrame: attemptedFrame,
            currentFrame: currentFrame
        ) else {
            return
        }
        _ = reader.setFrame(
            frame,
            for: element,
            messagingTimeout: windowLiftAXMessagingTimeout,
            verificationTolerance: WindowLiftAvoidance.verificationTolerance,
            onlyIfCurrentMatches: attemptedFrame
        )
    }

    private func canContinueOperation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        context: WindowLiftAvoidanceContext
    ) -> Bool {
        guard hostContexts().contains(context),
              NSRunningApplication(processIdentifier: key.pid)?.isActive == true,
              case let .writing(attempt) = states[key],
              attempt.generation == generation else {
            return false
        }
        return true
    }

    private func canBeginAXWrite(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        context: WindowLiftAvoidanceContext
    ) -> Bool {
        guard validationGenerations[key] == generation else { return false }
        validationGenerations.removeValue(forKey: key)
        return canContinueOperation(for: key, generation: generation, context: context)
    }

    private func finishOperation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        outcome: OperationOutcome
    ) {
        guard canMutateSessions() else {
            // 取消写任务会走到这里。冻结期间不许它顺手把会话清掉——
            // `.cancelled` / `.transientValidation` 分支都通向 clearManagedSession。
            if let writer = writeTasks.removeValue(forKey: key) { pendingDrains.append(writer) }
            return
        }
        guard case let .writing(attempt) = states[key], attempt.generation == generation else {
            return
        }
        if validationGenerations[key] == generation {
            validationGenerations.removeValue(forKey: key)
        }
        writeTasks.removeValue(forKey: key)
        let finishedAt = ProcessInfo.processInfo.systemUptime

        switch outcome {
        case .cancelled:
            clearManagedSession(for: key, cancelWriter: false, reason: "cancelled")

        case let .transientValidation(stage):
            logger.notice(
                "lift validation transient pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) stage=\(stage.rawValue, privacy: .public)"
            )
            // Validation has not written the window yet. A moving zoom candidate must return to
            // idle so the next global sample can establish a fresh native frame.
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: stage.rawValue
            )

        case let .unsupportedValidation(stage):
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFailed(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: attempt.reliftCount
                )
            )
            store(transition.state, for: key)
            logger.error(
                "lift validation unsupported pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) stage=\(stage.rawValue, privacy: .public)"
            )

        case let .externalFrame(actualQuartzFrame, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: false)
            if let frames = managedFrames[key] {
                let actualAppKit = WindowLiftAvoidance.appKitFrame(
                    fromQuartz: actualQuartzFrame,
                    primaryScreenHeight: frames.primaryScreenHeight
                )
                traceClassification(
                    WindowLiftAvoidance.frameClassification(
                        of: actualAppKit,
                        nativeFrame: frames.nativeAppKit,
                        targetFrame: frames.targetAppKit
                    ),
                    for: key
                )
                if traceEnabled {
                    logger.info(
                        "lift trace preserve external pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) frame=\(String(describing: actualAppKit), privacy: .public)"
                    )
                }
            }
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: "externalFrame",
                suppressUntilNative: true
            )

        case let .reliftLimitReached(_, reliftCount, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: true)
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .reliftLimitReached(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)
            logger.error(
                "lift abandoned pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) reason=reliftLimitReached count=\(reliftCount, privacy: .public)"
            )

        case let .failed(reason, rollback, progress, reliftCount, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: true)
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFailed(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)
            logger.error(
                "lift write failed pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) progress=\(progress, format: .fixed(precision: 3), privacy: .public) reason=\(String(describing: reason), privacy: .public) rollback=\(String(describing: rollback), privacy: .public)"
            )

        case let .completed(actualQuartzFrame, reliftCount, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: false)
            guard let frames = managedFrames[key] else { return }
            let actualAppKit = WindowLiftAvoidance.appKitFrame(
                fromQuartz: actualQuartzFrame,
                primaryScreenHeight: frames.primaryScreenHeight
            )
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFinished(
                    generation: generation,
                    at: finishedAt,
                    actualFrame: actualAppKit,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)
            if reliftCount > attempt.reliftCount {
                logger.notice(
                    "lift relift completed pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) count=\(reliftCount, privacy: .public)"
                )
            }
            if !WindowLiftAvoidance.framesMatch(actualAppKit, frames.targetAppKit) {
                logger.error(
                    "lift verification mismatch pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public)"
                )
            }
        }
        updateTrackedProbeLifecycle()
    }

    private func logWriteAnomalies(
        _ anomalies: [WriteAnomaly],
        for key: WindowLiftAvoidance.WindowKey,
        terminal: Bool
    ) {
        for anomaly in anomalies.prefix(4) {
            let progress = String(format: "%.3f", anomaly.progress)
            let message = "lift animation anomaly pid=\(key.pid) wid=\(key.cgWindowID) progress=\(progress) reason=\(String(describing: anomaly.reason)) decision=\(String(describing: anomaly.decision)) rollback=\(String(describing: anomaly.rollback))"
            if terminal {
                logger.error("\(message, privacy: .public)")
            } else {
                logger.notice("\(message, privacy: .public)")
            }
        }
    }

    private func cancelWrites(except activePID: pid_t?) {
        for (key, task) in writeTasks where key.pid != activePID {
            task.cancel()
        }
    }

    private func removeStates(forPID pid: pid_t) {
        let keys = Set(states.keys).union(suppressedFrames.keys).filter { $0.pid == pid }
        for key in keys {
            clearManagedSession(for: key, cancelWriter: true, reason: "applicationTerminated")
        }
    }

    private func pruneDeadWindowStates(
        liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>,
        observationGeneration: UInt64
    ) {
        let deadKeys = WindowLiftAvoidance.prunableDeadWindowKeys(
            tracked: Set(states.keys).union(suppressedFrames.keys),
            live: liveWindowKeys,
            observationGeneration: observationGeneration,
            observationWatermarks: observationWatermarks
        )
        for key in deadKeys {
            observationWatermarks[key] = observationGeneration
            clearManagedSession(for: key, cancelWriter: true, reason: "deadWindowPrune")
        }
    }

    private func restoreSettledWindowsAndClearSessions() {
        guard canMutateSessions() else { return }

        let cancelledWrites = Array(writeTasks.values) + writeDrainTasks.values.flatMap { $0 }
        for task in cancelledWrites { task.cancel() }
        writeTasks.removeAll()
        writeDrainTasks.removeAll()

        // 待还原数据入列即归控制器所有，还原成功一项才移除——这样中途失权时
        // 冻结机制接管得到这批数据，恢复授权后还能接着还。
        for (key, state) in states {
            guard let frames = managedFrames[key] else { continue }
            switch state {
            case .writing, .lifted, .abandoned:
                pendingRestorations[key] = frames
                pendingRestorationStartTimes[key] = ProcessLiveness.startTime(pid: key.pid)
            case .idle:
                break
            }
        }

        states.removeAll()
        sessionContexts.removeAll()
        managedFrames.removeAll()
        suppressedFrames.removeAll()
        observationWatermarks.removeAll()
        validationGenerations.removeAll()
        lastTraceClassifications.removeAll()
        stopTrackedProbe()
        guard !pendingRestorations.isEmpty || !cancelledWrites.isEmpty, restoreTask == nil else {
            updatePollTimerLifecycle()
            return
        }

        restoreGeneration &+= 1
        let generation = restoreGeneration
        let items = pendingRestorations
        let startTimes = pendingRestorationStartTimes
        restoreTask = Task.detached { [weak self] in
            // A cancelled AX call cannot be interrupted mid-message. Drain every old writer before
            // allowing the next context to scan, so a late rollback cannot overwrite a new lift.
            for task in cancelledWrites {
                await task.value
            }

            let reader = AXWindowReader()
            let liveWindowKeys = WindowLiftCGWindowProbe.liveWindowKeys()
            for (key, frames) in items {
                guard !Task.isCancelled else { break }
                let outcome = Self.restoreOne(
                    key: key,
                    frames: frames,
                    expectedStartTime: startTimes[key],
                    reader: reader,
                    liveWindowKeys: liveWindowKeys
                )
                guard outcome == .handled else { continue }
                await MainActor.run { [weak self] in
                    self?.pendingRestorations.removeValue(forKey: key)
                    self?.pendingRestorationStartTimes.removeValue(forKey: key)
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.restoreGeneration == generation else { return }
                self.restoreTask = nil
                self.updatePollTimerLifecycle()
                if self.isEnabled { self.poll() }
            }
        }
        updatePollTimerLifecycle()
    }

    /// 长时间冻结之后才还原，中间什么都可能变过，所以每一项都要重新验一遍：
    /// 进程有没有被换掉（pid 复用）、窗口还在不在（cgWindowID 复用）、
    /// 用户有没有自己动过。任何一条对不上就丢弃，绝不硬改。
    nonisolated private static func restoreOne(
        key: WindowLiftAvoidance.WindowKey,
        frames: ManagedFrames,
        expectedStartTime: timeval?,
        reader: AXWindowReader,
        liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?
    ) -> RestoreOutcome {
        if let expected = expectedStartTime {
            guard let current = ProcessLiveness.startTime(pid: key.pid),
                  current.tv_sec == expected.tv_sec,
                  current.tv_usec == expected.tv_usec else {
                return .handled
            }
        }
        if liveWindowKeys?.contains(key) == false { return .handled }

        guard let handle = reader.captureHandle(
                  forPID: key.pid,
                  cgWindowID: key.cgWindowID,
                  messagingTimeout: windowLiftAXMessagingTimeout
              ),
              let currentAXFrame = reader.frame(
                  of: handle.element,
                  messagingTimeout: windowLiftAXMessagingTimeout
              ) else {
            // 多半是还没拿到辅助功能权限。留在队列里，等授权回来再还。
            return .unreachable
        }

        let currentAppKitFrame = WindowLiftAvoidance.appKitFrame(
            fromQuartz: currentAXFrame,
            primaryScreenHeight: frames.primaryScreenHeight
        )
        switch WindowLiftAvoidance.frameClassification(
            of: currentAppKitFrame,
            nativeFrame: frames.nativeAppKit,
            targetFrame: frames.targetAppKit
        ) {
        case .target, .managedTrajectory:
            break
        case .native, .external:
            return .handled
        }

        _ = reader.setFrame(
            frames.nativeQuartz,
            for: handle.element,
            messagingTimeout: windowLiftAXMessagingTimeout,
            verificationTolerance: WindowLiftAvoidance.verificationTolerance,
            onlyIfCurrentMatches: currentAXFrame,
            restoreOnFailureTo: currentAXFrame
        )
        return .handled
    }

    private func store(
        _ state: WindowLiftAvoidance.SessionState,
        for key: WindowLiftAvoidance.WindowKey
    ) {
        let previous = states[key] ?? .idle
        if state == .idle {
            states.removeValue(forKey: key)
            lastTraceClassifications.removeValue(forKey: key)
        } else {
            states[key] = state
        }
        if traceEnabled, traceLabel(for: previous) != traceLabel(for: state) {
            let previousLabel = traceLabel(for: previous)
            let stateLabel = traceLabel(for: state)
            logger.info(
                "lift trace transition pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) from=\(previousLabel, privacy: .public) to=\(stateLabel, privacy: .public)"
            )
        }
        updateTrackedProbeLifecycle()
        updatePollTimerLifecycle()
    }

    private func clearManagedSession(
        for key: WindowLiftAvoidance.WindowKey,
        cancelWriter: Bool,
        reason: String,
        suppressUntilNative: Bool = false
    ) {
        guard canMutateSessions() else {
            // 冻结期间只丢任务引用，会话数据一概不动。
            if let writer = writeTasks.removeValue(forKey: key) {
                if cancelWriter { writer.cancel() }
                pendingDrains.append(writer)
            }
            return
        }
        if cancelWriter, let writer = writeTasks.removeValue(forKey: key) {
            writer.cancel()
            writeDrainTasks[key, default: []].append(writer)
        } else {
            writeTasks.removeValue(forKey: key)
        }
        observationWatermarks[key] = max(
            observationWatermarks[key] ?? 0,
            nextGeneration
        )
        validationGenerations.removeValue(forKey: key)
        let previous = states.removeValue(forKey: key)
        let frames = managedFrames.removeValue(forKey: key)
        if suppressUntilNative, let frames {
            suppressedFrames[key] = frames
        } else {
            suppressedFrames.removeValue(forKey: key)
        }
        lastTraceClassifications.removeValue(forKey: key)
        if traceEnabled, previous != nil {
            logger.info(
                "lift trace clear pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
        updateTrackedProbeLifecycle()
        updatePollTimerLifecycle()
    }

    private func traceClassification(
        _ classification: WindowLiftAvoidance.FrameClassification,
        for key: WindowLiftAvoidance.WindowKey
    ) {
        guard traceEnabled, lastTraceClassifications[key] != classification else { return }
        lastTraceClassifications[key] = classification
        logger.info(
            "lift trace classify pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) frame=\(String(describing: classification), privacy: .public)"
        )
    }

    private func traceLabel(for state: WindowLiftAvoidance.SessionState) -> String {
        switch state {
        case .idle:
            return "idle"
        case let .writing(attempt):
            return "writing(reliftCount:\(attempt.reliftCount))"
        case let .lifted(session):
            return "lifted(reliftCount:\(session.reliftCount))"
        case let .abandoned(session):
            return "abandoned(reason:\(String(describing: session.reason)),reliftCount:\(session.reliftCount))"
        }
    }
}
