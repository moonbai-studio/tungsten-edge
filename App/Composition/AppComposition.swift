import AppKit
import Foundation
import Combine
import os
import CoreGraphics
import Darwin

@MainActor
final class AppComposition {
    let state = DockState()
    let identity = WindowIdentityEngine()
    let transitions = LifecycleTransitionEngine()
    let placement = PlacementEngine()
    let actionPlanning = LifecycleActionPlanner()
    private let actionExecutor = PlatformActionExecutor()
    private let permissionService = PermissionService()
    private let roundAnomalyFuse = ObservationRoundAnomalyFuse()
    private let admissionGate = ObservationAdmissionGate()
    private let pendingCloseTracker = PendingCloseTracker()
    private let externalCloseTracker = ExternalCloseTracker()
    private let deduper = SnapshotDeduper()
    private let trustLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "taskbar-trust")

    lazy var observationPipeline = ObservationPipeline(
        state: state,
        identity: identity,
        transitions: transitions,
        placement: placement,
        pendingCloseTracker: pendingCloseTracker
    )

    lazy var intentPipeline = IntentPipeline(
        state: state,
        actionPlanning: actionPlanning
    )

    var hasRequiredPermissions: Bool {
        permissionService.hasRequiredPermissions()
    }

    var feedbackEntriesByWindowID: [String: IntentFeedbackState.Entry] {
        intentPipeline.feedbackState.entriesByWindowID
    }

    func canPerform(intent: UserIntent) -> Bool {
        intentPipeline.canBegin(intent: intent)
    }

    @discardableResult
    func perform(intent: UserIntent) -> Bool {
        let request = intentPipeline.plan(intent: intent)
        intentPipeline.registerPending(intent: intent, request: request)

        let success = actionExecutor.execute(request, snapshot: state.snapshot)
        intentPipeline.registerExecutionResult(intent: intent, request: request, success: success)

        if success, request.kind == .closeWindow, let windowID = request.windowID {
            pendingCloseTracker.track(windowID: windowID, at: Date())
        }

        return success
    }

    func removeWindows(forTerminatedPID pid: pid_t) {
        externalCloseTracker.confirmTerminated(pid: pid, in: state, identity: identity)
    }

    func applyObservations(
        _ observations: [SystemObservation],
        inventoryMainlineAvailable: Bool = true
    ) -> DockSnapshot {
        var processed: [ProcessedObservation] = []
        let roundAdmission = roundAnomalyFuse.decide(observations: observations, snapshot: state.snapshot)
        if roundAdmission.kind == .rejected {
            let sources = roundAdmission.sourceCounts
                .map { "\($0.key.rawValue)=\($0.value)" }
                .sorted()
                .joined(separator: ",")
            trustLogger.error("rejected observation round reason=\(roundAdmission.reason, privacy: .public) baseline=\(roundAdmission.baselineCount) candidates=\(roundAdmission.candidateCount) sources=\(sources, privacy: .public)")
            return state.snapshot
        }

        admissionGate.beginRound(
            at: observations.map(\.timestamp).min() ?? Date(),
            inventoryMainlineAvailable: inventoryMainlineAvailable
        )
        for observation in orderedForStableLifecycle(observations) {
            let admission = admissionGate.decide(observation: observation, snapshot: state.snapshot)
            guard admission.kind == .accepted else { continue }
            if let result = observationPipeline.process(observation) {
                processed.append(result)
            }
        }

        deduper.removeStaleChromiumDuplicates(in: state, identity: identity)
        externalCloseTracker.reconcile(in: state, identity: identity, processed: processed, now: Date())
        pendingCloseTracker.expire(at: Date())
        intentPipeline.reconcile(with: state.snapshot)
        return state.snapshot
    }

    private func orderedForStableLifecycle(_ observations: [SystemObservation]) -> [SystemObservation] {
        observations.sorted { lhs, rhs in
            if lhs.kind == .disappeared && rhs.kind != .disappeared {
                return false
            }
            if lhs.kind != .disappeared && rhs.kind == .disappeared {
                return true
            }
            return lhs.timestamp < rhs.timestamp
        }
    }
}

