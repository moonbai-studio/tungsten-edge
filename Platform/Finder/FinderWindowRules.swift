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
        bounds: CGRect?
    ) -> Bool {
        guard role == (kAXWindowRole as String) else { return false }
        if let subrole,
           subrole != (kAXStandardWindowSubrole as String) {
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

    static func normalizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else { return nil }
        return trimmed.lowercased()
    }

    private static let genericTitles: Set<String> = [
        "finder",
        "访达"
    ]
}
