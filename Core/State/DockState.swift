import Foundation

struct DockSnapshot: Sendable {
    var windows: [WindowID: WindowRecord]
    var orderedWindowIDs: [WindowID]

    static let empty = DockSnapshot(windows: [:], orderedWindowIDs: [])
}

@MainActor
final class DockState {
    private(set) var snapshot: DockSnapshot = .empty

    func commit(_ update: StateUpdate) {
        var next = snapshot
        if let windowRecord = update.windowRecord {
            next.windows[windowRecord.id] = windowRecord
        } else {
            next.windows.removeValue(forKey: update.windowID)
        }
        next.orderedWindowIDs = update.orderedWindowIDs
        snapshot = next
    }
}