@MainActor
final class AppRuntime: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot
    @Published private(set) var hasRequiredPermissions: Bool
    @Published private(set) var feedbackEntriesByWindowID: [String: IntentFeedbackState.Entry]
    @Published private(set) var observationStatusText: String

    private let composition: AppComposition
    private let observationCollector = ObservationCollector()
    private var observationTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    private var observationStartedAt: Date?
    private var hasReportedWarmStart = false
    private var hasReportedLiveObservation = false
    private let startupLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "startup")

    init(composition: AppComposition) {
        self.composition = composition
        self.snapshot = composition.state.snapshot
        self.hasRequiredPermissions = composition.hasRequiredPermissions
        self.feedbackEntriesByWindowID = composition.feedbackEntriesByWindowID
        self.observationStatusText = "正在启动"
    }

    convenience init() {
        self.init(composition: AppComposition())
    }

    func start() {
        guard observationTask == nil else { return }

        observationStartedAt = Date()
        hasRequiredPermissions = composition.hasRequiredPermissions
        observationStatusText = "正在预热"
        hasReportedWarmStart = false
        hasReportedLiveObservation = false
        startupLogger.info("startup began")
        startWorkspaceObservers()

        observationTask = Task { [weak self] in
            guard let self else { return }

            while Task.isCancelled == false {
                await self.pollNow(includeAccessibility: true)
                guard Task.isCancelled == false else { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        if let activateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activateObserver)
            self.activateObserver = nil
        }
    }

    func pollNow() {
        Task { [weak self] in
            await self?.pollNow(includeAccessibility: true)
        }
    }

    private func pollNow(includeAccessibility: Bool) async {
        hasRequiredPermissions = composition.hasRequiredPermissions
        let observations = await observationCollector.collectCurrentObservations(
            includeAccessibility: includeAccessibility && hasRequiredPermissions
        )
        snapshot = composition.applyObservations(
            observations,
            inventoryMainlineAvailable: includeAccessibility && hasRequiredPermissions
        )
        feedbackEntriesByWindowID = composition.feedbackEntriesByWindowID
        updateObservationStatus(didReadAccessibility: includeAccessibility && hasRequiredPermissions)
    }

    func activate(windowID: String) {
        trigger(.activate(WindowID(rawValue: windowID)))
    }

    func toggle(windowID: String) {
        trigger(.toggle(WindowID(rawValue: windowID)))
    }

    func minimize(windowID: String) {
        trigger(.minimize(WindowID(rawValue: windowID)))
    }

    func hide(windowID: String) {
        trigger(.hide(WindowID(rawValue: windowID)))
    }

    func close(windowID: String) {
        trigger(.close(WindowID(rawValue: windowID)))
    }

    private func trigger(_ intent: UserIntent) {
        guard composition.canPerform(intent: intent) else { return }
        let succeeded = composition.perform(intent: intent)
        feedbackEntriesByWindowID = composition.feedbackEntriesByWindowID
        guard succeeded else { return }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.pollNow(includeAccessibility: true)
        }
    }

    private func startWorkspaceObservers() {
        guard terminateObserver == nil else { return }
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                self?.composition.removeWindows(forTerminatedPID: pid)
                self?.snapshot = self?.composition.state.snapshot ?? .empty
                self?.feedbackEntriesByWindowID = self?.composition.feedbackEntriesByWindowID ?? [:]
            }
        }

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleWorkspaceFollowUpPolls(delays: [200_000_000, 700_000_000])
            }
        }

        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleWorkspaceFollowUpPolls(delays: [200_000_000])
            }
        }
    }

    private func scheduleWorkspaceFollowUpPolls(delays: [UInt64]) {
        for delay in delays {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                await self?.pollNow(includeAccessibility: true)
            }
        }
    }

    private func updateObservationStatus(didReadAccessibility: Bool) {
        guard let observationStartedAt else { return }
        let elapsedMilliseconds = Int(Date().timeIntervalSince(observationStartedAt) * 1000)

        if didReadAccessibility {
            guard hasReportedLiveObservation == false else { return }
            hasReportedLiveObservation = true
            observationStatusText = "实时 \(elapsedMilliseconds) 毫秒"
            startupLogger.info("live observation ready in \(elapsedMilliseconds) ms")
            return
        }

        guard hasReportedWarmStart == false else { return }
        hasReportedWarmStart = true
        if hasRequiredPermissions {
            observationStatusText = "预热 \(elapsedMilliseconds) 毫秒"
            startupLogger.info("warm start CG-only snapshot ready in \(elapsedMilliseconds) ms")
        } else {
            observationStatusText = "仅窗口列表 \(elapsedMilliseconds) 毫秒"
            startupLogger.info("cg-only snapshot ready in \(elapsedMilliseconds) ms")
        }
    }
}

