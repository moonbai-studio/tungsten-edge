import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import OSLog

struct FinderWindowReference: Sendable {
    let pid: Int32
    let cgWindowID: CGWindowID?
    let title: String
    let bounds: CGRect?
}

enum FinderWindowContentsTarget: Sendable {
    case folderURL(URL)
    case appleEvents(FinderWindowAppleEventsTarget)
}

enum FinderWindowContentsError: LocalizedError, Sendable {
    case missingAccessibilityPermission
    case missingFinderProcess
    case missingWindowID
    case windowNotFound
    case unsupportedWindow
    case automationPermissionRequired
    case temporarilyUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAccessibilityPermission:
            return String(localized: "Accessibility permission required")
        case .missingFinderProcess:
            return String(localized: "Finder is temporarily unavailable")
        case .missingWindowID, .windowNotFound:
            return String(localized: "Can’t locate this Finder window")
        case .unsupportedWindow:
            return String(localized: "This Finder window isn’t supported")
        case .automationPermissionRequired:
            return String(localized: "Permission to control Finder is required")
        case .temporarilyUnavailable:
            return String(localized: "Timed out while reading")
        }
    }
}

/// 访达窗口路径反查的 **I/O 层**：AX 窗口定位 + 权限流 + AppleScript 执行。
/// 纯匹配/解析逻辑在 `FinderAppleEventMatcher`（可纯单测）。
struct FinderWindowContentsReader {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.caye.macosdockcc.v2",
        category: "FinderContents"
    )

    private let axReader = AXWindowReader()

    @MainActor
    func target(for reference: FinderWindowReference, requestID: String? = nil) throws -> FinderWindowContentsTarget {
        let requestID = requestID ?? "none"
        Self.logger.info("target-start request=\(requestID, privacy: .public) pid=\(reference.pid, privacy: .public) cgWindowID=\(reference.cgWindowID.map(String.init) ?? "nil", privacy: .public)")
        guard AXIsProcessTrusted() else {
            Self.logger.error("target-failed request=\(requestID, privacy: .public) reason=missing-accessibility-permission")
            throw FinderWindowContentsError.missingAccessibilityPermission
        }
        guard reference.pid > 0,
              NSRunningApplication(processIdentifier: reference.pid)?.bundleIdentifier == FinderWindowRules.bundleIdentifier else {
            Self.logger.error("target-failed request=\(requestID, privacy: .public) reason=missing-finder-process")
            throw FinderWindowContentsError.missingFinderProcess
        }
        guard let cgWindowID = reference.cgWindowID else {
            Self.logger.error("target-failed request=\(requestID, privacy: .public) reason=missing-window-id")
            throw FinderWindowContentsError.missingWindowID
        }

        let axStart = CFAbsoluteTimeGetCurrent()
        let windows = finderAXWindows(pid: reference.pid, requestID: requestID)
        Self.logger.info("ax-end request=\(requestID, privacy: .public) elapsedMS=\(Self.elapsedMS(since: axStart), privacy: .public) windowCount=\(windows.count, privacy: .public)")
        guard let targetWindow = windows.first(where: { $0.cgWindowID == cgWindowID }) else {
            Self.logger.error("target-failed request=\(requestID, privacy: .public) reason=ax-window-not-found targetCgWindowID=\(cgWindowID, privacy: .public)")
            throw FinderWindowContentsError.windowNotFound
        }

        let documentStart = CFAbsoluteTimeGetCurrent()
        if let documentURL = fileDirectoryURL(from: targetWindow.element, attribute: kAXDocumentAttribute as CFString, label: "document", requestID: requestID) {
            Self.logger.info("document-url-succeeded request=\(requestID, privacy: .public) elapsedMS=\(Self.elapsedMS(since: documentStart), privacy: .public) path=\(documentURL.path, privacy: .public)")
            return .folderURL(documentURL)
        }
        Self.logger.info("document-url-unavailable request=\(requestID, privacy: .public) elapsedMS=\(Self.elapsedMS(since: documentStart), privacy: .public)")

        let axURLStart = CFAbsoluteTimeGetCurrent()
        if let axURL = fileDirectoryURL(from: targetWindow.element, attribute: kAXURLAttribute as CFString, label: "ax-url", requestID: requestID) {
            Self.logger.info("ax-url-succeeded request=\(requestID, privacy: .public) elapsedMS=\(Self.elapsedMS(since: axURLStart), privacy: .public) path=\(axURL.path, privacy: .public)")
            return .folderURL(axURL)
        }
        Self.logger.info("ax-url-unavailable request=\(requestID, privacy: .public) elapsedMS=\(Self.elapsedMS(since: axURLStart), privacy: .public)")

        let automationStart = CFAbsoluteTimeGetCurrent()
        let automationStatus = Self.finderAutomationPermissionStatus(askUserIfNeeded: false)
        Self.logger.info("automation-preflight request=\(requestID, privacy: .public) elapsedMS=\(Self.elapsedMS(since: automationStart), privacy: .public) status=\(automationStatus, privacy: .public)")
        guard automationStatus == noErr else {
            throw FinderWindowContentsError.automationPermissionRequired
        }

        Self.logger.info("target-kind request=\(requestID, privacy: .public) kind=apple-events-fallback title=\(targetWindow.title, privacy: .public)")
        return .appleEvents(
            FinderWindowAppleEventsTarget(
                title: targetWindow.title,
                cocoaFrame: targetWindow.cocoaFrame
            )
        )
    }

    static func folderURLViaAppleEvents(for target: FinderWindowAppleEventsTarget, requestID: String? = nil) throws -> URL {
        let requestID = requestID ?? "none"
        let finderWindows = readFinderWindowsViaAppleEvents(requestID: requestID)
        let matched = FinderAppleEventMatcher.matchAppleEventWindow(target: target, candidates: finderWindows, requestID: requestID)
        guard let matched else {
            logger.error("ae-failed request=\(requestID, privacy: .public) reason=no-unique-match candidateCount=\(finderWindows.count, privacy: .public)")
            throw FinderWindowContentsError.unsupportedWindow
        }
        logger.info("ae-match-succeeded request=\(requestID, privacy: .public) path=\(matched.url.path, privacy: .public)")
        return matched.url
    }

    static func requestFinderAutomationPermission(requestID: String? = nil) -> Bool {
        let requestID = requestID ?? "none"
        let start = CFAbsoluteTimeGetCurrent()
        let status = finderAutomationPermissionStatus(askUserIfNeeded: true)
        logger.info("automation-request request=\(requestID, privacy: .public) elapsedMS=\(elapsedMS(since: start), privacy: .public) status=\(status, privacy: .public)")
        return status == noErr
    }

    private func finderAXWindows(pid: pid_t, requestID: String) -> [AXFinderWindow] {
        Self.logger.info("ax-start request=\(requestID, privacy: .public) pid=\(pid, privacy: .public)")
        switch axReader.inventoryWindows(forPID: pid, messagingTimeout: 0.35) {
        case let .success(windows):
            let trackable: [AXFinderWindow] = windows.compactMap { snapshot -> AXFinderWindow? in
                guard let cgWindowID = snapshot.cgWindowID,
                      let title = snapshot.title,
                      let bounds = snapshot.bounds,
                      FinderWindowRules.isTrackable(
                        title: snapshot.title,
                        role: snapshot.role,
                        subrole: snapshot.subrole,
                        bounds: snapshot.bounds
                      ) else {
                    return nil
                }
                return AXFinderWindow(
                    cgWindowID: CGWindowID(cgWindowID),
                    title: title,
                    cocoaFrame: bounds,
                    element: snapshot.element
                )
            }
            Self.logger.info("ax-filtered request=\(requestID, privacy: .public) rawCount=\(windows.count, privacy: .public) trackableCount=\(trackable.count, privacy: .public)")
            return trackable
        case .unread:
            Self.logger.error("ax-unread request=\(requestID, privacy: .public) pid=\(pid, privacy: .public)")
            return []
        }
    }

    private func fileDirectoryURL(from element: AXUIElement, attribute: CFString, label: String, requestID: String) -> URL? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let value else {
            Self.logger.info("ax-url-raw request=\(requestID, privacy: .public) label=\(label, privacy: .public) status=\(status.rawValue, privacy: .public) valueType=nil")
            return nil
        }

        let url = Self.url(fromAXValue: value)
        let rawURL = url
        let validURL = rawURL.flatMap(FinderAppleEventMatcher.validDirectoryURL)
        Self.logger.info("ax-url-raw request=\(requestID, privacy: .public) label=\(label, privacy: .public) status=\(status.rawValue, privacy: .public) isFileURL=\((rawURL?.isFileURL ?? false), privacy: .public) validDirectory=\((validURL != nil), privacy: .public) raw=\(rawURL?.absoluteString ?? "nil", privacy: .public)")
        return validURL
    }

    private static func url(fromAXValue value: CFTypeRef) -> URL? {
        if let raw = value as? URL {
            return raw
        }
        if let raw = value as? NSURL {
            return raw as URL
        }
        if let raw = value as? String {
            return FinderAppleEventMatcher.fileURL(fromAppleEventValue: raw)
        }
        return nil
    }

    private static func readFinderWindowsViaAppleEvents(requestID: String) -> [AEFinderWindow] {
        let script = FinderAppleEventMatcher.appleEventWindowListingScript()
        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error),
              let output = descriptor.stringValue else {
            logger.error("ae-script-failed request=\(requestID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return []
        }
        let parseResult = FinderAppleEventMatcher.parseAppleEventWindowOutput(output)
        logger.info("ae-script-succeeded request=\(requestID, privacy: .public) rawLineCount=\(parseResult.rawLineCount, privacy: .public) validURLCount=\(parseResult.validURLCount, privacy: .public) validWindowCount=\(parseResult.windows.count, privacy: .public) firstError=\(parseResult.firstErrorSummary ?? "none", privacy: .public)")
        return parseResult.windows
    }

    private static func finderAutomationPermissionStatus(askUserIfNeeded: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let bundleID = FinderWindowRules.bundleIdentifier
        let status = bundleID.withCString { pointer -> OSStatus in
            OSStatus(AECreateDesc(
                typeApplicationBundleID,
                pointer,
                bundleID.utf8.count,
                &target
            ))
        }
        guard status == noErr else { return status }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target,
            typeWildCard,
            typeWildCard,
            askUserIfNeeded
        )
    }

    private static func elapsedMS(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}

private struct AXFinderWindow {
    let cgWindowID: CGWindowID
    let title: String
    let cocoaFrame: CGRect
    let element: AXUIElement
}
