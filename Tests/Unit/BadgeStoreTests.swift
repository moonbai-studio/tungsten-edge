import XCTest

/// BadgeStore 定点读改造的行为锁：范围过滤、瞬态失效沿用旧值、名单变化重走、10s 自愈。
@MainActor
final class BadgeStoreTests: XCTestCase {
    private let wechat = "com.tencent.xinWeChat"

    func testFullWalkThenTargetedPublishesMessagingScopedBadges() async {
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3", "com.apple.mail": "12"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        reader.targetedResult = .ok([wechat: "5"])
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        // 全走树落地：发布范围收窄到消息应用（Mail 的角标不进字典）。
        XCTAssertEqual(store.badgesByBundleID, [wechat: "3"])
        XCTAssertEqual(reader.fullWalkCount, 1)

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(store.badgesByBundleID, [wechat: "5"])
        XCTAssertEqual(reader.targetedCount, 1)
        XCTAssertEqual(reader.fullWalkCount, 1)
    }

    func testEmptyReadableSetMakesZeroReads() async {
        let reader = StubBadgeReader()
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        // kept 但没跑的消息应用没有 Dock 磁贴：可读集 = 可见 ∩ 在跑 = 空。
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(reader.fullWalkCount, 0)
        XCTAssertEqual(reader.targetedCount, 0)
        XCTAssertEqual(store.badgesByBundleID, [:])
    }

    func testCacheInvalidKeepsPreviousBadgesAndRewalksNextTick() async {
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        reader.targetedResult = .cacheInvalid
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        // 瞬态失效：沿用上次发布值，角标不闪没。
        XCTAssertEqual(store.badgesByBundleID, [wechat: "3"])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        // 下一 tick 重走全树恢复。
        XCTAssertEqual(reader.fullWalkCount, 2)
    }

    func testMessagingContextChangeTriggersRewalk() async {
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        reader.targetedResult = .ok([wechat: "3"])
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(reader.fullWalkCount, 1)

        // 新消息应用进入在跑集合 = Dock 磁贴新生 → 必须重走树把新磁贴收进缓存。
        store.updateMessagingContext(
            visibleMessagingIDs: [wechat, "com.electron.lark"],
            runningBundleIDs: [wechat, "com.electron.lark"]
        )
        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(reader.fullWalkCount, 2)
    }

    func testSelfHealRewalksAfterInterval() async {
        let uptime = BadgeUptimeBox(value: 100)
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        reader.targetedResult = .ok([wechat: "3"])
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { uptime.value })
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(reader.fullWalkCount, 1)
        XCTAssertEqual(reader.targetedCount, 1)

