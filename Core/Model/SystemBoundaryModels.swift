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

    enum ObservationSource: String, Hashable, Codable, Sendable {
        case coreGraphics
        case accessibility
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
