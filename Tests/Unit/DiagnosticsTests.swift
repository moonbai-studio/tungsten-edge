import AppKit
import ApplicationServices
import XCTest

final class DiagnosticEligibilityTests: XCTestCase {
    private let policy = DockWindowEligibilityPolicy()
    private let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func candidate(
        bid: String? = "test.app", name: String = "App", title: String? = "Window",
        role: String? = kAXStandardWindowSubrole as String, bounds: CGRect? = CGRect(x: 0, y: 0, width: 400, height: 300),
        alpha: Double? = 1, activation: NSApplication.ActivationPolicy = .regular, path: String? = nil
    ) -> DockWindowEligibilityPolicy.Candidate {
        .init(bundleIdentifier: bid, appName: name, title: title, subrole: role, bounds: bounds,
              alpha: alpha, activationPolicy: activation, executablePath: path)
    }

    func testEverySharedPolicyRejectionAndLegacyAdapter() {
        let cases: [(DockWindowEligibilityPolicy.Candidate, DockWindowEligibilityPolicy.Verdict)] = [
            (candidate(), .eligible),
            (candidate(bid: DockWindowEligibilityPolicy.selfBundleIdentifier), .selfApp),
            (candidate(alpha: 0), .transparent),
            (candidate(bid: "com.apple.notificationcenterui"), .systemSurfaceBundle),
            (candidate(bid: "com.apple.controlcenter"), .systemSurfaceBundle),
            (candidate(name: "Control Center"), .systemSurfaceAppName),
            (candidate(path: "/App/Widget.appex/file"), .systemSurfaceExtension),
            (candidate(path: "/App/DockHelper.xpc/file"), .systemSurfaceExecutable),
            (candidate(title: "Notification Center"), .systemSurfaceTitle),
            (candidate(title: "通知中心"), .systemSurfaceTitle),
            (candidate(activation: .prohibited), .prohibitedPolicy),
            (candidate(title: "", activation: .accessory), .accessoryWithoutTitleOrTooSmall),
            (candidate(bounds: .zero, activation: .accessory), .accessoryWithoutTitleOrTooSmall),
            (candidate(title: nil, role: nil), .emptyTitleNotStandardOrTooSmall),
            (candidate(title: "", bounds: .zero), .emptyTitleNotStandardOrTooSmall),
            (candidate(title: ""), .eligible),
            (candidate(bid: "com.electron.lark", title: "通知中心", activation: .prohibited), .eligible),
            (candidate(bid: "com.electron.lark", alpha: 0), .transparent)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(policy.verdict(input), expected)
            XCTAssertEqual(policy.evaluate(input), expected == .eligible ? .keep : .filter)
        }
    }

    func testEveryInventoryReasonAndBoolAdapter() {
        let cases: [(String, String?, String?, String?, Bool, DockWindowEligibilityPolicy.Verdict)] = [
            ("test.app", "Window", kAXWindowRole as String, kAXStandardWindowSubrole as String, false, .eligible),
            ("test.app", "Window", kAXWindowRole as String, kAXStandardWindowSubrole as String, true, .belowNormalLayer),
            ("com.electron.lark", "Window", "AXButton", kAXStandardWindowSubrole as String, false, .feishuNotMainWindow),
            ("com.apple.finder", "Finder", kAXWindowRole as String, kAXStandardWindowSubrole as String, false, .finderNotTrackable),
            ("test.app", "Window", "AXButton", kAXStandardWindowSubrole as String, false, .notMainWindow)
        ]
        for (bid, title, role, subrole, below, expected) in cases {
            let app = AppTrackerWindowEligibility.Application(bundleIdentifier: bid, appName: "App", activationPolicy: .regular, executablePath: nil)
            let verdict = AppTrackerWindowEligibility().verdict(title: title, role: role, subrole: subrole, bounds: frame,
                alpha: 1, isMinimized: false, isBelowNormalLayer: below, application: app)
            XCTAssertEqual(verdict, expected)
            XCTAssertEqual(AppTrackerWindowEligibility().isEligible(title: title, role: role, subrole: subrole,
                bounds: frame, alpha: 1, isMinimized: false, isBelowNormalLayer: below, application: app), expected == .eligible)
        }
    }
}

