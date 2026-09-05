import ApplicationServices
import Combine
import XCTest

final class AXWindowReaderResultTests: XCTestCase {
    func testSuccessPreservesOriginalWindowArray() {
        let snapshot = AXWindowSnapshot(
            pid: 42,
            cgWindowID: 123,
            titleRead: .value("test"),
            bounds: nil,
            role: nil,
            subrole: nil,
            isMinimized: false,
            isFocusedWindow: false,
            element: AXUIElementCreateApplication(42)
        )

        let windows = AXWindowReadResult.success([snapshot]).windowsOrEmpty

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].pid, snapshot.pid)
        XCTAssertEqual(windows[0].cgWindowID, snapshot.cgWindowID)
        XCTAssertEqual(windows[0].title, "test")
    }

    func testUnreadStillMapsToEmptyArrayAndKeepsError() {
        let result = AXWindowReadResult.unread(.cannotComplete)

        XCTAssertTrue(result.windowsOrEmpty.isEmpty)
        guard case .unread(let error) = result else {
            return XCTFail("expected unread")
        }
        XCTAssertEqual(error, .cannotComplete)
    }

    func testTitleReadClassifiesNonEmptyAndKnownEmptyValues() {
        XCTAssertEqual(
            AXWindowTitleRead.classify(result: .success, value: "  Window  " as CFString),
            .value("Window")
        )
        XCTAssertEqual(AXWindowTitleRead.classify(result: .success, value: "" as CFString), .empty)
        XCTAssertEqual(
            AXWindowTitleRead.classify(result: .success, value: " \n\t " as CFString),
            .empty
        )
        XCTAssertEqual(AXWindowTitleRead.classify(result: .noValue, value: nil), .empty)
        XCTAssertEqual(AXWindowTitleRead.classify(result: .attributeUnsupported, value: nil), .empty)
    }

    func testTitleReadKeepsFailuresDistinctFromEmpty() {
        XCTAssertEqual(
            AXWindowTitleRead.classify(result: .cannotComplete, value: nil),
            .unread(.cannotComplete)
        )
        XCTAssertEqual(
            AXWindowTitleRead.classify(result: .success, value: NSNumber(value: 7)),
            .unread(.failure)
        )
    }
}

final class ActionExecutionSwitchesTests: XCTestCase {
    func testFastHandleMetadataPreservesSnapshotTarget() {
        let bounds = CGRect(x: 10, y: 20, width: 900, height: 700)
        let rawHandle = AXWindowHandle(
            pid: 42,
            title: nil,
            bounds: nil,
            element: AXUIElementCreateApplication(42)
        )
        let handle = AccessibilityWindowActionExecutor.fastHandle(
            from: rawHandle,
            target: .init(pid: 42, title: "Project Window", bounds: bounds)
        )

        XCTAssertEqual(handle.pid, 42)
        XCTAssertEqual(handle.title, "Project Window")
        XCTAssertEqual(handle.bounds, bounds)
    }

    func testTargetMetadataSelectsOneWindowWhileMissingMetadataStaysAmbiguous() {
        let targetBounds = CGRect(x: 10, y: 20, width: 900, height: 700)
        let candidates = [
            AXWindowMatchPolicy.Candidate(
                title: "Project Window",
                bounds: CGRect(x: 1000, y: 20, width: 900, height: 700)
            ),
            AXWindowMatchPolicy.Candidate(title: "Project Window", bounds: targetBounds),
        ]

        XCTAssertEqual(AXWindowMatchPolicy.uniqueBestMatchIndex(
            targetTitle: "Project Window",
            targetBounds: targetBounds,
            candidates: candidates
        ), 1)
        XCTAssertNil(AXWindowMatchPolicy.uniqueBestMatchIndex(
            targetTitle: nil,
            targetBounds: nil,
            candidates: candidates
        ))
    }

    func testDefaultsUseFastHandleAndDisableDiagnosticsAndMinimizeFallback() {
        let switches = ActionExecutionSwitches(environment: [:])

        XCTAssertTrue(switches.fastWindowHandleEnabled)
        XCTAssertFalse(switches.chipProbeEnabled)
        XCTAssertFalse(switches.minimizeAppFallbackEnabled)
    }

