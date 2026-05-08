import AppKit
import CoreGraphics
import Foundation

struct DockWindowEligibilityPolicy {
    static let selfBundleIdentifier = "com.caye.macosdockcc.v2"

    enum Decision: Equatable {
        case keep
        case filter
    }

    struct Candidate {
        let bundleIdentifier: String?
        let appName: String
        let title: String?
        let bounds: CGRect?
        let alpha: Double?
        let activationPolicy: NSApplication.ActivationPolicy
        let executablePath: String?
    }

    func evaluate(_ candidate: Candidate) -> Decision {
        if candidate.bundleIdentifier == Self.selfBundleIdentifier {
            return .filter
        }

        if candidate.alpha == 0 {
            return .filter
        }

        if FeishuBundleRules.isFeishu(bundleIdentifier: candidate.bundleIdentifier) {
            return .keep
        }

        if isFilteredSystemWindow(candidate) {
            return .filter
        }

        switch candidate.activationPolicy {
        case .prohibited:
            return .filter
        case .accessory:
            guard hasTitle(candidate.title),
                  hasMinimumFrame(candidate.bounds) else {
                return .filter
            }
            return .keep
        case .regular:
            return hasTitle(candidate.title) ? .keep : .filter
        @unknown default:
            return hasTitle(candidate.title) ? .keep : .filter
        }
    }

    private func isFilteredSystemWindow(_ candidate: Candidate) -> Bool {
        if let bundleIdentifier = candidate.bundleIdentifier,
           filteredBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        if filteredAppNames.contains(candidate.appName) {
            return true
        }

        if let executablePath = candidate.executablePath {
            if executablePath.contains(".appex/") {
                return true
            }

            if filteredExecutablePathFragments.contains(where: { executablePath.contains($0) }) {
                return true
            }
        }

        if let title = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           filteredTitles.contains(title) {
            return true
        }

        return false
    }

    private func hasTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func hasMinimumFrame(_ bounds: CGRect?) -> Bool {
        guard let bounds else { return false }
        return bounds.width >= 80 && bounds.height >= 40
    }

    private let filteredBundleIdentifiers: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter"
    ]

    private let filteredAppNames: Set<String> = [
        "Notification Center",
        "Control Center"
    ]

    private let filteredTitles: Set<String> = [
        "Notification Center",
        "通知中心"
    ]

    private let filteredExecutablePathFragments: [String] = [
        "ThemeWidgetControlViewService.xpc",
        "ChronoCore.framework/Support/chronod",
        "DockHelper.xpc",
        "com.apple.dock.extra.xpc",
        "ControlCenterHelper.xpc"
    ]
}

enum FeishuBundleRules {
    private static let bundleIdentifiers: Set<String> = [
        "com.electron.lark",
        "com.feishu.app",
        "com.bytedance.lark"
    ]

    static func isFeishu(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundleIdentifier)
    }
}