final class DiagnosticSnapshotAssemblyTests: XCTestCase {
    private let identity = DiagnosticSeatIdentity(token: "seat-1", cgID: 1, formerCgIDs: [2], minimized: true)

    func testDiagnosticCGDetailsIncludeNonzeroLayersWithoutChangingInventorySets() {
        let rows: [[String: Any]] = [
            [kCGWindowNumber as String: 1, kCGWindowLayer as String: 0, kCGWindowIsOnscreen as String: true],
            [kCGWindowNumber as String: 2, kCGWindowLayer as String: 5, kCGWindowIsOnscreen as String: true],
            [kCGWindowNumber as String: 3, kCGWindowLayer as String: -1, kCGWindowIsOnscreen as String: false]
        ]
        let normal = AppTrackerCGWindowSnapshot.parse(rows)
        let diagnostics = AppTrackerCGWindowSnapshot.parse(rows, includeDiagnosticDetails: true)
        XCTAssertTrue(normal.layerByWindowID.isEmpty)
        XCTAssertEqual(diagnostics.layerByWindowID, [1: 0, 2: 5, 3: -1])
        XCTAssertEqual(diagnostics.diagnosticOnScreenWindowIDs, [1, 2])
        XCTAssertEqual(diagnostics.allWindowIDs, normal.allWindowIDs)
        XCTAssertEqual(diagnostics.belowNormalLayerWindowIDs, normal.belowNormalLayerWindowIDs)
    }

    private func inventory() -> DiagnosticInventoryApplication {
        DiagnosticInventoryApplication(header: "app=Test admission: not recorded F1 sampledAt=100",
            seats: [.init(identity: identity, title: "private-chat 文件", retention: "everSeenVisible=1 CGpresent=1 onScreen=0 shadowPool=0 age=10 absentProbe=0 minAbsentAge=2",
                          placement: "screen:0", titleRules: "titleRules messagingMain=0 finderGeneric=0 filtered=0")],
            after: [identity], readAt: Date(timeIntervalSince1970: 101), readError: nil,
            windows: [.init(cgID: 2, title: "private-chat 文件", role: nil, subrole: nil, size: nil,
                            onScreen: nil, layer: nil, minimized: nil, verdict: "notMainWindow", titleRules: "titleRules filtered=0")],
            cgOnlyIDs: [3], stripEntries: ["unit=screen position=0 kind=window cgID=1"], duplicateStripIDs: [])
    }

    private func report(_ blocks: [DiagnosticApplicationBlock]) -> DiagnosticSnapshotReport {
        .init(basic: "Tungsten Edge diagnostics", permissions: ["accessibility=true", "finderAutomation=0"],
              settings: ["kept=4"], panels: ["unit=screen visible=true", "Recent visibility changes (last 40):"], applications: blocks)
    }

    func testAllSectionsTitlesOffAndUnreadAttributes() {
        let text = report([inventory().block(includeTitles: false)]).text
        for section in ["A. Basic", "B. Permissions", "C. Settings", "D. Taskbar state", "E. Strip entries", "F. Window inventory", "Differences"] {
            XCTAssertTrue(text.contains("## " + section))
        }
        XCTAssertFalse(text.contains("private-chat"))
        XCTAssertTrue(text.contains("title: <"))
        XCTAssertTrue(text.contains("role=? subrole=? size=? onScreen=? layer=? min=?"))
        XCTAssertTrue(text.contains("seats=[seat-1]"))
        XCTAssertFalse(text.contains("F1 absent"), "former cgID must match")
        XCTAssertTrue(text.contains("CG layer-0 absent from AX: 3"))
    }

    func testTitlesOnEmptyUnreadAndLimit() {
        XCTAssertTrue(report([inventory().block(includeTitles: true)]).text.contains("private-chat 文件"))
        XCTAssertEqual(DiagnosticText.title(nil, include: true), "title: unread")
        XCTAssertEqual(DiagnosticText.title("", include: false), "title: empty")
        XCTAssertEqual(DiagnosticText.title(String(repeating: "中", count: 121), include: true), "title: " + String(repeating: "中", count: 120))
    }

