import ApplicationServices
import CoreGraphics
import XCTest

/// 周期对账批量后台读（schedulePeriodicBatchRead / completePeriodicBatch）的行为锁：
/// 每 pid 恰读一次并落地、在途事件读抑制批读、代际变更丢弃落地、`.unread` 不动座位状态。
@MainActor
final class AppTrackerPeriodicBatchTests: XCTestCase {
    private let pidA: pid_t = 4242
    private let pidB: pid_t = 4343
    private let cgWindowA: CGWindowID = 77
    private let cgWindowB: CGWindowID = 88

    func testBatchReadsEachTrackedPidOnceAndAppliesResult() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Renamed A")]),
            pidB: .success([makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Renamed B")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidB))

        await waitUntil {
            !tracker.hasPendingEventReadForTesting(pid: self.pidA)
                && !tracker.hasPendingEventReadForTesting(pid: self.pidB)
        }

        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.title, "Renamed A")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidB)?.windowsByID[cgWindowB]?.title, "Renamed B")
    }

    func testInFlightEventReadSuppressesPeriodicBatchForThatPid() async {
        let reader = PeriodicBatchReader(
            resultsByPID: [pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")])],
            blocksTimedReads: true
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.scheduleEventReadForTesting(pid: pidA, source: .windowCreated)
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))

        // 事件读在途 → 本轮批读必须跳过该 pid，不注册第二个 pending。
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())

        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        // 只有事件读那一次；批读没有为同 pid 排第二次。
        XCTAssertEqual(reader.readCount, 1)
    }

    func testGenerationBumpMidFlightDiscardsBatchLanding() async {
        let provider = BatchMutableProcessProvider()
        let reader = PeriodicBatchReader(
            resultsByPID: [pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Renamed A")])],
            blocksTimedReads: true
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: provider,
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        // 读还堵在探针里，此刻换代（pid 复用）：落地必须被身份检查拦下。
        provider.advanceGeneration()
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.title, "Window")
    }

    func testUnreadBatchRoundLeavesSeatStateUntouched() async {
        let absence = Date(timeIntervalSince1970: 10)
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .unread(.cannotComplete)])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        var app = makeApp(pid: pidA, cgWindowID: cgWindowA)
        app.windowsByID[cgWindowA]?.isMinimized = true
        app.windowsByID[cgWindowA]?.minAbsentSince = absence
        app.shadowTabCgIDs = [91, 92]
        tracker.installFixtureForTesting(app)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }

        let after = tracker.fixtureAppForTesting(pid: pidA)
        XCTAssertEqual(after?.windowOrder, [cgWindowA])
        XCTAssertEqual(after?.windowsByID[cgWindowA]?.title, "Window")
        XCTAssertEqual(after?.windowsByID[cgWindowA]?.minAbsentSince, absence)
        XCTAssertEqual(after?.shadowTabCgIDs, [91, 92])
        XCTAssertEqual(reader.readCount, 1)
    }

    // MARK: - 跳读门控集成（DOCK_RECONCILE_SKIP 默认开）

    func testQuiescentPidIsSkippedOnSecondBatch() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)

        // 第二轮：无事件、CG 集不变、上一轮无变化 → 跳过，连 pending 都不注册。
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertFalse(tracker.hasPendingEventReadForTesting(pid: pidA))
        await waitUntil(timeoutNanoseconds: 300_000_000) { reader.readCount > 1 }   // 短暂等待以证明确实没有读发生
        XCTAssertEqual(reader.readCount, 1)
    }

    func testMinimizeEventReopensGate() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // AX 最小化事件置脏 → 下一轮必须全读。
        tracker.minimizeForTesting(pid: pidA, cgWindowID: cgWindowA)
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testCGSetChangeReopensGate() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // 该 pid 的 CG layer-0 集合多了一个窗口 → 必须全读。
        let grown = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB, 99],
            onScreenWindowIDs: [cgWindowA, cgWindowB, 99],
            windowIDsByPID: [pidA: [cgWindowA, 99], pidB: [cgWindowB]],
            alphaByWindowID: [:]
        )
        tracker.runPeriodicBatchForTesting(cgSnapshot: grown)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testAbsenceClockKeepsReadingEveryBatch() async {
        // phantom 证据必须按原节奏采样：有缺席时钟的 pid 每一轮都读，绝不跳。
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([])])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        var app = makeApp(pid: pidA, cgWindowID: cgWindowA)
        app.windowsByID[cgWindowA]?.isMinimized = true
        app.windowsByID[cgWindowA]?.isFocused = false
        app.windowsByID[cgWindowA]?.minAbsentSince = Date(timeIntervalSince1970: 10)
        app.windowsByID[cgWindowA]?.absenceEpisodeID = UUID()
        tracker.installFixtureForTesting(app)
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testRefreshDueForcesReadAfterMaxSkipInterval() async {
        let uptime = UptimeBox(value: 1000)
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true,
            uptimeProvider: { uptime.value }
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // 越过 30s 单调时钟兜底 → 强制全读。
        uptime.value = 1031
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testUnreadRoundIsAlwaysRetried() async {
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .unread(.cannotComplete)])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    // MARK: - 前台缓存（下一轮 A）

    func testFrontmostCacheDrivesActiveHighlightWithoutWorkspaceQuery() {
        let tracker = AppTracker(
            reader: PeriodicBatchReader(resultsByPID: [:]),
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        // 缓存说 pidA 在前台 → 该窗口是 active（真实 frontmostApplication 在测试进程里是别人）。
        tracker.setFrontmostPIDForTesting(pidA)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .active)

        // 缓存改指别的进程 → 同一个座位立刻降级为 inactive。
        tracker.setFrontmostPIDForTesting(pidB)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .inactive)
    }

    func testFrontmostCacheKillSwitchIgnoresCachedValue() {
        let tracker = AppTracker(
            reader: PeriodicBatchReader(resultsByPID: [:]),
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true,
            frontmostCacheEnabled: false
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        // DOCK_FRONTMOST_CACHE=0：每次真查 NSWorkspace，缓存值不参与判定；
        // 测试进程的真实前台不是 pidA，所以座位不会被点亮。
        tracker.setFrontmostPIDForTesting(pidA)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .inactive)
    }

    // MARK: - CG 全表复用门控（DOCK_CG_SNAPSHOT_REUSE 默认开）

    private func makeCountingTracker(
        reuseEnabled: Bool = true,
        probeBox: ProbeBox,
        counters: CGCallCounters,
        uptime: UptimeBox? = nil
    ) -> AppTracker {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let snapshot = cgSnapshot()
        let box = uptime
        return AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { counters.noteCapture(); return snapshot },
            onScreenWindowIDsProvider: { counters.noteProbe(); return probeBox.value },
            eventAXAsyncEnabled: true,
            cgSnapshotReuseEnabled: reuseEnabled,
            uptimeProvider: { box?.value ?? 1000 }
        )
    }

    private func runEventRead(_ tracker: AppTracker) async {
        tracker.scheduleEventReadForTesting(pid: pidA, source: .frontmostPoll)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
    }

    func testQuietSecondEventReadReusesCachedTable() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(probeBox: ProbeBox(value: [cgWindowA]), counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)          // 无缓存 → 探针 + 现拍，缓存接上
        XCTAssertNotNil(tracker.cgSnapshotCacheForTesting())
        let capturesAfterFirst = counters.captures

        await runEventRead(tracker)          // 安静 tick：探针相同 → 复用，全拍数不增
        XCTAssertEqual(counters.captures, capturesAfterFirst)
    }

    func testProbeChangeForcesFreshCapture() async {
        let counters = CGCallCounters()
        let probeBox = ProbeBox(value: [cgWindowA])
        let tracker = makeCountingTracker(probeBox: probeBox, counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        probeBox.value = [cgWindowA, cgWindowB]   // on-screen 集变了（如切了标签）
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testEventGenerationBumpForcesFreshCapture() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(probeBox: ProbeBox(value: [cgWindowA]), counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        tracker.bumpCGEventGenerationForTesting()  // 期间来了 AX/workspace 事件
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testCacheExpiryForcesFreshCapture() async {
        let counters = CGCallCounters()
        let uptime = UptimeBox(value: 1000)
        let tracker = makeCountingTracker(
            probeBox: ProbeBox(value: [cgWindowA]), counters: counters, uptime: uptime
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        uptime.value = 1000 + CGSnapshotReuseDecision.defaultMaxCacheAge + 0.1
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testKillSwitchCapturesEveryTimeAndNeverProbes() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(
            reuseEnabled: false, probeBox: ProbeBox(value: [cgWindowA]), counters: counters
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        await runEventRead(tracker)
        // 与关门前逐位一致：每次事件读各现拍一张。探针计数只可能来自 rebuildSnapshot 的
        // on-screen 兜底（本用例 seats 不变、不重建），事件读路径必须一次探针都没拍。
        XCTAssertEqual(counters.captures, 2)
        XCTAssertEqual(counters.probes, 0)
        XCTAssertNil(tracker.cgSnapshotCacheForTesting())
    }

    // MARK: - Fixtures

    /// 关窗口事件必须走限时后台读，不能在主 actor 上触发不限时读（被关窗口的 App 卡住时主线程会冻 ~12s）。
    func testWindowDestroyedUsesTimedBackgroundReadNeverUntimedMainActorRead() async {
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([])])
        let emptyCG = AppTrackerCGWindowSnapshot(
            allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:]
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { emptyCG },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.destroyForTesting(pid: pidA, cgWindowID: cgWindowA)

        XCTAssertEqual(reader.untimedReadCount, 0, "destroy 处理器不得在主 actor 上做不限时 AX 读")
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(reader.untimedReadCount, 0)
        // AX 空 + CG 全列表已无该窗口 → 座位真删。
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
    }

    private func cgSnapshot() -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB],
            onScreenWindowIDs: [cgWindowA, cgWindowB],
            windowIDsByPID: [pidA: [cgWindowA], pidB: [cgWindowB]],
            alphaByWindowID: [:]
        )
    }

    private func makeApp(pid: pid_t, cgWindowID: CGWindowID) -> AppEntry {
        let seat = WindowEntry(
            cgWindowID: cgWindowID,
            token: "tabgrp-\(pid)-s1",
            title: "Window",
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            isMinimized: false,
            isFocused: true,
            everSeenVisible: true
        )
        return AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture\(pid)",
            appName: "Fixture\(pid)",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [cgWindowID: seat],
            windowOrder: [cgWindowID],
            isHidden: false
        )
    }

    private func makeSnapshot(pid: pid_t, cgWindowID: CGWindowID, title: String) -> AXWindowSnapshot {
        AXWindowSnapshot(
            pid: pid,
            cgWindowID: cgWindowID,
            titleRead: .value(title),
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isMinimized: false,
            isFocusedWindow: true,
            element: AXUIElementCreateApplication(pid)
        )
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

/// 可注入按 pid 定制结果的限时读探针；可选在读中阻塞（模拟批读在途窗口）。
private final class PeriodicBatchReader: AppTrackerWindowReading, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    private var untimedCount = 0
    private let resultsByPID: [pid_t: AXWindowReadResult]
    private let blocksTimedReads: Bool

    init(resultsByPID: [pid_t: AXWindowReadResult], blocksTimedReads: Bool = false) {
        self.resultsByPID = resultsByPID
        self.blocksTimedReads = blocksTimedReads
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func releaseOne() {
        semaphore.signal()
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }

    var untimedReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return untimedCount
    }

    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult {
        lock.lock()
        untimedCount += 1
        lock.unlock()
        return resultsByPID[pid] ?? .unread(.cannotComplete)
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        lock.lock()
        count += 1
        lock.unlock()
        if blocksTimedReads { semaphore.wait() }
        return resultsByPID[pid] ?? .unread(.cannotComplete)
    }
}

private final class CGCallCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var captureCount = 0
    private var probeCount = 0

    func noteCapture() { lock.lock(); captureCount += 1; lock.unlock() }
    func noteProbe() { lock.lock(); probeCount += 1; lock.unlock() }

    var captures: Int { lock.lock(); defer { lock.unlock() }; return captureCount }
    var probes: Int { lock.lock(); defer { lock.unlock() }; return probeCount }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<CGWindowID>

    init(value: Set<CGWindowID>) { self.storage = value }

    var value: Set<CGWindowID> {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private final class UptimeBox: @unchecked Sendable {
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

private struct BatchFixedProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(pid: pid, startTimeSec: 1, startTimeUsec: 2, bundleID: bundleID)
    }
}

private final class BatchMutableProcessProvider: AppTrackerProcessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: Int64 = 1

    func advanceGeneration() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        lock.lock()
        let current = generation
        lock.unlock()
        return ScanAdmissionDecision.ProcessIdentity(
            pid: pid,
            startTimeSec: current,
            startTimeUsec: 0,
            bundleID: bundleID
        )
    }
}
