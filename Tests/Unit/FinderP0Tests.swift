import AppKit
import CoreGraphics
import XCTest

final class FinderP0Tests: XCTestCase {
    func testObservationKindMergePrefersActionableState() {
        var merged: SystemObservation.ObservationKind?

        for kind in [
            SystemObservation.ObservationKind.unchanged,
            .unhidden,
            .minimized,
            .hidden
        ] {
            merged = ObservationKindMergeRule.preferred(merged, kind)
        }

        XCTAssertEqual(merged, .hidden)
    }

    func testObservationKindMergeKeepsMinimizedOverUnchanged() {
        let merged = ObservationKindMergeRule.preferred(.minimized, .unchanged)
        XCTAssertEqual(merged, .minimized)
    }

    func testToggleUsesSnapshotStatus() {
        let id = WindowID(rawValue: "cg-1")
        let planner = LifecycleActionPlanner()
        let activeSnapshot = snapshot(windowID: id, status: .active)
        let inactiveSnapshot = snapshot(windowID: id, status: .inactive)
        let minimizedSnapshot = snapshot(windowID: id, status: .minimized)
        // 测试进程的窗口（pid=1）不可能是前台，真实 NSWorkspace 前台检查永远 false。
        // 用乐观态注入前台轴，让「active + 前台 → minimize」分支可确定性测试。
        let activeFrontmost = [
            id.rawValue: OptimisticWindowState(status: .active, isAppFrontmost: true, createdAt: Date())
        ]

        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: activeSnapshot, optimisticStates: activeFrontmost).kind,
            .minimizeWindow
        )
        // active 但非前台 → 仍是 activate（带到前台），不是 minimize。
        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: activeSnapshot).kind,
            .activateWindow
        )
        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: inactiveSnapshot).kind,
            .activateWindow
        )
        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: minimizedSnapshot).kind,
            .activateWindow
        )
    }

    /// 可打断（2026-06-13）：快照还停在 active（没翻面）时，乐观态说已 minimized →
    /// 下一次 toggle 必须规划 activate（还原），而不是重复 minimize。这是连点
    /// 严格交替的根。
    func testToggleAlternatesViaOptimisticStateWhileSnapshotIsStale() {
        let id = WindowID(rawValue: "cg-optimistic")
        let planner = LifecycleActionPlanner()
        let staleActiveSnapshot = snapshot(windowID: id, status: .active)

        let afterMinimize = [
            id.rawValue: OptimisticWindowState(status: .minimized, isAppFrontmost: false, createdAt: Date())
        ]
        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: staleActiveSnapshot, optimisticStates: afterMinimize).kind,
            .activateWindow
        )

        let afterActivate = [
            id.rawValue: OptimisticWindowState(status: .active, isAppFrontmost: true, createdAt: Date())
        ]
        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: staleActiveSnapshot, optimisticStates: afterActivate).kind,
            .minimizeWindow
        )
    }

    func testToggleDoesNotMinimizeAppLevelFallbacks() {
        let id = WindowID(rawValue: "app-com.electron.lark")
        let planner = LifecycleActionPlanner()
        let activeSnapshot = snapshot(windowID: id, status: .active)

        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: activeSnapshot).kind,
            .activateWindow
        )
    }

    func testMinimizeFeedbackAcceptsTemporaryDisappearance() {
        let id = WindowID(rawValue: "cg-2")
        var feedback = IntentFeedbackState()
        feedback.begin(windowID: id.rawValue, action: .minimize, at: Date())

        feedback.reconcile(snapshot: snapshot(windowID: id, status: .disappeared), now: Date())

        XCTAssertEqual(feedback.entriesByWindowID[id.rawValue]?.phase, .success)
    }

    func testActivateFeedbackSucceedsImmediatelyWhenExecutionSucceeds() {
        let id = WindowID(rawValue: "cg-activate")
        var feedback = IntentFeedbackState()
        feedback.begin(windowID: id.rawValue, action: .activate, at: Date())

        feedback.markSucceededImmediatelyIfNeeded(windowID: id.rawValue, action: .activate, at: Date())

        XCTAssertEqual(feedback.entriesByWindowID[id.rawValue]?.phase, .success)
    }

    func testActivateFeedbackDoesNotFlipBackToFailureAfterInactiveObservation() {
        let id = WindowID(rawValue: "cg-activate")
        var feedback = IntentFeedbackState()
        let now = Date()
        feedback.begin(windowID: id.rawValue, action: .activate, at: now)
        feedback.markSucceededImmediatelyIfNeeded(windowID: id.rawValue, action: .activate, at: now)

        feedback.reconcile(
            snapshot: snapshot(windowID: id, status: .inactive),
            now: now.addingTimeInterval(0.5)
        )

        XCTAssertEqual(feedback.entriesByWindowID[id.rawValue]?.phase, .success)
    }

    func testAdmissionGateRejectsUnknownAXOnlyCandidate() {
        let gate = ObservationAdmissionGate()
        let now = Date()
        let observation = observation(
            timestamp: now,
            source: .accessibility,
            pid: 2001,
            title: "Unknown AX Window",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )

        gate.beginRound(at: now)
        let decision = gate.decide(observation: observation, snapshot: .empty)

        XCTAssertEqual(decision.kind, .rejected)
        XCTAssertEqual(decision.reason, "accessibility-orphan-inventory-required")
    }

    func testAdmissionGateAcceptsInventoryCandidate() {
        let gate = ObservationAdmissionGate()
        let now = Date()
        let observation = observation(
            timestamp: now,
            source: .appWindowInventory,
            pid: 2101,
            title: "Inventory Window",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )

        gate.beginRound(at: now)
        let decision = gate.decide(observation: observation, snapshot: .empty)

        XCTAssertEqual(decision.kind, .accepted)
        XCTAssertEqual(decision.reason, "app-window-inventory")
    }

    func testAdmissionGateRejectsCGOrphanWhenInventoryMainlineIsAvailable() {
        let gate = ObservationAdmissionGate()
        let now = Date()
        let observation = observation(
            timestamp: now,
            source: .coreGraphics,
            pid: 2201,
            cgWindowID: 9001,
            title: "CG Orphan",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )

        gate.beginRound(at: now, inventoryMainlineAvailable: true)
        let decision = gate.decide(observation: observation, snapshot: .empty)

        XCTAssertEqual(decision.kind, .rejected)
        XCTAssertEqual(decision.reason, "cg-orphan-inventory-required")
    }

    func testAdmissionGateAcceptsCGWhenInventoryMainlineIsUnavailable() {
        let gate = ObservationAdmissionGate()
        let now = Date()
        let observation = observation(
            timestamp: now,
            source: .coreGraphics,
            pid: 2301,
            cgWindowID: 9002,
            title: "CG Fallback",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )

        gate.beginRound(at: now, inventoryMainlineAvailable: false)
        let decision = gate.decide(observation: observation, snapshot: .empty)

        XCTAssertEqual(decision.kind, .accepted)
        XCTAssertEqual(decision.reason, "cg-permission-fallback")
    }

    func testAdmissionGateAcceptsCGWhenItMatchesExistingInventoryWindow() {
        let gate = ObservationAdmissionGate()
        let now = Date()
        let id = WindowID(rawValue: "inventory-window")
        let snapshot = DockSnapshot(
            windows: [
                id: WindowRecord(
                    id: id,
                    appID: AppID(rawValue: "com.example.app"),
                    pid: 2401,
                    bundleIdentifier: "com.example.app",
                    title: "Existing",
                    bounds: CGRect(x: 100, y: 100, width: 500, height: 400),
                    status: .inactive
                )
            ],
            orderedWindowIDs: [id]
        )
        let observation = observation(
            timestamp: now,
            source: .coreGraphics,
            pid: 2401,
            cgWindowID: 9003,
            title: "Existing",
            bounds: CGRect(x: 104, y: 103, width: 500, height: 400)
        )

        gate.beginRound(at: now, inventoryMainlineAvailable: true)
        let decision = gate.decide(observation: observation, snapshot: snapshot)

        XCTAssertEqual(decision.kind, .accepted)
        XCTAssertEqual(decision.reason, "matches-existing-window")
    }

    func testIdentityBindsCGToExistingInventoryWindow() {
        let identity = WindowIdentityEngine()
        let now = Date()
        let inventory = observation(
            timestamp: now,
            source: .appWindowInventory,
            pid: 2501,
            title: "Editor",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )
        let inventoryDecision = identity.identify(observation: inventory)

        let cg = observation(
            timestamp: now.addingTimeInterval(0.1),
            source: .coreGraphics,
            pid: 2501,
            cgWindowID: 9101,
            title: "Editor",
            bounds: CGRect(x: 106, y: 104, width: 500, height: 400)
        )
        let cgDecision = identity.identify(observation: cg)

        XCTAssertEqual(cgDecision.windowID, inventoryDecision.windowID)
        XCTAssertEqual(cgDecision.reason, "cg-bound-to-inventory")
    }

    func testIdentityDoesNotGuessCGBindingForAmbiguousSameTitleWindows() {
        let identity = WindowIdentityEngine()
        let now = Date()
        let first = observation(
            timestamp: now,
            source: .appWindowInventory,
            pid: 2601,
            title: "zsh",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )
        let second = observation(
            timestamp: now.addingTimeInterval(0.01),
            source: .appWindowInventory,
            pid: 2601,
            title: "zsh",
            bounds: CGRect(x: 160, y: 160, width: 500, height: 400)
        )
        _ = identity.identify(observation: first)
        _ = identity.identify(observation: second)

        let cg = observation(
            timestamp: now.addingTimeInterval(0.1),
            source: .coreGraphics,
            pid: 2601,
            cgWindowID: 9102,
            title: "zsh",
            bounds: CGRect(x: 130, y: 130, width: 500, height: 400)
        )
        let cgDecision = identity.identify(observation: cg)

        XCTAssertEqual(cgDecision.windowID, WindowID(rawValue: "cg-9102"))
        XCTAssertEqual(cgDecision.reason, "cg-window-id")
    }

    func testIdentityMatchesRetainedMinimizedWindowAfterLongGap() {
        let identity = WindowIdentityEngine()
        let retainedID = WindowID(rawValue: "cg-retained-minimized")
        let bounds = CGRect(x: 100, y: 120, width: 700, height: 500)
        let snapshot = retainedSnapshot(
            windowRecord(
                id: retainedID,
                pid: 2701,
                bundleIdentifier: "com.example.editor",
                title: "Quarterly.ai",
                bounds: bounds,
                status: .minimized
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(12 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2701,
            bundleIdentifier: "com.example.editor",
            title: "Quarterly.ai",
            bounds: CGRect(x: 108, y: 124, width: 700, height: 500),
            isMinimized: true
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, retainedID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "retained-seat-title-frame")
    }

    func testIdentityMatchesRetainedWindowByUniqueFrameWhenTitleChanged() {
        let identity = WindowIdentityEngine()
        let retainedID = WindowID(rawValue: "cg-retained-renamed")
        let bounds = CGRect(x: 80, y: 90, width: 640, height: 420)
        let snapshot = retainedSnapshot(
            windowRecord(
                id: retainedID,
                pid: 2702,
                bundleIdentifier: "com.example.design",
                title: "Draft.ai",
                bounds: bounds,
                status: .disappeared
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2702,
            bundleIdentifier: "com.example.design",
            title: "Draft.ai @ 125%",
            bounds: CGRect(x: 82, y: 92, width: 640, height: 420)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, retainedID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "retained-seat-frame")
    }

    func testIdentityDoesNotGuessRetainedWindowWhenFrameCandidatesAreAmbiguous() {
        let identity = WindowIdentityEngine()
        let firstID = WindowID(rawValue: "cg-retained-first")
        let secondID = WindowID(rawValue: "cg-retained-second")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: firstID,
                pid: 2703,
                bundleIdentifier: "com.example.notes",
                title: "Old A",
                bounds: CGRect(x: 100, y: 100, width: 600, height: 400),
                status: .minimized
            ),
            windowRecord(
                id: secondID,
                pid: 2703,
                bundleIdentifier: "com.example.notes",
                title: "Old B",
                bounds: CGRect(x: 112, y: 108, width: 600, height: 400),
                status: .hidden
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2703,
            bundleIdentifier: "com.example.notes",
            title: "Renamed",
            bounds: CGRect(x: 106, y: 104, width: 600, height: 400)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, firstID)
        XCTAssertNotEqual(decision.windowID, secondID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityDoesNotMatchRetainedWindowFromDifferentProcess() {
        let identity = WindowIdentityEngine()
        let retainedID = WindowID(rawValue: "cg-retained-other-process")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: retainedID,
                pid: 2704,
                bundleIdentifier: "com.example.editor",
                title: "Same Title",
                bounds: CGRect(x: 100, y: 100, width: 600, height: 400),
                status: .minimized
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2705,
            bundleIdentifier: "com.example.editor",
            title: "Same Title",
            bounds: CGRect(x: 100, y: 100, width: 600, height: 400)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, retainedID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityDoesNotMatchClosedPendingRetainedWindow() {
        let identity = WindowIdentityEngine()
        let retainedID = WindowID(rawValue: "cg-retained-closed")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: retainedID,
                pid: 2706,
                bundleIdentifier: "com.example.editor",
                title: "Closed Title",
                bounds: CGRect(x: 100, y: 100, width: 600, height: 400),
                status: .closedPending
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2706,
            bundleIdentifier: "com.example.editor",
            title: "Closed Title",
            bounds: CGRect(x: 100, y: 100, width: 600, height: 400)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, retainedID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityMatchesRetainedWindowByUniqueTitleWhenFrameMoved() {
        let identity = WindowIdentityEngine()
        let retainedID = WindowID(rawValue: "cg-retained-moved")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: retainedID,
                pid: 2707,
                bundleIdentifier: "com.example.photo",
                title: "Poster.psd",
                bounds: CGRect(x: 0, y: 490, width: 2500, height: 1410),
                status: .minimized
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2707,
            bundleIdentifier: "com.example.photo",
            title: "Poster.psd",
            bounds: CGRect(x: 0, y: 30, width: 2500, height: 1410)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, retainedID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "retained-seat-title")
    }

    func testIdentityDoesNotGuessRetainedTitleOnlyWhenAmbiguous() {
        let identity = WindowIdentityEngine()
        let firstID = WindowID(rawValue: "cg-retained-title-first")
        let secondID = WindowID(rawValue: "cg-retained-title-second")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: firstID,
                pid: 2708,
                bundleIdentifier: "com.example.finderlike",
                title: "Downloads",
                bounds: CGRect(x: 100, y: 100, width: 700, height: 500),
                status: .minimized
            ),
            windowRecord(
                id: secondID,
                pid: 2708,
                bundleIdentifier: "com.example.finderlike",
                title: "Downloads",
                bounds: CGRect(x: 900, y: 100, width: 700, height: 500),
                status: .hidden
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2708,
            bundleIdentifier: "com.example.finderlike",
            title: "Downloads",
            bounds: CGRect(x: 500, y: 500, width: 700, height: 500)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, firstID)
        XCTAssertNotEqual(decision.windowID, secondID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityMatchesActiveWindowFromSnapshotAfterLongGap() {
        let identity = WindowIdentityEngine()
        let existingID = WindowID(rawValue: "ax-existing-active")
        let bounds = CGRect(x: 120, y: 140, width: 900, height: 700)
        let snapshot = retainedSnapshot(
            windowRecord(
                id: existingID,
                pid: 2710,
                bundleIdentifier: "com.example.browser",
                title: "Inbox",
                bounds: bounds,
                status: .active
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(10 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2710,
            bundleIdentifier: "com.example.browser",
            title: "Inbox",
            bounds: CGRect(x: 130, y: 146, width: 900, height: 700)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, existingID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "snapshot-seat-title-frame")
    }

    func testIdentityMatchesActiveWindowByUniqueFrameWhenTitleChanged() {
        let identity = WindowIdentityEngine()
        let existingID = WindowID(rawValue: "ax-existing-renamed")
        let bounds = CGRect(x: 220, y: 240, width: 1000, height: 760)
        let snapshot = retainedSnapshot(
            windowRecord(
                id: existingID,
                pid: 2711,
                bundleIdentifier: "com.example.design",
                title: "Draft.ai @ 50%",
                bounds: bounds,
                status: .inactive
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(9 * 60 * 60),
            kind: .titleChanged,
            source: .appWindowInventory,
            pid: 2711,
            bundleIdentifier: "com.example.design",
            title: "Final.ai @ 125%",
            bounds: CGRect(x: 224, y: 244, width: 1000, height: 760)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, existingID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "snapshot-seat-frame")
    }

    func testIdentityMatchesActiveWindowByUniqueTitleWhenFrameMoved() {
        let identity = WindowIdentityEngine()
        let existingID = WindowID(rawValue: "ax-existing-moved")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: existingID,
                pid: 2715,
                bundleIdentifier: "com.example.finder",
                title: "Downloads",
                bounds: CGRect(x: 1170, y: 705, width: 1034, height: 436),
                status: .active
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(9 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2715,
            bundleIdentifier: "com.example.finder",
            title: "Downloads",
            bounds: CGRect(x: 1446, y: 661, width: 1034, height: 436)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, existingID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "snapshot-seat-title")
    }

    func testIdentityDoesNotGuessActiveWindowWhenFrameCandidatesAreAmbiguous() {
        let identity = WindowIdentityEngine()
        let firstID = WindowID(rawValue: "ax-existing-first")
        let secondID = WindowID(rawValue: "ax-existing-second")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: firstID,
                pid: 2712,
                bundleIdentifier: "com.example.terminal",
                title: "Old A",
                bounds: CGRect(x: 300, y: 320, width: 600, height: 420),
                status: .active
            ),
            windowRecord(
                id: secondID,
                pid: 2712,
                bundleIdentifier: "com.example.terminal",
                title: "Old B",
                bounds: CGRect(x: 308, y: 328, width: 600, height: 420),
                status: .inactive
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(9 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2712,
            bundleIdentifier: "com.example.terminal",
            title: "Renamed",
            bounds: CGRect(x: 304, y: 324, width: 600, height: 420)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, firstID)
        XCTAssertNotEqual(decision.windowID, secondID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityDoesNotGuessActiveTitleOnlyWhenAmbiguous() {
        let identity = WindowIdentityEngine()
        let firstID = WindowID(rawValue: "ax-existing-title-first")
        let secondID = WindowID(rawValue: "ax-existing-title-second")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: firstID,
                pid: 2716,
                bundleIdentifier: "com.example.browser",
                title: "Inbox",
                bounds: CGRect(x: 100, y: 100, width: 900, height: 700),
                status: .active
            ),
            windowRecord(
                id: secondID,
                pid: 2716,
                bundleIdentifier: "com.example.browser",
                title: "Inbox",
                bounds: CGRect(x: 1200, y: 100, width: 900, height: 700),
                status: .inactive
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(9 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2716,
            bundleIdentifier: "com.example.browser",
            title: "Inbox",
            bounds: CGRect(x: 600, y: 600, width: 900, height: 700)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, firstID)
        XCTAssertNotEqual(decision.windowID, secondID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testIdentityBindsCGToExistingActiveSnapshotAfterLongGap() {
        let identity = WindowIdentityEngine()
        let existingID = WindowID(rawValue: "ax-existing-cg")
        let bounds = CGRect(x: 420, y: 440, width: 1100, height: 800)
        let snapshot = retainedSnapshot(
            windowRecord(
                id: existingID,
                pid: 2713,
                bundleIdentifier: "com.example.editor",
                title: "Notes",
                bounds: bounds,
                status: .inactive
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(11 * 60 * 60),
            kind: .unchanged,
            source: .coreGraphics,
            pid: 2713,
            bundleIdentifier: "com.example.editor",
            cgWindowID: 9301,
            title: "Notes",
            bounds: CGRect(x: 424, y: 442, width: 1100, height: 800)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertEqual(decision.windowID, existingID)
        XCTAssertEqual(decision.kind, .knownWindow)
        XCTAssertEqual(decision.reason, "snapshot-seat-title-frame")
    }

    func testIdentityDoesNotTreatAppLevelFallbackAsLiveWindowSeat() {
        let identity = WindowIdentityEngine()
        let appLevelID = WindowID(rawValue: "app-com.example.chat")
        let snapshot = retainedSnapshot(
            windowRecord(
                id: appLevelID,
                pid: 2714,
                bundleIdentifier: "com.example.chat",
                title: "Chat",
                bounds: CGRect(x: 520, y: 540, width: 700, height: 500),
                status: .active
            )
        )
        let returningObservation = observation(
            timestamp: Date().addingTimeInterval(8 * 60 * 60),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: 2714,
            bundleIdentifier: "com.example.chat",
            title: "Chat",
            bounds: CGRect(x: 520, y: 540, width: 700, height: 500)
        )

        let decision = identity.identify(observation: returningObservation, snapshot: snapshot)

        XCTAssertNotEqual(decision.windowID, appLevelID)
        XCTAssertEqual(decision.kind, .newWindow)
    }

    func testRoundAnomalyFuseRejectsCandidateExplosion() {
        let fuse = ObservationRoundAnomalyFuse()
        let snapshot = snapshot(windowCount: 2)
        var observations: [SystemObservation] = []

        for index in 0..<60 {
            observations.append(
                observation(
                    source: .accessibility,
                    pid: Int32(3000 + index),
                    title: "System Surface \(index)",
                    bounds: CGRect(
                        x: CGFloat(index * 10),
                        y: CGFloat(index * 8),
                        width: 180,
                        height: 120
                    )
                )
            )
        }

        let decision = fuse.decide(observations: observations, snapshot: snapshot)

        XCTAssertEqual(decision.kind, ObservationRoundAdmissionKind.rejected)
        XCTAssertEqual(decision.reason, "count-spike")
        XCTAssertEqual(decision.baselineCount, 2)
        XCTAssertEqual(decision.candidateCount, 60)
    }

    func testRoundAnomalyFuseAcceptsPlausibleRound() {
        let fuse = ObservationRoundAnomalyFuse()
        let snapshot = snapshot(windowCount: 2)
        var observations: [SystemObservation] = []

        for index in 0..<5 {
            observations.append(
                observation(
                    source: .accessibility,
                    pid: Int32(4000 + index),
                    title: "Real Window \(index)",
                    bounds: CGRect(
                        x: CGFloat(index * 20),
                        y: CGFloat(index * 16),
                        width: 500,
                        height: 400
                    )
                )
            )
        }

        let decision = fuse.decide(observations: observations, snapshot: snapshot)

        XCTAssertEqual(decision.kind, ObservationRoundAdmissionKind.accepted)
        XCTAssertEqual(decision.reason, "plausible-round")
    }

    func testFeishuFallbackRetentionKeepsRunningAppLevelItem() {
        let record = WindowRecord(
            id: WindowID(rawValue: "app-com.electron.lark"),
            appID: AppID(rawValue: "com.electron.lark"),
            pid: 5001,
            bundleIdentifier: "com.electron.lark",
            title: "飞书",
            bounds: nil,
            status: .inactive
        )

        XCTAssertTrue(
            AppFallbackRetentionPolicy.shouldRetainMissingFallback(
                record: record,
                isProcessAlive: true
            )
        )
        XCTAssertFalse(
            AppFallbackRetentionPolicy.shouldRetainMissingFallback(
                record: record,
                isProcessAlive: false
            )
        )
    }

    func testWindowEligibilityFiltersTransparentWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: "Real Window",
                    alpha: 0,
                    activationPolicy: .regular
                )
            ),
            .filter
        )
    }

    func testWindowEligibilityFiltersTaskbarSelfAppWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: DockWindowEligibilityPolicy.selfBundleIdentifier,
                    appName: "任务条调试台",
                    title: "任务条调试台",
                    activationPolicy: .regular,
                    executablePath: "/Applications/macos-dock-cc-v2.app/Contents/MacOS/macos-dock-cc-v2"
                )
            ),
            .filter
        )
    }

    func testAXTaskbarWindowRulesKeepsStandardWindows() {
        XCTAssertEqual(
            AXTaskbarWindowRules.decision(
                role: "AXWindow",
                subrole: "AXStandardWindow",
                bounds: CGRect(x: 0, y: 0, width: 400, height: 300)
            ),
            .mainWindow
        )
    }

    func testAXTaskbarWindowRulesAllowsMissingSubroleForReasonableWindow() {
        XCTAssertEqual(
            AXTaskbarWindowRules.decision(
                role: "AXWindow",
                subrole: nil,
                bounds: CGRect(x: 0, y: 0, width: 400, height: 300)
            ),
            .unconfirmedMainWindow
        )
    }

    func testAXTaskbarWindowRulesRejectsMissingSubroleForTinyWindow() {
        XCTAssertEqual(
            AXTaskbarWindowRules.decision(
                role: "AXWindow",
                subrole: nil,
                bounds: CGRect(x: 0, y: 0, width: 79, height: 40)
            ),
            .rejected
        )
    }

    func testAXTaskbarWindowRulesRejectsSheetsDialogsAndNonWindows() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertEqual(
            AXTaskbarWindowRules.decision(role: "AXWindow", subrole: "AXSheet", bounds: bounds),
            .rejected
        )
        XCTAssertEqual(
            AXTaskbarWindowRules.decision(role: "AXWindow", subrole: "AXDialog", bounds: bounds),
            .rejected
        )
        XCTAssertEqual(
            AXTaskbarWindowRules.decision(role: "AXGroup", subrole: "AXStandardWindow", bounds: bounds),
            .rejected
        )
    }

    func testWindowEligibilityFiltersUntitledRegularWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(candidate(title: nil, activationPolicy: .regular)),
            .filter
        )
    }

    func testWindowEligibilityKeepsTitledSmallRegularWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: "Small Real Window",
                    bounds: CGRect(x: 0, y: 0, width: 30, height: 20),
                    activationPolicy: .regular
                )
            ),
            .keep
        )
    }

    func testWindowEligibilityFiltersProhibitedWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(candidate(title: "Background Window", activationPolicy: .prohibited)),
            .filter
        )
    }

    func testWindowEligibilityKeepsTitledAccessoryWindowWithReasonableFrame() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: "Agent Window",
                    bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
                    activationPolicy: .accessory
                )
            ),
            .keep
        )
    }

    func testWindowEligibilityFiltersSmallAccessoryWindow() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: "Tiny Agent Window",
                    bounds: CGRect(x: 0, y: 0, width: 79, height: 40),
                    activationPolicy: .accessory
                )
            ),
            .filter
        )
    }

    func testWindowEligibilityKeepsUntitledFeishuFallbackCandidate() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: "com.electron.lark",
                    title: nil,
                    activationPolicy: .regular
                )
            ),
            .keep
        )
    }

    func testWindowEligibilityFiltersNotificationCenterByTitle() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(candidate(title: "Notification Center", activationPolicy: .regular)),
            .filter
        )
        XCTAssertEqual(
            policy.evaluate(candidate(title: "通知中心", activationPolicy: .regular)),
            .filter
        )
    }

    func testWindowEligibilityFiltersNotificationCenterByBundleID() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: "com.apple.notificationcenterui",
                    appName: "Notification Center",
                    title: "Weather",
                    activationPolicy: .regular
                )
            ),
            .filter
        )
    }

    func testWindowEligibilityFiltersLocalizedNotificationCenterAXCandidate() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: "com.apple.notificationcenterui",
                    appName: "通知中心",
                    title: "天气预报",
                    bounds: CGRect(x: 188, y: 38, width: 180, height: 180),
                    activationPolicy: .accessory,
                    executablePath: "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter"
                )
            ),
            .filter
        )
    }

    func testWindowEligibilityFiltersAppExtensionWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: "Share Extension",
                    activationPolicy: .regular,
                    executablePath: "/System/Applications/App.app/Contents/PlugIns/ShareExtension.appex/Contents/MacOS/ShareExtension"
                )
            ),
            .filter
        )
    }

    func testWindowEligibilityFiltersWidgetAndSystemServiceExecutables() {
        let policy = DockWindowEligibilityPolicy()

        let paths = [
            "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/ThemeWidgetControlViewService.xpc/Contents/MacOS/ThemeWidgetControlViewService",
            "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod",
            "/System/Library/CoreServices/Dock.app/Contents/XPCServices/DockHelper.xpc/Contents/MacOS/DockHelper",
            "/System/Library/CoreServices/Dock.app/Contents/XPCServices/com.apple.dock.extra.xpc/Contents/MacOS/com.apple.dock.extra",
            "/System/Library/CoreServices/ControlCenter.app/Contents/XPCServices/ControlCenterHelper.xpc/Contents/MacOS/ControlCenterHelper"
        ]

        for path in paths {
            XCTAssertEqual(
                policy.evaluate(
                    candidate(
                        title: "System Panel",
                        activationPolicy: .regular,
                        executablePath: path
                    )
                ),
                .filter
            )
        }
    }

    func testWindowEligibilityKeepsSpotlightAccessoryWindow() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: "com.apple.Spotlight",
                    appName: "Spotlight",
                    title: "Spotlight",
                    bounds: CGRect(x: 0, y: 0, width: 680, height: 80),
                    activationPolicy: .accessory,
                    executablePath: "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"
                )
            ),
            .keep
        )
    }

    func testFinderTrackableWindowFiltering() {
        let bounds = CGRect(x: 10, y: 10, width: 400, height: 300)

        XCTAssertTrue(
            FinderWindowRules.isTrackable(
                title: "codex-finder-test-alpha-20260505",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                bounds: bounds
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "访达",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                bounds: bounds
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Preview",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: bounds
            )
        )
        XCTAssertTrue(
            FinderWindowRules.isTrackable(
                title: "Documents",
                role: "AXWindow",
                subrole: nil,
                bounds: bounds
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Downloads",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                bounds: nil
            )
        )
    }

    func testStripItemsHideTitleForSingleAppCard() {
        let record = windowRecord(
            id: WindowID(rawValue: "cg-chrome-1"),
            pid: 101,
            bundleIdentifier: "com.google.Chrome",
            title: "Chrome",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            status: .inactive
        )

        let items = StripItem.items(from: retainedSnapshot(record))

        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].showsTitle)
        XCTAssertEqual(items[0].sameAppCardCount, 1)
    }

    func testStripItemsShowTitlesForMultipleCardsFromSameApp() {
        let first = windowRecord(
            id: WindowID(rawValue: "cg-chrome-1"),
            pid: 101,
            bundleIdentifier: "com.google.Chrome",
            title: "First",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            status: .inactive
        )
        let second = windowRecord(
            id: WindowID(rawValue: "cg-chrome-2"),
            pid: 101,
            bundleIdentifier: "com.google.Chrome",
            title: "Second",
            bounds: CGRect(x: 20, y: 20, width: 800, height: 600),
            status: .active
        )

        let items = StripItem.items(from: retainedSnapshot(first, second))

        XCTAssertEqual(items.map(\.showsTitle), [true, true])
        XCTAssertEqual(items.map(\.sameAppCardCount), [2, 2])
    }

    func testStripItemsGroupFallbacksByAppIDWhenBundleIsMissing() {
        let first = WindowRecord(
            id: WindowID(rawValue: "fallback-1"),
            appID: AppID(rawValue: "fallback-app"),
            pid: 201,
            bundleIdentifier: nil,
            title: "First",
            bounds: nil,
            status: .inactive
        )
        let second = WindowRecord(
            id: WindowID(rawValue: "fallback-2"),
            appID: AppID(rawValue: "fallback-app"),
            pid: 202,
            bundleIdentifier: nil,
            title: "Second",
            bounds: nil,
            status: .inactive
        )

        let items = StripItem.items(from: retainedSnapshot(first, second))

        XCTAssertEqual(items.map(\.showsTitle), [true, true])
        XCTAssertEqual(items.map(\.sameAppCardCount), [2, 2])
    }

    func testStripItemsHideTitlesForDifferentSingleAppCards() {
        let chrome = windowRecord(
            id: WindowID(rawValue: "cg-chrome-1"),
            pid: 101,
            bundleIdentifier: "com.google.Chrome",
            title: "Chrome",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            status: .inactive
        )
        let terminal = windowRecord(
            id: WindowID(rawValue: "cg-terminal-1"),
            pid: 102,
            bundleIdentifier: "com.apple.Terminal",
            title: "Terminal",
            bounds: CGRect(x: 20, y: 20, width: 800, height: 600),
            status: .inactive
        )

        let items = StripItem.items(from: retainedSnapshot(chrome, terminal))

        XCTAssertEqual(items.map(\.showsTitle), [false, false])
    }

    // MARK: - 原生标签组合并（2026-06-14）

    func testStripItemsMergeNativeTabGroupWithIdenticalFrame() {
        // 真机探路数据（2026-06-13 Ghostty pid 30201，两标签同 frame）
        let frame = CGRect(x: 172, y: 87, width: 1191, height: 831)
        let tabA = WindowRecord(
            id: WindowID(rawValue: "cgw-240522"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "ob 协作",
            bounds: frame,
            status: .inactive,
            cgWindowID: 240522
        )
        let tabB = WindowRecord(
            id: WindowID(rawValue: "cgw-249469"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "程序坞-规划",
            bounds: frame,
            status: .active,
            cgWindowID: 249469
        )

        let items = StripItem.items(from: retainedSnapshot(tabA, tabB))

        XCTAssertEqual(items.count, 1)
        let chip = items[0]
        XCTAssertEqual(Set(chip.memberWindowIDs), ["cgw-240522", "cgw-249469"])
        // 单个标签组 → 图标-only（与单窗口一致），sameAppCardCount 按合并后的卡计数
        XCTAssertFalse(chip.showsTitle)
        XCTAssertEqual(chip.sameAppCardCount, 1)
        // SwiftUI 身份锚 = 最小 cgWindowID（稳定，不随聚焦切换 → 不抖）
        XCTAssertEqual(chip.id, "cgw-240522")
        // 动作落点 + 标题 = 聚焦（active）标签
        XCTAssertEqual(chip.actionWindowID, "cgw-249469")
        XCTAssertEqual(chip.title, "程序坞-规划")
    }

    func testStripItemsBackgroundedTabGroupRepresentsVisibleTab() {
        // 真机数据（2026-06-14）：原生标签组里，非当前标签在 AX 报告为 .minimized；
        // 后台窗口（app 非前台）没有任何 .active member。representative 必须选「可见标签」
        // （唯一 min=0 的那个），而不是 fallback 到最小 cgID 的 anchor——anchor 这里恰好
        // 落在一个被最小化的后台标签上，旧逻辑会显示错误标题。
        let frame = CGRect(x: 82, y: 107, width: 1191, height: 809)
        let bgLow = WindowRecord(   // 最小 cgID = anchor，但它是后台（最小化）标签
            id: WindowID(rawValue: "cgw-249469"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "程序坞-规划",
            bounds: frame,
            status: .minimized,
            cgWindowID: 249469
        )
        let visible = WindowRecord(  // 唯一可见标签（min=0 → .inactive，因 app 非前台）
            id: WindowID(rawValue: "cgw-254022"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "发生的",
            bounds: frame,
            status: .inactive,
            cgWindowID: 254022
        )
        let bgHigh = WindowRecord(
            id: WindowID(rawValue: "cgw-253982"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "阿方索的",
            bounds: frame,
            status: .minimized,
            cgWindowID: 253982
        )

        let items = StripItem.items(from: retainedSnapshot(bgLow, visible, bgHigh))

        XCTAssertEqual(items.count, 1)
        let chip = items[0]
        // 身份锚仍是最小 cgID（稳定不抖）
        XCTAssertEqual(chip.id, "cgw-249469")
        // 但标题/动作落点 = 可见标签，不是 anchor
        XCTAssertEqual(chip.title, "发生的")
        XCTAssertEqual(chip.actionWindowID, "cgw-254022")
    }

    func testStripItemsDoNotMergeWhenFrameDiffers() {
        // 同 app 两窗口、近似但不逐像素相同（Chrome 实测高度差 25px）→ 不合并
        let a = WindowRecord(
            id: WindowID(rawValue: "cgw-1"),
            appID: AppID(rawValue: "com.google.Chrome"),
            pid: 64774,
            bundleIdentifier: "com.google.Chrome",
            title: "A",
            bounds: CGRect(x: 0, y: 33, width: 1512, height: 862),
            status: .inactive,
            cgWindowID: 1
        )
        let b = WindowRecord(
            id: WindowID(rawValue: "cgw-2"),
            appID: AppID(rawValue: "com.google.Chrome"),
            pid: 64774,
            bundleIdentifier: "com.google.Chrome",
            title: "B",
            bounds: CGRect(x: 0, y: 33, width: 1512, height: 887),
            status: .inactive,
            cgWindowID: 2
        )

        let items = StripItem.items(from: retainedSnapshot(a, b))

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.memberWindowIDs.count), [1, 1])
    }

    func testStripItemsDoNotMergeAcrossDifferentApps() {
        // 同 frame 但不同 app（Illustrator/Photoshop 实测同 frame）→ pid+bundle 隔离
        let frame = CGRect(x: 0, y: 32, width: 2560, height: 1410)
        let ai = WindowRecord(
            id: WindowID(rawValue: "cgw-10"),
            appID: AppID(rawValue: "com.adobe.illustrator"),
            pid: 65589,
            bundleIdentifier: "com.adobe.illustrator",
            title: "AI",
            bounds: frame,
            status: .inactive,
            cgWindowID: 10
        )
        let ps = WindowRecord(
            id: WindowID(rawValue: "cgw-11"),
            appID: AppID(rawValue: "com.adobe.Photoshop"),
            pid: 55311,
            bundleIdentifier: "com.adobe.Photoshop",
            title: "PS",
            bounds: frame,
            status: .inactive,
            cgWindowID: 11
        )

        let items = StripItem.items(from: retainedSnapshot(ai, ps))

        XCTAssertEqual(items.count, 2)
    }

    private func snapshot(windowID: WindowID, status: WindowStatus) -> DockSnapshot {
        DockSnapshot(
            windows: [
                windowID: WindowRecord(
                    id: windowID,
                    appID: AppID(rawValue: "test-app"),
                    pid: 1,
                    bundleIdentifier: nil,
                    title: "Test",
                    bounds: nil,
                    status: status
                )
            ],
            orderedWindowIDs: [windowID]
        )
    }

    private func snapshot(windowCount: Int) -> DockSnapshot {
        var windows: [WindowID: WindowRecord] = [:]
        var orderedWindowIDs: [WindowID] = []

        for index in 0..<windowCount {
            let windowID = WindowID(rawValue: "cg-baseline-\(index)")
            orderedWindowIDs.append(windowID)
            windows[windowID] = WindowRecord(
                id: windowID,
                appID: AppID(rawValue: "com.example.baseline"),
                pid: Int32(1000 + index),
                bundleIdentifier: "com.example.baseline",
                title: "Baseline \(index)",
                bounds: CGRect(
                    x: CGFloat(index * 20),
                    y: CGFloat(index * 20),
                    width: 500,
                    height: 400
                ),
                status: .inactive
            )
        }

        return DockSnapshot(windows: windows, orderedWindowIDs: orderedWindowIDs)
    }

    private func retainedSnapshot(_ records: WindowRecord...) -> DockSnapshot {
        DockSnapshot(
            windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
            orderedWindowIDs: records.map(\.id)
        )
    }

    private func windowRecord(
        id: WindowID,
        pid: Int32,
        bundleIdentifier: String,
        title: String,
        bounds: CGRect,
        status: WindowStatus
    ) -> WindowRecord {
        WindowRecord(
            id: id,
            appID: AppID(rawValue: bundleIdentifier),
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            title: title,
            bounds: bounds,
            status: status
        )
    }

    private func observation(
        timestamp: Date = Date(),
        kind: SystemObservation.ObservationKind = .appeared,
        source: SystemObservation.ObservationSource,
        pid: Int32,
        bundleIdentifier: String? = "com.example.app",
        cgWindowID: UInt32? = nil,
        title: String?,
        appName: String? = "Example",
        bounds: CGRect?,
        isMinimized: Bool = false,
        isFocusedWindow: Bool = false
    ) -> SystemObservation {
        SystemObservation(
            timestamp: timestamp,
            kind: kind,
            source: source,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            cgWindowID: cgWindowID,
            title: title,
            appName: appName,
            bounds: bounds,
            isMinimized: isMinimized,
            isFocusedWindow: isFocusedWindow
        )
    }

    private func candidate(
        bundleIdentifier: String? = "com.example.app",
        appName: String = "Example",
        title: String?,
        bounds: CGRect? = CGRect(x: 0, y: 0, width: 400, height: 300),
        alpha: Double? = 1,
        activationPolicy: NSApplication.ActivationPolicy,
        executablePath: String? = "/Applications/Example.app/Contents/MacOS/Example"
    ) -> DockWindowEligibilityPolicy.Candidate {
        DockWindowEligibilityPolicy.Candidate(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            title: title,
            bounds: bounds,
            alpha: alpha,
            activationPolicy: activationPolicy,
            executablePath: executablePath
        )
    }
}