    func testUnreadApplicationAndDifferencesDoNotAssertClosure() {
        var input = inventory()
        input.readError = AXError.cannotComplete.rawValue
        input.windows = []
        let unread = input.block(includeTitles: false)
        XCTAssertTrue(unread.inventory.joined().contains("unread(-25204)"))
        XCTAssertTrue(unread.differences.isEmpty)
        input.readError = nil
        input.after = []
        input.duplicateStripIDs = [1]
        let changed = input.block(includeTitles: false)
        XCTAssertTrue(changed.header.contains("unstable"))
        XCTAssertEqual(changed.differences.count, 2)
        XCTAssertTrue(changed.differences.allSatisfy { $0.contains("unstable") && $0.contains("everSeenVisible") })
    }

    func testMultipleSeatsMatchAndEveryInstabilityField() {
        var input = inventory()
        var second = input.seats[0]
        second.identity = .init(token: "seat-2", cgID: 4, formerCgIDs: [2], minimized: false)
        input.seats.append(second)
        XCTAssertTrue(input.block(includeTitles: false).differences.contains { $0.contains("multiple seats") })
        for changed in [DiagnosticSeatIdentity(token: "other", cgID: 1, formerCgIDs: [2], minimized: true),
                        .init(token: "seat-1", cgID: 2, formerCgIDs: [1], minimized: true),
                        .init(token: "seat-1", cgID: 1, formerCgIDs: [2, 3], minimized: true),
                        .init(token: "seat-1", cgID: 1, formerCgIDs: [2], minimized: false)] {
            XCTAssertTrue(DiagnosticSeatIdentity.unstable([identity], [changed]))
        }
        XCTAssertFalse(DiagnosticSeatIdentity.unstable([identity], [identity]))
    }

    func testSanitizesEveryControlAndHomeBeforeCounting() {
        let controls = (0...0x1f).compactMap(UnicodeScalar.init).map(String.init).joined()
            + String(UnicodeScalar(0x7f)!) + "\u{85}\u{2028}\u{2029}"
        let cleaned = DiagnosticText.clean("/Users/person/private\n\t" + controls, home: "/Users/person")
        XCTAssertTrue(cleaned.hasPrefix("~/private"))
        XCTAssertFalse(cleaned.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
        XCTAssertEqual(DiagnosticText.clean("/not/the/home", home: ""), "/not/the/home")
    }

    func testGlobalBudgetWithMultibyteTitlesAndManyApplications() {
        let blocks = (0..<70).map { app in
            DiagnosticApplicationBlock(header: "app=\(app)", hasSeatOrStrip: app == 0,
                entries: ["unit=screen position=\(app)"],
                inventory: (0..<15).map { "\($0) " + DiagnosticText.title(String(repeating: "中文🙂", count: 120), include: true) })
        }
        let text = report(blocks).text
        XCTAssertLessThanOrEqual(text.utf8.count, 60 * 1024)
        XCTAssertTrue(text.contains("more"))
        XCTAssertTrue(text.contains("app=69"), "trim across apps before omitting entire apps")
        XCTAssertFalse(text.contains("�"))
    }

    func testAllAppsAtHeadersStillOverBudgetPreferUnseatedOmission() {
        let blocks = (0..<900).map { app in
            DiagnosticApplicationBlock(header: "app=\(app) " + String(repeating: "中", count: 70), hasSeatOrStrip: app == 0)
        }
        let text = report(blocks).text
        XCTAssertLessThanOrEqual(text.utf8.count, 60 * 1024)
        XCTAssertTrue(text.contains("apps omitted"))
        XCTAssertTrue(text.contains("app=0 "))
    }

    func testTrimsLongestApplicationIncludingItsHeader() {
        let first = DiagnosticApplicationBlock(header: String(repeating: "H", count: 40_000), hasSeatOrStrip: true,
            inventory: ["first-row " + String(repeating: "a", count: 12_000)])
        let second = DiagnosticApplicationBlock(header: "second app", hasSeatOrStrip: true,
            inventory: ["second-row " + String(repeating: "b", count: 15_000)])
        let text = report([first, second]).text
        XCTAssertFalse(text.contains("first-row"))
        XCTAssertTrue(text.contains("second-row"))
        XCTAssertLessThanOrEqual(text.utf8.count, DiagnosticText.byteLimit)
    }

    func testCGFailureStaysUnknownAndOversizedExtrasStillRespectBudget() {
        var input = inventory()
        input.cgReadFailed = true
        XCTAssertTrue(input.block(includeTitles: false).inventory.contains("CG layer-0 absent from AX: ? (CG unread)"))
        var full = report([input.block(includeTitles: false)])
        full.stripExtras = (0..<1_000).map { "unit=screen position=\($0) " + String(repeating: "字", count: 30) }
        XCTAssertLessThanOrEqual(full.text.utf8.count, DiagnosticText.byteLimit)
    }
}

@MainActor
final class DiagnosticSessionTests: XCTestCase {
    func testTabOrderAndSymbol() {
        XCTAssertEqual(SettingsTab.allCases, [.general, .advanced, .license, .feedback, .diagnostics, .about])
        XCTAssertEqual(SettingsTab.diagnostics.symbolName, "stethoscope")
        XCTAssertEqual(SettingsTab.diagnostics.title, String(localized: "Diagnostics"))
    }

