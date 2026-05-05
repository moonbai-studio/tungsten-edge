import AppKit
import ApplicationServices
import Foundation

final class AccessibilitySource {
    private let startupScanLimit = 6
    private let steadyStateScanLimit = 12
    private var observeRounds = 0
    private var previousWindowKindsBySignature: [String: SystemObservation.ObservationKind] = [:]
    private var previousHiddenSignatures: Set<String> = []

    func observe() -> [SystemObservation] {
        guard AXIsProcessTrusted() else { return [] }
        let now = Date()
        observeRounds += 1
        let scanLimit = observeRounds <= 2 ? startupScanLimit : steadyStateScanLimit

        let apps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy != .prohibited
        }
        .prefix(scanLimit)

        var observations: [SystemObservation] = []
        var currentHiddenSignatures: Set<String> = []

        for app in apps {
            let appObservations = observeWindows(for: app, now: now)
            observations.append(contentsOf: appObservations)

            for observation in appObservations {
                if observation.kind == .hidden {
                    currentHiddenSignatures.insert(observationSignature(observation))
                }
            }
        }

        previousWindowKindsBySignature = Dictionary(
            uniqueKeysWithValues: observations.map { (observationSignature($0), $0.kind) }
        )
        previousHiddenSignatures = currentHiddenSignatures
        return observations
    }

    private func observeWindows(for app: NSRunningApplication, now: Date) -> [SystemObservation] {
        let elements = windows(for: app.processIdentifier)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedElement = axElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement)
        let isAppHidden = app.isHidden

        return elements.compactMap { element in
            let title = axStringAttribute(kAXTitleAttribute as CFString, from: element)
            guard title != nil else { return nil }
            let isMinimized = axBoolAttribute(kAXMinimizedAttribute as CFString, from: element) ?? false
            let bounds = axFrame(of: element)
            let isFocusedWindow = focusedElement.map { CFEqual($0, element) } ?? false
            let baseObservation = SystemObservation(
                timestamp: now,
                kind: .unchanged,
                source: .accessibility,
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                cgWindowID: nil,
                title: title,
                appName: app.localizedName,
                bounds: bounds,
                isMinimized: isMinimized,
                isFocusedWindow: isFocusedWindow
            )
            let signature = observationSignature(baseObservation)
            let previousKind = previousWindowKindsBySignature[signature]
            let wasHidden = previousHiddenSignatures.contains(signature)
            let kind: SystemObservation.ObservationKind

            if isMinimized {
                kind = .minimized
            } else if isAppHidden {
                kind = .hidden
            } else if wasHidden || previousKind == .hidden {
                kind = .unhidden
            } else {
                kind = .unchanged
            }

            return SystemObservation(
                timestamp: now,
                kind: kind,
                source: .accessibility,
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                cgWindowID: nil,
                title: title,
                appName: app.localizedName,
                bounds: bounds,
                isMinimized: isMinimized,
                isFocusedWindow: isFocusedWindow
            )
        }
    }

    private func observationSignature(_ observation: SystemObservation) -> String {
        let title = observation.title?.lowercased() ?? "<untitled>"
        let frame = observation.bounds.map {
            "\($0.origin.x.rounded()):\($0.origin.y.rounded()):\($0.width.rounded()):\($0.height.rounded())"
        } ?? "<unknown>"
        return "\(observation.pid)|\(title)|\(frame)"
    }
}

struct AccessibilityWindowActionExecutor {
    struct ActionExecution {
        let success: Bool
        let mechanism: String
        let verifiedMinimized: Bool?
    }

    struct WindowTarget {
        let pid: Int32
        let title: String?
        let bounds: CGRect?
    }

    struct WindowHandle {
        let pid: Int32
        let title: String?
        let bounds: CGRect?
        fileprivate let element: AXUIElement
    }

    func captureHandle(for target: WindowTarget) -> WindowHandle? {
        guard AXIsProcessTrusted() else { return nil }

        let candidates = windows(for: target.pid)
        guard let element = bestMatch(for: target, from: candidates) else { return nil }
        return WindowHandle(
            pid: target.pid,
            title: axStringAttribute(kAXTitleAttribute as CFString, from: element),
            bounds: axFrame(of: element),
            element: element
        )
    }

    func minimize(_ handle: WindowHandle) -> ActionExecution {
        if setMinimized(true, for: handle) {
            let verified = axBoolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            if verified == true {
                return ActionExecution(
                    success: true,
                    mechanism: "set-minimized-attribute",
                    verifiedMinimized: verified
                )
            }
        }

        guard let button = axElementAttribute(kAXMinimizeButtonAttribute as CFString, from: handle.element) else {
            return ActionExecution(
                success: false,
                mechanism: "missing-minimize-button",
                verifiedMinimized: axBoolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            )
        }

        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            return ActionExecution(
                success: false,
                mechanism: "press-minimize-button-failed",
                verifiedMinimized: axBoolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            )
        }

