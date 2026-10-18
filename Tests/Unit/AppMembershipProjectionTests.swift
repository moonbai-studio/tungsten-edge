import XCTest
@testable import macos_dock_cc_v2

final class AppMembershipProjectionTests: XCTestCase {

    func testDrawerMembersDeduplicates() {
        let result = AppMembershipProjection.drawerMembers(drawerIDs: ["a", "a", "b"])
        XCTAssertEqual(result, ["a", "b"])
    }

    func testDrawerMembersPreservesOrder() {
        let result = AppMembershipProjection.drawerMembers(drawerIDs: ["c", "a", "b"])
        XCTAssertEqual(result, ["c", "a", "b"])
    }

    // MARK: - visibleDrawerIDs = drawer ∩ (running ∪ kept)

    func testVisibleDrawerIDsUsesRunningKeptUnion() {
        let result = AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: ["running", "kept", "messagingOnly", "hidden"],
            keptIDs: ["kept"],
            runningIDs: ["running"]
        )
        // messagingOnly 既不 running 也不 kept → 现在隐藏（messaging 不再独立保活）。
        XCTAssertEqual(result, ["running", "kept"])
    }

    func testVisibleDrawerIDsPreservesInputOrderAndDeduplicates() {
        let result = AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: ["b", "a", "b", "c"],
            keptIDs: ["a", "b", "c"],
            runningIDs: []
        )
        XCTAssertEqual(result, ["b", "a", "c"])
    }

    func testDrawerPreviewHonorsLimit() {
        let drawerIDs = (0..<15).map { "app\($0)" }
        let result = AppMembershipProjection.drawerPreview(
            drawerIDs: drawerIDs,
            keptIDs: drawerIDs,
            runningIDs: [],
            limit: 4
        )
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.first, "app0")
    }

    func testDrawerPreviewExcludesInactivePlacements() {
        let result = AppMembershipProjection.drawerPreview(
            drawerIDs: ["a", "b", "c"],
            keptIDs: ["b"],
            runningIDs: ["c"],
            limit: 9
        )
        XCTAssertEqual(result, ["b", "c"])
    }

    // MARK: - visibleMessagingIDs = (messaging − drawer) ∩ (running ∪ kept)

    func testVisibleMessagingIDsExcludesDrawerAndRequiresRunningOrKept() {
        let result = AppMembershipProjection.visibleMessagingIDs(
            messagingIDs: ["running", "kept", "stashed", "gone"],
            drawerIDs: ["stashed"],
            keptIDs: ["kept"],
            runningIDs: ["running"]
        )
        // stashed → 抽屉里隐藏；gone → 既不 running 也不 kept，隐藏。
        XCTAssertEqual(result, ["running", "kept"])
    }

    func testVisibleMessagingIDsPreservesOrderAndDeduplicates() {
        let result = AppMembershipProjection.visibleMessagingIDs(
            messagingIDs: ["c", "a", "c", "b"],
            drawerIDs: [],
            keptIDs: ["a", "b", "c"],
            runningIDs: []
        )
        XCTAssertEqual(result, ["c", "a", "b"])
    }


    // MARK: - badgeEligibleIDs = 身份 ∩ 在跑 − 抽屉（2026-08-23 角标与消息区解绑）

    func testBadgeEligibleIDsUsesIdentityNotZone() {
        let identity: Set<String> = ["com.apple.MobileSMS", "com.tencent.xinWeChat", "com.slack"]
        let result = AppMembershipProjection.badgeEligibleIDs(
            showsUnreadBadge: { identity.contains($0) },
            drawerIDs: ["com.slack"],                      // 抽屉里的不读
            runningIDs: ["com.apple.MobileSMS", "com.slack", "com.apple.Safari", "com.tencent.xinWeChat"]
        )
        // 信息从没进过消息区，但它是消息应用且在跑 → 有角标资格；Safari 不是消息应用。
        XCTAssertEqual(result, ["com.apple.MobileSMS", "com.tencent.xinWeChat"])
    }

    func testBadgeEligibleIDsIsEmptyWhenNothingRuns() {
        let result = AppMembershipProjection.badgeEligibleIDs(
            showsUnreadBadge: { _ in true },
            drawerIDs: [],
            runningIDs: []
        )
        XCTAssertTrue(result.isEmpty, "没有消息应用在跑 → 空集 → BadgeStore 停轮询")
    }

    @MainActor
    func testExplicitBadgeChoiceLetsOrdinaryRunningAppStayOutsideMessagingZone() {
        let suite = "test-badge-projection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MessagingAppStore(defaults: defaults)
        store.setShowsUnreadBadge("com.example.editor", enabled: true)
        store.setShowsUnreadBadge("com.example.drawer", enabled: true)
        store.setShowsUnreadBadge("com.example.stopped", enabled: true)
        store.setShowsUnreadBadge("com.apple.MobileSMS", enabled: false)
        let result = AppMembershipProjection.badgeEligibleIDs(
            showsUnreadBadge: { store.showsUnreadBadge($0) },
            drawerIDs: ["com.example.drawer"],
            runningIDs: ["", "com.example.editor", "com.example.drawer", "com.apple.MobileSMS"]
        )
        XCTAssertEqual(result, ["com.example.editor"])
        XCTAssertTrue(store.bundleIDs.isEmpty)
    }
}
