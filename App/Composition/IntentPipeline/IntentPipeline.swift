import Foundation
import os

struct IntentActionID: Hashable, Sendable {
    let rawValue: UInt64
}

/// Window actions touch process-wide focus state, so their platform work must never
/// overlap. Submission stays synchronous and cheap; the blocking AX/SkyLight work
/// runs FIFO on this dedicated background queue.
final class SerialActionExecutionQueue: @unchecked Sendable {
    typealias Operation = () -> Bool
    typealias Completion = (IntentActionID, Bool) -> Void

    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "action-queue")

    init(label: String = "com.caye.macosdockcc.v2.platform-actions") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func submit(
        actionID: IntentActionID,
        request: PlatformActionRequest,
        operation: @escaping Operation,
        completion: @escaping Completion
    ) {
        let submittedAt = CFAbsoluteTimeGetCurrent()
        let actionLogger = logger
        queue.async {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let waitMilliseconds = Int((startedAt - submittedAt) * 1_000)
            actionLogger.info("action-start id=\(actionID.rawValue, privacy: .public) kind=\(request.kind.rawValue, privacy: .public) windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) forceRestore=\(request.forceRestoreBeforeFocus, privacy: .public) queueWaitMs=\(waitMilliseconds, privacy: .public)")

            let success = operation()

            let durationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
            actionLogger.info("action-end id=\(actionID.rawValue, privacy: .public) kind=\(request.kind.rawValue, privacy: .public) windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(success, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public)")
            completion(actionID, success)
        }
    }
}

@MainActor
final class IntentPipeline {
    private let actionPlanning: LifecycleActionPlanner
    private(set) var feedbackState = IntentFeedbackState()
    private var nextActionID: UInt64 = 0
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "intent-pipeline")

    init(actionPlanning: LifecycleActionPlanner) {
        self.actionPlanning = actionPlanning
    }

    func plan(
        intent: UserIntent,
        snapshot: DockSnapshot,
        optimisticStates: [String: OptimisticWindowState] = [:]
    ) -> PlatformActionRequest {
        actionPlanning.plan(intent: intent, snapshot: snapshot, optimisticStates: optimisticStates)
    }

    func canBegin(intent: UserIntent) -> Bool {
        feedbackState.canBegin(windowID: intent.windowID.rawValue)
    }

    @discardableResult
    func registerPending(intent: UserIntent, request: PlatformActionRequest) -> IntentActionID {
        nextActionID &+= 1
        let actionID = IntentActionID(rawValue: nextActionID)
        feedbackState.begin(
            windowID: intent.windowID.rawValue,
            action: feedbackAction(for: request, fallback: intent.action),
            actionID: actionID,
            at: Date()
        )
        return actionID
    }

    func registerExecutionResult(
        intent: UserIntent,
        request: PlatformActionRequest,
        actionID: IntentActionID,
        success: Bool
    ) {
        let action = feedbackAction(for: request, fallback: intent.action)
        let accepted: Bool
        if success {
            accepted = feedbackState.markSucceededImmediatelyIfNeeded(
                windowID: intent.windowID.rawValue,
                action: action,
                actionID: actionID,
                at: Date()
            )
        } else {
            accepted = feedbackState.markFailed(
                windowID: intent.windowID.rawValue,
                action: action,
                actionID: actionID,
                at: Date()
            )
        }
        if !accepted {
            logger.info("stale-action-completion ignored id=\(actionID.rawValue, privacy: .public) windowID=\(intent.windowID.rawValue, privacy: .public) action=\(action.rawValue, privacy: .public) success=\(success, privacy: .public)")
        }
    }

    func reconcile(with snapshot: DockSnapshot) {
        let before = feedbackState.entriesByWindowID
        feedbackState.reconcile(snapshot: snapshot, now: Date())
        for (windowID, entry) in feedbackState.entriesByWindowID {
            if let old = before[windowID], old.phase == .pending, entry.phase != .pending {
                logger.info("[B-pending-cleared] t=\(CFAbsoluteTimeGetCurrent(), privacy: .public) windowID=\(windowID, privacy: .public) action=\(entry.action.rawValue, privacy: .public) → \(entry.phase.rawValue, privacy: .public)")
            }
        }
    }

    private func feedbackAction(
        for request: PlatformActionRequest,
        fallback: UserIntentAction
    ) -> UserIntentAction {
        switch request.kind {
        case .activateWindow:
            return .activate
        case .minimizeWindow:
            return .minimize
        case .hideApp:
            return .hide
        case .closeWindow:
            return .close
        case .quitApp:
            return .quit
        case .newWindow:
            return .newWindow
        }
    }
}

