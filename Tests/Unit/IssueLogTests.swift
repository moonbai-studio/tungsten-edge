import Foundation
import XCTest

final class IssueLogTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    private func directory() -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/issue-log-tests")
        let value = root.appendingPathComponent(UUID().uuidString)
        directories.append(value)
        return value
    }

    private func log(at now: Date? = nil) -> IssueLog {
        let date = now ?? at
        return IssueLog(directory: directory(), enabled: true, now: { date }, schedulesTimer: false)
    }

    private func seat(age: Double, title: String = "Private chat /Users/private/file") -> WindowEntry {
        WindowEntry(cgWindowID: 1, token: "seat", title: title, bounds: nil,
                    isMinimized: false, isFocused: false, createdAt: at.addingTimeInterval(-age))
    }

    func testSixClassificationsAndNormalOperationCounterexamples() throws {
        XCTAssertEqual(IssueKind.allCases.filter(\.isIssue),
                       [.phantomHealed, .appUnreadable, .fullscreenFlapping, .windowLiftStopped])
        XCTAssertEqual(IssueEvent.phantomHealed(didHeal: true)?.kind, .phantomHealed)
        XCTAssertNil(IssueEvent.phantomHealed(didHeal: false))
        XCTAssertEqual(IssueEvent.appUnreadable(consecutiveReads: 3)?.kind, .appUnreadable)
        for count in [0, 1, 2, 4, 20] { XCTAssertNil(IssueEvent.appUnreadable(consecutiveReads: count)) }
        XCTAssertEqual(IssueEvent.fullscreenFlapping(toggles: 4, alreadyReported: false)?.kind, .fullscreenFlapping)
        XCTAssertNil(IssueEvent.fullscreenFlapping(toggles: 3, alreadyReported: false))
        XCTAssertNil(IssueEvent.fullscreenFlapping(toggles: 5, alreadyReported: true))

        // Closing within three seconds, merging tabs and closing without a notification are observations.
        for (age, reason, destroyed) in [(3.0, InventorySeatReleasedReason.leftCGList, true),
                                       (9.0, .mergedIntoTabbedWindow, false), (3.0, .hiddenWithoutDestroy, false),
                                       (3.0, .leftCGList, false)] {
            let event = try XCTUnwrap(IssueEvent.seatReleasedEarly(seat(age: age), reason: reason,
                                                                hasDestroyEvidence: destroyed, at: at))
            XCTAssertEqual(event.kind, .seatReleasedEarly)
            XCTAssertFalse(event.kind.isIssue)
            XCTAssertEqual(event.detail.releaseReason, reason)
            XCTAssertEqual(event.detail.hasDestroyEvidence, reason == .leftCGList ? destroyed : nil)
        }
        XCTAssertNil(IssueEvent.seatReleasedEarly(seat(age: 10), reason: .leftCGList, hasDestroyEvidence: false, at: at))
        XCTAssertNil(IssueEvent.seatReleasedEarly(seat(age: 3), reason: .processGone, hasDestroyEvidence: false, at: at))

        // A normal new window and a newly admitted app are never issues.
        XCTAssertNil(IssueEvent.seatCreatedBySweep(alreadyTracked: true, source: .windowCreated, isNewSeat: true))
        XCTAssertNil(IssueEvent.seatCreatedBySweep(alreadyTracked: false, source: .periodicReconcile, isNewSeat: true))
        for source in [InventoryReconcileSource.seed, .initialEnumeration] {
            XCTAssertNil(IssueEvent.seatCreatedBySweep(alreadyTracked: true, source: source, isNewSeat: true))
        }
        XCTAssertNil(IssueEvent.seatCreatedBySweep(alreadyTracked: true, source: .periodicReconcile, isNewSeat: false))
        XCTAssertEqual(IssueEvent.seatCreatedBySweep(alreadyTracked: true, source: .periodicReconcile, isNewSeat: true)?.kind,
                       .seatCreatedBySweep)
        // Independent minimized windows of different sizes can reach the split branch at launch.
        let split = try XCTUnwrap(IssueEvent.tabFoldSplit(isMinimized: true, hasPlacedSeat: true, createdNewSeat: true))
        XCTAssertFalse(split.kind.isIssue)
        XCTAssertNil(IssueEvent.tabFoldSplit(isMinimized: false, hasPlacedSeat: true, createdNewSeat: true))
        XCTAssertNil(IssueEvent.tabFoldSplit(isMinimized: true, hasPlacedSeat: false, createdNewSeat: true))
        XCTAssertNil(IssueEvent.tabFoldSplit(isMinimized: true, hasPlacedSeat: true, createdNewSeat: false))
    }

    func testLiftStopsSplitByReasonAndDisplayAndKeepEachDisplaysDetail() throws {
        let external = IssueScreen(width: 2560, height: 1440, scale: 1, builtIn: false)
        let builtIn = IssueScreen(width: 1512, height: 982, scale: 2, builtIn: true)
        let log = log()
        log.record(IssueEvent.windowLiftStopped(reason: .reverted, screen: external), bundleID: "com.example.a", at: at)
        log.record(IssueEvent.windowLiftStopped(reason: .reverted, screen: external), bundleID: "com.example.a", at: at)
        log.record(IssueEvent.windowLiftStopped(reason: .didNotApply, screen: external), bundleID: "com.example.a", at: at)
        log.record(IssueEvent.windowLiftStopped(reason: .reverted, screen: builtIn), bundleID: "com.example.a", at: at)
        log.record(IssueEvent.windowLiftStopped(reason: .reverted, screen: nil), bundleID: "com.example.a", at: at)
        log.flush()
        let entries = log.entries()
        XCTAssertEqual(entries.count, 4)
        let externalReverted = try XCTUnwrap(entries.first {
            $0.detail.liftStopReason == .reverted && $0.detail.builtInScreen == false
        })
        XCTAssertEqual(externalReverted.count, 2)
        XCTAssertEqual(externalReverted.detail.screenScale, 1)
        XCTAssertEqual(externalReverted.detail.screenWidth, 2560)
        XCTAssertEqual(entries.first { $0.detail.builtInScreen == true }?.detail.screenScale, 2)
        XCTAssertTrue(entries.contains { $0.detail.liftStopReason == .reverted && $0.detail.screenWidth == nil })
        XCTAssertTrue(entries.allSatisfy { $0.kind.isIssue && !$0.kind.statusLabel.isEmpty })
        // One user-facing row per app per day, whatever the display.
        XCTAssertEqual(IssueList.rows(entries).count, 1)
    }

    func testUnreadStreakIgnoresOtherUnreadReadsAndReportsOnceUntilSuccess() {
        var streak = IssueUnreadStreak()
        XCTAssertNil(streak.read(source: .periodicReconcile, timed: true, unread: true))
        // A skipped periodic round makes no call; event and compatibility failures do not count or reset.
        XCTAssertNil(streak.read(source: .windowCreated, timed: true, unread: true))
        XCTAssertNil(streak.read(source: .periodicReconcile, timed: false, unread: true))
        XCTAssertEqual(streak.count, 1)
        XCTAssertNil(streak.read(source: .periodicReconcile, timed: true, unread: true))
        XCTAssertEqual(streak.read(source: .periodicReconcile, timed: true, unread: true)?.kind, .appUnreadable)
        for _ in 0..<20 { XCTAssertNil(streak.read(source: .periodicReconcile, timed: true, unread: true)) }
        XCTAssertNil(streak.read(source: .focusChanged, timed: true, unread: false))
        XCTAssertEqual(streak.count, 0)
        for _ in 0..<2 { XCTAssertNil(streak.read(source: .periodicReconcile, timed: true, unread: true)) }
        XCTAssertNotNil(streak.read(source: .periodicReconcile, timed: true, unread: true))
    }

    func testFullscreenCountsEndingShowsAndReportsOncePerRollingBurst() {
        var burst = IssueFullscreenBurst()
        for index in 0..<4 {
            let event = burst.change(visible: index % 2 == 1, fullscreenReason: index % 2 == 0,
                                     at: at.addingTimeInterval(Double(index) * 3))
            XCTAssertEqual(event?.kind, index == 3 ? .fullscreenFlapping : nil)
        }
        for index in 4..<12 {
            XCTAssertNil(burst.change(visible: index % 2 == 1, fullscreenReason: index % 2 == 0,
                                     at: at.addingTimeInterval(Double(index) * 3)))
        }
        for index in 0..<4 {
            let event = burst.change(visible: index % 2 == 1, fullscreenReason: index % 2 == 0,
                                     at: at.addingTimeInterval(60 + Double(index)))
            XCTAssertEqual(event?.kind, index == 3 ? .fullscreenFlapping : nil)
        }
    }

    func testNormalAutoHideAndSlowFullscreenTransitionsDoNotReport() {
        var autoHide = IssueFullscreenBurst()
        var slow = IssueFullscreenBurst()
        for index in 0..<20 {
            XCTAssertNil(autoHide.change(visible: index % 2 == 1, fullscreenReason: false,
                                        at: at.addingTimeInterval(Double(index))))
            XCTAssertNil(slow.change(visible: index % 2 == 1, fullscreenReason: index % 2 == 0,
                                    at: at.addingTimeInterval(Double(index) * 4)))
        }
    }

    func testAggregationReadsOpenWindowsWithoutFlushingAndSeparatesKeys() throws {
        let log = log()
        let event = IssueEvent(kind: .phantomHealed)
        log.record(event, bundleID: "test.app", at: at)
        log.record(event, bundleID: "test.app", at: at.addingTimeInterval(599))
        XCTAssertEqual(log.entries().first?.count, 2)
        XCTAssertEqual(try Data(contentsOf: log.fileURL).count, 0)
        XCTAssertEqual(log.reportLines().count, 1)
        XCTAssertEqual(try Data(contentsOf: log.fileURL).count, 0)
        log.record(event, bundleID: "test.app", at: at.addingTimeInterval(600))
        log.record(event, bundleID: "other.app", at: at.addingTimeInterval(600))
        log.record(IssueEvent(kind: .tabFoldSplit), bundleID: "test.app", at: at.addingTimeInterval(600))
        XCTAssertEqual(log.entries().map(\.count).sorted(), [1, 1, 1, 2])
        XCTAssertEqual(try String(contentsOf: log.fileURL).split(separator: "\n").count, 1)
        log.flushClosedWindows(at: at.addingTimeInterval(1200))
        XCTAssertEqual(try String(contentsOf: log.fileURL).split(separator: "\n").count, 4)
        log.flush()
        XCTAssertEqual(log.entries().map(\.count).sorted(), [1, 1, 1, 2])
    }

    func testTerminationFlushAndPermissionsAndTitleBearingInput() throws {
        let log = log()
        let privateTitle = "CONFIDENTIAL-chat /Users/private/secret.pdf"
        log.record(IssueEvent.seatReleasedEarly(seat(age: 2, title: privateTitle), reason: .leftCGList,
                   hasDestroyEvidence: false, at: at), bundleID: "test.app", at: at)
        log.flush()
        let data = try Data(contentsOf: log.fileURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(privateTitle))
        XCTAssertFalse(text.contains("CONFIDENTIAL"))
        XCTAssertFalse(text.contains("/Users/"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["ts", "kind", "bundleID", "count", "detail"])
        let detail = try XCTUnwrap(object["detail"] as? [String: Any])
        XCTAssertEqual(Set(detail.keys), ["releaseReason", "hasDestroyEvidence", "ageSeconds"])
        let mode = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: log.fileURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirMode?.intValue, 0o700)
        XCTAssertTrue(log.reportLines()[0].hasPrefix("observation "))
        XCTAssertTrue(IssueList.rows(log.entries()).isEmpty)
    }

    func testKillSwitchAndInventoryLogIndependence() {
        XCTAssertEqual(DebugSwitch.issueLog.kind, .killSwitch)
        XCTAssertTrue(DebugSwitch.issueLog.isEnabled(in: [:]))
        XCTAssertFalse(DebugSwitch.issueLog.isEnabled(in: [DebugSwitch.issueLog.rawValue: "0"]))
        let directory = directory()
        let disabled = IssueLog(directory: directory, enabled: false)
        disabled.record(IssueEvent(kind: .phantomHealed), bundleID: "app")
        disabled.flush()
        XCTAssertTrue(disabled.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let enabled = log()
        enabled.record(IssueEvent(kind: .phantomHealed), bundleID: "app", at: at)
        XCTAssertEqual(enabled.entries().count, 1)
    }

    func testLaunchTrimsExpiredAndOversizedLinesAndRepairsPartialTail() throws {
        let directory = directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("issues.jsonl")
        var entries = [IssueLogEntry(ts: at.addingTimeInterval(-IssueLog.retention - 1), kind: .phantomHealed,
                                    bundleID: "expired", count: 1, detail: .init())]
        entries += (0..<1600).map { index in
            IssueLogEntry(ts: at.addingTimeInterval(Double(index) - 2000), kind: .appUnreadable,
                          bundleID: "app." + String(repeating: "x", count: 150) + String(index),
                          count: 1, detail: .init(consecutiveReads: 3))
        }
        var data = try entries.reduce(into: Data()) { data, entry in
            data.append(try IssueLogEntry.encoder().encode(entry)); data.append(0x0A)
        }
        data.append(Data("{broken".utf8))
        XCTAssertGreaterThan(data.count, IssueLog.byteLimit)
        try data.write(to: url)
        let log = IssueLog(directory: directory, enabled: true, now: { self.at }, schedulesTimer: false)
        let kept = log.entries()
        XCTAssertFalse(kept.contains { $0.bundleID == "expired" })
        XCTAssertEqual(kept.last?.bundleID, entries.last?.bundleID)
        XCTAssertLessThan(kept.count, entries.count)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, IssueLog.byteLimit * 4 / 5)
        XCTAssertTrue(try String(contentsOf: url).hasSuffix("\n"))
    }

    func testWriteCrossingCapTrimsOldestToEightyPercent() throws {
        let log = log()
        for index in 0..<1700 {
            log.record(IssueEvent(kind: .phantomHealed), bundleID: "app." + String(repeating: "x", count: 150) + String(index),
                       at: at.addingTimeInterval(Double(index) / 1000))
        }
        log.flush()
        XCTAssertLessThanOrEqual(try Data(contentsOf: log.fileURL).count, IssueLog.byteLimit)
        XCTAssertLessThan(log.entries().count, 1700)
        XCTAssertTrue(log.entries().contains { $0.bundleID.hasSuffix("1699") })
    }

    func testDailyRowsMergeIssuesOnlyUseLatestTimeAndKeepDaysSeparate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let entries = [IssueLogEntry(ts: at, kind: .phantomHealed, bundleID: "app", count: 2, detail: .init()),
                       .init(ts: at.addingTimeInterval(60), kind: .phantomHealed, bundleID: "app", count: 3, detail: .init()),
                       .init(ts: at.addingTimeInterval(86400), kind: .phantomHealed, bundleID: "app", count: 1, detail: .init()),
                       .init(ts: at, kind: .appUnreadable, bundleID: "app", count: 1, detail: .init()),
                       .init(ts: at, kind: .phantomHealed, bundleID: "other", count: 1, detail: .init())]
            + [IssueKind.tabFoldSplit, .seatReleasedEarly, .seatCreatedBySweep].map {
                IssueLogEntry(ts: at, kind: $0, bundleID: "app", count: 100, detail: .init())
            }
        let rows = IssueList.rows(entries, calendar: calendar)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].ts, at.addingTimeInterval(86400))
        XCTAssertEqual(rows[1].count, 5)
        XCTAssertEqual(rows[1].ts, at.addingTimeInterval(60))
        XCTAssertTrue(rows.allSatisfy { $0.kind.isIssue })
    }

    func testReportIncludesLastFiftyBothTiersAndPreservesGUnderBudgetPressure() {
        let log = log()
        for index in 0..<60 {
            log.record(IssueEvent(kind: index.isMultiple(of: 2) ? .phantomHealed : .seatCreatedBySweep),
                       bundleID: "app.\(index)", at: at.addingTimeInterval(Double(index)))
        }
        let lines = log.reportLines()
        XCTAssertEqual(lines.count, 50)
        XCTAssertTrue(lines[0].contains("app.10\""))
        XCTAssertTrue(lines.last?.contains("app.59\"") == true)
        XCTAssertEqual(lines.filter { $0.hasPrefix("observation ") }.count, 25)
        var report = DiagnosticSnapshotReport(basic: "basic", permissions: [], settings: [], panels: [],
            applications: [.init(header: "app", hasSeatOrStrip: true, inventory: Array(repeating: String(repeating: "中", count: 1000), count: 100))],
            recentIssues: lines)
        for text in [report.text, { report.basic = String(repeating: "中", count: 30_000); return report.text }()] {
            XCTAssertLessThanOrEqual(text.utf8.count, DiagnosticText.byteLimit)
            XCTAssertTrue(text.contains("## G. Recent issues"))
            for line in lines { XCTAssertTrue(text.contains(line)) }
        }
        let largeLines = (0..<50).map { "issue.\($0) " + String(repeating: "x", count: 800) }
        report.recentIssues = largeLines
        let largeText = report.text
        XCTAssertLessThanOrEqual(largeText.utf8.count, DiagnosticText.byteLimit)
        for line in largeLines { XCTAssertTrue(largeText.contains(line)) }
    }

    func testTimerFlushesClosedWindowWithoutAnotherOccurrence() async throws {
        let log = IssueLog(directory: directory(), enabled: true, aggregationInterval: 0.02)
        log.record(IssueEvent(kind: .phantomHealed), bundleID: "timer.app")
        _ = log.entries()
        let deadline = Date().addingTimeInterval(3)
        while (try Data(contentsOf: log.fileURL)).isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(try Data(contentsOf: log.fileURL).isEmpty)
        XCTAssertEqual(log.entries().count, 1)
    }

    @MainActor
    func testUnifiedVisibilityRecorderHandlesAllSourcesDuplicatesUnitsAndRemoval() {
        let log = log()
        let recorder = DiagnosticVisibilityRecorder(issueLog: log)
        for (index, source) in ["visibility", "intent", "intent-cancel", "space-intent"].enumerated() {
            let visible = index % 2 == 1
            recorder.noteVisibilityChange(unit: "A", screen: "screen", previousVisible: !visible, visible: visible,
                reasons: visible ? [] : (index == 0 ? [.fullscreen] : [.fullscreenTransitionPending]),
                source: source, at: at.addingTimeInterval(Double(index)))
            recorder.noteVisibilityChange(unit: "A", screen: "screen", previousVisible: !visible, visible: visible,
                reasons: [], source: "duplicate", at: at.addingTimeInterval(Double(index)))
            recorder.noteVisibilityChange(unit: "B", screen: "screen", previousVisible: !visible, visible: visible,
                reasons: [.edgeAutoHide], source: "visibility", at: at.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(recorder.history.changes.filter { $0.unit == "A" }.count, 4)
        XCTAssertEqual(log.entries().map(\.kind), [.fullscreenFlapping])
        recorder.remove(unit: "A")
        recorder.noteVisibilityChange(unit: "A", screen: "screen", previousVisible: true, visible: false,
            reasons: [.fullscreen], source: "space-intent-timeout", at: at.addingTimeInterval(4))
        XCTAssertEqual(log.entries().first?.count, 1)
        let session = DiagnosticsSession()
        session.loadIssues(from: log)
        XCTAssertEqual(session.issueRows.count, 1)
        log.record(IssueEvent(kind: .appUnreadable), bundleID: "another", at: at)
        XCTAssertEqual(session.issueRows.count, 1)
    }
}
