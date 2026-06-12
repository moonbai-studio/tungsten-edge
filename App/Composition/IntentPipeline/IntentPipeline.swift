import Foundation
import os

final class IntentPipeline {
    private let actionPlanning: LifecycleActionPlanner
    private(set) var feedbackState = IntentFeedbackState()
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "intent-pipeline")

    init(actionPlanning: LifecycleActionPlanner) {
        self.actionPlanning = actionPlanning
    }

    func plan(intent: UserIntent, snapshot: DockSnapshot) -> PlatformActionRequest {
        actionPlanning.plan(intent: intent, snapshot: snapshot)
    }

    func canBegin(intent: UserIntent) -> Bool {
        feedbackState.canBegin(windowID: intent.windowID.rawValue)
    }

    func registerPending(intent: UserIntent, request: PlatformActionRequest) {
        feedbackState.begin(
            windowID: intent.windowID.rawValue,
            action: feedbackAction(for: request, fallback: intent.action),
            at: Date()
        )
    }

    func registerExecutionResult(intent: UserIntent, request: PlatformActionRequest, success: Bool) {
        let action = feedbackAction(for: request, fallback: intent.action)
        if success {
            feedbackState.markSucceededImmediatelyIfNeeded(
                windowID: intent.windowID.rawValue,
                action: action,
                at: Date()
            )
        } else {
            feedbackState.markFailed(windowID: intent.windowID.rawValue, action: action, at: Date())
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

    mutating func begin(windowID: String, action: UserIntentAction, at timestamp: Date) {
        let entry = Entry(
            windowID: windowID,
            action: action,
            phase: .pending,
            updatedAt: timestamp
        )
        entriesByWindowID[windowID] = entry
    }

    mutating func markSucceededImmediatelyIfNeeded(
        windowID: String,
        action: UserIntentAction,
        at timestamp: Date
    ) {
        // newWindow opens a *new* window (a different windowID), so it can never be
        // confirmed by reconciling this chip's snapshot status. Treat a successful
        // executor return as immediate success, same as activate.
        if action == .activate || action == .newWindow {
            update(windowID: windowID, phase: .success, at: timestamp)
        }
    }

    mutating func markFailed(windowID: String, action: UserIntentAction, at timestamp: Date) {
        update(windowID: windowID, phase: .failure, at: timestamp)
    }

    mutating func reconcile(snapshot: DockSnapshot, now: Date) {
        for (windowID, entry) in entriesByWindowID {
            if entry.phase == .pending,
               now.timeIntervalSince(entry.updatedAt) > entry.phase.retention {
                update(windowID: windowID, phase: .failure, at: now)
                continue
            }

            guard let typedWindowID = snapshot.orderedWindowIDs.first(where: { $0.rawValue == windowID }) ?? snapshot.windows.keys.first(where: { $0.rawValue == windowID }) else {
                if entry.action == .close {
                    update(windowID: windowID, phase: .success, at: now)
                }
                continue
            }

            guard let record = snapshot.windows[typedWindowID] else { continue }

            switch entry.action {
            case .toggle:
                break
            case .activate:
                if record.status == .active {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .minimize:
                if record.status == .minimized || record.status == .disappeared {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .hide:
                if record.status == .hidden || record.status == .disappeared {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .close:
                if record.status == .closedPending {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .quit:
                if record.status == .disappeared {
                    update(windowID: windowID, phase: .success, at: now)
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

    private mutating func update(windowID: String, phase: FeedbackPhase, at timestamp: Date) {
        guard var entry = entriesByWindowID[windowID] else { return }
        entry.phase = phase
        entry.updatedAt = timestamp
        entriesByWindowID[windowID] = entry
    }

    struct Entry: Hashable {
        let windowID: String
        let action: UserIntentAction
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
