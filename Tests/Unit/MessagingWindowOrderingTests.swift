import XCTest
@testable import macos_dock_cc_v2

/// #4：消息应用弹出窗口落窗口区头部。纯 `StripOrdering.reconcile` 的 head-preferred 分支，
/// 以及真 `StripOrderStore` 双路径（reconciled 渲染 / sync 副作用）一致性（Codex 二审 #2）。
@MainActor
final class MessagingWindowOrderingTests: XCTestCase {

    private final class TimeBox {
        var time: Date
        init(_ time: Date) { self.time = time }
    }

    private func makeStore(timeBox: TimeBox) -> StripOrderStore {
        let suite = "test-msg-order-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return StripOrderStore(defaults: defaults, now: { timeBox.time })
    }

    private let msg: Set<String> = ["com.msg"]

    // MARK: - reconcile 纯层

    func testMessagingWindowNoSiblingGoesHead() {
        let result = StripOrdering.reconcile(
            remembered: ["tabgrp-normal"],
            current: ["tabgrp-normal", "tabgrp-msg"],
            appKeyOf: ["tabgrp-normal": "com.normal", "tabgrp-msg": "com.msg"],
            headPreferredKeys: msg
        )
        XCTAssertEqual(result, ["tabgrp-msg", "tabgrp-normal"])
    }

    func testMultipleMessagingWindowsClusterAtHeadInOrder() {
        let result = StripOrdering.reconcile(
            remembered: ["n1"],
            current: ["n1", "m1", "m2"],
            appKeyOf: ["n1": "com.normal", "m1": "com.msg", "m2": "com.msg"],
            headPreferredKeys: msg
        )
        // m1 落头部；m2 有同伴 m1 → 紧跟其后；彼此相对序保持。
        XCTAssertEqual(result, ["m1", "m2", "n1"])
    }

    func testNormalWindowStillGoesEnd() {
        let result = StripOrdering.reconcile(
            remembered: ["m1"],
            current: ["m1", "n1"],
            appKeyOf: ["m1": "com.msg", "n1": "com.normal"],
            headPreferredKeys: msg
        )
        XCTAssertEqual(result, ["m1", "n1"])
    }

    func testRememberedMessagingWindowKeepsPositionNotReHeaded() {
        // m1 已记住在末尾（用户拖过）；再对账不把它拎回头部。
        let result = StripOrdering.reconcile(
            remembered: ["n1", "m1"],
            current: ["n1", "m1"],
            appKeyOf: ["n1": "com.normal", "m1": "com.msg"],
            headPreferredKeys: msg
        )
        XCTAssertEqual(result, ["n1", "m1"])
    }

    // MARK: - StripOrderStore 双路径

    func testStoreNewMessagingWindowLandsHead() {
        let store = makeStore(timeBox: TimeBox(Date()))
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        store.sync(current: ["n1", "m1"],
                   appKeyOf: ["n1": "com.normal", "m1": "com.msg"], headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["m1", "n1"])
    }

    func testStoreMultipleMessagingWindowsClusterHead() {
        let store = makeStore(timeBox: TimeBox(Date()))
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        store.sync(current: ["n1", "m1", "m2"],
                   appKeyOf: ["n1": "com.normal", "m1": "com.msg", "m2": "com.msg"],
                   headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["m1", "m2", "n1"])
    }

    func testStoreNormalWindowsUnaffected() {
        let store = makeStore(timeBox: TimeBox(Date()))
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        store.sync(current: ["n1", "n2"],
                   appKeyOf: ["n1": "com.normal", "n2": "com.other"], headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["n1", "n2"])
    }

    func testStoreDraggedMessagingWindowKeepsPositionOnReappear() {
        let store = makeStore(timeBox: TimeBox(Date()))
        let keys = ["n1": "com.normal", "m1": "com.msg"]
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["m1", "n1"])
        // 用户把 m1 拖到 n1 右边。
        store.reorder(draggedID: "m1", relativeTo: "n1", after: true, current: ["m1", "n1"])
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
        // 再次 sync（窗口都在）→ m1 已记住，保持原位，不被重新提头。
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
    }

    func testStoreMessagingWindowGraceAbsenceDoesNotReHead() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        let keys = ["n1": "com.normal", "m1": "com.msg"]
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        store.reorder(draggedID: "m1", relativeTo: "n1", after: true, current: ["m1", "n1"])
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
        // m1 短暂消失（grace 内）→ 保住 rank。
        timeBox.time = timeBox.time.addingTimeInterval(1)
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
        // 返场 → 仍在原位，未被重新提头。
        timeBox.time = timeBox.time.addingTimeInterval(1)
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
    }

    /// Codex 二审 #2 核心：渲染路径 reconciled 与副作用路径 sync 必须用同一 headPreferred，
    /// 否则首帧头部、sync 后跳位。两路对同一新消息窗口结果一致。
    func testReconciledMatchesSyncForNewMessagingWindow() {
        let store = makeStore(timeBox: TimeBox(Date()))
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        let keys = ["n1": "com.normal", "m1": "com.msg"]
        let rendered = store.reconciled(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        XCTAssertEqual(rendered, ["m1", "n1"])
        XCTAssertEqual(store.liveOrder, rendered)
    }

    /// 影子滑动修复对消息区的边界：已记住位置（拖过）的消息窗口在 grace 内关闭后换**新** seat，
    /// 首帧就继承旧 rank，不因 headPreferred 重新提头（pre-sync 与 post-sync 一致）。
    /// 全新、无记忆的消息窗口仍走 head，由 `testStoreNewMessagingWindowLandsHead` /
    /// `testReconciledMatchesSyncForNewMessagingWindow` 覆盖。
    func testMessagingNewWindowWithinGraceInheritsRankNotReHead() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        let keys = ["n1": "com.normal", "m1": "com.msg"]
        store.sync(current: ["n1", "m1"], appKeyOf: keys, headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["m1", "n1"])
        // 用户把 m1 拖到 n1 右边 → 记住 [n1, m1]
        store.reorder(draggedID: "m1", relativeTo: "n1", after: true, current: ["m1", "n1"])
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
        // m1 关闭（grace 内打戳）
        timeBox.time = timeBox.time.addingTimeInterval(1)
        store.sync(current: ["n1"], appKeyOf: ["n1": "com.normal"], headPreferred: msg)
        XCTAssertEqual(store.liveOrder, ["n1", "m1"])
        // grace 内换新窗口 m2：首帧 render（sync 未跑）→ 继承 m1 旧位（n1 右），不提头
        timeBox.time = timeBox.time.addingTimeInterval(1)
        let newKeys = ["n1": "com.normal", "m2": "com.msg"]
        let firstFrame = store.reconciled(current: ["n1", "m2"], appKeyOf: newKeys, headPreferred: msg)
        XCTAssertEqual(firstFrame, ["n1", "m2"])   // 不是 ["m2", "n1"]
        store.sync(current: ["n1", "m2"], appKeyOf: newKeys, headPreferred: msg)
        let postSync = store.reconciled(current: ["n1", "m2"], appKeyOf: newKeys, headPreferred: msg)
        XCTAssertEqual(firstFrame, postSync)
    }
}