        uptime.value = 111   // 越过 10s 自愈间隔
        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(reader.fullWalkCount, 2)
    }

    func testShrinkingReadableSetImmediatelyRemovesDisabledBadges() async {
        let lark = "com.electron.lark"
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3", lark: "8"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        store.updateMessagingContext(visibleMessagingIDs: [wechat, lark], runningBundleIDs: [wechat, lark])
        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(store.badgesByBundleID, [wechat: "3", lark: "8"])

        store.updateMessagingContext(visibleMessagingIDs: [lark], runningBundleIDs: [wechat, lark])
        // Closing one checkbox removes its badge synchronously, even while another app stays eligible.
        XCTAssertEqual(store.badgesByBundleID, [lark: "8"])

        store.updateMessagingContext(visibleMessagingIDs: [], runningBundleIDs: [wechat, lark])
        XCTAssertEqual(store.badgesByBundleID, [:])
    }

    func testTargetedReadInFlightCannotRestoreDisabledBadge() async {
        let lark = "com.electron.lark"
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3", lark: "8"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        reader.targetedResult = .ok([wechat: "9", lark: "5"])
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        store.updateMessagingContext(visibleMessagingIDs: [wechat, lark], runningBundleIDs: [wechat, lark])
        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }

        let gate = DispatchSemaphore(value: 0)
        reader.targetedReadGate = gate
        defer { gate.signal() }
        store.readOnceForTesting()
        await waitUntil { reader.targetedCount == 1 }
        XCTAssertEqual(reader.targetedCount, 1)
        XCTAssertTrue(store.isReadingForTesting)

        store.updateMessagingContext(visibleMessagingIDs: [lark], runningBundleIDs: [wechat, lark])
        gate.signal()
        await waitUntil { !store.isReadingForTesting }

        // The old AX response still contains WeChat; only the currently enabled app may be published.
        XCTAssertEqual(store.badgesByBundleID, [lark: "5"])
    }

    func testLegacyKillSwitchStillRespectsReadableSet() async {
        let reader = StubBadgeReader()
        reader.legacyResult = [wechat: "3", "com.apple.mail": "12"]
        let store = BadgeStore(reader: reader, targetedEnabled: false, uptimeProvider: { 100 })
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        // The kill switch changes how AX is read, not which apps the user allowed to show badges.
        XCTAssertEqual(store.badgesByBundleID, [wechat: "3"])
        XCTAssertEqual(reader.legacyCount, 1)

        store.updateMessagingContext(visibleMessagingIDs: [], runningBundleIDs: [wechat])
        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(store.badgesByBundleID, [:])
        XCTAssertEqual(reader.legacyCount, 2)
    }

    // MARK: - 零感知门控（WI-6）

    func testStartWithEmptyContextStaysPausedUntilMessagingAppears() async {
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        defer { store.stop() }

        store.start()
        // 没有任何可读消息应用：连计时器都不起，零 AX 流量。
        XCTAssertFalse(store.isTimerRunningForTesting)
        XCTAssertEqual(reader.fullWalkCount, 0)

        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])
        // 恢复条件出现：计时器重建并立即读一次。
        XCTAssertTrue(store.isTimerRunningForTesting)
        await waitUntil { !store.isReadingForTesting && reader.fullWalkCount == 1 }
        XCTAssertEqual(reader.fullWalkCount, 1)
        XCTAssertEqual(store.badgesByBundleID, [wechat: "3"])
    }

    func testHiddenTaskbarPausesAndKeepsBadgesThenResumeReadsImmediately() async {
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        reader.targetedResult = .ok([wechat: "3"])
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        defer { store.stop() }
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])
        store.start()
        await waitUntil { !store.isReadingForTesting && reader.fullWalkCount == 1 }

        store.setTaskbarVisible(false)
        XCTAssertFalse(store.isTimerRunningForTesting)
        // 隐藏期间保留上次值：重新显示时 chip 立即带旧角标出现，不闪。
        XCTAssertEqual(store.badgesByBundleID, [wechat: "3"])
        let readsWhileHidden = reader.fullWalkCount + reader.targetedCount

        store.setTaskbarVisible(true)
        XCTAssertTrue(store.isTimerRunningForTesting)
        await waitUntil { !store.isReadingForTesting && reader.fullWalkCount + reader.targetedCount > readsWhileHidden }
        // 恢复必须立即读一次，不等下一个 0.5s tick。
        XCTAssertEqual(reader.fullWalkCount + reader.targetedCount, readsWhileHidden + 1)
    }

    func testPauseKillSwitchKeepsTimerRunning() {
        let reader = StubBadgeReader()
        let store = BadgeStore(
            reader: reader,
            targetedEnabled: true,
            pauseEnabled: false,
            uptimeProvider: { 100 }
        )
        defer { store.stop() }

        store.start()
        // DOCK_BADGE_PAUSE=0：计时器常驻；空名单 tick 本身零 AX 流量（读不到任何调用）。
        XCTAssertTrue(store.isTimerRunningForTesting)
        XCTAssertEqual(reader.fullWalkCount, 0)
        XCTAssertEqual(reader.targetedCount, 0)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private final class StubBadgeReader: DockBadgeReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _fullWalkResult = DockBadgeWalkOutcome(badges: [:], cache: nil, pathToBundleID: [:])
    private var _targetedResult = DockBadgeTargetedOutcome.ok([:])
    private var _targetedReadGate: DispatchSemaphore?
    private var _legacyResult: [String: String] = [:]
    private var _fullWalkCount = 0
    private var _targetedCount = 0
    private var _legacyCount = 0

    var fullWalkResult: DockBadgeWalkOutcome {
        get { lock.lock(); defer { lock.unlock() }; return _fullWalkResult }
        set { lock.lock(); _fullWalkResult = newValue; lock.unlock() }
    }

    var targetedResult: DockBadgeTargetedOutcome {
        get { lock.lock(); defer { lock.unlock() }; return _targetedResult }
        set { lock.lock(); _targetedResult = newValue; lock.unlock() }
    }

    var targetedReadGate: DispatchSemaphore? {
        get { lock.lock(); defer { lock.unlock() }; return _targetedReadGate }
        set { lock.lock(); _targetedReadGate = newValue; lock.unlock() }
    }

    var legacyResult: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return _legacyResult }
        set { lock.lock(); _legacyResult = newValue; lock.unlock() }
    }

    var fullWalkCount: Int { lock.lock(); defer { lock.unlock() }; return _fullWalkCount }
    var targetedCount: Int { lock.lock(); defer { lock.unlock() }; return _targetedCount }
    var legacyCount: Int { lock.lock(); defer { lock.unlock() }; return _legacyCount }

    func readBadges() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        _legacyCount += 1
        return _legacyResult
    }

    func fullWalk(previousPathMap: [String: String]) -> DockBadgeWalkOutcome {
        lock.lock(); defer { lock.unlock() }
        _fullWalkCount += 1
        return _fullWalkResult
    }

    func targetedRead(
        cache: DockItemCache,
        bundleIDs: [String],
        previousBadges: [String: String]
    ) -> DockBadgeTargetedOutcome {
        lock.lock()
        _targetedCount += 1
        let result = _targetedResult
        let gate = _targetedReadGate
        lock.unlock()
        gate?.wait()
        return result
    }
}

private final class BadgeUptimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval

    init(value: TimeInterval) {
        self.storage = value
    }

    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
