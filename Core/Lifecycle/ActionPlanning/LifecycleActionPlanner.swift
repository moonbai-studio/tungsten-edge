import AppKit
import Foundation

enum UserIntentAction: String, Hashable, Sendable {
    case toggle
    case activate
    case minimize
    case hide
    case close
    case quit
}

enum UserIntent: Hashable, Sendable {
    case toggle(WindowID)
    case activate(WindowID)
    case minimize(WindowID)
    case hide(WindowID)
    case close(WindowID)
    case quit(WindowID)

    var windowID: WindowID {
        switch self {
        case let .toggle(id), let .activate(id), let .minimize(id), let .hide(id), let .close(id), let .quit(id):
            return id
        }
    }

    var action: UserIntentAction {
        switch self {
        case .toggle:
            return .toggle
        case .activate:
            return .activate
        case .minimize:
            return .minimize
        case .hide:
            return .hide
        case .close:
            return .close
        case .quit:
            return .quit
        }
    }
}

final class LifecycleActionPlanner {
    func plan(intent: UserIntent, snapshot: DockSnapshot) -> PlatformActionRequest {
        switch intent {
        case let .toggle(id):
            guard let record = snapshot.windows[id] else {
                return PlatformActionRequest(kind: .activateWindow, windowID: id)
            }
            let appIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == record.pid
            if record.id.rawValue.hasPrefix("app-") {
                return PlatformActionRequest(kind: appIsFrontmost ? .hideApp : .activateWindow, windowID: id)
            }
            if record.status == .active && appIsFrontmost {
                return PlatformActionRequest(kind: .minimizeWindow, windowID: id)
            }
            return PlatformActionRequest(kind: .activateWindow, windowID: id)
        case let .activate(id):
            return PlatformActionRequest(kind: .activateWindow, windowID: id)
        case let .minimize(id):
            return PlatformActionRequest(kind: .minimizeWindow, windowID: id)
        case let .hide(id):
            return PlatformActionRequest(kind: .hideApp, windowID: id)
        case let .close(id):
            return PlatformActionRequest(kind: .closeWindow, windowID: id)
        case let .quit(id):
            return PlatformActionRequest(kind: .quitApp, windowID: id)
        }
    }
}
