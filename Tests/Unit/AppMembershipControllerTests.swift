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

    // MARK: - applyDragLanding（收纳落定补勾 kept；每次拖入都重新打开）

    func testApplyDragLandingEnablesKeptOnlyWhenEndedInDrawerFromStripOrMessaging() {
        for source in [DragSource.strip, .drawer, .folder, .messaging] {
            for endedInDrawer in [true, false] {
                let defaults = makeDefaults()
                let kept = KeptAppStore(defaults: defaults)
                let drawer = DrawerStore(defaults: defaults)
                let messaging = MessagingAppStore(defaults: defaults)
                let controller = AppMembershipController(keptAppStore: kept, drawerStore: drawer, messagingStore: messaging)
                if endedInDrawer { drawer.add("com.example.app") }
                controller.applyDragLanding(bundleID: "com.example.app", originSource: source)
                let expected = endedInDrawer && (source == .strip || source == .messaging)
                XCTAssertEqual(kept.contains("com.example.app"), expected, "source=\(source) endedInDrawer=\(endedInDrawer)")
                XCTAssertEqual(drawer.contains("com.example.app"), endedInDrawer, "落定补勾不得改 drawer")
            }
        }
    }

    func testApplyDragLandingReEnablesKeptAfterManualUncheck() {
        drawer.add("com.example.app")
        controller.applyDragLanding(bundleID: "com.example.app", originSource: .strip)
        XCTAssertTrue(kept.contains("com.example.app"))
        controller.setKept("com.example.app", enabled: false)
        XCTAssertFalse(kept.contains("com.example.app"))
        controller.applyDragLanding(bundleID: "com.example.app", originSource: .messaging)
        XCTAssertTrue(kept.contains("com.example.app"), "不是一次性播种：再次拖入重新打开")
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

    /// 2026-08-20 反转：访达也走统一的「在程序坞中保留」，默认已由播种勾上，可以取消再勾回。
    func testSetKeptAcceptsFinderBothWays() {
        let finder = FinderTaskbarPolicy.bundleID
        XCTAssertTrue(kept.contains(finder), "新建 store 应已把访达播种为已保留")
        controller.setKept(finder, enabled: false)
        XCTAssertFalse(kept.contains(finder))
        controller.setKept(finder, enabled: true)
        XCTAssertTrue(kept.contains(finder))
    }

    func testMoveToDrawerAcceptsFinder() {
        let finder = FinderTaskbarPolicy.bundleID
        controller.moveToDrawer(finder)
        XCTAssertTrue(drawer.contains(finder))
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

    /// 访达可 kept、可进抽屉，但消息区仍然进不去。
    func testMarkMessagingRejectsFinder() {
        let finder = FinderTaskbarPolicy.bundleID
        controller.markMessaging(finder)
        XCTAssertFalse(messaging.contains(finder))
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
        XCTAssertEqual(unchecked.label, String(localized: "Pin to Messaging Zone"))
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
        XCTAssertEqual(checked.label, String(localized: "Pin to Messaging Zone"))
        XCTAssertEqual(checked.isChecked, true)
        checked.action()
        XCTAssertFalse(messaging.contains(bundleID))
        XCTAssertTrue(kept.contains(bundleID), "取消标记不改变 kept")
        XCTAssertTrue(drawer.contains(bundleID), "取消标记不改变 drawer placement")
    }

    // MARK: - reconcileInvalidMemberships (只清访达的消息身份)

    /// 每次启动都会跑：只能清消息身份。清抽屉会把用户自己拖进去的访达抹掉（2026-08-20）。
    func testReconcileClearsOnlyFinderMessagingAndKeepsDrawerPlacement() {
        let finder = FinderTaskbarPolicy.bundleID
        drawer.add(finder)
        messaging.mark(finder)
        controller.reconcileInvalidMemberships()
        XCTAssertTrue(drawer.contains(finder))
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