actor ObservationCollector {
    private var coreGraphicsSource = CoreGraphicsSource()
    private let accessibilitySource = AccessibilitySource()
    private let workspaceSource = WorkspaceSource()
    private let finderSource = FinderSource()
    private let inventoryFirstEnabled = ObservationAdmissionGate.Mode.current() != .legacy

    func collectCurrentObservations(includeAccessibility: Bool) -> [SystemObservation] {
        if includeAccessibility && inventoryFirstEnabled {
            let inventory = workspaceSource.observe()
            var observations = inventory.observations
            observations += coreGraphicsSource.observe(inventoryDegradedPIDs: inventory.degradedPIDs)
            observations += finderSource.observe()
            return observations
        }

        var observations = coreGraphicsSource.observe()
        if includeAccessibility {
            observations += accessibilitySource.observe()
        }
        observations += finderSource.observe()
        return observations
    }
}

final class SnapshotDeduper {
    func removeStaleChromiumDuplicates(in state: DockState, identity: WindowIdentityEngine) {
        removeStaleDisappearedDuplicates(in: state, identity: identity)

        let snapshot = state.snapshot
        let chromiumRecords = snapshot.windows.values.filter { record in
            guard let bundleIdentifier = record.bundleIdentifier else { return false }
            return bundleIdentifier == "com.google.Chrome"
                || bundleIdentifier == "com.google.Chrome.canary"
                || bundleIdentifier == "com.google.Chrome.beta"
                || bundleIdentifier == "com.google.Chrome.dev"
        }

        let grouped = Dictionary(grouping: chromiumRecords) { record in
            chromiumWindowGroupKey(for: record)
        }

        for records in grouped.values where records.count > 1 {
            let visibleRecords = records.filter { $0.status != .disappeared && $0.status != .closedPending }
            guard visibleRecords.count == 1, let keeper = visibleRecords.first else { continue }

            for record in records where record.id != keeper.id && record.status == .disappeared {
                remove(recordID: record.id, preserving: keeper.id, in: state)
                identity.retire(windowID: record.id)
            }
        }
    }

    private func removeStaleDisappearedDuplicates(in state: DockState, identity: WindowIdentityEngine) {
        let snapshot = state.snapshot
        let grouped = Dictionary(grouping: snapshot.windows.values) { record in
            duplicateGroupKey(for: record)
        }

        for records in grouped.values where records.count > 1 {
            let visibleRecords = records.filter { $0.status != .disappeared && $0.status != .closedPending }
            guard visibleRecords.count == 1, let keeper = visibleRecords.first else { continue }

            for record in records where record.id != keeper.id && record.status == .disappeared {
                remove(recordID: record.id, preserving: keeper.id, in: state)
                identity.retire(windowID: record.id)
            }
        }
    }

    private func duplicateGroupKey(for record: WindowRecord) -> String {
        let app = record.bundleIdentifier ?? record.appID.rawValue
        let normalizedTitle = record.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let frame: String
        if let bounds = record.bounds {
            frame = "\(Int(bounds.origin.x.rounded())):\(Int(bounds.origin.y.rounded())):\(Int(bounds.width.rounded())):\(Int(bounds.height.rounded()))"
        } else {
            frame = "no-frame"
        }
        return "\(record.pid)|\(app)|\(normalizedTitle)|\(frame)"
    }