    func testCompatibilityKillSwitchesAreDirectional() {
        let switches = ActionExecutionSwitches(environment: [
            "DOCK_FAST_WINDOW_HANDLE": "0",
            "DOCK_CHIP_PROBE": "1",
            "DOCK_MINIMIZE_APP_FALLBACK": "1"
        ])

        XCTAssertFalse(switches.fastWindowHandleEnabled)
        XCTAssertTrue(switches.chipProbeEnabled)
        XCTAssertTrue(switches.minimizeAppFallbackEnabled)
    }

    func testFastHandleHitSkipsFallback() {
        var fastCalls = 0
        var fallbackCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: false,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: false,
            cached: { _ in nil },
            fast: { _ in fastCalls += 1; return "fast" },
            fallback: { fallbackCalls += 1; return "fallback" }
        )

        XCTAssertEqual(result, "fast")
        XCTAssertEqual(fastCalls, 1)
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testFastHandleMissFallsBackExactlyOnce() {
        var fastCalls = 0
        var fallbackCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: false,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: false,
            cached: { _ in nil },
            fast: { _ in fastCalls += 1; return nil },
            fallback: { fallbackCalls += 1; return "fallback" }
        )

        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(fastCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
    }

    // MARK: - 缓存元素档（最小化恢复提速，2026-08-11）

    func testCachedHandleHitSkipsBothSlowerTiers() {
        var cachedCalls = 0
        var fastCalls = 0
        var fallbackCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: true,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: false,
            cached: { _ in cachedCalls += 1; return "cached" },
            fast: { _ in fastCalls += 1; return "fast" },
            fallback: { fallbackCalls += 1; return "fallback" }
        )

        XCTAssertEqual(result, "cached")
        XCTAssertEqual(cachedCalls, 1)
        XCTAssertEqual(fastCalls, 0)
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testCachedHandleMissFallsThroughToFastThenFallback() {
        var cachedCalls = 0
        var fastCalls = 0
        var fallbackCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: true,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: false,
            cached: { _ in cachedCalls += 1; return nil },
            fast: { _ in fastCalls += 1; return nil },
            fallback: { fallbackCalls += 1; return "fallback" }
        )

        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(cachedCalls, 1)
        XCTAssertEqual(fastCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
    }

