import Foundation

final class DrawerStore: ObservableObject {
    @Published private(set) var bundleIDs: [String] = []
    private let key = "drawerBundleIDs"

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
