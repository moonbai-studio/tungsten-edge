import AppKit
import ApplicationServices

/// Reads per-app badge strings from the system Dock's accessibility tree.
///
/// Apps publish unread counts by setting their Dock tile badge; there is no public
/// API to read another app's badge directly, but the Dock process exposes each icon
/// as an AX element whose `AXStatusLabel` attribute carries the badge text ("3",
/// "99+", "•"). Mapping element → app uses the Dock item's `AXURL` (the .app bundle
/// URL), which is exact — no name matching.
///
/// Requires Accessibility permission, which this app already needs. Apps only get a
/// Dock icon while running (or pinned), and messaging chips only render while the
/// app runs, so coverage is aligned by construction.
struct DockBadgeReader: Sendable {
    /// Returns [bundleID: badge text] for every Dock item that currently shows a badge.
    /// Call off the main thread; AX messaging to the Dock can block briefly.
    func readBadges() -> [String: String] {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(dockElement, 0.25)

        var bundleIDByPath: [String: String] = [:]
        var result: [String: String] = [:]
        // Dock AX hierarchy: application element → AXList children → AXDockItem children.
        for list in children(of: dockElement) {
            for item in children(of: list) {
                guard let badge = stringAttribute("AXStatusLabel", of: item),
                      !badge.isEmpty,
                      let url = urlAttribute(kAXURLAttribute as String, of: item),
                      let bundleID = bundleID(forAppURL: url, cache: &bundleIDByPath) else { continue }
                result[bundleID] = badge
            }
        }
        return result
    }

    // MARK: - AX helpers

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func urlAttribute(_ attribute: String, of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let url = value as? NSURL else { return nil }
        return url as URL
    }

    private func bundleID(forAppURL url: URL, cache: inout [String: String]) -> String? {
        let path = url.path
        if let cached = cache[path] { return cached }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        cache[path] = bundleID
        return bundleID
    }
}