    /// 刚 unhide 出来的 App，**前两档一律禁用**：AX 元素可能仍在过渡态，缓存里那个更是
    /// 隐藏之前存下的。既有规则（原来只管 fast 一档），扩到缓存档后必须继续成立。
    func testJustUnhidSkipsCachedAndFastTiers() {
        var cachedCalls = 0
        var fastCalls = 0
        var fallbackCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: true,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: true,
            cached: { _ in cachedCalls += 1; return "cached" },
            fast: { _ in fastCalls += 1; return "fast" },
            fallback: { fallbackCalls += 1; return "fallback" }
        )

        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(cachedCalls, 0)
        XCTAssertEqual(fastCalls, 0)
        XCTAssertEqual(fallbackCalls, 1)
    }

    /// `DOCK_AX_ELEMENT_CACHE=0` 必须完整退回改动前的两档行为。
    func testCacheDisabledRestoresPreviousTwoTierBehaviour() {
        var cachedCalls = 0
        var fastCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: false,
            fastEnabled: true,
            cgWindowID: 7,
            justUnhid: false,
            cached: { _ in cachedCalls += 1; return "cached" },
            fast: { _ in fastCalls += 1; return "fast" },
            fallback: { "fallback" }
        )

        XCTAssertEqual(result, "fast")
        XCTAssertEqual(cachedCalls, 0)
        XCTAssertEqual(fastCalls, 1)
    }

    func testNoCGWindowIDGoesStraightToFallback() {
        var cachedCalls = 0
        var fastCalls = 0
        let result: String? = WindowHandleCapturePlan.capture(
            cachedEnabled: true,
            fastEnabled: true,
            cgWindowID: nil,
            justUnhid: false,
            cached: { _ in cachedCalls += 1; return "cached" },
            fast: { _ in fastCalls += 1; return "fast" },
            fallback: { "fallback" }
        )

        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(cachedCalls, 0)
        XCTAssertEqual(fastCalls, 0)
    }

    func testMinimizeCaptureFailureDoesNotUseAppFallbackByDefault() {
        XCTAssertFalse(WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
            requestKind: .minimizeWindow,
            isFinderWindow: false,
            minimizeAppFallbackEnabled: false,
            knownMinimized: false
        ))
        XCTAssertTrue(WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
            requestKind: .minimizeWindow,
            isFinderWindow: false,
            minimizeAppFallbackEnabled: true,
            knownMinimized: false
        ))
        XCTAssertTrue(WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
            requestKind: .activateWindow,
            isFinderWindow: false,
            minimizeAppFallbackEnabled: false,
            knownMinimized: false
        ))
    }

    /// 【承重,2026-08-25】knownMinimized 的 activate 禁止 app 级兜底,且**不挂沉降门开关**:
    /// `activateAppWithWindowRecovery` raise 的是 `visibleWindows[0]`,对最小化目标永远还原
    /// 不了它,只会把兄弟窗口带到前面(owner 连点实测的确切出处)。
    func testKnownMinimizedActivateNeverUsesAppFallback() {
        XCTAssertFalse(WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
            requestKind: .activateWindow,
            isFinderWindow: false,
            minimizeAppFallbackEnabled: false,
            knownMinimized: true
        ))
        // 两轴正交:knownMinimized 不影响 minimize 请求的兜底开关语义。
        XCTAssertTrue(WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
            requestKind: .minimizeWindow,
            isFinderWindow: false,
            minimizeAppFallbackEnabled: true,
            knownMinimized: true
        ))
        // Finder guard 优先级不变。
        XCTAssertFalse(WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
            requestKind: .activateWindow,
            isFinderWindow: true,
            minimizeAppFallbackEnabled: false,
            knownMinimized: true
        ))
    }
}

@MainActor
final class AppTrackerReadSemanticsTests: XCTestCase {
    private let pid: pid_t = 4242
    private let cgWindowID: CGWindowID = 77

    func testUnreadRoundPreservesSeatAbsenceAndShadowState() throws {
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppTrackerUnreadTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        let tracker = AppTracker(inventoryLog: inventoryLog, eventAXAsyncEnabled: true)
        let absence = Date(timeIntervalSince1970: 10)
        let episode = UUID()
        tracker.installFixtureForTesting(makeApp(
            isMinimized: true,
            minAbsentSince: absence,
            episodeID: episode,
            shadowIDs: [88, 89]
        ))

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: emptyCGSnapshot(),
            now: Date(timeIntervalSince1970: 100),
            eligible: [],
            readOutcome: .unread(errorCode: AXError.cannotComplete.rawValue)
        )

