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
    /// 乐观态说该窗口已最小化：既不能提前聚焦（order-out 窗口切前台会顶起可见兄弟，
    /// Docs/22 §13），又必须无条件先提交恢复——同步 AX 读回可能还没翻面（异步最小化的
    /// App，或最小化刚提交、快照未兑现的连点）。两件事同源，共用一个标志。
    let forceRestoreBeforeFocus: Bool

    init(kind: ActionKind, windowID: WindowID?, forceRestoreBeforeFocus: Bool = false) {
        self.kind = kind
        self.windowID = windowID
        self.forceRestoreBeforeFocus = forceRestoreBeforeFocus
    }

    enum ActionKind: String, Hashable, Codable, Sendable {
        case activateWindow
        case minimizeWindow
        case closeWindow
        case hideApp
        case quitApp
        case newWindow
    }
}
