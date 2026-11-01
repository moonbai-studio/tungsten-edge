import Combine
import Darwin
import Foundation

struct AppIconStamp: Equatable, Sendable {
    let bundleInode: UInt64
    let bundleChangeSeconds: Int
    let bundleChangeNanoseconds: Int
    let infoPlistExists: Bool
    let infoPlistInode: UInt64
    let infoPlistModificationSeconds: Int
    let infoPlistModificationNanoseconds: Int

    static func stamp(atPath path: String) -> AppIconStamp? {
        var bundle = stat()
        guard stat(path, &bundle) == 0 else { return nil }
        var infoPlist = stat()
        let infoPlistExists = stat(path + "/Contents/Info.plist", &infoPlist) == 0
        return AppIconStamp(
            bundleInode: bundle.st_ino,
            bundleChangeSeconds: bundle.st_ctimespec.tv_sec,
            bundleChangeNanoseconds: bundle.st_ctimespec.tv_nsec,
            infoPlistExists: infoPlistExists,
            infoPlistInode: infoPlistExists ? infoPlist.st_ino : 0,
            infoPlistModificationSeconds: infoPlistExists ? infoPlist.st_mtimespec.tv_sec : 0,
            infoPlistModificationNanoseconds: infoPlistExists ? infoPlist.st_mtimespec.tv_nsec : 0
        )
    }
}

@MainActor
final class AppIconRevision: ObservableObject {
    static let shared = AppIconRevision()
    @Published private(set) var revision: Int = 0

    private init() {}

    func advance() {
        revision += 1
    }
}

/// Runs on app activation only, never on a timer or inside the 5s inventory poll (`Docs/26`).
@MainActor
final class AppIconFreshnessChecker {
    struct Entry: Sendable {
        /// Who owns the path: a bundle id in `AppIconResolver`, a pinned folder in `PinnedFolderCoverStore`.
        let key: String
        let path: String
        let stamp: AppIconStamp?
    }

    /// `stat` stays off the main thread: an app on an unresponsive network volume blocks it.
    private let queue = DispatchQueue(label: "com.caye.macosdockcc.v2.app-icon-freshness", qos: .utility)
    private let snapshot: @MainActor () -> [Entry]
    private let didCheck: @MainActor ([Entry]) -> Void
    private var isChecking = false
    private var needsAnotherCheck = false

    init(snapshot: @escaping @MainActor () -> [Entry],
         didCheck: @escaping @MainActor ([Entry]) -> Void) {
        self.snapshot = snapshot
        self.didCheck = didCheck
    }

    func requestCheck() {
        guard !isChecking else {
            needsAnotherCheck = true
            return
        }
        let entries = snapshot()
        guard !entries.isEmpty else { return }
        isChecking = true
        queue.async {
            let checked = entries.map {
                Entry(key: $0.key, path: $0.path, stamp: AppIconStamp.stamp(atPath: $0.path))
            }
            DispatchQueue.main.async {
                self.didCheck(checked)
                self.isChecking = false
                if self.needsAnotherCheck {
                    self.needsAnotherCheck = false
                    self.requestCheck()
                }
            }
        }
    }
}

/// The pinned folder cover's half of the check; the store lives in `PinnedFolderCoverStore`.
enum PinnedFolderCoverFreshness {
    static func packageLayerPaths(in stack: [FolderContentsLoader.Entry]) -> [String] {
        stack.filter(\.isPackage).map(\.url.path)
    }

    /// Folders with a layer whose fresh stamp differs from the one recorded *now* — not when the
    /// check started: a folder its watcher refreshed meanwhile is compared against its new layers.
    static func foldersNeedingRefresh(recorded: [String: [String: AppIconStamp?]],
                                      checked: [AppIconFreshnessChecker.Entry]) -> Set<String> {
        var folders = Set<String>()
        for entry in checked {
            guard let layers = recorded[entry.key], let stamp = layers[entry.path], stamp != entry.stamp else { continue }
            folders.insert(entry.key)
        }
        return folders
    }
}
