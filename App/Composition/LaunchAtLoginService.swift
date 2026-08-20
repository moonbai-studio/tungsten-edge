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
            title = String(localized: "Open at Login (macOS 13+)")
            isEnabled = false
            isChecked = false
            showsSettingsItem = false
        case .off:
            title = String(localized: "Open at Login")
            isEnabled = true
            isChecked = false
            showsSettingsItem = false
        case .on:
            title = String(localized: "Open at Login")
            isEnabled = true
            isChecked = true
            showsSettingsItem = false
        case .requiresApproval:
            title = String(localized: "Open at Login (Pending Approval)")
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
    func currentState() async -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

@MainActor
final class LaunchAtLoginService: LaunchAtLoginServicing {
    private let stateReader: () -> LaunchAtLoginState
    private let readerQueue = DispatchQueue(label: "com.caye.macosdockcc.v2.launch-at-login-reader", qos: .userInitiated)

    init(stateReader: @escaping () -> LaunchAtLoginState = LaunchAtLoginService.readStateFromSystem) {
        self.stateReader = stateReader
    }

    func currentState() async -> LaunchAtLoginState {
        let stateReader = stateReader
        let readerQueue = readerQueue
        return await withCheckedContinuation { continuation in
            readerQueue.async {
                continuation.resume(returning: stateReader())
            }
        }
    }

    nonisolated static func readStateFromSystem() -> LaunchAtLoginState {
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
    nonisolated private static func mapStatus(_ status: SMAppService.Status) -> LaunchAtLoginState {
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
            return String(localized: "Open at Login requires macOS 13 or later.")
        }
    }
}
