import XCTest

@MainActor
final class MessagingAppStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test-messaging-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(_ ids: [String], defaults: UserDefaults? = nil) -> MessagingAppStore {
        let d = defaults ?? makeDefaults()
        let store = MessagingAppStore(defaults: d)
        for id in ids { store.mark(id) }
        return store
    }

    // MARK: - reorder

    func testReorderBeforeAndAfterTarget() {
        let store = makeStore(["a", "b", "c"])
        store.reorder(draggedID: "c", relativeTo: "a", after: false)
        XCTAssertEqual(store.bundleIDs, ["c", "a", "b"])
        store.reorder(draggedID: "c", relativeTo: "b", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b", "c"])
    }

    func testReorderToHeadAndTail() {
        let store = makeStore(["a", "b", "c"])
        store.reorder(draggedID: "b", relativeTo: "a", after: false)   // 首位
        XCTAssertEqual(store.bundleIDs, ["b", "a", "c"])
        store.reorder(draggedID: "b", relativeTo: "c", after: true)    // 末位
        XCTAssertEqual(store.bundleIDs, ["a", "c", "b"])
    }

    func testReorderMiddle() {
        let store = makeStore(["a", "b", "c", "d"])
        store.reorder(draggedID: "d", relativeTo: "b", after: false)
        XCTAssertEqual(store.bundleIDs, ["a", "d", "b", "c"])
    }

    func testReorderOntoSelfIsNoOp() {
        let store = makeStore(["a", "b"])
        store.reorder(draggedID: "a", relativeTo: "a", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b"])
    }

    func testReorderUnknownIDsAreNoOp() {
        let store = makeStore(["a", "b"])
        store.reorder(draggedID: "ghost", relativeTo: "a", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b"])
        store.reorder(draggedID: "a", relativeTo: "ghost", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b"])
    }

    /// 隐藏成员（收进抽屉/未运行,不在区里显示）保持相对位置——reorder 直接改全量持久数组。
    func testHiddenMemberKeepsRelativePosition() {
        let store = makeStore(["a", "hidden", "b"])
        store.reorder(draggedID: "a", relativeTo: "b", after: true)
        XCTAssertEqual(store.bundleIDs, ["hidden", "b", "a"])
    }

    func testReorderPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = makeStore(["a", "b", "c"], defaults: defaults)
        store.reorder(draggedID: "c", relativeTo: "a", after: false)
        let reloaded = MessagingAppStore(defaults: defaults)
        XCTAssertEqual(reloaded.bundleIDs, ["c", "a", "b"])
    }

    // MARK: - V2 key migration

    func testNameListMigratesFromLegacyKeyToV2AndFreezesLegacy() {
        let defaults = makeDefaults()
        defaults.set(["com.chat.legacy"], forKey: "messagingBundleIDs")
        let store = MessagingAppStore(defaults: defaults)
        XCTAssertTrue(store.contains("com.chat.legacy"))
        XCTAssertEqual(defaults.stringArray(forKey: "messagingBundleIDsV2"), ["com.chat.legacy"])
        // 旧键冻结、不动（回滚可读）。
        XCTAssertEqual(defaults.stringArray(forKey: "messagingBundleIDs"), ["com.chat.legacy"])
    }

    func testFreshInstallPersistsEmptyV2Markers() {
        let defaults = makeDefaults()
        _ = MessagingAppStore(defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "messagingBundleIDsV2"), [])
        XCTAssertEqual(defaults.stringArray(forKey: "messagingOptOutBundleIDsV2"), [])
    }

    func testExistingV2KeyPreventsRemigrationFromLegacy() {
        let defaults = makeDefaults()
        defaults.set(["com.v2.only"], forKey: "messagingBundleIDsV2")
        defaults.set(["com.legacy.ignored"], forKey: "messagingBundleIDs")
        let store = MessagingAppStore(defaults: defaults)
        XCTAssertTrue(store.contains("com.v2.only"))
        XCTAssertFalse(store.contains("com.legacy.ignored"))
    }

    func testOptOutMigratesIndependentlyOfNameList() {
        // 名单已有 V2、opt-out 只有旧键 → opt-out 独立迁移（部分迁移状态）。
        let defaults = makeDefaults()
        defaults.set([String](), forKey: "messagingBundleIDsV2")
        defaults.set(["com.tencent.qq"], forKey: "messagingOptOutBundleIDs") // builtin，被 opt-out
        let store = MessagingAppStore(defaults: defaults)
        let added = store.autoRegister(runningBundleIDs: ["com.tencent.qq"],
                                       mainWindowIdentifiableBundleIDs: ["com.tencent.qq"])
        XCTAssertTrue(added.isEmpty) // opt-out 迁移生效，不重新注册
        XCTAssertEqual(defaults.stringArray(forKey: "messagingOptOutBundleIDsV2"), ["com.tencent.qq"])
    }

    func testMarkReturnsTrueOnFirstJoinFalseAfter() {
        let store = MessagingAppStore(defaults: makeDefaults())
        XCTAssertTrue(store.mark("com.chat.app"))
        XCTAssertFalse(store.mark("com.chat.app"))
    }

    func testAutoRegisterReturnsNewlyAddedIDs() {
        let store = MessagingAppStore(defaults: makeDefaults())
        let chat = "com.tencent.xinWeChat" // builtin whitelist
        let added = store.autoRegister(runningBundleIDs: [chat, "com.not.messaging"],
                                       mainWindowIdentifiableBundleIDs: [chat])
        XCTAssertEqual(added, [chat])
        // 第二轮无新增
        XCTAssertTrue(store.autoRegister(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat]).isEmpty)
    }

    // MARK: - 准入能力门槛（认不出主窗口就不进消息区）

    func testAutoRegisterSkipsWhitelistedAppWithoutIdentifiableMainWindow() {
        // Apple「信息」在内置名单里，但 Catalyst 编号标题永远认不出主窗口 → 不得注册。
        let store = MessagingAppStore(defaults: makeDefaults())
        let messages = "com.apple.MobileSMS"
        XCTAssertTrue(store.autoRegister(runningBundleIDs: [messages],
                                         mainWindowIdentifiableBundleIDs: []).isEmpty)
        XCTAssertFalse(store.contains(messages))
    }

    func testAutoRegisterAdmitsOnceMainWindowBecomesIdentifiable() {
        // 主窗关闭时不注册；主窗出现那一轮才进名单。
        let store = MessagingAppStore(defaults: makeDefaults())
        let chat = "com.tencent.xinWeChat"
        XCTAssertTrue(store.autoRegister(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: []).isEmpty)
        XCTAssertEqual(store.autoRegister(runningBundleIDs: [chat],
                                          mainWindowIdentifiableBundleIDs: [chat]), [chat])
    }

    func testMemberIsNeverReTestedSoItCannotFlapOutOfTheZone() {
        // 一次通过即永久落名单：微信主窗关闭（此刻认不出）不得把它踢出消息区。
        let store = MessagingAppStore(defaults: makeDefaults())
        let chat = "com.tencent.xinWeChat"
        XCTAssertEqual(store.autoRegister(runningBundleIDs: [chat],
                                          mainWindowIdentifiableBundleIDs: [chat]), [chat])
        _ = store.autoRegister(runningBundleIDs: [chat], mainWindowIdentifiableBundleIDs: [])
        XCTAssertTrue(store.contains(chat), "已注册成员不因当前认不出主窗口而被移除")
    }

    func testManualMarkBypassesTheCapabilityGate() {
        // owner 2026-07-21：手动标记不受准入门槛限制。
        let store = MessagingAppStore(defaults: makeDefaults())
        XCTAssertTrue(store.mark("com.apple.MobileSMS"))
        XCTAssertTrue(store.contains("com.apple.MobileSMS"))
    }


    // MARK: - isMessagingApp：身份与「在不在消息区」分开（2026-08-23）

    func testBuiltinAppIsMessagingAppWithoutEnteringZone() {
        let store = makeStore([])
        XCTAssertTrue(store.isMessagingApp("com.apple.MobileSMS"), "内置名单 = 身份，不需要进区")
        XCTAssertFalse(store.contains("com.apple.MobileSMS"), "身份不等于消息区成员")
    }

    func testManualPinGrantsIdentityUntilUnpinnedForUnknownApp() {
        let store = makeStore(["custom.chat"])
        XCTAssertTrue(store.isMessagingApp("custom.chat"))
        store.unmark("custom.chat")
        XCTAssertFalse(store.isMessagingApp("custom.chat"), "既不在名单也不在白名单的 app，取消固定后没有任何身份来源")
    }

    /// 2026-08-23 验收回炉：owner 早先把信息从消息区取消过，红点就没了。「固定在 Dock 栏左侧」的取消
    /// 只表达「别钉在区里」，内置消息应用的红点不能跟着没。
    func testUnpinningBuiltinKeepsIdentity() {
        let store = makeStore(["com.apple.MobileSMS"])
        store.unmark("com.apple.MobileSMS")
        XCTAssertFalse(store.contains("com.apple.MobileSMS"), "取消后不在区里")
        XCTAssertTrue(store.isMessagingApp("com.apple.MobileSMS"), "但仍是消息应用，红点照画")
    }

    func testUnknownAppIsNotMessagingApp() {
        let store = makeStore([])
        XCTAssertFalse(store.isMessagingApp("com.example.nothing"))
        XCTAssertFalse(store.isMessagingApp(""))
    }

    func testBadgeDefaultsPreserveExistingMessagingBehavior() {
        let store = makeStore(["custom.chat"])
        XCTAssertTrue(store.showsUnreadBadge("custom.chat"))
        XCTAssertTrue(store.showsUnreadBadge("com.apple.MobileSMS"))
        XCTAssertFalse(store.showsUnreadBadge("com.example.editor"))
        store.unmark("com.apple.MobileSMS")
        XCTAssertTrue(store.showsUnreadBadge("com.apple.MobileSMS"))
    }

    func testOrdinaryAppCanEnableBadgeWithoutJoiningMessagingZone() {
        let store = makeStore([])
        store.setShowsUnreadBadge("com.example.editor", enabled: true)
        XCTAssertTrue(store.showsUnreadBadge("com.example.editor"))
        XCTAssertFalse(store.isMessagingApp("com.example.editor"))
        XCTAssertTrue(store.bundleIDs.isEmpty)
        XCTAssertTrue(store.autoRegister(runningBundleIDs: ["com.example.editor"],
                                         mainWindowIdentifiableBundleIDs: ["com.example.editor"]).isEmpty)
    }

    func testBadgeChoicesPersistAcrossReloadAndPinChanges() {
        let defaults = makeDefaults()
        let store = MessagingAppStore(defaults: defaults)
        store.setShowsUnreadBadge("com.example.editor", enabled: true)
        store.setShowsUnreadBadge("com.apple.MobileSMS", enabled: false)
        for id in ["com.example.editor", "com.apple.MobileSMS"] {
            store.mark(id)
            store.unmark(id)
        }
        let reloaded = MessagingAppStore(defaults: defaults)
        XCTAssertTrue(reloaded.showsUnreadBadge("com.example.editor"))
        XCTAssertFalse(reloaded.showsUnreadBadge("com.apple.MobileSMS"))
        XCTAssertTrue(reloaded.bundleIDs.isEmpty)
    }

    func testExplicitChoiceMatchingDefaultSurvivesLaterPinChanges() {
        let store = makeStore([])
        store.setShowsUnreadBadge("com.example.editor", enabled: false)
        store.mark("com.example.editor")
        XCTAssertFalse(store.showsUnreadBadge("com.example.editor"))
        store.setShowsUnreadBadge("com.example.editor", enabled: true)
        store.unmark("com.example.editor")
        XCTAssertTrue(store.showsUnreadBadge("com.example.editor"))
    }

    func testAutomaticRegistrationDoesNotOverrideDisabledBadge() {
        let store = makeStore([])
        store.setShowsUnreadBadge("com.tencent.qq", enabled: false)
        _ = store.autoRegister(runningBundleIDs: ["com.tencent.qq"],
                                mainWindowIdentifiableBundleIDs: ["com.tencent.qq"])
        XCTAssertTrue(store.contains("com.tencent.qq"))
        XCTAssertFalse(store.showsUnreadBadge("com.tencent.qq"))
    }

    func testEmptyBundleIDCannotEnableBadge() {
        let store = makeStore([])
        store.setShowsUnreadBadge("", enabled: true)
        XCTAssertTrue(store.badgeOverrides.isEmpty)
        XCTAssertFalse(store.showsUnreadBadge(""))
    }
}