struct IntentFeedbackState {
    private(set) var entriesByWindowID: [String: Entry] = [:]

    func canBegin(windowID: String) -> Bool {
        guard let entry = entriesByWindowID[windowID] else { return true }
        return entry.phase != .pending
    }

    mutating func begin(
        windowID: String,
        action: UserIntentAction,
        actionID: IntentActionID,
        at timestamp: Date
    ) {
        let entry = Entry(
            windowID: windowID,
            action: action,
            actionID: actionID,
            phase: .pending,
            updatedAt: timestamp
        )
        entriesByWindowID[windowID] = entry
    }

    mutating func markSucceededImmediatelyIfNeeded(
        windowID: String,
        action: UserIntentAction,
        actionID: IntentActionID,
        at timestamp: Date
    ) -> Bool {
        guard entriesByWindowID[windowID]?.actionID == actionID else { return false }
        // newWindow opens a *new* window (a different windowID), so it can never be
        // confirmed by reconciling this chip's snapshot status. Treat a successful
        // executor return as immediate success, same as activate.
        if action == .activate || action == .newWindow {
            update(windowID: windowID, actionID: actionID, phase: .success, at: timestamp)
        }
        return true
    }

    mutating func markFailed(
        windowID: String,
        action: UserIntentAction,
        actionID: IntentActionID,
        at timestamp: Date
    ) -> Bool {
        guard entriesByWindowID[windowID]?.actionID == actionID else { return false }
        update(windowID: windowID, actionID: actionID, phase: .failure, at: timestamp)
        return true
    }

    mutating func reconcile(snapshot: DockSnapshot, now: Date) {
        for (windowID, entry) in entriesByWindowID {
            if entry.phase == .pending,
               now.timeIntervalSince(entry.updatedAt) > entry.phase.retention {
                update(windowID: windowID, actionID: entry.actionID, phase: .failure, at: now)
                continue
            }

            guard let typedWindowID = snapshot.orderedWindowIDs.first(where: { $0.rawValue == windowID }) ?? snapshot.windows.keys.first(where: { $0.rawValue == windowID }) else {
                if entry.action == .close {
                    update(windowID: windowID, actionID: entry.actionID, phase: .success, at: now)
                }
                continue
            }

            guard let record = snapshot.windows[typedWindowID] else { continue }

            switch entry.action {
            case .toggle:
                break
            case .activate:
                if record.status == .active {
                    update(windowID: windowID, actionID: entry.actionID, phase: .success, at: now)
                }
            case .minimize:
                if record.status == .minimized || record.status == .disappeared {
                    update(windowID: windowID, actionID: entry.actionID, phase: .success, at: now)
                }
            case .hide:
                if record.status == .hidden || record.status == .disappeared {
                    update(windowID: windowID, actionID: entry.actionID, phase: .success, at: now)
                }
            case .close:
                if record.status == .closedPending {
                    update(windowID: windowID, actionID: entry.actionID, phase: .success, at: now)
                }
            case .quit:
                if record.status == .disappeared {
                    update(windowID: windowID, actionID: entry.actionID, phase: .success, at: now)
                }
            case .newWindow:
                // Success was marked immediately on executor return; nothing to
                // reconcile here (the new window is a separate windowID).
                break
            }
        }

        entriesByWindowID = entriesByWindowID.filter { _, entry in
            now.timeIntervalSince(entry.updatedAt) <= entry.phase.retention
        }
    }

    private mutating func update(
        windowID: String,
        actionID: IntentActionID,
        phase: FeedbackPhase,
        at timestamp: Date
    ) {
        guard var entry = entriesByWindowID[windowID], entry.actionID == actionID else { return }
        entry.phase = phase
        entry.updatedAt = timestamp
        entriesByWindowID[windowID] = entry
    }

    struct Entry: Hashable {
        let windowID: String
        let action: UserIntentAction
        let actionID: IntentActionID
        var phase: FeedbackPhase
        var updatedAt: Date
    }

    enum FeedbackPhase: String, Hashable {
        case pending
        case success
        case failure

        var retention: TimeInterval {
            switch self {
            case .pending:
                return 4.0
            case .success, .failure:
                return 1.5
            }
        }
    }
}
