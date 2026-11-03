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

    func testDockClickDefaultsToActivateForEveryWindowState() {
        let id = WindowID(rawValue: "cg-default-click")
        let planner = LifecycleActionPlanner(isAppFrontmost: { _ in true })

        for status in [WindowStatus.active, .inactive, .minimized, .hidden] {
            XCTAssertEqual(
                planner.plan(intent: .toggle(id), snapshot: snapshot(windowID: id, status: status)).kind,
                .activateWindow
            )
        }
        let optimisticActive = [id.rawValue: OptimisticWindowState(status: .active, createdAt: Date())]
        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: snapshot(windowID: id, status: .inactive),
                         optimisticStates: optimisticActive).kind,
            .activateWindow
        )
        let fallbackID = WindowID(rawValue: "app-com.example.running")
        XCTAssertEqual(
            planner.plan(intent: .toggle(fallbackID), snapshot: snapshot(windowID: fallbackID, status: .active)).kind,
            .activateWindow
        )
    }

    @MainActor
    func testDockClickReadsSettingChangesWithoutRecreatingPlanner() {
        let suite = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        let planner = LifecycleActionPlanner(
            minimizeOnDockClick: { store.minimizeOnDockClick },
            isAppFrontmost: { _ in true }
        )
        let id = WindowID(rawValue: "cg-live-click-setting")
        let active = snapshot(windowID: id, status: .active)

        XCTAssertEqual(planner.plan(intent: .toggle(id), snapshot: active).kind, .activateWindow)
        store.setMinimizeOnDockClick(true)
        XCTAssertEqual(planner.plan(intent: .toggle(id), snapshot: active).kind, .minimizeWindow)
        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: snapshot(windowID: id, status: .minimized)).kind,
            .activateWindow
        )
        store.setMinimizeOnDockClick(false)
        XCTAssertEqual(planner.plan(intent: .toggle(id), snapshot: active).kind, .activateWindow)
    }

    func testExplicitMinimizeAndHideRemainAvailableWhenClickMinimizeIsOff() {
        let id = WindowID(rawValue: "cg-explicit-action")
        let planner = LifecycleActionPlanner(isAppFrontmost: { _ in true })
        let active = snapshot(windowID: id, status: .active)

        XCTAssertEqual(planner.plan(intent: .minimize(id), snapshot: active).kind, .minimizeWindow)
        XCTAssertEqual(planner.plan(intent: .hide(id), snapshot: active).kind, .hideApp)
    }

    func testToggleUsesSnapshotStatus() {
        let id = WindowID(rawValue: "cg-1")
        // 前台轴走注入桩（真实读数对测试假 pid 永远 false，无法覆盖 minimize 分支）。
        let frontmostPlanner = LifecycleActionPlanner(minimizeOnDockClick: { true }, isAppFrontmost: { _ in true })
        let backgroundPlanner = LifecycleActionPlanner(minimizeOnDockClick: { true }, isAppFrontmost: { _ in false })
        let activeSnapshot = snapshot(windowID: id, status: .active)
        let inactiveSnapshot = snapshot(windowID: id, status: .inactive)
        let minimizedSnapshot = snapshot(windowID: id, status: .minimized)

        XCTAssertEqual(
            frontmostPlanner.plan(intent: .toggle(id), snapshot: activeSnapshot).kind,
            .minimizeWindow
        )
        // active 但非前台 → 仍是 activate（带到前台），不是 minimize。
        XCTAssertEqual(
            backgroundPlanner.plan(intent: .toggle(id), snapshot: activeSnapshot).kind,
            .activateWindow
        )
        XCTAssertEqual(
            backgroundPlanner.plan(intent: .toggle(id), snapshot: inactiveSnapshot).kind,
            .activateWindow
        )
        XCTAssertEqual(
            backgroundPlanner.plan(intent: .toggle(id), snapshot: minimizedSnapshot).kind,
            .activateWindow
        )
    }

    /// 可打断（2026-06-13）：快照还停在 active（没翻面）时，乐观态说已 minimized →
    /// 下一次 toggle 必须规划 activate（还原），而不是重复 minimize。这是连点
    /// 严格交替的根。
    func testToggleAlternatesViaOptimisticStateWhileSnapshotIsStale() {
        let id = WindowID(rawValue: "cg-optimistic")
        let planner = LifecycleActionPlanner(minimizeOnDockClick: { true }, isAppFrontmost: { _ in true })
        let staleActiveSnapshot = snapshot(windowID: id, status: .active)

        let afterMinimize = [
            id.rawValue: OptimisticWindowState(status: .minimized, createdAt: Date())
        ]
        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: staleActiveSnapshot, optimisticStates: afterMinimize).kind,
            .activateWindow
        )

        let afterActivate = [
            id.rawValue: OptimisticWindowState(status: .active, createdAt: Date())
        ]
        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: staleActiveSnapshot, optimisticStates: afterActivate).kind,
            .minimizeWindow
        )
    }

    /// 回归（2026-07-05）：激活 B1 后 4s 内切去别的 App，乐观 .active 残留未兑现；
    /// 此时再点 B1 卡片，App 已非前台（即时读 false）→ 必须规划 activate（提前），
    /// 绝不能被残留乐观态带成 minimize（曾把该激活的点击直接最小化）。
    func testToggleWithStaleOptimisticActiveButAppNotFrontmostPlansActivate() {
        let id = WindowID(rawValue: "cg-stale-optimistic")
        let planner = LifecycleActionPlanner(minimizeOnDockClick: { true }, isAppFrontmost: { _ in false })
        let lingering = [
            id.rawValue: OptimisticWindowState(status: .active, createdAt: Date())
        ]

        for status in [WindowStatus.active, .inactive] {
            XCTAssertEqual(
                planner.plan(
                    intent: .toggle(id),
                    snapshot: snapshot(windowID: id, status: status),
                    optimisticStates: lingering
                ).kind,
                .activateWindow
            )
        }
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

    // hidden 状态 toggle 应规划 activateWindow，而非其他动作（确保 unhide 路径
    // 对应正确的 intent，不因 hidden 状态退化成 minimizeWindow 等）。
    func testToggleOnHiddenWindowPlansActivate() {
        let id = WindowID(rawValue: "cg-hidden")
        let planner = LifecycleActionPlanner()
        let hiddenSnapshot = snapshot(windowID: id, status: .hidden)

        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: hiddenSnapshot).kind,
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

    func testWindowEligibilityKeepsUntitledStandardRegularWindows() {
        let policy = DockWindowEligibilityPolicy()

        for title in [nil, "", " \n\t"] as [String?] {
            XCTAssertEqual(
                policy.evaluate(
                    candidate(
                        title: title,
                        subrole: kAXStandardWindowSubrole as String,
                        bounds: CGRect(x: 0, y: 0, width: 723, height: 626),
                        activationPolicy: .regular
                    )
                ),
                .keep
            )
        }
    }

    func testWindowEligibilityAppliesMinimumFrameToUntitledStandardRegularWindows() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: nil,
                    subrole: kAXStandardWindowSubrole as String,
                    bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
                    activationPolicy: .regular
                )
            ),
            .keep
        )

        for bounds in [
            CGRect(x: 0, y: 0, width: 79, height: 40),
            CGRect(x: 0, y: 0, width: 80, height: 39)
        ] {
            XCTAssertEqual(
                policy.evaluate(
                    candidate(
                        title: nil,
                        subrole: kAXStandardWindowSubrole as String,
                        bounds: bounds,
                        activationPolicy: .regular
                    )
                ),
                .filter
            )
        }
    }

    func testWindowEligibilityRejectsUntitledRegularWindowsWithoutStandardSubrole() {
        let policy = DockWindowEligibilityPolicy()

        for subrole in [nil, kAXDialogSubrole as String] as [String?] {
            XCTAssertEqual(
                policy.evaluate(
                    candidate(
                        title: nil,
                        subrole: subrole,
                        activationPolicy: .regular
                    )
                ),
                .filter
            )
        }
    }

    func testWindowEligibilityDoesNotExtendUntitledStandardRuleBeyondRegularApps() {
        let policy = DockWindowEligibilityPolicy()

        for activationPolicy in [NSApplication.ActivationPolicy.accessory, .prohibited] {
            XCTAssertEqual(
                policy.evaluate(
                    candidate(
                        title: nil,
                        subrole: kAXStandardWindowSubrole as String,
                        activationPolicy: activationPolicy
                    )
                ),
                .filter
            )
        }
    }

    func testAppTrackerEligibilityKeepsOnlyFullyQualifiedUntitledStandardWindow() {
        let eligibility = AppTrackerWindowEligibility()
        let application = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.apple.systempreferences",
            appName: "System Settings",
            activationPolicy: .regular,
            executablePath: "/System/Applications/System Settings.app/Contents/MacOS/System Settings"
        )

        XCTAssertTrue(
            eligibility.isEligible(
                title: "",
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: CGRect(x: 0, y: 0, width: 723, height: 626),
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: application
            )
        )
    }

    /// Widgetify's desktop widgets: `.regular`, empty title, AXStandardWindow, CG layer -20.
    func testAppTrackerEligibilityRejectsBelowNormalLayerWindowsForEveryApp() {
        let eligibility = AppTrackerWindowEligibility()
        func eligible(bundleID: String, title: String, below: Bool) -> Bool {
            eligibility.isEligible(
                title: title,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: CGRect(x: 16, y: 30, width: 344, height: 359),
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: below,
                application: AppTrackerWindowEligibility.Application(
                    bundleIdentifier: bundleID,
                    appName: "Fixture",
                    activationPolicy: .regular,
                    executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture"
                )
            )
        }

        XCTAssertTrue(eligible(bundleID: "com.jian.Widgetify", title: "", below: false))
        XCTAssertFalse(eligible(bundleID: "com.jian.Widgetify", title: "", below: true))
        XCTAssertFalse(eligible(bundleID: "com.jian.Widgetify", title: "Clock", below: true))
        XCTAssertFalse(eligible(bundleID: "com.feishu.app", title: "飞书", below: true))
        XCTAssertFalse(eligible(bundleID: "com.apple.finder", title: "Documents", below: true))
    }

    func testAppTrackerEligibilityAppliesMetadataDenyFiltersBeforeUntitledAdmission() {
        let eligibility = AppTrackerWindowEligibility()
        let frame = CGRect(x: 0, y: 0, width: 723, height: 626)
        let normal = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.example.app",
            appName: "Example",
            activationPolicy: .regular,
            executablePath: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let extensionProcess = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.example.share",
            appName: "Share Extension",
            activationPolicy: .regular,
            executablePath: "/Applications/Example.app/Contents/PlugIns/Share.appex/Contents/MacOS/Share"
        )
        let notificationCenter = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.apple.notificationcenterui",
            appName: "Notification Center",
            activationPolicy: .regular,
            executablePath: "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter"
        )

        XCTAssertFalse(
            eligibility.isEligible(
                title: nil,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: frame,
                alpha: 0,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: normal
            )
        )
        XCTAssertFalse(
            eligibility.isEligible(
                title: nil,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: frame,
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: extensionProcess
            )
        )
        XCTAssertFalse(
            eligibility.isEligible(
                title: nil,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: frame,
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: notificationCenter
            )
        )
    }

    func testAppTrackerEligibilityDoesNotLetNilBundleBypassUntitledSubroleGate() {
        let eligibility = AppTrackerWindowEligibility()
        let application = AppTrackerWindowEligibility.Application(
            bundleIdentifier: nil,
            appName: "Unknown",
            activationPolicy: .regular,
            executablePath: nil
        )

        XCTAssertFalse(
            eligibility.isEligible(
                title: nil,
                role: kAXWindowRole as String,
                subrole: nil,
                bounds: CGRect(x: 0, y: 0, width: 723, height: 626),
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: application
            )
        )
    }

    func testAppTrackerEligibilityFiltersTransparentFeishuWindowBeforeShortcut() {
        let eligibility = AppTrackerWindowEligibility()
        let application = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.electron.lark",
            appName: "Feishu",
            activationPolicy: .regular,
            executablePath: "/Applications/Feishu.app/Contents/MacOS/Feishu"
        )

        XCTAssertFalse(
            eligibility.isEligible(
                title: "Feishu",
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                bounds: CGRect(x: 0, y: 0, width: 723, height: 626),
                alpha: 0,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: application
            )
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

    func testWindowEligibilityAppliesSystemFiltersBeforeUntitledStandardRule() {
        let policy = DockWindowEligibilityPolicy()

        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    bundleIdentifier: "com.apple.notificationcenterui",
                    appName: "Notification Center",
                    title: nil,
                    subrole: kAXStandardWindowSubrole as String,
                    activationPolicy: .regular
                )
            ),
            .filter
        )
        XCTAssertEqual(
            policy.evaluate(
                candidate(
                    title: nil,
                    subrole: kAXStandardWindowSubrole as String,
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
                bounds: bounds,
                isMinimized: false
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "访达",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                bounds: bounds,
                isMinimized: false
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Preview",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: bounds,
                isMinimized: false
            )
        )
        XCTAssertTrue(
            FinderWindowRules.isTrackable(
                title: "Documents",
                role: "AXWindow",
                subrole: nil,
                bounds: bounds,
                isMinimized: false
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Downloads",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                bounds: nil,
                isMinimized: false
            )
        )
    }

    // Finder reports every minimized window as AXDialog; only the min=true pair is admitted,
    // and the frame / generic-title gates still apply to it.
    func testFinderTrackableAdmitsMinimizedDialogSubroleOnly() {
        let bounds = CGRect(x: 297, y: 611, width: 1227, height: 504)

        XCTAssertTrue(
            FinderWindowRules.isTrackable(
                title: "Backup",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: bounds,
                isMinimized: true
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Backup",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: bounds,
                isMinimized: false
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Backup",
                role: "AXSheet",
                subrole: "AXDialog",
                bounds: bounds,
                isMinimized: true
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "访达",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: bounds,
                isMinimized: true
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Backup",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: CGRect(x: 0, y: 0, width: 30, height: 30),
                isMinimized: true
            )
        )
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Backup",
                role: "AXWindow",
                subrole: "AXFloatingWindow",
                bounds: bounds,
                isMinimized: true
            )
        )
    }

    func testAppTrackerEligibilityAdmitsMinimizedFinderDialogButNotOtherApps() {
        let eligibility = AppTrackerWindowEligibility()
        let bounds = CGRect(x: 297, y: 611, width: 1227, height: 504)
        let finder = AppTrackerWindowEligibility.Application(
            bundleIdentifier: FinderWindowRules.bundleIdentifier,
            appName: "Finder",
            activationPolicy: .regular,
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        )
        let other = AppTrackerWindowEligibility.Application(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            activationPolicy: .regular,
            executablePath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit"
        )

        XCTAssertTrue(
            eligibility.isEligible(
                title: "Backup",
                role: kAXWindowRole as String,
                subrole: kAXDialogSubrole as String,
                bounds: bounds,
                alpha: 1,
                isMinimized: true,
                isBelowNormalLayer: false,
                application: finder
            )
        )
        XCTAssertFalse(
            eligibility.isEligible(
                title: "Backup",
                role: kAXWindowRole as String,
                subrole: kAXDialogSubrole as String,
                bounds: bounds,
                alpha: 1,
                isMinimized: false,
                isBelowNormalLayer: false,
                application: finder
            )
        )
        XCTAssertFalse(
            eligibility.isEligible(
                title: "Untitled",
                role: kAXWindowRole as String,
                subrole: kAXDialogSubrole as String,
                bounds: bounds,
                alpha: 1,
                isMinimized: true,
                isBelowNormalLayer: false,
                application: other
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
            cgWindowID: 240522,
            groupID: "tabgrp-30201-s1"
        )
        let tabB = WindowRecord(
            id: WindowID(rawValue: "cgw-249469"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "程序坞-规划",
            bounds: frame,
            status: .active,
            cgWindowID: 249469,
            groupID: "tabgrp-30201-s1"
        )

        let items = StripItem.items(from: retainedSnapshot(tabA, tabB))

        XCTAssertEqual(items.count, 1)
        let chip = items[0]
        XCTAssertEqual(Set(chip.memberWindowIDs), ["cgw-240522", "cgw-249469"])
        // 单个标签组 → 图标-only（与单窗口一致），sameAppCardCount 按合并后的卡计数
        XCTAssertFalse(chip.showsTitle)
        XCTAssertEqual(chip.sameAppCardCount, 1)
        // SwiftUI 身份锚 = AppTracker 分配的稳定座位 token（不随 active cgID 切换 → 不抖）
        XCTAssertEqual(chip.id, "tabgrp-30201-s1")
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
            cgWindowID: 249469,
            groupID: "tabgrp-30201-s1"
        )
        let visible = WindowRecord(  // 唯一可见标签（min=0 → .inactive，因 app 非前台）
            id: WindowID(rawValue: "cgw-254022"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "发生的",
            bounds: frame,
            status: .inactive,
            cgWindowID: 254022,
            groupID: "tabgrp-30201-s1"
        )
        let bgHigh = WindowRecord(
            id: WindowID(rawValue: "cgw-253982"),
            appID: AppID(rawValue: "com.mitchellh.ghostty"),
            pid: 30201,
            bundleIdentifier: "com.mitchellh.ghostty",
            title: "阿方索的",
            bounds: frame,
            status: .minimized,
            cgWindowID: 253982,
            groupID: "tabgrp-30201-s1"
        )

        let items = StripItem.items(from: retainedSnapshot(bgLow, visible, bgHigh))

        XCTAssertEqual(items.count, 1)
        let chip = items[0]
        // 身份锚仍是稳定座位 token（稳定不抖）
        XCTAssertEqual(chip.id, "tabgrp-30201-s1")
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

    /// 兄弟顶替即清（2026-08-22）：乐观 .active 落空、同 App 兄弟窗口已被快照证实 .active
    /// → 该预测必须被清掉，否则残留满 4 秒会把下一次点击误规划成 minimize（macOS 26
    /// SkyLight make-key 静默失效时的真实症状）。只清 .active 预测，且只认同 pid 的兄弟。
    func testOptimisticActiveSupersededByActiveSibling() {
        let w1 = WindowID(rawValue: "cg-sibling-1")
        let w2 = WindowID(rawValue: "cg-sibling-2")

        func record(_ id: WindowID, pid: Int32, status: WindowStatus) -> WindowRecord {
            WindowRecord(
                id: id, appID: AppID(rawValue: "test-app"), pid: pid,
                bundleIdentifier: nil, title: "Test", bounds: nil, status: status
            )
        }
        func makeSnapshot(_ records: [WindowRecord]) -> DockSnapshot {
            DockSnapshot(
                windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                orderedWindowIDs: records.map(\.id)
            )
        }

        let now = Date()
        func superseded(predicted: WindowStatus, snapshot: DockSnapshot,
                        optimisticStates: [String: OptimisticWindowState] = [:]) -> Bool {
            OptimisticWindowState.supersededByActiveSibling(
                windowID: w1.rawValue,
                state: OptimisticWindowState(status: predicted, createdAt: now),
                now: now, optimisticStates: optimisticStates,
                snapshot: snapshot, handoffGraceEnabled: true
            )
        }

        // 同 pid 兄弟已 .active → 顶替成立
        XCTAssertTrue(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active)])
        ))
        // 兄弟 .active 但属于别的 pid → 不算顶替
        XCTAssertFalse(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 2, status: .active)])
        ))
        // 没有任何兄弟 .active → 预测继续等兑现/超时
        XCTAssertFalse(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .inactive)])
        ))
        // 预测不是 .active（minimize 类）→ 与兄弟状态无关，永不因顶替被清
        XCTAssertFalse(superseded(
            predicted: .minimized,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active)])
        ))
        // 自己 .active 不算「兄弟」——兑现路径由 optimisticConfirmed 负责
        XCTAssertFalse(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .active)])
        ))
        // 在飞折扣（2026-08-26）：兄弟快照 .active 但它自己有在飞的乐观 .minimized
        //（用户刚收起它）→ 那是残影，不算顶替者
        XCTAssertFalse(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active)]),
            optimisticStates: [w2.rawValue: OptimisticWindowState(status: .minimized, createdAt: now)]
        ))
        // 兄弟在飞的是乐观 .active（用户点了它）→ 快照 .active 可信，顶替照常成立
        XCTAssertTrue(superseded(
            predicted: .active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active)]),
            optimisticStates: [w2.rawValue: OptimisticWindowState(status: .active, createdAt: now)]
        ))
    }

    /// 还原宽限（2026-08-26）：还原出身的乐观 .active 在 1.5s 宽限内不被兄弟顶替清掉。
    /// 访达实测：还原动画期 App 已前台、焦点仍挂可见兄弟，快照短暂证实兄弟 .active，
    /// 预测 10–530ms 就被顶掉，之后 ~1s 内的收起点击全成了空 activate（「点了不收」）。
    /// 让位条件：非还原出身 / 过宽限 / 兄弟自己也有乐观 .active（用户真点了兄弟卡）/
    /// 杀开关关 —— 任一成立即回到 2026-08-22 顶替原语义。
    func testRestoreOriginOptimisticActiveSurvivesTransientSiblingActive() {
        let w1 = WindowID(rawValue: "cg-restore-1")
        let w2 = WindowID(rawValue: "cg-restore-2")
        func record(_ id: WindowID, pid: Int32, status: WindowStatus) -> WindowRecord {
            WindowRecord(
                id: id, appID: AppID(rawValue: "test-app"), pid: pid,
                bundleIdentifier: nil, title: "Test", bounds: nil, status: status
            )
        }
        func makeSnapshot(_ records: [WindowRecord]) -> DockSnapshot {
            DockSnapshot(
                windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                orderedWindowIDs: records.map(\.id)
            )
        }
        let now = Date()
        // 还原动画期的真实快照形态：刚还原的 w1 尚未兑现，兄弟 w2 被短暂证实 .active。
        let handoffSnapshot = makeSnapshot([
            record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active),
        ])
        let restoreOrigin = OptimisticWindowState(status: .active, createdAt: now, focusHandoffGrace: true)

        // 还原出身 + 宽限内 + 无兄弟在飞 → 豁免，预测存活
        XCTAssertFalse(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue, state: restoreOrigin, now: now,
            optimisticStates: [w1.rawValue: restoreOrigin],
            snapshot: handoffSnapshot, handoffGraceEnabled: true
        ))
        // 非还原出身（普通激活）→ 顶替原语义照清
        XCTAssertTrue(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue,
            state: OptimisticWindowState(status: .active, createdAt: now),
            now: now, optimisticStates: [:],
            snapshot: handoffSnapshot, handoffGraceEnabled: true
        ))
        // 过宽限 → 照清
        XCTAssertTrue(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue, state: restoreOrigin,
            now: now.addingTimeInterval(OptimisticWindowState.handoffSupersessionGrace + 0.1),
            optimisticStates: [w1.rawValue: restoreOrigin],
            snapshot: handoffSnapshot, handoffGraceEnabled: true
        ))
        // 兄弟自己也持有乐观 .active（用户点了兄弟卡，焦点真被拿走）→ 照清
        XCTAssertTrue(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue, state: restoreOrigin, now: now,
            optimisticStates: [
                w1.rawValue: restoreOrigin,
                w2.rawValue: OptimisticWindowState(status: .active, createdAt: now),
            ],
            snapshot: handoffSnapshot, handoffGraceEnabled: true
        ))
        // 杀开关关 → 照清
        XCTAssertTrue(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue, state: restoreOrigin, now: now,
            optimisticStates: [w1.rawValue: restoreOrigin],
            snapshot: handoffSnapshot, handoffGraceEnabled: false
        ))
        // 没有兄弟被证实 .active → 核心判定就不成立，与豁免无关
        XCTAssertFalse(OptimisticWindowState.supersededByActiveSibling(
            windowID: w1.rawValue, state: restoreOrigin, now: now,
            optimisticStates: [w1.rawValue: restoreOrigin],
            snapshot: makeSnapshot([
                record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .inactive),
            ]),
            handoffGraceEnabled: true
        ))
    }

    /// 系统预测证伪（2026-08-26）：交接预测落在实际已收起的窗上时（快照滞后 + 动画期 CG
    /// 在屏残留），快照 minimized/hidden 即矛盾 → 立即清除，唤醒点击回到 activate。
    /// 用户自己「还原→再收起」的交替态（非系统预测的 .active + 快照 minimized）绝不能清。
    func testSystemPredictionFalsifiedOnlyClearsSystemPredictions() {
        let now = Date()
        let prediction = OptimisticWindowState(
            status: .active, createdAt: now, focusHandoffGrace: true, systemPredicted: true
        )
        let userRestore = OptimisticWindowState(status: .active, createdAt: now, focusHandoffGrace: true)

        // 系统预测 + 快照 minimized / hidden → 证伪
        XCTAssertTrue(OptimisticWindowState.systemPredictionFalsified(state: prediction, actual: .minimized))
        XCTAssertTrue(OptimisticWindowState.systemPredictionFalsified(state: prediction, actual: .hidden))
        // 快照 inactive（还在等兑现）→ 不证伪
        XCTAssertFalse(OptimisticWindowState.systemPredictionFalsified(state: prediction, actual: .inactive))
        // 用户还原出身（非系统预测）→ 交替态正常在飞，绝不清
        XCTAssertFalse(OptimisticWindowState.systemPredictionFalsified(state: userRestore, actual: .minimized))
        // 非 .active 预测与证伪无关
        XCTAssertFalse(OptimisticWindowState.systemPredictionFalsified(
            state: OptimisticWindowState(status: .minimized, createdAt: now, systemPredicted: true),
            actual: .inactive
        ))
    }

    /// 兄弟激活在飞（2026-08-25）：同 App 另一窗口的乐观 .active 尚未兑现 → toggle 的收起
    /// 判定必须降级为 activate——来回快点两个可见窗口时，快照/乐观 active 都可能是焦点交接
    /// 迟滞的残影，误收起是 Release 实测症状。宁可多余激活，绝不错误收起。
    func testSiblingActivationInFlightDowngradesMinimizeToActivate() {
        let w1 = WindowID(rawValue: "cg-inflight-1")
        let w2 = WindowID(rawValue: "cg-inflight-2")
        func record(_ id: WindowID, pid: Int32, status: WindowStatus) -> WindowRecord {
            WindowRecord(
                id: id, appID: AppID(rawValue: "test-app"), pid: pid,
                bundleIdentifier: nil, title: "Test", bounds: nil, status: status
            )
        }
        func makeSnapshot(_ records: [WindowRecord]) -> DockSnapshot {
            DockSnapshot(
                windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                orderedWindowIDs: records.map(\.id)
            )
        }
        let planner = LifecycleActionPlanner(minimizeOnDockClick: { true }, isAppFrontmost: { _ in true })
        let optimisticW2Active = ["cg-inflight-2": OptimisticWindowState(status: .active, createdAt: Date())]

        // 纯函数：兄弟乐观 .active 未兑现 → 在飞
        XCTAssertTrue(OptimisticWindowState.siblingActivationInFlight(
            windowID: w1.rawValue, optimisticStates: optimisticW2Active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .active), record(w2, pid: 1, status: .inactive)])
        ))
        // 兄弟已兑现（快照 .active）→ 不在飞
        XCTAssertFalse(OptimisticWindowState.siblingActivationInFlight(
            windowID: w1.rawValue, optimisticStates: optimisticW2Active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .active)])
        ))
        // 兄弟属别的 pid → 不相干
        XCTAssertFalse(OptimisticWindowState.siblingActivationInFlight(
            windowID: w1.rawValue, optimisticStates: optimisticW2Active,
            snapshot: makeSnapshot([record(w1, pid: 1, status: .active), record(w2, pid: 2, status: .inactive)])
        ))
        // 自己的乐观态不算兄弟
        XCTAssertFalse(OptimisticWindowState.siblingActivationInFlight(
            windowID: w1.rawValue,
            optimisticStates: ["cg-inflight-1": OptimisticWindowState(status: .active, createdAt: Date())],
            snapshot: makeSnapshot([record(w1, pid: 1, status: .active)])
        ))
        // 规划接线：W1 快照 active + 前台，但 W2 激活在飞 → 降级为 activate
        XCTAssertEqual(
            planner.plan(
                intent: .toggle(w1),
                snapshot: makeSnapshot([record(w1, pid: 1, status: .active), record(w2, pid: 1, status: .inactive)]),
                optimisticStates: optimisticW2Active
            ).kind,
            .activateWindow
        )
        // 无在飞兄弟 → 收起判定原样（护栏不扰动正常 toggle）
        XCTAssertEqual(
            planner.plan(
                intent: .toggle(w1),
                snapshot: makeSnapshot([record(w1, pid: 1, status: .active), record(w2, pid: 1, status: .inactive)])
            ).kind,
            .minimizeWindow
        )
        // 乐观陈旧路径：W1 的乐观 .active 是**更旧的**残留 + W2 在飞（用户后点了 W2）
        // → 焦点正流向 W2，照旧降级（08-25 语义，2026-08-26 起以时间先后为准）
        let base = Date()
        var both = ["cg-inflight-2": OptimisticWindowState(status: .active, createdAt: base)]
        both["cg-inflight-1"] = OptimisticWindowState(status: .active, createdAt: base.addingTimeInterval(-1.0))
        XCTAssertEqual(
            planner.plan(
                intent: .toggle(w1),
                snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .inactive)]),
                optimisticStates: both
            ).kind,
            .activateWindow
        )
        // 时序裁决（2026-08-26）：W1 自己的乐观 .active 比 W2 的**更新**（批量还原后用户
        // 最近点的就是 W1）→ 第二击是同窗严格交替，不降级、正常收起
        var ownNewer = ["cg-inflight-2": OptimisticWindowState(status: .active, createdAt: base)]
        ownNewer["cg-inflight-1"] = OptimisticWindowState(status: .active, createdAt: base.addingTimeInterval(1.0))
        XCTAssertEqual(
            planner.plan(
                intent: .toggle(w1),
                snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .inactive)]),
                optimisticStates: ownNewer
            ).kind,
            .minimizeWindow
        )
        // 同刻（时间戳相等）→ 保守降级
        var tied = ["cg-inflight-2": OptimisticWindowState(status: .active, createdAt: base)]
        tied["cg-inflight-1"] = OptimisticWindowState(status: .active, createdAt: base)
        XCTAssertEqual(
            planner.plan(
                intent: .toggle(w1),
                snapshot: makeSnapshot([record(w1, pid: 1, status: .inactive), record(w2, pid: 1, status: .inactive)]),
                optimisticStates: tied
            ).kind,
            .activateWindow
        )
    }

    /// 还原前预激活（2026-08-22 还原时序矩阵）：只有目标 App 除目标外全为最小化窗口时
    /// 才允许「先切前台再还原」；任何非最小化兄弟（含 hidden——App 被激活会整体 unhide，
    /// 同样有可提拔对象）都禁用。别的 App 的窗口不算兄弟。
    func testMinimizedRestorePreActivation() {
        let t1 = WindowID(rawValue: "cg-restore-1")
        let t2 = WindowID(rawValue: "cg-restore-2")
        func record(_ id: WindowID, pid: Int32, status: WindowStatus) -> WindowRecord {
            WindowRecord(
                id: id, appID: AppID(rawValue: "test-app"), pid: pid,
                bundleIdentifier: nil, title: "Test", bounds: nil, status: status
            )
        }
        func makeSnapshot(_ records: [WindowRecord]) -> DockSnapshot {
            DockSnapshot(
                windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                orderedWindowIDs: records.map(\.id)
            )
        }
        let target = record(t1, pid: 1, status: .minimized)

        // 没有任何兄弟 → 可预激活
        XCTAssertTrue(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target]), target: target))
        // 兄弟也是最小化 → 可预激活
        XCTAssertTrue(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target, record(t2, pid: 1, status: .minimized)]), target: target))
        // 兄弟可见（inactive / active）→ 禁用
        XCTAssertFalse(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target, record(t2, pid: 1, status: .inactive)]), target: target))
        XCTAssertFalse(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target, record(t2, pid: 1, status: .active)]), target: target))
        // 兄弟 hidden → 保守禁用
        XCTAssertFalse(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target, record(t2, pid: 1, status: .hidden)]), target: target))
        // 别的 App 的可见窗口不算兄弟
        XCTAssertTrue(MinimizedRestorePreActivation.canPreActivate(
            snapshot: makeSnapshot([target, record(t2, pid: 2, status: .active)]), target: target))
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
        subrole: String? = nil,
        bounds: CGRect? = CGRect(x: 0, y: 0, width: 400, height: 300),
        alpha: Double? = 1,
        activationPolicy: NSApplication.ActivationPolicy,
        executablePath: String? = "/Applications/Example.app/Contents/MacOS/Example"
    ) -> DockWindowEligibilityPolicy.Candidate {
        DockWindowEligibilityPolicy.Candidate(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            title: title,
            subrole: subrole,
            bounds: bounds,
            alpha: alpha,
            activationPolicy: activationPolicy,
            executablePath: executablePath
        )
    }

    // MARK: - 任务条拖动重排 · A 路线排序原语（slice 1，纯逻辑）

    /// 防打乱核心：手动排成 C A B 后，快照刷新（顺序不变的另一次对账）仍是 C A B。
    func testReconcileKeepsManualOrderOnUnchangedRefresh() {
        let manual = ["C", "A", "B"]
        let result = StripOrdering.reconcile(remembered: manual, current: ["A", "B", "C"])
        XCTAssertEqual(result, ["C", "A", "B"])
    }

    /// 新窗口进末尾：C A B 状态下新开 D → C A B D（按 current 自然序追加）。
    func testReconcileAppendsNewcomersAtTail() {
        let result = StripOrdering.reconcile(remembered: ["C", "A", "B"], current: ["A", "B", "C", "D"])
        XCTAssertEqual(result, ["C", "A", "B", "D"])
    }

    /// 多个新窗口同时出现：按 current 里的相对顺序追加到末尾。
    func testReconcileAppendsMultipleNewcomersInCurrentOrder() {
        let result = StripOrdering.reconcile(remembered: ["B", "A"], current: ["A", "B", "D", "C"])
        XCTAssertEqual(result, ["B", "A", "D", "C"])
    }

    /// 贴同伴：G 是 ghostty 窗口，拖标签出来成独立窗口 G2(同 app)。即便 ghostty chip 被手动拖到
    /// 中间，新窗口 G2 也插在 G 右边，而非任务条最右。app 键映射驱动。
    func testReconcileInsertsNewWindowNextToSameAppSibling() {
        let appKeyOf = ["A": "a", "G": "ghostty", "B": "b", "G2": "ghostty"]
        let result = StripOrdering.reconcile(
            remembered: ["A", "G", "B"],
            current: ["A", "G", "G2", "B"],
            appKeyOf: appKeyOf
        )
        XCTAssertEqual(result, ["A", "G", "G2", "B"])
    }

    /// 全新 app 的窗口（没有同 app 同伴）仍追加到末尾，不乱插。
    func testReconcileAppendsBrandNewAppAtTail() {
        let appKeyOf = ["A": "a", "G": "ghostty", "B": "b", "X": "x"]
        let result = StripOrdering.reconcile(
            remembered: ["G", "A", "B"],
            current: ["A", "G", "B", "X"],
            appKeyOf: appKeyOf
        )
        XCTAssertEqual(result, ["G", "A", "B", "X"])
    }

    /// 关闭（座位真结束 → 从 snapshot 消失）：C A B D 中 A 关闭 → C B D，其余顺序不动。
    func testReconcileDropsClosedAndPreservesRest() {
        let result = StripOrdering.reconcile(remembered: ["C", "A", "B", "D"], current: ["B", "C", "D"])
        XCTAssertEqual(result, ["C", "B", "D"])
    }

    /// 打散后不自动聚回：同 app 两窗（A1 A2）被手动拆到两端，刷新后仍保持打散，不重新相邻。
    func testReconcileDoesNotRegroupScatteredSameAppChips() {
        let scattered = ["A1", "B", "A2"]
        let result = StripOrdering.reconcile(remembered: scattered, current: ["A1", "A2", "B"])
        XCTAssertEqual(result, ["A1", "B", "A2"])
    }

    /// 关闭 + 新开复合：旧序里掉一个、又来一个新的，存活项保序、新项进末尾。
    func testReconcileHandlesSimultaneousCloseAndOpen() {
        let result = StripOrdering.reconcile(remembered: ["C", "A", "B"], current: ["C", "B", "E"])
        XCTAssertEqual(result, ["C", "B", "E"])
    }

    /// 空记忆（首次）→ 直接采用 current 的自然顺序。
    func testReconcileWithEmptyMemoryAdoptsCurrentOrder() {
        let result = StripOrdering.reconcile(remembered: [], current: ["A", "B", "C"])
        XCTAssertEqual(result, ["A", "B", "C"])
    }

    /// 拖动落右半边：A 拖到 C 右边 → B C A。
    func testReorderingDropsAfterTarget() {
        let result = StripOrdering.reordering(["A", "B", "C"], move: "A", relativeTo: "C", after: true)
        XCTAssertEqual(result, ["B", "C", "A"])
    }

    /// 拖动落左半边：A 拖到 C 左边 → B A C。
    func testReorderingDropsBeforeTarget() {
        let result = StripOrdering.reordering(["A", "B", "C"], move: "A", relativeTo: "C", after: false)
        XCTAssertEqual(result, ["B", "A", "C"])
    }

    /// 从右往左拖：C 拖到 A 左边 → C A B。
    func testReorderingMovesLeftBeforeTarget() {
        let result = StripOrdering.reordering(["A", "B", "C"], move: "C", relativeTo: "A", after: false)
        XCTAssertEqual(result, ["C", "A", "B"])
    }

    /// 落到自己、或任一 id 不存在 → 原样返回。
    func testReorderingGuardsSelfAndMissing() {
        XCTAssertEqual(StripOrdering.reordering(["A", "B"], move: "A", relativeTo: "A", after: true), ["A", "B"])
        XCTAssertEqual(StripOrdering.reordering(["A", "B"], move: "Z", relativeTo: "A", after: true), ["A", "B"])
        XCTAssertEqual(StripOrdering.reordering(["A", "B"], move: "A", relativeTo: "Z", after: false), ["A", "B"])
    }

    /// 落盘保留 tabgrp-* + kept 的 app-*；非 kept 的 app-* / cgw-* 临时键不写盘，且保持相对顺序。
    func testPersistableLiveOrderKeepsOnlyWindowChips() {
        let order = ["tabgrp-1-s1", "app-com.x", "cgw-legacy", "tabgrp-2-s1", "app-com.y"]
        // 无 keptIDs：所有 app-* 不落盘（旧行为）
        XCTAssertEqual(StripOrdering.persistableLiveOrder(order), ["tabgrp-1-s1", "tabgrp-2-s1"])
        // 有 keptIDs：com.x 是 kept → app-com.x 落盘；com.y 不是 → 不落
        XCTAssertEqual(
            StripOrdering.persistableLiveOrder(order, keptIDs: ["com.x"]),
            ["tabgrp-1-s1", "app-com.x", "tabgrp-2-s1"]
        )
    }

    /// app-* 升级成真窗口：新 id 顶替旧 id，继承原位置（rank）。
    func testSubstitutingInheritsRankOnUpgrade() {
        let result = StripOrdering.substituting(["C", "app-com.x", "B"], oldID: "app-com.x", newID: "cgw-42")
        XCTAssertEqual(result, ["C", "cgw-42", "B"])
    }

    /// 顶替的防御：旧 id 不在序列、或新 id 已在序列（防重复）→ 原样返回。
    func testSubstitutingIsGuardedAgainstMissingOrDuplicate() {
        XCTAssertEqual(StripOrdering.substituting(["A", "B"], oldID: "Z", newID: "cgw-42"), ["A", "B"])
        XCTAssertEqual(StripOrdering.substituting(["A", "B"], oldID: "A", newID: "B"), ["A", "B"])
    }
}
