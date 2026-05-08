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
