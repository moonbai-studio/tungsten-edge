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

        XCTAssertEqual(
            planner.plan(intent: .toggle(id), snapshot: activeSnapshot).kind,
            .minimizeWindow
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
        XCTAssertFalse(
            FinderWindowRules.isTrackable(
                title: "Downloads",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                bounds: nil
            )
        )
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
}
