import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case unsupported
    case off
    case on
    case requiresApproval
}

struct LaunchAtLoginMenuPresentation: Equatable {
    var title: String
    var isEnabled: Bool
    var isChecked: Bool
    var showsSettingsItem: Bool

    init(title: String, isEnabled: Bool, isChecked: Bool, showsSettingsItem: Bool) {
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.showsSettingsItem = showsSettingsItem
    }

    init(state: LaunchAtLoginState) {
        switch state {
        case .unsupported:
            title = "登录时启动（macOS 13+）"
            isEnabled = false
            isChecked = false
            showsSettingsItem = false
        case .off:
            title = "登录时启动"
            isEnabled = true
            isChecked = false
            showsSettingsItem = false
        case .on:
            title = "登录时启动"
            isEnabled = true
            isChecked = true
            showsSettingsItem = false
        case .requiresApproval:
            title = "登录时启动（待批准）"
            isEnabled = true
            isChecked = false
            showsSettingsItem = true
        }
    }
}

enum LaunchAtLoginMenuModel {
    static func requestedEnabledValue(afterSelecting state: LaunchAtLoginState) -> Bool? {
        switch state {
        case .unsupported:
            return nil
        case .off, .requiresApproval:
            return true
        case .on:
            return false
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing {
    var state: LaunchAtLoginState { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

@MainActor
final class LaunchAtLoginService: LaunchAtLoginServicing {
    var state: LaunchAtLoginState {
        guard #available(macOS 13.0, *) else { return .unsupported }
        return Self.mapStatus(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { throw LaunchAtLoginError.unsupported }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSystemSettings() {
        guard #available(macOS 13.0, *) else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    @available(macOS 13.0, *)
    private static func mapStatus(_ status: SMAppService.Status) -> LaunchAtLoginState {
        switch status {
        case .enabled:
            return .on
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .off
        @unknown default:
            return .off
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "登录时启动需要 macOS 13 或更新系统。"
        }
    }
}
