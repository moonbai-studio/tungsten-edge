import AppKit
import Foundation

enum UserIntentAction: String, Hashable, Sendable {
    case toggle
    case activate
    case minimize
    case hide
    case close
    case quit
    case newWindow
}

enum UserIntent: Hashable, Sendable {
    case toggle(WindowID)
    case activate(WindowID)
    case minimize(WindowID)
    case hide(WindowID)
    case close(WindowID)
    case quit(WindowID)
    case newWindow(WindowID)

    var windowID: WindowID {
        switch self {
        case let .toggle(id), let .activate(id), let .minimize(id), let .hide(id), let .close(id), let .quit(id), let .newWindow(id):
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
        case .newWindow:
            return .newWindow
        }
    }
}

final class LifecycleActionPlanner {
    /// 前台轴检查，默认 = 新建 NSRunningApplication 实例的即时 isActive 读
    ///（SkyLight 切换后立即翻面，Docs/22 §11 POSTACTIVATE 实证；测试注入桩）。
    private let isAppFrontmost: (pid_t) -> Bool
    /// 访达是否常驻任务条（设置「任务条常驻访达」）。为 false 时访达 app-* 卡与普通应用
    /// 一致：前台点击隐藏、非前台点击激活，不再无条件激活（issue #7）。
    private let isFinderPersistent: () -> Bool

    init(
        isAppFrontmost: @escaping (pid_t) -> Bool = {
            NSRunningApplication(processIdentifier: $0)?.isActive == true
        },
        isFinderPersistent: @escaping () -> Bool = { true }
    ) {
        self.isAppFrontmost = isAppFrontmost
        self.isFinderPersistent = isFinderPersistent
    }

    func plan(
        intent: UserIntent,
        snapshot: DockSnapshot,
        optimisticStates: [String: OptimisticWindowState] = [:]
    ) -> PlatformActionRequest {
        switch intent {
        case let .toggle(id):
            guard let record = snapshot.windows[id] else {
                return PlatformActionRequest(kind: .activateWindow, windowID: id)
            }
            // 乐观态优先（仅 status 轴）：上一个动作刚发出、快照还没翻面时，按预测态规划，
            // 连点才能严格交替（minimize → activate → …）而不是重复上一个动作。
            let optimistic = optimisticStates[id.rawValue]
            let status = optimistic?.status ?? record.status
            // 前台轴永远即时读，不许被乐观态覆盖（2026-07-05）：乐观 isAppFrontmost=true
            // 在「激活后 4s 内切去别的 App 再点回卡片」时残留不清（快照永远等不到 .active
            // 来兑现它），曾把该激活的点击误规划成 minimize。即时读本来就永远正确。
            let appIsFrontmost = isAppFrontmost(record.pid)
            if record.id.rawValue.hasPrefix("app-") {
                // Finder persistent chip: never hide — always open/focus to match system Dock behavior.
                // 仅常驻档生效；关闭常驻后与普通应用一致（前台 → 隐藏，否则激活）。
                if record.bundleIdentifier == "com.apple.finder", isFinderPersistent() {
                    return PlatformActionRequest(kind: .activateWindow, windowID: id)
                }
                return PlatformActionRequest(kind: appIsFrontmost ? .hideApp : .activateWindow, windowID: id)
            }
            if status == .active && appIsFrontmost {
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
        case let .newWindow(id):
            return PlatformActionRequest(kind: .newWindow, windowID: id)
        }
    }
}