        usleep(150_000)
        let verified = axBoolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
        return ActionExecution(
            success: verified == true,
            mechanism: "press-minimize-button",
            verifiedMinimized: verified
        )
    }

    func restore(_ handle: WindowHandle) -> ActionExecution {
        if setMinimized(false, for: handle) {
            _ = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
            let verified = axBoolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            return ActionExecution(
                success: verified == false,
                mechanism: "clear-minimized-attribute",
                verifiedMinimized: verified
            )
        }

        guard let rebound = recapture(from: handle) else {
            return ActionExecution(
                success: false,
                mechanism: "recapture-for-restore-failed",
                verifiedMinimized: nil
            )
        }
        guard setMinimized(false, for: rebound) else {
            return ActionExecution(
                success: false,
                mechanism: "clear-minimized-after-recapture-failed",
                verifiedMinimized: axBoolAttribute(kAXMinimizedAttribute as CFString, from: rebound.element)
            )
        }
        _ = AXUIElementPerformAction(rebound.element, kAXRaiseAction as CFString)
        let verified = axBoolAttribute(kAXMinimizedAttribute as CFString, from: rebound.element)
        return ActionExecution(
            success: verified == false,
            mechanism: "clear-minimized-after-recapture",
            verifiedMinimized: verified
        )
    }

    func activate(_ handle: WindowHandle) -> Bool {
        let runningApp = NSRunningApplication(processIdentifier: handle.pid)
        if let minimized = axBoolAttribute(kAXMinimizedAttribute as CFString, from: handle.element),
           minimized {
            _ = setMinimized(false, for: handle)
            let activated = runningApp?.activate(options: [.activateIgnoringOtherApps]) ?? false
            if activated {
                return true
            }
        }

        if runningApp?.isActive == true {
            return AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString) == .success
        }

        let appActivated = runningApp?.activate(options: [.activateIgnoringOtherApps]) ?? false
        guard appActivated else {
            return AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString) == .success
        }

        usleep(120_000)
        if let focusedWindow = axElementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: AXUIElementCreateApplication(handle.pid)
        ),
           CFEqual(focusedWindow, handle.element) {
            return true
        }

        return AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString) == .success
    }

    func close(_ handle: WindowHandle) -> Bool {
        guard let button = axElementAttribute(kAXCloseButtonAttribute as CFString, from: handle.element) else {
            return false
        }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private func recapture(from handle: WindowHandle) -> WindowHandle? {
        captureHandle(
            for: WindowTarget(
                pid: handle.pid,
                title: handle.title,
                bounds: handle.bounds
            )
        )
    }

    private func setMinimized(_ minimized: Bool, for handle: WindowHandle) -> Bool {
        let value: CFTypeRef = minimized ? kCFBooleanTrue : kCFBooleanFalse
        let result = AXUIElementSetAttributeValue(
            handle.element,
            kAXMinimizedAttribute as CFString,
            value
        )
        return result == .success
    }

    private func bestMatch(for target: WindowTarget, from elements: [AXUIElement]) -> AXUIElement? {
        let scored = elements.compactMap { element -> (AXUIElement, Int)? in
            let title = axStringAttribute(kAXTitleAttribute as CFString, from: element)
            let bounds = axFrame(of: element)
            let score = matchScore(
                targetTitle: target.title,
                targetBounds: target.bounds,
                candidateTitle: title,
                candidateBounds: bounds
            )
            return score.map { (element, $0) }
        }

        return scored.min(by: { $0.1 < $1.1 })?.0
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
                score += 500
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

struct PlatformActionExecutor {
    private let windowExecutor = AccessibilityWindowActionExecutor()

    @discardableResult
    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot) -> Bool {
        guard let windowID = request.windowID,
              let record = snapshot.windows[windowID] else {
            return false
        }

        if record.id.rawValue.hasPrefix("app-") {
            return executeAppFallback(request: request, record: record)
        }

        let target = AccessibilityWindowActionExecutor.WindowTarget(
            pid: record.pid,
            title: record.title,
            bounds: record.bounds
        )
        guard let handle = windowExecutor.captureHandle(for: target) else {
            return executeAppFallback(request: request, record: record)
        }

        switch request.kind {
        case .activateWindow:
            return windowExecutor.activate(handle)
        case .minimizeWindow:
            return windowExecutor.minimize(handle).success
        case .closeWindow:
            return windowExecutor.close(handle)
        case .hideApp:
            return executeAppFallback(request: request, record: record)
        }
    }

    private func executeAppFallback(request: PlatformActionRequest, record: WindowRecord) -> Bool {
        let runningApp = NSRunningApplication(processIdentifier: record.pid)

        switch request.kind {
        case .activateWindow:
            return runningApp?.activate(options: []) ?? false
        case .minimizeWindow, .hideApp:
            return runningApp?.hide() ?? false
        case .closeWindow:
            return false
        }
    }
}

private func windows(for pid: pid_t) -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(pid)
    guard let value = axCopyAttributeValue(kAXWindowsAttribute as CFString, from: appElement),
          let elements = value as? [AXUIElement] else {
        return []
    }
    return elements
}

private func axStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
    guard let value = axCopyAttributeValue(attribute, from: element),
          let text = value as? String else {
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func axBoolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
    guard let value = axCopyAttributeValue(attribute, from: element),
          let number = value as? NSNumber else {
        return nil
    }
    return number.boolValue
}

private func axElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
    guard let value = axCopyAttributeValue(attribute, from: element) else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func axFrame(of element: AXUIElement) -> CGRect? {
    guard let positionAX = axCopyAttributeValue(kAXPositionAttribute as CFString, from: element),
          let sizeAX = axCopyAttributeValue(kAXSizeAttribute as CFString, from: element) else {
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

private func axCopyAttributeValue(
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
