import Foundation

final class IntentPipeline {
    private let state: DockState
    private let actionPlanning: LifecycleActionPlanner
    private(set) var feedbackState = IntentFeedbackState()

    init(state: DockState, actionPlanning: LifecycleActionPlanner) {
        self.state = state
        self.actionPlanning = actionPlanning
    }

    func plan(intent: UserIntent) -> PlatformActionRequest {
        actionPlanning.plan(intent: intent, snapshot: state.snapshot)
    }

    func canBegin(intent: UserIntent) -> Bool {
        feedbackState.canBegin(windowID: intent.windowID.rawValue)
    }

    func registerPending(intent: UserIntent) {
        feedbackState.begin(intent: intent, at: Date())
    }

    func registerExecutionResult(intent: UserIntent, success: Bool) {
        if success {
            feedbackState.markSucceededImmediatelyIfNeeded(for: intent, at: Date())
        } else {
            feedbackState.markFailed(intent: intent, at: Date())
        }
    }

    func reconcile(with snapshot: DockSnapshot) {
        feedbackState.reconcile(snapshot: snapshot, now: Date())
    }
}

struct IntentFeedbackState {
    private(set) var entriesByWindowID: [String: Entry] = [:]

    func canBegin(windowID: String) -> Bool {
        guard let entry = entriesByWindowID[windowID] else { return true }
        return entry.phase != .pending
    }

    mutating func begin(intent: UserIntent, at timestamp: Date) {
        let entry = Entry(
            windowID: intent.windowID.rawValue,
            action: intent.action,
            phase: .pending,
            updatedAt: timestamp
        )
        entriesByWindowID[intent.windowID.rawValue] = entry
    }

    mutating func markSucceededImmediatelyIfNeeded(for intent: UserIntent, at timestamp: Date) {
        guard intent.action != .activate else { return }
        update(windowID: intent.windowID.rawValue, phase: .success, at: timestamp)
    }

    mutating func markFailed(intent: UserIntent, at timestamp: Date) {
        update(windowID: intent.windowID.rawValue, phase: .failure, at: timestamp)
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
            case .activate:
                if record.status == .active {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .minimize:
                if record.status == .minimized {
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
