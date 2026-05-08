import Foundation
import CoreGraphics

struct SystemObservation: Hashable, Sendable {
    let timestamp: Date
    let kind: ObservationKind
    let source: ObservationSource
    let pid: Int32
    let bundleIdentifier: String?
    let cgWindowID: UInt32?
    let title: String?
    let appName: String?
    let bounds: CGRect?
    let isMinimized: Bool
    let isFocusedWindow: Bool
    let isInventoryDegraded: Bool

    init(
        timestamp: Date,
        kind: ObservationKind,
        source: ObservationSource,
        pid: Int32,
        bundleIdentifier: String?,
        cgWindowID: UInt32?,
        title: String?,
        appName: String?,
        bounds: CGRect?,
        isMinimized: Bool,
        isFocusedWindow: Bool,
        isInventoryDegraded: Bool = false
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.source = source
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.cgWindowID = cgWindowID
        self.title = title
        self.appName = appName
        self.bounds = bounds
        self.isMinimized = isMinimized
        self.isFocusedWindow = isFocusedWindow
        self.isInventoryDegraded = isInventoryDegraded
    }

    enum ObservationSource: String, Hashable, Codable, Sendable {
        case coreGraphics
        case accessibility
        case appWindowInventory
    }

    enum ObservationKind: String, Hashable, Codable, Sendable {
        case appeared
        case disappeared
        case titleChanged
        case unchanged
        case minimized
        case restored
        case hidden
        case unhidden
    }
}

struct PlatformActionRequest: Hashable, Sendable {
    let kind: ActionKind
    let windowID: WindowID?

    enum ActionKind: String, Hashable, Codable, Sendable {
        case activateWindow
        case minimizeWindow
        case closeWindow
        case hideApp
    }
}