    private func chromiumWindowGroupKey(for record: WindowRecord) -> String {
        let app = record.bundleIdentifier ?? record.appID.rawValue
        let frame: String
        if let bounds = record.bounds {
            frame = "\(Int(bounds.origin.x.rounded())):\(Int(bounds.origin.y.rounded())):\(Int(bounds.width.rounded())):\(Int(bounds.height.rounded()))"
        } else {
            frame = "no-frame"
        }
        return "\(record.pid)|\(app)|\(frame)"
    }

    private func remove(recordID: WindowID, preserving keeperID: WindowID, in state: DockState) {
        var orderedWindowIDs = state.snapshot.orderedWindowIDs
        if let staleIndex = orderedWindowIDs.firstIndex(of: recordID) {
            if let keeperIndex = orderedWindowIDs.firstIndex(of: keeperID) {
                if staleIndex < keeperIndex {
                    orderedWindowIDs[staleIndex] = keeperID
                }
            } else {
                orderedWindowIDs[staleIndex] = keeperID
            }
        }

        orderedWindowIDs = deduplicated(orderedWindowIDs)
        state.commit(
            StateUpdate(
                windowID: recordID,
                windowRecord: nil,
                orderedWindowIDs: orderedWindowIDs
            )
        )
    }

    private func deduplicated(_ orderedWindowIDs: [WindowID]) -> [WindowID] {
        var seen: Set<WindowID> = []
        var deduplicated: [WindowID] = []
        for windowID in orderedWindowIDs where seen.insert(windowID).inserted {
            deduplicated.append(windowID)
        }
        return deduplicated
    }
}

final class ExternalCloseTracker {
    private static let confirmationWindow: TimeInterval = 2.0
    private static let appFallbackGraceWindow: TimeInterval = 5.0
    private var firstDisappearedAtByWindowID: [WindowID: Date] = [:]
    private var firstMissingFallbackAtByWindowID: [WindowID: Date] = [:]
    private let axExecutor = AccessibilityWindowActionExecutor()

    func reconcile(
        in state: DockState,
        identity: WindowIdentityEngine,
        processed: [ProcessedObservation],
        now: Date
    ) {
        let liveObservations = processed.filter { $0.lifecycle.newStatus != .disappeared }
        let liveObservationWindowIDs = Set(liveObservations.map(\.lifecycle.windowID))

        removeTerminatedWindows(in: state, identity: identity)
        reconcileAppFallbacks(
            in: state,
            identity: identity,
            liveObservationWindowIDs: liveObservationWindowIDs,
            now: now
        )
        let snapshot = state.snapshot

        for record in snapshot.windows.values where record.status != .disappeared {
            firstDisappearedAtByWindowID.removeValue(forKey: record.id)
        }

        for record in snapshot.windows.values where record.status == .disappeared {
            if shouldSkipExternalClose(for: record) {
                firstDisappearedAtByWindowID.removeValue(forKey: record.id)
                continue
            }

            if hasLiveReplacement(for: record, liveObservations: liveObservations) {
                firstDisappearedAtByWindowID.removeValue(forKey: record.id)
                continue
            }

            if isProcessAlive(pid: record.pid) == false {
                confirmClosed(recordID: record.id, in: state, identity: identity)
                continue
            }

            if NSRunningApplication(processIdentifier: record.pid)?.isHidden == true {
                firstDisappearedAtByWindowID.removeValue(forKey: record.id)
                continue
            }

            if stillPresentInAccessibility(record: record) {
                firstDisappearedAtByWindowID.removeValue(forKey: record.id)
                continue
            }

            let firstSeenAt = firstDisappearedAtByWindowID[record.id] ?? now
            firstDisappearedAtByWindowID[record.id] = firstSeenAt
            if now.timeIntervalSince(firstSeenAt) >= Self.confirmationWindow {
                confirmClosed(recordID: record.id, in: state, identity: identity)
            }
        }

        firstDisappearedAtByWindowID = firstDisappearedAtByWindowID.filter { windowID, _ in
            state.snapshot.windows[windowID]?.status == .disappeared
        }
    }

    func confirmTerminated(pid: pid_t, in state: DockState, identity: WindowIdentityEngine) {
        let ids = state.snapshot.windows.values
            .filter { $0.pid == pid }
            .map(\.id)
        for id in ids {
            confirmClosed(recordID: id, in: state, identity: identity)
        }
    }

