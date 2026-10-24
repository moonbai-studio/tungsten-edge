import Foundation

final class StripProjectionRegistry {
    struct Record {
        let projection: StripProjection
        let displayUUID: String?
    }

    static let shared = StripProjectionRegistry()
    private let lock = NSLock()
    private var records: [String: Record] = [:]

    func store(_ projection: StripProjection, surface: String, displayUUID: String?) {
        lock.lock()
        records[surface] = Record(projection: projection, displayUUID: displayUUID)
        lock.unlock()
    }

    func remove(surface: String) {
        lock.lock()
        records.removeValue(forKey: surface)
        lock.unlock()
    }

    func snapshot() -> [String: Record] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    static func exclusion(token: String, cgID: UInt32, bundleID: String?, in projection: StripProjection) -> String {
        if let bundleID, projection.drawerBundleIDs.contains(bundleID) { return "hiddenInDrawer" }
        if projection.messagingAbsorbedIDs.contains(token) { return "messagingAbsorbed" }
        if projection.trashAbsorbedIDs.contains(WindowID(rawValue: "cgw-\(cgID)")) { return "trashAbsorbed" }
        if projection.otherDisplayIDs.contains(token) { return "otherDisplay" }
        if projection.snapshotItems.contains(where: { $0.bundleIdentifier == bundleID && $0.isAppLevelFallback }) {
            return "appLevelFallback"
        }
        return "unknown"
    }
}
