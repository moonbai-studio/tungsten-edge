import ApplicationServices
import CoreGraphics
import Foundation

enum FinderWindowRules {
    static let bundleIdentifier = "com.apple.finder"

    static func isFinder(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == Self.bundleIdentifier
    }

    static func isTrackable(
        title: String?,
        role: String?,
        subrole: String?,
        bounds: CGRect?,
        isMinimized: Bool
    ) -> Bool {
        guard AXTaskbarWindowRules.isMainWindow(
            role: role,
            subrole: subrole,
            bounds: bounds
        ) || isMinimizedMainWindow(role: role, subrole: subrole, isMinimized: isMinimized) else {
            return false
        }

        guard let bounds, bounds.width >= 40, bounds.height >= 40 else {
            return false
        }

        guard let normalized = normalizedTitle(title),
              genericTitles.contains(normalized) == false else {
            return false
        }

        return true
    }

    /// Finder reports every minimized window as `AXDialog` (folder windows, every tab of a
    /// minimized tab group, Get Info, the copy-progress window alike) and flips it back to
    /// `AXStandardWindow` on restore. The generic rule rejects dialogs, so a window minimized
    /// before launch would never seat. Admit the pair `min=true + AXDialog` for Finder only;
    /// every Finder window measured is a standard window while visible, so this admits nothing
    /// that would not already carry a card while visible. Title and frame checks still apply.
    private static func isMinimizedMainWindow(role: String?, subrole: String?, isMinimized: Bool) -> Bool {
        isMinimized
            && role == (kAXWindowRole as String)
            && subrole == (kAXDialogSubrole as String)
    }

    static func normalizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else { return nil }
        return trimmed.lowercased()
    }

    static func matchesGenericTitle(_ title: String?) -> Bool {
        normalizedTitle(title).map(genericTitles.contains) ?? false
    }

    private static let genericTitles: Set<String> = [
        "finder",
        "访达"
    ]
}
