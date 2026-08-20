import XCTest
@testable import macos_dock_cc_v2

@MainActor
final class AppMembershipControllerTests: XCTestCase {

    private var kept: KeptAppStore!
    private var drawer: DrawerStore!
    private var messaging: MessagingAppStore!
    private var controller: AppMembershipController!

    private func makeDefaults() -> UserDefaults {
        let suite = "test-membership-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    override func setUp() {
        super.setUp()
        let defaults = makeDefaults()
        kept = KeptAppStore(defaults: defaults)
        drawer = DrawerStore(defaults: defaults)
        messaging = MessagingAppStore(defaults: defaults)
        controller = AppMembershipController(
            keptAppStore: kept,
            drawerStore: drawer,
            messagingStore: messaging
        )
    }

    // MARK: - setKept (kept只改 kept，可与 messaging 共存)

    func testSetKeptAddsWithoutChangingDrawerPlacement() {
        drawer.add("com.example.app")
        controller.setKept("com.example.app", enabled: true)
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
    }

    func testSetKeptCoexistsWithMessagingIdentity() {
        messaging.mark("com.example.app")
        controller.setKept("com.example.app", enabled: true)
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(messaging.contains("com.example.app"))
    }

    func testSetKeptRejectsFinder() {
        let finder = KeptAppStore.forbiddenBundleID
        controller.setKept(finder, enabled: true)
        XCTAssertFalse(kept.contains(finder))
    }

    func testUnsetKeptLeavesDrawerPlacementAndMessagingUntouched() {
        controller.setKept("com.example.app", enabled: true)
        drawer.add("com.example.app")
        messaging.mark("com.example.app")
        controller.setKept("com.example.app", enabled: false)
        XCTAssertFalse(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
        XCTAssertTrue(messaging.contains("com.example.app"))
    }

    func testMoveToDrawerPreservesKept() {
        controller.setKept("com.example.app", enabled: true)
        controller.moveToDrawer("com.example.app")
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
    }

    // MARK: - markMessaging (首次加入补 kept，永不改 drawer)

    func testMarkMessagingFirstJoinSeedsKeptAndKeepsDrawer() {
        drawer.add("com.example.app")
        controller.markMessaging("com.example.app")
        XCTAssertTrue(messaging.contains("com.example.app"))
        XCTAssertTrue(kept.contains("com.example.app"))     // 首次加入补 kept
        XCTAssertTrue(drawer.contains("com.example.app"))   // placement 不动
    }

    func testMarkMessagingAgainDoesNotReopenUserRemovedKept() {
        controller.markMessaging("com.example.app")            // 首次 → 补 kept
        controller.setKept("com.example.app", enabled: false)  // 用户取消保留
        controller.markMessaging("com.example.app")            // 已是成员 → 不重补
        XCTAssertTrue(messaging.contains("com.example.app"))
        XCTAssertFalse(kept.contains("com.example.app"))
    }

    func testMarkMessagingRejectsFinder() {
        let finder = KeptAppStore.forbiddenBundleID
        controller.markMessaging(finder)
        XCTAssertFalse(messaging.contains(finder))
        XCTAssertFalse(kept.contains(finder))
    }

    // MARK: - autoRegisterMessaging (首次识别补 kept，扫描不重开)

    func testAutoRegisterMessagingSeedsKeptForNewMembers() {
        let chat = "com.tencent.xinWeChat"   // builtin whitelist
        controller.autoRegisterMessaging(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat])
        XCTAssertTrue(messaging.contains(chat))
        XCTAssertTrue(kept.contains(chat))
    }

