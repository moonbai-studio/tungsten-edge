import Foundation

/// Ordered list of「待启动」apps: the user registers a fixed launch slot for an app
/// WITHOUT moving it off the strip. While running, the app keeps its normal strip
/// chips and stays out of the drawer; once it quits, the drawer's 待启动区 shows a
/// launcher chip for it (方案 B 稳定排序: only currently-closed apps are listed, in
/// registration order, no holes).
///
/// Coexists with DrawerStore (收纳) since 2026-06-16 — no longer forced mutually
/// exclusive (reversed from the original 「四者互斥」: pinning a drawer app used to
/// bounce it back onto the main strip, fighting the point of stashing it). Note:
/// 收进抽屉 still clears this store on that path (see `DockStripView`), so the two
/// only coexist via pin-then-stash, not stash-then-pin. Still mutually exclusive
/// with MessagingAppStore (消息类) — `AppDelegate` excludes favorites from messaging
/// auto-registration, and `ChipView`'s menu actions clear the messaging flag on pin.
///
/// `bundleIDs` stays an ordered array (same shape as `DrawerStore`): registration
/// order is the zone's muscle-memory order, and future drag-reorder reorders it.
@MainActor
final class LaunchFavoriteStore: ObservableObject {
    @Published private(set) var bundleIDs: [String] = []
    private let key = "launchFavoriteBundleIDs"

    init() {
        bundleIDs = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func contains(_ id: String) -> Bool { bundleIDs.contains(id) }

    func add(_ id: String) {
        guard !id.isEmpty, !bundleIDs.contains(id) else { return }
        bundleIDs.append(id)
        persist()
    }

    func remove(_ id: String) {
        bundleIDs.removeAll { $0 == id }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(bundleIDs, forKey: key)
    }
}
