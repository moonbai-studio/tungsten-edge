import XCTest
@testable import macos_dock_cc_v2

/// 三个成员仓库（kept / drawer / messaging）跑遍公开变更后的不变量锁：
/// - 访达永不在消息区；
/// - 消息身份与 opt-out 不同时成立；
/// - 三张表无空白、无重复；
/// - UserDefaults 域里只出现现行键 + 冻结旧键，且冻结旧键字节不变（代码回滚仍能读同样的数据）。
@MainActor
final class AppMembershipInvariantTests: XCTestCase {
    private static let liveKeys: Set<String> = [
        "keptAppBundleIDsV3", "keptAppFinderSeededV1",
        "messagingBundleIDsV2", "messagingOptOutBundleIDsV2",
        "drawerBundleIDs",
    ]
    private static let frozenSeed: [String: [String]] = [
        "keptAppBundleIDsV2": ["com.legacy.v2"],
        "keptAppBundleIDs": ["com.legacy.v1"],
        "pinnedAppBundleIDs": ["com.legacy.pinned"],
        "messagingBundleIDs": ["com.legacy.messaging"],
        "messagingOptOutBundleIDs": ["com.legacy.optout"],
    ]

    private var suite = ""
    private var defaults: UserDefaults!
    private var kept: KeptAppStore!
    private var drawer: DrawerStore!
    private var messaging: MessagingAppStore!
    private var controller: AppMembershipController!

    override func setUp() {
        super.setUp()
        suite = "test-membership-invariants-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        for (key, value) in Self.frozenSeed { defaults.set(value, forKey: key) }
        kept = KeptAppStore(defaults: defaults)
        drawer = DrawerStore(defaults: defaults)
        messaging = MessagingAppStore(defaults: defaults)
        controller = AppMembershipController(keptAppStore: kept, drawerStore: drawer, messagingStore: messaging)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func assertInvariants(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let finder = FinderTaskbarPolicy.bundleID
        XCTAssertFalse(messaging.contains(finder), "[\(step)] 访达进了消息区", file: file, line: line)
        let optOut = Set(defaults.stringArray(forKey: "messagingOptOutBundleIDsV2") ?? [])
        XCTAssertTrue(optOut.isDisjoint(with: messaging.bundleIDs), "[\(step)] 消息身份与 opt-out 同时成立", file: file, line: line)
        for (name, list) in [("kept", kept.bundleIDs), ("drawer", drawer.bundleIDs), ("messaging", messaging.bundleIDs)] {
            XCTAssertEqual(Set(list).count, list.count, "[\(step)] \(name) 有重复", file: file, line: line)
            XCTAssertFalse(list.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "[\(step)] \(name) 有空白", file: file, line: line)
        }
        let keys = Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
        let allowed = Self.liveKeys.union(Self.frozenSeed.keys)
        XCTAssertTrue(keys.isSubset(of: allowed), "[\(step)] 出现了未登记的键：\(keys.subtracting(allowed))", file: file, line: line)
        for (key, value) in Self.frozenSeed {
            XCTAssertEqual(defaults.stringArray(forKey: key), value, "[\(step)] 冻结旧键被改写：\(key)", file: file, line: line)
        }
    }

    func testEveryPublicMutationKeepsTheInvariants() {
        assertInvariants("init")
        controller.setKept("com.example.a", enabled: true); assertInvariants("setKept on")
        controller.setKept("  ", enabled: true); assertInvariants("setKept blank")
        controller.setKept("com.example.a", enabled: true); assertInvariants("setKept twice")
        controller.moveToDrawer("com.example.a"); assertInvariants("moveToDrawer")
        controller.moveToDrawer("com.example.a"); assertInvariants("moveToDrawer twice")
        controller.applyDragLanding(bundleID: "com.example.b", originSource: .strip); assertInvariants("landing not in drawer")
        drawer.add("com.example.b")
        controller.applyDragLanding(bundleID: "com.example.b", originSource: .strip); assertInvariants("landing in drawer")
        controller.markMessaging("com.example.c"); assertInvariants("markMessaging")
        controller.markMessaging("com.example.c"); assertInvariants("markMessaging twice")
        controller.markMessaging(FinderTaskbarPolicy.bundleID); assertInvariants("markMessaging finder (rejected)")
        messaging.reorder(draggedID: "com.example.c", relativeTo: "com.example.c", after: true); assertInvariants("reorder self")
        controller.unmarkMessaging("com.example.c"); assertInvariants("unmarkMessaging")
        controller.autoRegisterMessaging(runningBundleIDs: ["com.example.c", "Mattermost.Desktop"],
                                         mainWindowIdentifiableBundleIDs: ["com.example.c", "Mattermost.Desktop"])
        assertInvariants("autoRegister")
        XCTAssertFalse(messaging.contains("com.example.c"), "opt-out 之后自动注册不得再加回来")
        controller.setKept("com.example.a", enabled: false); assertInvariants("setKept off")
        drawer.remove("com.example.a"); assertInvariants("drawer remove")
        controller.reconcileInvalidMemberships(); assertInvariants("reconcile")
        XCTAssertTrue(kept.contains("com.example.b"))
    }

    func testFinderInMessagingIsRepairedOnStartup() {
        // 模拟坏数据：旧版本写进去的访达消息身份。
        defaults.set([FinderTaskbarPolicy.bundleID, "com.example.c"], forKey: "messagingBundleIDsV2")
        let messaging = MessagingAppStore(defaults: defaults)
        let controller = AppMembershipController(keptAppStore: kept, drawerStore: drawer, messagingStore: messaging)
        XCTAssertTrue(messaging.contains(FinderTaskbarPolicy.bundleID))
        controller.reconcileInvalidMemberships()
        XCTAssertFalse(messaging.contains(FinderTaskbarPolicy.bundleID))
        XCTAssertTrue(messaging.contains("com.example.c"), "修复只清访达，不动别人")
    }
}
