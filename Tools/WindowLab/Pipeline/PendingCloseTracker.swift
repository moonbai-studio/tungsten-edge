import Foundation

final class PendingCloseTracker {
    private static let expirationWindow: TimeInterval = 2.0
    private var requestedAtByWindowID: [WindowID: Date] = [:]

    func track(windowID: WindowID, at timestamp: Date) {
        requestedAtByWindowID[windowID] = timestamp
    }

    func consumeClosedPending(windowID: WindowID, observation: SystemObservation) -> Bool {
        guard observation.kind == .disappeared,
              let requestedAt = requestedAtByWindowID[windowID],
              observation.timestamp.timeIntervalSince(requestedAt) <= Self.expirationWindow else {
            return false
        }

        requestedAtByWindowID.removeValue(forKey: windowID)
        return true
    }

    func expire(at timestamp: Date) {
        requestedAtByWindowID = requestedAtByWindowID.filter { _, requestedAt in
            timestamp.timeIntervalSince(requestedAt) <= Self.expirationWindow
        }
    }
}
