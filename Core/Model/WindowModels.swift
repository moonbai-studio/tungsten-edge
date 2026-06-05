import Foundation
import CoreGraphics

struct WindowRecord: Hashable, Sendable {
    let id: WindowID
    let appID: AppID
    let pid: Int32
    let bundleIdentifier: String?
    var title: String
    var bounds: CGRect?
    var status: WindowStatus
    var cgWindowID: CGWindowID?
    var isOnDesktop: Bool

    init(
        id: WindowID,
        appID: AppID,
        pid: Int32,
        bundleIdentifier: String?,
        title: String,
        bounds: CGRect?,
        status: WindowStatus,
        cgWindowID: CGWindowID? = nil,
        isOnDesktop: Bool = false
    ) {
        self.id = id
        self.appID = appID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.bounds = bounds
        self.status = status
        self.cgWindowID = cgWindowID
        self.isOnDesktop = isOnDesktop
    }
}

enum WindowStatus: String, Hashable, Codable, Sendable {
    case active
    case inactive
    case minimized
    case hidden
    case closedPending
    case disappeared
}
