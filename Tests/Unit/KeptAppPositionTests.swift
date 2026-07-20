import XCTest
@testable import macos_dock_cc_v2

@MainActor
final class KeptAppPositionTests: XCTestCase {

    /// 可变时间盒，让 `now` 闭包能从测试方法里推进。
    private final class TimeBox {
        var time: Date
        init(_ time: Date) { self.time = time }
    }

    private func makeStore(timeBox: TimeBox, keptIDs: Set<String> = []) -> StripOrderStore {
        let suite = "test-kept-pos-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return StripOrderStore(
            defaults: defaults,
            now: { timeBox.time },
            keptIDsProvider: { keptIDs }
        )
    }

    // MARK: - a. app exit → tabgrp-* grace → app-* placeholder → position = rightmost tabgrp-*

    func testExitPlaceholderInheritsRightmostWindowPosition() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        // Two windows from com.app, already ordered
        store.sync(current: ["tabgrp-100-s1", "tabgrp-100-s2"],
                   appKeyOf: ["tabgrp-100-s1": "com.app", "tabgrp-100-s2": "com.app"])
        // App exits → placeholder injected (DockStripView would do this)
        store.sync(current: ["app-com.app"],
                   appKeyOf: ["app-com.app": "com.app"])
        // Grace: tabgrp-* still in liveOrder; placeholder inserted after rightmost tabgrp-*
        // reconciled 只返回 current 中的 id（用户只看到占位），但 liveOrder 保留了完整位置
        XCTAssertEqual(store.liveOrder, ["tabgrp-100-s1", "tabgrp-100-s2", "app-com.app"])
        XCTAssertEqual(store.reconciled(current: ["app-com.app"],
                                        appKeyOf: ["app-com.app": "com.app"]),
                       ["app-com.app"])
    }

    // MARK: - b. grace expires → tabgrp-* gone → placeholder keeps position

    func testGraceExpiresPlaceholderStaysInPlace() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        // com.app 两窗在左、com.other 一窗在右——占位"保持原位"= 停在 com.other 左边
        store.sync(current: ["tabgrp-100-s1", "tabgrp-100-s2", "tabgrp-300-s1"],
                   appKeyOf: ["tabgrp-100-s1": "com.app", "tabgrp-100-s2": "com.app",
                              "tabgrp-300-s1": "com.other"])
        store.sync(current: ["app-com.app", "tabgrp-300-s1"],
                   appKeyOf: ["app-com.app": "com.app", "tabgrp-300-s1": "com.other"])
        // 宽限内：占位插到本 app 最右窗口卡之后，仍在 com.other 左边
        XCTAssertEqual(store.liveOrder,
                       ["tabgrp-100-s1", "tabgrp-100-s2", "app-com.app", "tabgrp-300-s1"])
        // Advance past grace (5s)
        timeBox.time = Date().addingTimeInterval(6)
        store.sync(current: ["app-com.app", "tabgrp-300-s1"],
                   appKeyOf: ["app-com.app": "com.app", "tabgrp-300-s1": "com.other"])
        // 宽限过期：tabgrp-100-* 真正离开 liveOrder，占位留在原位（com.other 左边）
        XCTAssertEqual(store.liveOrder, ["app-com.app", "tabgrp-300-s1"])
        XCTAssertEqual(store.reconciled(current: ["app-com.app", "tabgrp-300-s1"],
                                        appKeyOf: ["app-com.app": "com.app",
                                                   "tabgrp-300-s1": "com.other"]),
                       ["app-com.app", "tabgrp-300-s1"])
    }

    // MARK: - c. click placeholder → new tabgrp-* inserts next to placeholder → placeholder stops → window block returns

    func testLaunchFromPlaceholderInsertsNextToIt() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-100-s1", "tabgrp-100-s2"],
                   appKeyOf: ["tabgrp-100-s1": "com.app", "tabgrp-100-s2": "com.app"])
        // Exit → placeholder
        store.sync(current: ["app-com.app"],
                   appKeyOf: ["app-com.app": "com.app"])
        // Advance past grace
        timeBox.time = Date().addingTimeInterval(6)
        store.sync(current: ["app-com.app"],
                   appKeyOf: ["app-com.app": "com.app"])
        // New window appears → sticky appKey for "app-com.app" = "com.app"
        // New tabgrp-* should insert after "app-com.app" (same appKey)
        store.sync(current: ["app-com.app", "tabgrp-100-s3"],
                   appKeyOf: ["app-com.app": "com.app", "tabgrp-100-s3": "com.app"])
        let reconciled = store.reconciled(current: ["app-com.app", "tabgrp-100-s3"],
                                          appKeyOf: ["app-com.app": "com.app", "tabgrp-100-s3": "com.app"])
        XCTAssertEqual(reconciled, ["app-com.app", "tabgrp-100-s3"])
        // Now placeholder stops injecting (app running with real window)
        store.sync(current: ["tabgrp-100-s3"],
                   appKeyOf: ["tabgrp-100-s3": "com.app"])
        // app-com.app enters grace, still in liveOrder temporarily
        // reconciled 只返回 current（用户只看到 tabgrp-100-s3），但 liveOrder 保留了 app-com.app 的位置
        XCTAssertEqual(store.liveOrder, ["app-com.app", "tabgrp-100-s3"])
        XCTAssertEqual(store.reconciled(current: ["tabgrp-100-s3"],
                                        appKeyOf: ["tabgrp-100-s3": "com.app"]),
                       ["tabgrp-100-s3"])
    }

    // MARK: - d. multiple kept apps alternate exit/launch without cross-contamination

    func testMultipleKeptAppsNoCrossContamination() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        // Two apps with windows, interleaved in order
        store.sync(current: ["tabgrp-100-s1", "tabgrp-200-s1", "tabgrp-100-s2"],
                   appKeyOf: ["tabgrp-100-s1": "com.a", "tabgrp-200-s1": "com.b", "tabgrp-100-s2": "com.a"])
        // App A exits → placeholder
        store.sync(current: ["tabgrp-200-s1", "app-com.a"],
                   appKeyOf: ["tabgrp-200-s1": "com.b", "app-com.a": "com.a"])
        // Advance past grace for tabgrp-100-*
        timeBox.time = Date().addingTimeInterval(6)
        store.sync(current: ["tabgrp-200-s1", "app-com.a"],
                   appKeyOf: ["tabgrp-200-s1": "com.b", "app-com.a": "com.a"])
        // App B exits → placeholder
        store.sync(current: ["app-com.a", "app-com.b"],
                   appKeyOf: ["app-com.a": "com.a", "app-com.b": "com.b"])
        // Advance past grace for tabgrp-200-s1
        timeBox.time = Date().addingTimeInterval(12)
        store.sync(current: ["app-com.a", "app-com.b"],
                   appKeyOf: ["app-com.a": "com.a", "app-com.b": "com.b"])
        // Both placeholders in order: A before B (matching original interleaving)
        let reconciled = store.reconciled(current: ["app-com.a", "app-com.b"],
                                          appKeyOf: ["app-com.a": "com.a", "app-com.b": "com.b"])
        XCTAssertEqual(reconciled, ["app-com.a", "app-com.b"])
        // App A relaunches → new window inserts next to app-com.a
        store.sync(current: ["app-com.a", "tabgrp-100-s3", "app-com.b"],
                   appKeyOf: ["app-com.a": "com.a", "tabgrp-100-s3": "com.a", "app-com.b": "com.b"])
        let reconciled2 = store.reconciled(current: ["app-com.a", "tabgrp-100-s3", "app-com.b"],
                                           appKeyOf: ["app-com.a": "com.a", "tabgrp-100-s3": "com.a", "app-com.b": "com.b"])
        XCTAssertEqual(reconciled2, ["app-com.a", "tabgrp-100-s3", "app-com.b"])
    }

    // MARK: - e. sticky appKey pruning

    func testStickyAppKeyPruning() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        // com.app 在左、com.other 在右——若粘性键/旧 id 未被清，重开的窗口会错误接回左边原位
        store.sync(current: ["tabgrp-100-s1", "tabgrp-300-s1"],
                   appKeyOf: ["tabgrp-100-s1": "com.app", "tabgrp-300-s1": "com.other"])
        // com.app 关闭（非 kept，无占位注入），宽限过期后 id 与粘性键都应清掉
        store.sync(current: ["tabgrp-300-s1"],
                   appKeyOf: ["tabgrp-300-s1": "com.other"])
        timeBox.time = Date().addingTimeInterval(6)
        store.sync(current: ["tabgrp-300-s1"],
                   appKeyOf: ["tabgrp-300-s1": "com.other"])
        XCTAssertEqual(store.liveOrder, ["tabgrp-300-s1"])
        // 新窗口重开：无残留记忆可匹配 → 追加末尾（com.other 右边），不复活旧位置
        store.sync(current: ["tabgrp-300-s1", "tabgrp-100-s2"],
                   appKeyOf: ["tabgrp-300-s1": "com.other", "tabgrp-100-s2": "com.app"])
        XCTAssertEqual(store.liveOrder, ["tabgrp-300-s1", "tabgrp-100-s2"])
    }

    // MARK: - f. persistableLiveOrder with keptIDs

    func testPersistableLiveOrderWithKeptIDs() {
        let order = ["tabgrp-1-s1", "app-com.kept", "app-com.notkept", "tabgrp-2-s1"]
        let result = StripOrdering.persistableLiveOrder(order, keptIDs: ["com.kept"])
        XCTAssertEqual(result, ["tabgrp-1-s1", "app-com.kept", "tabgrp-2-s1"])
    }

    func testPersistableLiveOrderWithoutKeptIDs() {
        let order = ["tabgrp-1-s1", "app-com.kept", "tabgrp-2-s1"]
        let result = StripOrdering.persistableLiveOrder(order)
        XCTAssertEqual(result, ["tabgrp-1-s1", "tabgrp-2-s1"])
    }

    // MARK: - g. pre-sync 首帧一致（影子滑动修复）
    //
    // 关键：DockStripView 首帧先用**旧 liveOrder + 新 current** 渲染（reconciled），`.onChange`
    // 才触发 sync。这些用例直接调 reconciled、**不先跑对应 current 的 sync**，锁死首帧不再把
    // 新 app-*/tabgrp-* 甩到尾部（否则 spring 会把它从右拉回 = 影子滑动）。

    /// 退出首帧：位于两条目之间的 kept app 退出，占位首帧就落原位，绝不尾插。
    func testExitFirstFramePreSyncKeepsPosition() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-A", "tabgrp-K", "tabgrp-B"],
                   appKeyOf: ["tabgrp-A": "com.a", "tabgrp-K": "com.k", "tabgrp-B": "com.b"])
        // K 退出：sync 尚未跑，current 已换成占位 app-com.k
        let firstFrame = store.reconciled(
            current: ["tabgrp-A", "app-com.k", "tabgrp-B"],
            appKeyOf: ["tabgrp-A": "com.a", "app-com.k": "com.k", "tabgrp-B": "com.b"])
        XCTAssertEqual(firstFrame, ["tabgrp-A", "app-com.k", "tabgrp-B"])
    }

    /// 重开首帧：占位 → 新窗口的真实互斥切换，pre-sync 与 post-sync 可见顺序完全一致。
    func testReopenFirstFramePreSyncMatchesPostSync() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-A", "tabgrp-K", "tabgrp-B"],
                   appKeyOf: ["tabgrp-A": "com.a", "tabgrp-K": "com.k", "tabgrp-B": "com.b"])
        store.sync(current: ["tabgrp-A", "app-com.k", "tabgrp-B"],
                   appKeyOf: ["tabgrp-A": "com.a", "app-com.k": "com.k", "tabgrp-B": "com.b"])
        timeBox.time = timeBox.time.addingTimeInterval(6) // 过 grace，旧 tabgrp-K 落地
        store.sync(current: ["tabgrp-A", "app-com.k", "tabgrp-B"],
                   appKeyOf: ["tabgrp-A": "com.a", "app-com.k": "com.k", "tabgrp-B": "com.b"])
        XCTAssertEqual(store.liveOrder, ["tabgrp-A", "app-com.k", "tabgrp-B"])
        // 重开：占位 → 新窗口 tabgrp-new（互斥，不共存）。首帧 render（sync 未跑）。
        let keys = ["tabgrp-A": "com.a", "tabgrp-new": "com.k", "tabgrp-B": "com.b"]
        let preSync = store.reconciled(current: ["tabgrp-A", "tabgrp-new", "tabgrp-B"], appKeyOf: keys)
        store.sync(current: ["tabgrp-A", "tabgrp-new", "tabgrp-B"], appKeyOf: keys)
        let postSync = store.reconciled(current: ["tabgrp-A", "tabgrp-new", "tabgrp-B"], appKeyOf: keys)
        XCTAssertEqual(preSync, ["tabgrp-A", "tabgrp-new", "tabgrp-B"])
        XCTAssertEqual(preSync, postSync)
    }

    /// 多窗口 kept app 折叠为一个占位：首帧就继承整块窗口的既定 rank（夹在两邻居之间）。
    func testMultiWindowKeptCollapsesToPlaceholderKeepingRank() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-L", "tabgrp-K1", "tabgrp-K2", "tabgrp-R"],
                   appKeyOf: ["tabgrp-L": "com.l", "tabgrp-K1": "com.k",
                              "tabgrp-K2": "com.k", "tabgrp-R": "com.r"])
        // 两窗一起退出 → 单占位，首帧 render
        let firstFrame = store.reconciled(
            current: ["tabgrp-L", "app-com.k", "tabgrp-R"],
            appKeyOf: ["tabgrp-L": "com.l", "app-com.k": "com.k", "tabgrp-R": "com.r"])
        XCTAssertEqual(firstFrame, ["tabgrp-L", "app-com.k", "tabgrp-R"])
    }

    /// 普通（非 kept）app 在 grace 内换新 seat：首帧继承原位；grace 后再开落尾由既有
    /// `testStickyAppKeyPruning` 覆盖。
    func testPlainAppNewSeatWithinGraceInheritsPositionFirstFrame() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-L", "tabgrp-K1", "tabgrp-R"],
                   appKeyOf: ["tabgrp-L": "com.l", "tabgrp-K1": "com.k", "tabgrp-R": "com.r"])
        // K1 关闭（普通 app，无占位注入）→ sync 打戳、liveOrder 仍留 K1（grace 内）
        store.sync(current: ["tabgrp-L", "tabgrp-R"],
                   appKeyOf: ["tabgrp-L": "com.l", "tabgrp-R": "com.r"])
        XCTAssertEqual(store.liveOrder, ["tabgrp-L", "tabgrp-K1", "tabgrp-R"])
        timeBox.time = timeBox.time.addingTimeInterval(2) // 仍在 grace 内
        // 新窗口 K2 首帧 render（sync 未跑）→ 继承 K1 原位，不甩尾
        let firstFrame = store.reconciled(
            current: ["tabgrp-L", "tabgrp-K2", "tabgrp-R"],
            appKeyOf: ["tabgrp-L": "com.l", "tabgrp-K2": "com.k", "tabgrp-R": "com.r"])
        XCTAssertEqual(firstFrame, ["tabgrp-L", "tabgrp-K2", "tabgrp-R"])
    }

    /// 多个 kept app 同帧各自退出（占位并存）：首帧互不串位。
    func testMultipleKeptAppsFirstFrameNoCrossContamination() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-A1", "tabgrp-B1", "tabgrp-A2", "tabgrp-C1"],
                   appKeyOf: ["tabgrp-A1": "com.a", "tabgrp-B1": "com.b",
                              "tabgrp-A2": "com.a", "tabgrp-C1": "com.c"])
        // A、B 同帧退出 → 各出占位；C 仍在。首帧 render。
        let firstFrame = store.reconciled(
            current: ["app-com.a", "app-com.b", "tabgrp-C1"],
            appKeyOf: ["app-com.a": "com.a", "app-com.b": "com.b", "tabgrp-C1": "com.c"])
        // A 占位继承 A 块（原 A1..A2 区间头 = B1 之前）；B 占位继承 B1 位；C 不动。
        XCTAssertEqual(firstFrame, ["app-com.a", "app-com.b", "tabgrp-C1"])
    }
}
