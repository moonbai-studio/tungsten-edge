import Foundation

enum UserIntentAction: String, Hashable, Sendable {
    case activate
    case minimize
    case hide
    case close
}

enum UserIntent: Hashable, Sendable {
    case activate(WindowID)
    case minimize(WindowID)
    case hide(WindowID)
    case close(WindowID)

    var windowID: WindowID {
        switch self {
        case let .activate(id), let .minimize(id), let .hide(id), let .close(id):
            return id
        }
    }

    var action: UserIntentAction {
        switch self {
        case .activate:
            return .activate
        case .minimize:
            return .minimize
        case .hide:
            return .hide
        case .close:
            return .close
        }
    }
}

final class LifecycleActionPlanner {
    func plan(intent: UserIntent, snapshot: DockSnapshot) -> PlatformActionRequest {
        switch intent {
        case let .activate(id):
            return PlatformActionRequest(kind: .activateWindow, windowID: id)
        case let .minimize(id):
            return PlatformActionRequest(kind: .minimizeWindow, windowID: id)
        case let .hide(id):
            return PlatformActionRequest(kind: .hideApp, windowID: id)
        case let .close(id):
            return PlatformActionRequest(kind: .closeWindow, windowID: id)
        }
    }
}
