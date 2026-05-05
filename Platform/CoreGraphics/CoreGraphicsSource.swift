import AppKit
import CoreGraphics
import Foundation

struct CoreGraphicsSource {
    private var previousWindowsByID: [UInt32: CGWindowSnapshot] = [:]

    mutating func observe() -> [SystemObservation] {
        let now = Date()
        let currentWindows = currentSnapshots()
        let currentByID = Dictionary(uniqueKeysWithValues: currentWindows.map { ($0.cgWindowID, $0) })

        var events: [SystemObservation] = []

        for window in currentWindows {
            let kind: SystemObservation.ObservationKind
            if let previous = previousWindowsByID[window.cgWindowID] {
                if previous.title != window.title {
                    kind = .titleChanged
                } else {
                    kind = .unchanged
                }
            } else {
                kind = .appeared
            }

            events.append(
                SystemObservation(
                    timestamp: now,
                    kind: kind,
                    source: .coreGraphics,
                    pid: window.pid,
                    bundleIdentifier: window.bundleIdentifier,
                    cgWindowID: window.cgWindowID,
                    title: window.title,
                    appName: window.appName,
                    bounds: window.bounds
                    ,
                    isMinimized: false,
                    isFocusedWindow: false
                )
            )
        }

        for previous in previousWindowsByID.values where currentByID[previous.cgWindowID] == nil {
            events.append(
                SystemObservation(
                    timestamp: now,
                    kind: .disappeared,
                    source: .coreGraphics,
                    pid: previous.pid,
                    bundleIdentifier: previous.bundleIdentifier,
                    cgWindowID: previous.cgWindowID,
                    title: previous.title,
                    appName: previous.appName,
                    bounds: previous.bounds
                    ,
                    isMinimized: false,
                    isFocusedWindow: false
                )
            )
        }

        previousWindowsByID = currentByID

        return events.sorted { lhs, rhs in
            let lhsID = lhs.cgWindowID ?? 0
            let rhsID = rhs.cgWindowID ?? 0
            if lhsID != rhsID {
                return lhsID < rhsID
            }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private func currentSnapshots() -> [CGWindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        return rawList.compactMap { info -> CGWindowSnapshot? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            guard let cgWindowID = info[kCGWindowNumber as String] as? UInt32 else { return nil }
            guard let appName = info[kCGWindowOwnerName as String] as? String,
                  !appName.isEmpty else { return nil }

            let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap {
                CGRect(dictionaryRepresentation: $0 as CFDictionary)
            }
            if let bounds, (bounds.width < 40 || bounds.height < 40) {
                return nil
            }

            let title = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return CGWindowSnapshot(
                cgWindowID: cgWindowID,
                pid: pid,
                bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                appName: appName,
                title: (title?.isEmpty == false) ? title : nil,
                bounds: bounds
            )
        }
    }
}

private struct CGWindowSnapshot: Hashable {
    let cgWindowID: UInt32
    let pid: pid_t
    let bundleIdentifier: String?
    let appName: String
    let title: String?
    let bounds: CGRect?
}