    func testSwitchInvalidatesOldResultAndOutOfOrderCompletion() throws {
        let session = DiagnosticsSession()
        let first = try XCTUnwrap(session.begin())
        XCTAssertNil(session.begin())
        session.setIncludesTitles(true)
        let second = try XCTUnwrap(session.begin())
        XCTAssertFalse(session.complete(first, text: "old"))
        XCTAssertTrue(session.isCollecting)
        XCTAssertTrue(session.complete(second, text: "current"))
        XCTAssertFalse(session.complete(first, text: "late"))
        XCTAssertEqual(session.report, "current")
        XCTAssertFalse(session.complete(second, text: "duplicate"))
        session.setIncludesTitles(false)
        XCTAssertNil(session.report)
    }

    func testCloseInvalidatesAndNewSessionDefaultsOff() throws {
        let session = DiagnosticsSession()
        session.setIncludesTitles(true)
        let request = try XCTUnwrap(session.begin())
        session.close()
        XCTAssertFalse(session.complete(request, text: "private"))
        XCTAssertNil(session.report)
        XCTAssertNil(session.begin())
        XCTAssertFalse(session.includesTitles)
        XCTAssertFalse(DiagnosticsSession().includesTitles)
    }

    func testThreeVisibilitySourcesCancellationTimeoutDedupAndRingLimit() {
        var history = DiagnosticVisibilityHistory()
        for source in ["ax", "green-button-prediction", "space-intent-right"] {
            XCTAssertNotNil(history.noteVisibilityChange(unit: source, screen: "display", previousVisible: true,
                visible: false, reasons: [.fullscreenTransitionPending], source: source))
            XCTAssertNil(history.noteVisibilityChange(unit: source, screen: "display", previousVisible: false,
                visible: false, reasons: [.fullscreen], source: "confirmation"))
            XCTAssertNotNil(history.noteVisibilityChange(unit: source, screen: "display", previousVisible: false,
                visible: true, reasons: [], source: "intent-cancel-timeout"))
        }
        XCTAssertEqual(history.changes.count, 6)
        XCTAssertEqual(history.changes.first?.reasons, ["fullscreenTransitionPending"])
        for i in 0..<60 {
            history.noteVisibilityChange(unit: "loop", screen: "display", previousVisible: i % 2 != 0,
                visible: i % 2 == 0, reasons: [], source: "timeout-recovery")
        }
        XCTAssertEqual(history.changes.count, 40)
        XCTAssertTrue(history.changes.allSatisfy { $0.source == "timeout-recovery" })
    }
}

private struct DiagnosticFixtureReader: AppTrackerWindowReading {
    let unread: Bool
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult {
        precondition(!Thread.isMainThread)
        return result
    }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { result }
    private var result: AXWindowReadResult { unread ? .unread(.cannotComplete) : .success([]) }
}

private struct DiagnosticFixtureProcess: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool { true }
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        .init(pid: pid, startTimeSec: 1, startTimeUsec: 0, bundleID: bundleID)
    }
}

