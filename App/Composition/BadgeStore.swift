import Foundation
import os

/// Publishes [bundleID: badge text] read from the system Dock (see DockBadgeReader).
/// Polls every 0.5s off the main thread (one tiny AX walk; clearing an unread badge
/// must feel immediate). Publishes only on change so SwiftUI doesn't re-render chips
/// for identical badge state. Consumed by the strip's messaging chips (product
/// decision 2026-06-12: badges on messaging chips only).
@MainActor
final class BadgeStore: ObservableObject {
    @Published private(set) var badgesByBundleID: [String: String] = [:]

    private let reader = DockBadgeReader()
    private var timer: Timer?
    private var isReading = false
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "Badge")

    func start() {
        guard timer == nil else { return }
        readOnce()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.readOnce() }
        }
        timer?.tolerance = 0.05
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    private func readOnce() {
        guard !isReading else { return }   // serialize: skip a tick if the last read is still running
        isReading = true
        let reader = reader
        Task.detached { [weak self] in
            let badges = reader.readBadges()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isReading = false
                if badges != self.badgesByBundleID {
                    self.badgesByBundleID = badges
                    // Diagnostic: full badge dict as read from the Dock, logged on change only.
                    self.logger.info("badges-changed \(badges.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "), privacy: .public)")
                }
            }
        }
    }
}