    func testAutoRegisterMessagingDoesNotReopenUserRemovedKept() {
        let chat = "com.tencent.xinWeChat"
        // 首见 → 补 kept
        controller.autoRegisterMessaging(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat])
        controller.setKept(chat, enabled: false)                   // 用户取消保留
        // 再扫描 → 已是成员
        controller.autoRegisterMessaging(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat])
        XCTAssertTrue(messaging.contains(chat))
        XCTAssertFalse(kept.contains(chat))
    }

    func testAutoRegisterMessagingSkipsAppWithoutIdentifiableMainWindow() {
        // 「信息」这类主窗口永远认不出的应用不进消息区,也就不会被补 kept。
        let messages = "com.apple.MobileSMS"  // builtin whitelist
        controller.autoRegisterMessaging(runningBundleIDs: [messages],
                                         mainWindowIdentifiableBundleIDs: [])
        XCTAssertFalse(messaging.contains(messages))
        XCTAssertFalse(kept.contains(messages))
    }

    // MARK: - unmarkMessaging (只清消息身份，保留 kept + drawer)

    func testUnmarkMessagingKeepsKeptAndDrawer() {
        controller.markMessaging("com.example.app") // messaging + kept
        drawer.add("com.example.app")
        controller.unmarkMessaging("com.example.app")
        XCTAssertFalse(messaging.contains("com.example.app"))
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
    }

    func testMessagingMenuDescriptorRoundTripPreservesAsymmetricSemantics() throws {
        let bundleID = "com.example.app"
        drawer.add(bundleID)

        let unchecked = try XCTUnwrap(LauncherMembershipItem.items(
            surface: .strip,
            bundleID: bundleID,
            isKept: false,
            isMessaging: false,
            controller: controller
        ).last)
        XCTAssertEqual(unchecked.label, String(localized: "Mark as Messaging App"))
        XCTAssertEqual(unchecked.isChecked, false)
        unchecked.action()
        XCTAssertTrue(messaging.contains(bundleID))
        XCTAssertTrue(kept.contains(bundleID), "首次标记仍应补 kept")
        XCTAssertTrue(drawer.contains(bundleID), "标记不改变 drawer placement")

        let checked = try XCTUnwrap(LauncherMembershipItem.items(
            surface: .drawer,
            bundleID: bundleID,
            isKept: true,
            isMessaging: true,
            controller: controller
        ).last)
        XCTAssertEqual(checked.label, String(localized: "Mark as Messaging App"))
        XCTAssertEqual(checked.isChecked, true)
        checked.action()
        XCTAssertFalse(messaging.contains(bundleID))
        XCTAssertTrue(kept.contains(bundleID), "取消标记不改变 kept")
        XCTAssertTrue(drawer.contains(bundleID), "取消标记不改变 drawer placement")
    }

    // MARK: - reconcileInvalidMemberships (只清 Finder)

    func testReconcileClearsFinderFromDrawerAndMessaging() {
        let finder = KeptAppStore.forbiddenBundleID
        drawer.add(finder)
        messaging.mark(finder)
        controller.reconcileInvalidMemberships()
        XCTAssertFalse(drawer.contains(finder))
        XCTAssertFalse(messaging.contains(finder))
    }

    func testReconcilePreservesKeptMessagingOverlap() {
        controller.setKept("com.example.app", enabled: true)
        messaging.mark("com.example.app")
        controller.reconcileInvalidMemberships()
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(messaging.contains("com.example.app"))
    }

    // MARK: - DrawerStore migration

    func testDrawerStoreMigratesLaunchFavoriteKey() {
        let defaults = makeDefaults()
        defaults.set(["com.example.fav1", "com.example.fav2"], forKey: "launchFavoriteBundleIDs")
        defaults.set(["com.example.existing"], forKey: "drawerBundleIDs")
        let migrated = DrawerStore(defaults: defaults)
        XCTAssertTrue(migrated.contains("com.example.fav1"))
        XCTAssertTrue(migrated.contains("com.example.fav2"))
        XCTAssertTrue(migrated.contains("com.example.existing"))
        XCTAssertNil(defaults.stringArray(forKey: "launchFavoriteBundleIDs"))
    }
}