    private func removeTerminatedWindows(in state: DockState, identity: WindowIdentityEngine) {
        let ids = state.snapshot.windows.values
            .filter { isProcessAlive(pid: $0.pid) == false }
            .map(\.id)
        for id in ids {
            confirmClosed(recordID: id, in: state, identity: identity)
        }
    }

    private func reconcileAppFallbacks(
        in state: DockState,
        identity: WindowIdentityEngine,
        liveObservationWindowIDs: Set<WindowID>,
        now: Date
    ) {
        for record in state.snapshot.windows.values where record.id.rawValue.hasPrefix("app-") {
            if liveObservationWindowIDs.contains(record.id) {
                firstMissingFallbackAtByWindowID.removeValue(forKey: record.id)
                continue
            }

            let processAlive = isProcessAlive(pid: record.pid)
            if processAlive == false {
                confirmClosed(recordID: record.id, in: state, identity: identity)
                continue
            }

            if AppFallbackRetentionPolicy.shouldRetainMissingFallback(
                record: record,
                isProcessAlive: processAlive
            ) {
                firstMissingFallbackAtByWindowID.removeValue(forKey: record.id)
                continue
            }

            if NSRunningApplication(processIdentifier: record.pid)?.isHidden == true {
                firstMissingFallbackAtByWindowID.removeValue(forKey: record.id)
                continue
            }

            let firstMissingAt = firstMissingFallbackAtByWindowID[record.id] ?? now
            firstMissingFallbackAtByWindowID[record.id] = firstMissingAt
            if now.timeIntervalSince(firstMissingAt) >= Self.appFallbackGraceWindow {
                confirmClosed(recordID: record.id, in: state, identity: identity)
            }
        }

        firstMissingFallbackAtByWindowID = firstMissingFallbackAtByWindowID.filter { windowID, _ in
            state.snapshot.windows[windowID] != nil
        }
    }

    private func hasLiveReplacement(
        for record: WindowRecord,
        liveObservations: [ProcessedObservation]
    ) -> Bool {
        liveObservations.contains { processed in
            let observation = processed.observation
            guard observation.pid == record.pid else { return false }
            guard observation.bundleIdentifier == record.bundleIdentifier else { return false }

            if let recordBounds = record.bounds {
                guard let observationBounds = observation.bounds else { return false }
                return WindowFrameMatchPolicy.areClose(recordBounds, observationBounds)
            }

            return record.bounds == nil && observation.bounds == nil
        }
    }

    private func shouldSkipExternalClose(for record: WindowRecord) -> Bool {
        guard let bundleIdentifier = record.bundleIdentifier else { return false }
        return FeishuBundleRules.isFeishu(bundleIdentifier: bundleIdentifier)
    }

    private func confirmClosed(recordID: WindowID, in state: DockState, identity: WindowIdentityEngine) {
        state.commit(
            StateUpdate(
                windowID: recordID,
                windowRecord: nil,
                orderedWindowIDs: state.snapshot.orderedWindowIDs.filter { $0 != recordID }
            )
        )
        identity.retire(windowID: recordID)
        firstDisappearedAtByWindowID.removeValue(forKey: recordID)
        firstMissingFallbackAtByWindowID.removeValue(forKey: recordID)
    }

    private func stillPresentInAccessibility(record: WindowRecord) -> Bool {
        let isFinderWindow = FinderWindowRules.isFinder(bundleIdentifier: record.bundleIdentifier)
        return axExecutor.captureHandle(
            for: AccessibilityWindowActionExecutor.WindowTarget(
                pid: record.pid,
                title: record.title,
                bounds: record.bounds
            ),
            attempts: isFinderWindow ? 3 : 1,
            retryIntervalMicroseconds: isFinderWindow ? 150_000 : 0
        ) != nil
    }

    private func isProcessAlive(pid: pid_t) -> Bool {
        errno = 0
        let result = kill(pid, 0)
        if result == 0 || errno == EPERM {
            return true
        }

        if errno == ESRCH {
            return false
        }

        return NSRunningApplication(processIdentifier: pid)?.isTerminated == false
    }
}
