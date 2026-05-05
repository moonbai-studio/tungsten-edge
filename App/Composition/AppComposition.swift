import AppKit
import Foundation
import Combine
import os
import CoreGraphics

@MainActor
final class AppComposition {
    let state = DockState()
    let identity = WindowIdentityEngine()
    let transitions = LifecycleTransitionEngine()
    let placement = PlacementEngine()
    let actionPlanning = LifecycleActionPlanner()
    private let actionExecutor = PlatformActionExecutor()
    private let permissionService = PermissionService()
    private let pendingCloseTracker = PendingCloseTracker()
    private let externalCloseTracker = ExternalCloseTracker()
    private let deduper = SnapshotDeduper()

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
        intentPipeline.registerPending(intent: intent)

        let success = actionExecutor.execute(request, snapshot: state.snapshot)
        intentPipeline.registerExecutionResult(intent: intent, success: success)

        if success, request.kind == .closeWindow, let windowID = request.windowID {
            pendingCloseTracker.track(windowID: windowID, at: Date())
        }

        return success
    }

    func applyObservations(_ observations: [SystemObservation]) -> DockSnapshot {
        var processed: [ProcessedObservation] = []
        for observation in observations {
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

        observationTask = Task { [weak self] in
            guard let self else { return }

            await self.pollNow(includeAccessibility: false)
            guard Task.isCancelled == false else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)

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
        snapshot = composition.applyObservations(observations)
        feedbackEntriesByWindowID = composition.feedbackEntriesByWindowID
        updateObservationStatus(didReadAccessibility: includeAccessibility && hasRequiredPermissions)
    }

    func activate(windowID: String) {
        trigger(.activate(WindowID(rawValue: windowID)))
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

    func collectCurrentObservations(includeAccessibility: Bool) -> [SystemObservation] {
        var observations = coreGraphicsSource.observe()
        if includeAccessibility {
            observations += accessibilitySource.observe()
        }
        observations += workspaceSource.observe()
        observations += finderSource.observe()
        return observations
    }
}

final class SnapshotDeduper {
    func removeStaleChromiumDuplicates(in state: DockState, identity: WindowIdentityEngine) {
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
    private static let confirmationWindow: TimeInterval = 1.5
    private var firstDisappearedAtByWindowID: [WindowID: Date] = [:]
    private let axExecutor = AccessibilityWindowActionExecutor()

    func reconcile(
        in state: DockState,
        identity: WindowIdentityEngine,
        processed: [ProcessedObservation],
        now: Date
    ) {
        let snapshot = state.snapshot
        let liveObservations = processed.filter { $0.lifecycle.newStatus != .disappeared }

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

            guard let runningApp = NSRunningApplication(processIdentifier: record.pid) else {
                confirmClosed(recordID: record.id, in: state, identity: identity)
                continue
            }

            if runningApp.isTerminated {
                confirmClosed(recordID: record.id, in: state, identity: identity)
                continue
            }

            if runningApp.isHidden {
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

    private func hasLiveReplacement(
        for record: WindowRecord,
        liveObservations: [ProcessedObservation]
    ) -> Bool {
        liveObservations.contains { processed in
            let observation = processed.observation
            guard observation.pid == record.pid else { return false }
            guard observation.bundleIdentifier == record.bundleIdentifier else { return false }

            if let recordBounds = record.bounds, let observationBounds = observation.bounds {
                return areClose(recordBounds, observationBounds)
            }

            return false
        }
    }

    private func shouldSkipExternalClose(for record: WindowRecord) -> Bool {
        if record.id.rawValue.hasPrefix("app-") {
            return true
        }

        guard let bundleIdentifier = record.bundleIdentifier else { return false }
        return bundleIdentifier == "com.electron.lark" || bundleIdentifier == "com.feishu.app"
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
    }

    private func stillPresentInAccessibility(record: WindowRecord) -> Bool {
        axExecutor.captureHandle(
            for: AccessibilityWindowActionExecutor.WindowTarget(
                pid: record.pid,
                title: record.title,
                bounds: record.bounds
            )
        ) != nil
    }

    private func areClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= 4
            && abs(lhs.origin.y - rhs.origin.y) <= 4
            && abs(lhs.width - rhs.width) <= 4
            && abs(lhs.height - rhs.height) <= 4
    }
}
