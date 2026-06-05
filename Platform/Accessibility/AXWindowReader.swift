import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct AXWindowSnapshot {
    let pid: Int32
    let cgWindowID: UInt32?
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

enum AXWindowReadResult {
    case success([AXWindowSnapshot])
    case unread(AXError)
}

struct AXWindowReader {
    func windows(for app: NSRunningApplication) -> [AXWindowSnapshot] {
        windows(forPID: app.processIdentifier)
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] {
        switch readWindows(forPID: pid, messagingTimeout: nil) {
        case let .success(windows):
            return windows
        case .unread:
            return []
        }
    }

    func inventoryWindows(for app: NSRunningApplication, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        readWindows(forPID: app.processIdentifier, messagingTimeout: messagingTimeout)
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        readWindows(forPID: pid, messagingTimeout: messagingTimeout)
    }

    private func readWindows(forPID pid: pid_t, messagingTimeout: TimeInterval?) -> AXWindowReadResult {
        let appElement = AXUIElementCreateApplication(pid)
        applyMessagingTimeout(messagingTimeout, to: appElement)

        var rawWindows: CFTypeRef?
        let maxAttempts = messagingTimeout == nil ? 2 : 1
        let result = copyAttributeValue(
            kAXWindowsAttribute as CFString,
            from: appElement,
            into: &rawWindows,
            maxAttempts: maxAttempts
        )
        guard result == .success, let elements = rawWindows as? [AXUIElement] else {
            return .unread(result)
        }

        let focusedElement = elementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement)
        return .success(elements.map { element in
            applyMessagingTimeout(messagingTimeout, to: element)
            return AXWindowSnapshot(
                pid: pid,
                cgWindowID: cgWindowID(for: element, maxAttempts: maxAttempts),
                title: stringAttribute(kAXTitleAttribute as CFString, from: element, maxAttempts: maxAttempts),
                bounds: frame(of: element, maxAttempts: maxAttempts),
                role: stringAttribute(kAXRoleAttribute as CFString, from: element, maxAttempts: maxAttempts),
                subrole: stringAttribute(kAXSubroleAttribute as CFString, from: element, maxAttempts: maxAttempts),
                isMinimized: boolAttribute(kAXMinimizedAttribute as CFString, from: element, maxAttempts: maxAttempts) ?? false,
                isFocusedWindow: focusedElement.map { CFEqual($0, element) } ?? false,
                element: element
            )
        })
    }

    func captureHandle(
        for target: AXWindowTarget,
        attempts: Int = 1,
        retryIntervalMicroseconds: useconds_t = 0,
        messagingTimeout: TimeInterval? = nil
    ) -> AXWindowHandle? {
        guard AXIsProcessTrusted() else { return nil }
        let boundedAttempts = max(1, attempts)

        for attempt in 0..<boundedAttempts {
            let candidates: [AXWindowSnapshot]
            if let timeout = messagingTimeout {
                switch inventoryWindows(forPID: target.pid, messagingTimeout: timeout) {
                case .success(let s): candidates = s
                case .unread: candidates = []
                }
            } else {
                candidates = windows(forPID: target.pid)
            }
            if let snapshot = bestMatch(for: target, from: candidates) {
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

    func stringAttribute(_ attribute: CFString, from element: AXUIElement, maxAttempts: Int = 2) -> String? {
        guard let value = copyAttributeValue(attribute, from: element, maxAttempts: maxAttempts),
              let text = value as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func boolAttribute(_ attribute: CFString, from element: AXUIElement, maxAttempts: Int = 2) -> Bool? {
        guard let value = copyAttributeValue(attribute, from: element, maxAttempts: maxAttempts),
              let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    static func cgWindowID(for element: AXUIElement) -> CGWindowID? {
        AXWindowIDBridge.cgWindowID(for: element)
    }

    func cgWindowID(for element: AXUIElement, maxAttempts: Int = 2) -> UInt32? {
        if let bridgedID = AXWindowIDBridge.cgWindowID(for: element) {
            return bridgedID
        }

        for attribute in AXWindowIDBridge.fallbackAttributeNames {
            if let id = numericWindowIDAttribute(attribute, from: element, maxAttempts: maxAttempts) {
                return id
            }
        }

        return nil
    }

    func elementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttributeValue(attribute, from: element) else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    func frame(of element: AXUIElement, maxAttempts: Int = 2) -> CGRect? {
        guard let positionAX = copyAttributeValue(kAXPositionAttribute as CFString, from: element, maxAttempts: maxAttempts),
              let sizeAX = copyAttributeValue(kAXSizeAttribute as CFString, from: element, maxAttempts: maxAttempts) else {
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
        var value: CFTypeRef?
        let result = copyAttributeValue(attribute, from: element, into: &value, maxAttempts: maxAttempts)
        return result == .success ? value : nil
    }

    @discardableResult
    func copyAttributeValue(
        _ attribute: CFString,
        from element: AXUIElement,
        into value: inout CFTypeRef?,
        maxAttempts: Int = 2
    ) -> AXError {
        var attempt = 0
        var lastResult: AXError = .failure
        while attempt < maxAttempts {
            let result = AXUIElementCopyAttributeValue(element, attribute, &value)
            if result == .success {
                return result
            }

            lastResult = result
            if result != .cannotComplete {
                return result
            }

            attempt += 1
        }

        return lastResult
    }

    private func numericWindowIDAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        maxAttempts: Int
    ) -> UInt32? {
        guard let value = copyAttributeValue(attribute, from: element, maxAttempts: maxAttempts) else {
            return nil
        }
        return AXWindowIDBridge.cgWindowID(from: value)
    }

    private func applyMessagingTimeout(_ timeout: TimeInterval?, to element: AXUIElement) {
        guard let timeout else { return }
        _ = AXUIElementSetMessagingTimeout(element, Float(timeout))
    }

    private func bestMatch(
        for target: AXWindowTarget,
        from snapshots: [AXWindowSnapshot]
    ) -> AXWindowSnapshot? {
        let scored = snapshots.compactMap { snapshot -> (AXWindowSnapshot, Int)? in
            AXWindowMatchPolicy.matchScore(
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

}

private enum AXWindowIDBridge {
    typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let fallbackAttributeNames: [CFString] = [
        "AXWindowID" as CFString,
        "AXWindowNumber" as CFString
    ]

    private static let getWindowFunction: GetWindowFunction? = {
        let frameworkPaths = [
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        ]
        let symbolNames = [
            "_AXUIElementGetWindow",
            "AXUIElementGetWindow"
        ]

        for path in frameworkPaths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            for symbolName in symbolNames {
                if let symbol = dlsym(handle, symbolName) {
                    return unsafeBitCast(symbol, to: GetWindowFunction.self)
                }
            }
        }

        return nil
    }()

    static func cgWindowID(for element: AXUIElement) -> UInt32? {
        guard let getWindowFunction else { return nil }

        var windowID = CGWindowID(0)
        guard getWindowFunction(element, &windowID) == .success else {
            return nil
        }
        return windowID == 0 ? nil : UInt32(windowID)
    }

    static func cgWindowID(from value: CFTypeRef) -> UInt32? {
        if let number = value as? NSNumber {
            let id = number.uint32Value
            return id == 0 ? nil : id
        }

        if let string = value as? String,
           let id = UInt32(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id == 0 ? nil : id
        }

        return nil
    }
}
