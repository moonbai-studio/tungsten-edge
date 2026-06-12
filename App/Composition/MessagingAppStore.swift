import Foundation

/// Persistent list of "messaging" apps that keep a pinned chip on the strip even
/// when their windows are closed (or the app is not running). Mirrors `DrawerStore`:
/// an ordered array (order is meaningful for the future strip drag-reorder) backed
/// by UserDefaults. Mutually exclusive with `DrawerStore` — enforced at the call
/// sites that mutate membership (mark-as-messaging removes from drawer, and vice versa).
final class MessagingAppStore: ObservableObject {
    @Published private(set) var bundleIDs: [String] = []
    private let key = "messagingBundleIDs"

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
