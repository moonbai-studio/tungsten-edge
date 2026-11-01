import XCTest

final class PinnedFolderCoverFreshnessTests: XCTestCase {
    private let folder = "/pinned"
    private let app = "/pinned/X.app"

    private func stamp(_ change: Int) -> AppIconStamp {
        AppIconStamp(bundleInode: 1, bundleChangeSeconds: change, bundleChangeNanoseconds: 0,
                     infoPlistExists: true, infoPlistInode: 2,
                     infoPlistModificationSeconds: 0, infoPlistModificationNanoseconds: 0)
    }

    private func checked(_ path: String, _ stamp: AppIconStamp?) -> AppIconFreshnessChecker.Entry {
        AppIconFreshnessChecker.Entry(key: folder, path: path, stamp: stamp)
    }

    private func entry(_ name: String, isDirectory: Bool, isPackage: Bool) -> FolderContentsLoader.Entry {
        FolderContentsLoader.Entry(url: URL(fileURLWithPath: "/pinned/\(name)"), name: name,
                                   isDirectory: isDirectory, isPackage: isPackage)
    }

    func testOnlyPackageLayersAreStamped() {
        let stack = [
            entry("X.app", isDirectory: true, isPackage: true),
            entry("Downloads", isDirectory: true, isPackage: false),
            entry("a.txt", isDirectory: false, isPackage: false),
        ]
        XCTAssertEqual(PinnedFolderCoverFreshness.packageLayerPaths(in: stack), [app])
    }

    func testUnchangedStampNeedsNoRefresh() {
        let recorded: [String: [String: AppIconStamp?]] = [folder: [app: stamp(1)]]
        XCTAssertEqual(PinnedFolderCoverFreshness.foldersNeedingRefresh(recorded: recorded, checked: [checked(app, stamp(1))]), [])
    }

    func testChangedStampRefreshesThatFolderOnly() {
        let recorded: [String: [String: AppIconStamp?]] = [folder: [app: stamp(1)], "/other": ["/other/Y.app": stamp(1)]]
        let result = PinnedFolderCoverFreshness.foldersNeedingRefresh(
            recorded: recorded,
            checked: [checked(app, stamp(2)),
                      AppIconFreshnessChecker.Entry(key: "/other", path: "/other/Y.app", stamp: stamp(1))]
        )
        XCTAssertEqual(result, [folder])
    }

    func testLayerNoLongerRecordedIsSkipped() {
        // The folder's watcher refreshed it while the check ran and X.app left the cover.
        let recorded: [String: [String: AppIconStamp?]] = [folder: ["/pinned/Z.app": stamp(1)]]
        XCTAssertEqual(PinnedFolderCoverFreshness.foldersNeedingRefresh(recorded: recorded, checked: [checked(app, stamp(2))]), [])
        XCTAssertEqual(PinnedFolderCoverFreshness.foldersNeedingRefresh(recorded: [:], checked: [checked(app, stamp(2))]), [])
    }

    func testMissingStampsCompareByPresence() {
        let unreadable: [String: [String: AppIconStamp?]] = [folder: [app: AppIconStamp?.none]]
        XCTAssertEqual(PinnedFolderCoverFreshness.foldersNeedingRefresh(recorded: unreadable, checked: [checked(app, nil)]), [])
        XCTAssertEqual(PinnedFolderCoverFreshness.foldersNeedingRefresh(recorded: unreadable, checked: [checked(app, stamp(1))]), [folder])
        let readable: [String: [String: AppIconStamp?]] = [folder: [app: stamp(1)]]
        XCTAssertEqual(PinnedFolderCoverFreshness.foldersNeedingRefresh(recorded: readable, checked: [checked(app, nil)]), [folder])
    }
}