@MainActor
final class DiagnosticAdmissionTests: XCTestCase {
    func testMinimizedRawReadDistinguishesFalseFromUnread() {
        for raw in [nil, false, true] as [Bool?] {
            let snapshot = AXWindowSnapshot(pid: 4242, cgWindowID: 7, titleRead: .empty, bounds: nil,
                role: nil, subrole: nil, isMinimized: raw ?? false, isFocusedWindow: false,
                element: AXUIElementCreateApplication(4242), isMinimizedRead: raw)
            XCTAssertEqual(snapshot.isMinimizedRead, raw)
            XCTAssertEqual(snapshot.isMinimized, raw ?? false)
        }
    }

    func testCreatedAtSurvivesContinuationAndNewSeatUsesReadTime() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let oldTime = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let tracker = AppTracker(processProvider: DiagnosticFixtureProcess(), onScreenWindowIDsProvider: { [] })
        let seat = WindowEntry(cgWindowID: 7, token: "old-seat", title: "Old", bounds: frame,
            isMinimized: false, isFocused: false, everSeenVisible: true, createdAt: oldTime)
        tracker.installFixtureForTesting(.init(pid: 4242, bundleIdentifier: "test.app", appName: "App",
            activationPolicy: .regular, executablePath: nil, windowsByID: [7: seat], windowOrder: [7], isHidden: false))
        let snapshots = [UInt32(7), 9].map { id in
            AXWindowSnapshot(pid: 4242, cgWindowID: id, titleRead: .value("Updated"),
                bounds: id == 7 ? frame : CGRect(x: 500, y: 500, width: 500, height: 400),
                role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
                isMinimized: false, isFocusedWindow: false, element: AXUIElementCreateApplication(4242))
        }
        _ = tracker.reconcileFixtureForTesting(pid: 4242,
            cgSnapshot: .init(allWindowIDs: [7, 9], onScreenWindowIDs: [7, 9], windowIDsByPID: [4242: [7, 9]],
                              alphaByWindowID: [7: 1, 9: 1]), now: now, eligible: snapshots, readOutcome: .success(count: 2))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: 4242)?.windowsByID[7]?.createdAt, oldTime)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: 4242)?.windowsByID[9]?.createdAt, now)
        tracker.stop()
    }

    func testRealSeedScanAndLaunchRetryEntrancesRecordWithInventoryLogOff() async {
        for source in ["seed", "scan", "launchRetry"] {
            for unread in [false, true] {
                let log = WindowInventoryAnomalyLog(configuration: .init(enabled: false,
                    directoryURL: URL(fileURLWithPath: "/unused"), maxFileSize: 1024, archiveCount: 0))
                XCTAssertFalse(log.isEnabled)
                let tracker = AppTracker(inventoryLog: log, reader: DiagnosticFixtureReader(unread: unread),
                    processProvider: DiagnosticFixtureProcess(), cgSnapshotProvider: { .failed }, onScreenWindowIDsProvider: { [] })
                tracker.runAdmissionForTesting(source: source)
                let pid = NSRunningApplication.current.processIdentifier
                for _ in 0..<1_000 {
                    if tracker.lastAdmissionVerdictByPID[pid] != nil { break }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                XCTAssertEqual(tracker.lastAdmissionVerdictByPID[pid]?.source, source)
                XCTAssertEqual(tracker.lastAdmissionVerdictByPID[pid]?.verdict, unread ? "skipUnread" : "skipNoEligible")
                XCTAssertTrue(tracker.diagnosticApps().isEmpty)
                tracker.stop()
                XCTAssertTrue(tracker.lastAdmissionVerdictByPID.isEmpty)
            }
        }
    }
}