        XCTAssertFalse(changed)
        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowOrder, [cgWindowID])
        XCTAssertEqual(app?.shadowTabCgIDs, [88, 89])
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.minAbsentSince, absence)
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.absenceEpisodeID, episode)

        inventoryLog.flush()
        let text = try String(contentsOf: inventoryLog.currentFileURL, encoding: .utf8)
        let record = try XCTUnwrap(text.split(separator: "\n").first)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["event"] as? String, "reconcileUnread")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["readMode"] as? String, "timed")
        XCTAssertEqual(payload["usedPreloadedAX"] as? Bool, true)
        XCTAssertEqual(payload["errorCode"] as? Int, Int(AXError.cannotComplete.rawValue))
    }

    func testSuccessfulEmptyRoundsKeepCGPresentSeatAndShadowPool() throws {
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppTrackerEmptyInventoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        let tracker = AppTracker(inventoryLog: inventoryLog, eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp(shadowIDs: [88, 89]))
        let cgSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID, 88, 89],
            onScreenWindowIDs: [],
            windowIDsByPID: [pid: [cgWindowID, 88, 89]],
            alphaByWindowID: [:]
        )

        for now in [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 110)] {
            _ = tracker.reconcileFixtureForTesting(
                pid: pid,
                cgSnapshot: cgSnapshot,
                now: now,
                eligible: [],
                readOutcome: .success(count: 0)
            )
        }

        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowOrder, [cgWindowID])
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.token, "tabgrp-\(pid)-s1")
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.title, "Window")
        XCTAssertEqual(
            app?.windowsByID[cgWindowID]?.bounds,
            CGRect(x: 10, y: 20, width: 500, height: 400)
        )
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.isFocused, false)
        XCTAssertEqual(app?.shadowTabCgIDs, [88, 89])

        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        XCTAssertFalse(records.contains { record in
            guard record["event"] as? String == "seatReleased",
                  let payload = record["payload"] as? [String: Any] else { return false }
            return payload["reason"] as? String == "absentBeyondGrace"
        })
    }

    func testUnidentifiedSnapshotDoesNotReleaseCGPresentSeat() {
        let tracker = AppTracker(eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp())
        let cgSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID],
            onScreenWindowIDs: [cgWindowID],
            windowIDsByPID: [pid: [cgWindowID]],
            alphaByWindowID: [:]
        )

        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(timeIntervalSince1970: 100),
            eligible: [makeSnapshot(cgWindowID: nil, titleRead: .value("Unknown ID"))],
            readOutcome: .success(count: 1)
        )

        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowOrder, [cgWindowID])
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.token, "tabgrp-\(pid)-s1")
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.title, "Window")
    }

    func testPartialInventoryRetainsOldSeatAndSideWindowStillClosesNormally() throws {
        let sideWindowID: CGWindowID = 88
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppTrackerPartialInventoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        let tracker = AppTracker(inventoryLog: inventoryLog, eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp(seatToken: "existing-seat"))
        let cgSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID, sideWindowID],
            onScreenWindowIDs: [cgWindowID, sideWindowID],
            windowIDsByPID: [pid: [cgWindowID, sideWindowID]],
            alphaByWindowID: [:]
        )

        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(timeIntervalSince1970: 100),
            eligible: [
                makeSnapshot(cgWindowID: nil, titleRead: .value("Unknown ID")),
                makeSnapshot(
                    cgWindowID: sideWindowID,
                    titleRead: .value("Side"),
                    bounds: CGRect(x: 700, y: 20, width: 500, height: 400)
                ),
            ],
            readOutcome: .success(count: 2)
        )

        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowOrder, [cgWindowID, sideWindowID])
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.token, "existing-seat")
        XCTAssertEqual(app?.windowsByID[cgWindowID]?.title, "Window")
        XCTAssertEqual(app?.windowsByID[sideWindowID]?.title, "Side")
        XCTAssertNotEqual(app?.windowsByID[sideWindowID]?.token, "existing-seat")

        let mainOnlyCGSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID],
            onScreenWindowIDs: [cgWindowID],
            windowIDsByPID: [pid: [cgWindowID]],
            alphaByWindowID: [:]
        )
        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: mainOnlyCGSnapshot,
            now: Date(timeIntervalSince1970: 110),
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window"))],
            readOutcome: .success(count: 1)
        )

        let finalApp = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(finalApp?.windowOrder, [cgWindowID])
        XCTAssertEqual(finalApp?.windowsByID[cgWindowID]?.token, "existing-seat")
        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        let sideRelease = try XCTUnwrap(records.first { record in
            guard record["event"] as? String == "seatReleased",
                  let payload = record["payload"] as? [String: Any] else { return false }
            return payload["activeCgID"] as? Int == Int(sideWindowID)
        })
        let payload = try XCTUnwrap(sideRelease["payload"] as? [String: Any])
        XCTAssertEqual(payload["reason"] as? String, "leftCGList")
    }

    func testRetainedSeatReappearsWithSameTokenAndHeldTitle() {
        let tracker = AppTracker(eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp())
        let cgSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID],
            onScreenWindowIDs: [cgWindowID],
            windowIDsByPID: [pid: [cgWindowID]],
            alphaByWindowID: [:]
        )

        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(timeIntervalSince1970: 100),
            eligible: [],
            readOutcome: .success(count: 0)
        )
        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(timeIntervalSince1970: 110),
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .unread(.cannotComplete))],
            readOutcome: .success(count: 1)
        )

        let seat = tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID]
        XCTAssertEqual(seat?.token, "tabgrp-\(pid)-s1")
        XCTAssertEqual(seat?.title, "Window")
    }

    func testCGDisappearanceReleasesSeatAsLeftCGList() throws {
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppTrackerCGCloseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        let tracker = AppTracker(inventoryLog: inventoryLog, eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp())

        _ = tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: emptyCGSnapshot(),
            now: Date(timeIntervalSince1970: 100),
            eligible: [],
            readOutcome: .success(count: 0)
        )

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowOrder, [])
        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        let release = try XCTUnwrap(records.first { $0["event"] as? String == "seatReleased" })
        let payload = try XCTUnwrap(release["payload"] as? [String: Any])
        XCTAssertEqual(payload["reason"] as? String, "leftCGList")
        XCTAssertEqual(payload["seatToken"] as? String, "tabgrp-\(pid)-s1")
    }

    func testDestroyTombstoneReleasesSeatEvenWhileCGStillListsIt() async throws {
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppTrackerDestroyCloseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        // destroy 事件走限时后台读（同其它 AX 事件）；不限时读在主 actor 上一次都不许发生。
        let reader = ControlledAppTrackerReader(
            result: .success([]),
            blocksTimedReads: false
        )
        let cgSnapshot = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowID],
            onScreenWindowIDs: [],
            windowIDsByPID: [pid: [cgWindowID]],
            alphaByWindowID: [:]
        )
        let tracker = AppTracker(
            inventoryLog: inventoryLog,
            reader: reader,
            processProvider: FixedAppTrackerProcessProvider(pid: pid),
            cgSnapshotProvider: { cgSnapshot },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.destroyForTesting(pid: pid, cgWindowID: cgWindowID)
        XCTAssertEqual(reader.untimedReadCount, 0)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }
        XCTAssertEqual(reader.untimedReadCount, 0)

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowOrder, [])
        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        let release = try XCTUnwrap(records.first { $0["event"] as? String == "seatReleased" })
        let payload = try XCTUnwrap(release["payload"] as? [String: Any])
        XCTAssertEqual(payload["reason"] as? String, "leftCGList")
    }

    func testSameWindowUnreadTitlePreservesKnownTitleAndLogsHold() throws {
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppTrackerTitleHeldTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))
        let tracker = AppTracker(inventoryLog: inventoryLog, eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp())

        _ = reconcile(
            tracker,
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .unread(.cannotComplete))]
        )

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID]?.title, "Window")
        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        let held = try XCTUnwrap(records.first { $0["event"] as? String == "titleHeld" })
        let payload = try XCTUnwrap(held["payload"] as? [String: Any])
        XCTAssertEqual(payload["pid"] as? Int, Int(pid))
        XCTAssertEqual(payload["seatToken"] as? String, "tabgrp-\(pid)-s1")
        XCTAssertEqual(payload["activeCgID"] as? Int, Int(cgWindowID))
        XCTAssertEqual(payload["errorCode"] as? Int, Int(AXError.cannotComplete.rawValue))
        XCTAssertNil(payload["title"])
        XCTAssertNil(payload["previousTitle"])
    }

    func testTitleHeldIsNotLoggedWhenNoPreviousTitleIsInherited() throws {
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppTrackerTitleNotHeldTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let inventoryLog = WindowInventoryAnomalyLog(configuration: .init(
            enabled: true,
            directoryURL: logDirectory,
            maxFileSize: 1_000_000,
            archiveCount: 1
        ))

        let knownEmptyTracker = AppTracker(inventoryLog: inventoryLog, eventAXAsyncEnabled: true)
        knownEmptyTracker.installFixtureForTesting(makeApp())
        _ = reconcile(
            knownEmptyTracker,
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .empty)]
        )

        let knownValueTracker = AppTracker(inventoryLog: inventoryLog, eventAXAsyncEnabled: true)
        knownValueTracker.installFixtureForTesting(makeApp())
        _ = reconcile(
            knownValueTracker,
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Updated"))]
        )

        let replacementID: CGWindowID = 88
        let replacementTracker = AppTracker(inventoryLog: inventoryLog, eventAXAsyncEnabled: true)
        replacementTracker.installFixtureForTesting(makeApp())
        _ = reconcile(
            replacementTracker,
            eligible: [makeSnapshot(cgWindowID: replacementID, titleRead: .unread(.cannotComplete))],
            allCGWindowIDs: [cgWindowID, replacementID]
        )

        let newWindowID: CGWindowID = 99
        let newSeatTracker = AppTracker(inventoryLog: inventoryLog, eventAXAsyncEnabled: true)
        newSeatTracker.installFixtureForTesting(makeApp())
        _ = reconcile(
            newSeatTracker,
            eligible: [
                makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window")),
                makeSnapshot(
                    cgWindowID: newWindowID,
                    titleRead: .unread(.cannotComplete),
                    bounds: CGRect(x: 700, y: 20, width: 500, height: 400)
                ),
            ],
            allCGWindowIDs: [cgWindowID, newWindowID]
        )

        inventoryLog.flush()
        let records = try jsonRecords(at: inventoryLog.currentFileURL)
        XCTAssertFalse(records.contains { $0["event"] as? String == "titleHeld" })
    }

    func testSameWindowKnownEmptyTitleClearsKnownTitle() {
        let tracker = AppTracker(eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp())

        _ = reconcile(tracker, eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .empty)])

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID]?.title, "")
    }

    func testSameWindowKnownTitleUpdatesKnownTitle() {
        let tracker = AppTracker(eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp())

        _ = reconcile(
            tracker,
            eligible: [makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Updated"))]
        )

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID]?.title, "Updated")
    }

    func testTabReplacementDoesNotInheritUnreadTitle() {
        let replacementID: CGWindowID = 88
        let tracker = AppTracker(eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp())

        _ = reconcile(
            tracker,
            eligible: [makeSnapshot(cgWindowID: replacementID, titleRead: .unread(.cannotComplete))],
            allCGWindowIDs: [cgWindowID, replacementID]
        )

        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowOrder, [replacementID])
        XCTAssertEqual(app?.windowsByID[replacementID]?.title, "")
    }

    func testTearOutReplacementDoesNotInheritUnreadTitle() {
        let replacementID: CGWindowID = 88
        let tracker = AppTracker(eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp())
        let originalBounds = CGRect(x: 10, y: 20, width: 500, height: 400)
        let movedBounds = CGRect(x: 700, y: 20, width: 500, height: 400)

        _ = reconcile(
            tracker,
            eligible: [
                makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Moved"), bounds: movedBounds),
                makeSnapshot(
                    cgWindowID: replacementID,
                    titleRead: .unread(.cannotComplete),
                    bounds: originalBounds
                ),
            ],
            allCGWindowIDs: [cgWindowID, replacementID]
        )

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[replacementID]?.title, "")
    }

    func testNewSeatDoesNotInheritUnreadTitle() {
        let newWindowID: CGWindowID = 99
        let tracker = AppTracker(eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp())

        _ = reconcile(
            tracker,
            eligible: [
                makeSnapshot(cgWindowID: cgWindowID, titleRead: .value("Window")),
                makeSnapshot(
                    cgWindowID: newWindowID,
                    titleRead: .unread(.cannotComplete),
                    bounds: CGRect(x: 700, y: 20, width: 500, height: 400)
                ),
            ],
            allCGWindowIDs: [cgWindowID, newWindowID]
        )

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[newWindowID]?.title, "")
    }

    func testEventBurstRunsOneLeadingAndExactlyOneTrailingRead() async {
        let reader = ControlledAppTrackerReader()
        let tracker = AppTracker(
            reader: reader,
            processProvider: FixedAppTrackerProcessProvider(pid: pid),
            cgSnapshotProvider: { self.emptyCGSnapshot() },
            onScreenWindowIDsProvider: { [] },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.scheduleEventReadForTesting(pid: pid, source: .windowCreated)
        tracker.scheduleEventReadForTesting(pid: pid, source: .focusChanged)
        tracker.scheduleEventReadForTesting(pid: pid, source: .titleChanged)

        await waitUntil { reader.readCount == 1 }
        reader.releaseOne()
        await waitUntil { reader.readCount == 2 }
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }

        XCTAssertEqual(reader.readCount, 2)
    }

    func testFrontmostPollUsesTimedBackgroundReader() async {
        let reader = ControlledAppTrackerReader(result: .success([]))
        let tracker = AppTracker(
            reader: reader,
            processProvider: FixedAppTrackerProcessProvider(pid: pid),
            cgSnapshotProvider: { self.emptyCGSnapshot() },
            onScreenWindowIDsProvider: { [] },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.scheduleFrontmostPollForTesting(pid: pid)

        await waitUntil { reader.readCount == 1 }
        XCTAssertEqual(reader.untimedReadCount, 0)
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pid))

        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }
    }

    func testMinimizeMutationRejectsOlderAsyncRead() async {
        let reader = ControlledAppTrackerReader(result: .success([]))
        let tracker = AppTracker(
            reader: reader,
            processProvider: FixedAppTrackerProcessProvider(pid: pid),
            cgSnapshotProvider: { self.emptyCGSnapshot() },
            onScreenWindowIDsProvider: { [] },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.scheduleEventReadForTesting(pid: pid, source: .focusChanged)
        await waitUntil { reader.readCount == 1 }
        tracker.minimizeForTesting(pid: pid, cgWindowID: cgWindowID)
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID]?.isMinimized, true)
    }

    func testDestroyMutationRejectsOlderAsyncRead() async {
        let reader = ControlledAppTrackerReader(result: .success([]))
        let tracker = AppTracker(
            reader: reader,
            processProvider: FixedAppTrackerProcessProvider(pid: pid),
            cgSnapshotProvider: { self.emptyCGSnapshot() },
            onScreenWindowIDsProvider: { [] },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.scheduleEventReadForTesting(pid: pid, source: .titleChanged)
        await waitUntil { reader.readCount == 1 }
        tracker.destroyForTesting(pid: pid, cgWindowID: cgWindowID)
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }

        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID])
    }

    func testPIDReuseRejectsOlderAsyncRead() async {
        let reader = ControlledAppTrackerReader(result: .success([]))
        let processProvider = MutableAppTrackerProcessProvider(pid: pid)
        let tracker = AppTracker(
            reader: reader,
            processProvider: processProvider,
            cgSnapshotProvider: { self.emptyCGSnapshot() },
            onScreenWindowIDsProvider: { [] },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.scheduleEventReadForTesting(pid: pid, source: .windowCreated)
        await waitUntil { reader.readCount == 1 }
        processProvider.advanceGeneration()
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pid) }

        XCTAssertNotNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindowID])
    }

    func testAsyncKillSwitchUsesSynchronousReader() {
        let reader = ControlledAppTrackerReader(result: .unread(.cannotComplete), blocksTimedReads: false)
        let tracker = AppTracker(
            reader: reader,
            processProvider: FixedAppTrackerProcessProvider(pid: pid),
            cgSnapshotProvider: { self.emptyCGSnapshot() },
            onScreenWindowIDsProvider: { [] },
            eventAXAsyncEnabled: false
        )
        tracker.installFixtureForTesting(makeApp())

        tracker.scheduleEventReadForTesting(pid: pid, source: .focusChanged)

        XCTAssertEqual(reader.untimedReadCount, 1)
        XCTAssertFalse(tracker.hasPendingEventReadForTesting(pid: pid))
    }

    func testEquivalentSnapshotRebuildPublishesOnlyOnce() {
        let tracker = AppTracker(eventAXAsyncEnabled: true)
        tracker.installFixtureForTesting(makeApp())
        var publicationCount = 0
        let subscription = tracker.$snapshot.dropFirst().sink { _ in publicationCount += 1 }

        tracker.rebuildSnapshotForTesting()
        tracker.rebuildSnapshotForTesting()

        XCTAssertEqual(publicationCount, 1)
        withExtendedLifetime(subscription) {}
    }

    private func makeApp(
        isMinimized: Bool = false,
        minAbsentSince: Date? = nil,
        episodeID: UUID? = nil,
        shadowIDs: Set<CGWindowID> = [],
        seatToken: String? = nil
    ) -> AppEntry {
        let seat = WindowEntry(
            cgWindowID: cgWindowID,
            token: seatToken ?? "tabgrp-\(pid)-s1",
            title: "Window",
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            isMinimized: isMinimized,
            isFocused: !isMinimized,
            minAbsentSince: minAbsentSince,
            absenceEpisodeID: episodeID,
            everSeenVisible: true
        )
        return AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture",
            appName: "Fixture",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [cgWindowID: seat],
            windowOrder: [cgWindowID],
            isHidden: false,
            shadowTabCgIDs: shadowIDs
        )
    }

    @discardableResult
    private func reconcile(
        _ tracker: AppTracker,
        eligible: [AXWindowSnapshot],
        allCGWindowIDs: Set<CGWindowID>? = nil
    ) -> Bool {
        let ids = allCGWindowIDs ?? Set(eligible.compactMap(\.cgWindowID))
        return tracker.reconcileFixtureForTesting(
            pid: pid,
            cgSnapshot: AppTrackerCGWindowSnapshot(
                allWindowIDs: ids,
                onScreenWindowIDs: ids,
                windowIDsByPID: [pid: ids],
                alphaByWindowID: [:]
            ),
            now: Date(),
            eligible: eligible,
            readOutcome: .success(count: eligible.count)
        )
    }

    private func makeSnapshot(
        cgWindowID: CGWindowID?,
        titleRead: AXWindowTitleRead,
        bounds: CGRect = CGRect(x: 10, y: 20, width: 500, height: 400)
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            pid: pid,
            cgWindowID: cgWindowID,
            titleRead: titleRead,
            bounds: bounds,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isMinimized: false,
            isFocusedWindow: true,
            element: AXUIElementCreateApplication(pid)
        )
    }

    private func jsonRecords(at url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    private nonisolated func emptyCGSnapshot() -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [],
            onScreenWindowIDs: [],
            windowIDsByPID: [:],
            alphaByWindowID: [:]
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private final class ControlledAppTrackerReader: AppTrackerWindowReading, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    private var untimedCount = 0
    private let result: AXWindowReadResult
    private let untimedResult: AXWindowReadResult
    private let blocksTimedReads: Bool

    init(
        result: AXWindowReadResult = .unread(.cannotComplete),
        untimedResult: AXWindowReadResult = .unread(.cannotComplete),
        blocksTimedReads: Bool = true
    ) {
        self.result = result
        self.untimedResult = untimedResult
        self.blocksTimedReads = blocksTimedReads
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var untimedReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return untimedCount
    }

    func releaseOne() {
        semaphore.signal()
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }

    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult {
        lock.lock()
        untimedCount += 1
        lock.unlock()
        return untimedResult
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        lock.lock()
        count += 1
        lock.unlock()
        if blocksTimedReads { semaphore.wait() }
        return result
    }
}

private final class MutableAppTrackerProcessProvider: AppTrackerProcessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private var generation: Int64 = 1

    init(pid: pid_t) {
        self.pid = pid
    }

    func advanceGeneration() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func isAlive(pid: pid_t) -> Bool { pid == self.pid }

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

private struct FixedAppTrackerProcessProvider: AppTrackerProcessProviding {
    let pid: pid_t

    func isAlive(pid: pid_t) -> Bool { pid == self.pid }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(
            pid: pid,
            startTimeSec: 1,
            startTimeUsec: 2,
            bundleID: bundleID
        )
    }
}
