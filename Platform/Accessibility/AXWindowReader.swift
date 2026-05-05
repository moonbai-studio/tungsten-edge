import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AXWindowSnapshot {
    let pid: Int32
    let title: String?
    let bounds: CGRect?
    let role: String?
    let subrole: String?
    let isMinimized: Bool
    let isFocusedWindow: Bool
    let element: AXUIElement
}

struct AXWindowTarget {
    let pid: Int32
    let title: String?
    let bounds: CGRect?
}

struct AXWindowHandle {
    let pid: Int32
    let title: String?
    let bounds: CGRect?
    let element: AXUIElement
}

struct AXWindowReader {
    func windows(for app: NSRunningApplication) -> [AXWindowSnapshot] {
        windows(forPID: app.processIdentifier)
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] {
        let appElement = AXUIElementCreateApplication(pid)
        guard let value = copyAttributeValue(kAXWindowsAttribute as CFString, from: appElement),
              let elements = value as? [AXUIElement] else {
            return []
        }

        let focusedElement = elementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement)
        return elements.map { element in
            AXWindowSnapshot(
                pid: pid,
                title: stringAttribute(kAXTitleAttribute as CFString, from: element),
                bounds: frame(of: element),
                role: stringAttribute(kAXRoleAttribute as CFString, from: element),
                subrole: stringAttribute(kAXSubroleAttribute as CFString, from: element),
                isMinimized: boolAttribute(kAXMinimizedAttribute as CFString, from: element) ?? false,
                isFocusedWindow: focusedElement.map { CFEqual($0, element) } ?? false,
                element: element
            )
        }
    }

    func captureHandle(
        for target: AXWindowTarget,
        attempts: Int = 1,
        retryIntervalMicroseconds: useconds_t = 0
    ) -> AXWindowHandle? {
        guard AXIsProcessTrusted() else { return nil }
        let boundedAttempts = max(1, attempts)

        for attempt in 0..<boundedAttempts {
            if let snapshot = bestMatch(for: target, from: windows(forPID: target.pid)) {
                return AXWindowHandle(
                    pid: target.pid,
                    title: snapshot.title,
                    bounds: snapshot.bounds,
                    element: snapshot.element
                )
            }

            if attempt < boundedAttempts - 1, retryIntervalMicroseconds > 0 {
                usleep(retryIntervalMicroseconds)
            }
        }

        return nil
    }

    func focusedWindow(forPID pid: pid_t) -> AXUIElement? {
        elementAttribute(kAXFocusedWindowAttribute as CFString, from: AXUIElementCreateApplication(pid))
    }

    func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(attribute, from: element),
              let text = value as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func boolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        guard let value = copyAttributeValue(attribute, from: element),
              let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    func elementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttributeValue(attribute, from: element) else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    func frame(of element: AXUIElement) -> CGRect? {
        guard let positionAX = copyAttributeValue(kAXPositionAttribute as CFString, from: element),
              let sizeAX = copyAttributeValue(kAXSizeAttribute as CFString, from: element) else {
            return nil
        }

        let position = positionAX as! AXValue
        let sizeValueRef = sizeAX as! AXValue

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(position) == .cgPoint,
              AXValueGetType(sizeValueRef) == .cgSize,
              AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(sizeValueRef, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }

    func setMinimized(_ minimized: Bool, for handle: AXWindowHandle) -> Bool {
        let value: CFTypeRef = minimized ? kCFBooleanTrue : kCFBooleanFalse
        let result = AXUIElementSetAttributeValue(
            handle.element,
            kAXMinimizedAttribute as CFString,
            value
        )
        return result == .success
    }

    func copyAttributeValue(
        _ attribute: CFString,
        from element: AXUIElement,
        maxAttempts: Int = 2
    ) -> CFTypeRef? {
        var attempt = 0
        while attempt < maxAttempts {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute, &value)
            if result == .success {
                return value
            }

            if result != .cannotComplete {
                return nil
            }

            attempt += 1
            usleep(20_000)
        }

        return nil
    }

    private func bestMatch(
        for target: AXWindowTarget,
        from snapshots: [AXWindowSnapshot]
    ) -> AXWindowSnapshot? {
        let scored = snapshots.compactMap { snapshot -> (AXWindowSnapshot, Int)? in
            matchScore(
                targetTitle: target.title,
                targetBounds: target.bounds,
                candidateTitle: snapshot.title,
                candidateBounds: snapshot.bounds
            ).map { (snapshot, $0) }
        }

        guard let bestScore = scored.map(\.1).min() else { return nil }
        let bestMatches = scored.filter { $0.1 == bestScore }
        guard bestMatches.count == 1 else { return nil }
        return bestMatches[0].0
    }

    private func matchScore(
        targetTitle: String?,
        targetBounds: CGRect?,
        candidateTitle: String?,
        candidateBounds: CGRect?
    ) -> Int? {
        var score = 0

        if let targetTitle {
            guard let candidateTitle else {
                return nil
            }

            let targetNormalized = normalizedTitle(targetTitle)
            let candidateNormalized = normalizedTitle(candidateTitle)

            if targetNormalized == candidateNormalized {
                score += 0
            } else if candidateNormalized.contains(targetNormalized) || targetNormalized.contains(candidateNormalized) {
                score += 25
            } else {
                return nil
            }
        }

        if let targetBounds, let candidateBounds {
            let delta = Int(
                abs(targetBounds.origin.x - candidateBounds.origin.x)
                + abs(targetBounds.origin.y - candidateBounds.origin.y)
                + abs(targetBounds.width - candidateBounds.width)
                + abs(targetBounds.height - candidateBounds.height)
            )
            return score + delta
        }

        if targetBounds != nil {
            return nil
        }

        return score
    }

    private func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
