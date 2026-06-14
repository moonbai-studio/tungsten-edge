import Foundation

/// Ordered list of「待启动」apps: the user registers a fixed launch slot for an app
/// WITHOUT moving it off the strip. While running, the app keeps its normal strip
/// chips and stays out of the drawer; once it quits, the drawer's 待启动区 shows a
/// launcher chip for it (方案 B 稳定排序: only currently-closed apps are listed, in
/// registration order, no holes).
///
/// Membership is mutually exclusive with DrawerStore (收纳) and MessagingAppStore
/// (消息类) — 2026-06-12 拍板「四者互斥」. The menu actions in `ChipView` enforce it
/// on write, and `AppDelegate` excludes launch favorites from messaging
/// auto-registration (explicit registration outranks auto detection).
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
