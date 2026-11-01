import CoreGraphics
import XCTest

final class WindowLiftAvoidanceTests: XCTestCase {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 949)
    private let geometry = WindowLiftAvoidance.Geometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949),
        taskbarTop: 60
    )

    // MARK: - Geometry

    func testFillsVisibleFrameUsesTwelvePointToleranceOnAllFourEdges() {
        XCTAssertTrue(geometry.fillsVisibleFrame(visibleFrame.insetBy(dx: 12, dy: 12)))
        XCTAssertFalse(geometry.fillsVisibleFrame(visibleFrame.insetBy(dx: 12.1, dy: 12)))
        XCTAssertFalse(geometry.fillsVisibleFrame(
            CGRect(x: 0, y: 0, width: visibleFrame.width, height: visibleFrame.height - 12.1)
        ))
    }

    func testAdjustedFrameRaisesOnlyBottomAndKeepsTopLeftAndWidth() throws {
        let adjusted = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))

        XCTAssertEqual(adjusted.minY, 62)
        XCTAssertEqual(adjusted.maxY, visibleFrame.maxY)
        XCTAssertEqual(adjusted.minX, visibleFrame.minX)
        XCTAssertEqual(adjusted.width, visibleFrame.width)
    }

    func testSideSystemDockReservationIsPreserved() throws {
        let sideDockGeometry = WindowLiftAvoidance.Geometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 90, y: 0, width: 1422, height: 949),
            taskbarTop: 60
        )
        let adjusted = try XCTUnwrap(sideDockGeometry.adjustedFrame(for: sideDockGeometry.visibleFrame))

        XCTAssertEqual(adjusted.minX, 90)
        XCTAssertEqual(adjusted.width, 1422)
        XCTAssertEqual(adjusted.minY, 62)
    }

    func testExistingBottomSystemDockReservationWinsOverTungstenClearance() {
        let bottomDockGeometry = WindowLiftAvoidance.Geometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 90, width: 1512, height: 859),
            taskbarTop: 60
        )

        XCTAssertNil(bottomDockGeometry.adjustedFrame(for: bottomDockGeometry.visibleFrame))
    }

    func testNegativeAndVerticallyStackedScreenGeometry() throws {
        let lowerScreenGeometry = WindowLiftAvoidance.Geometry(
            screenFrame: CGRect(x: -2408, y: -640, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -2408, y: -640, width: 1920, height: 1055),
            taskbarTop: -580
        )
        let adjusted = try XCTUnwrap(
            lowerScreenGeometry.adjustedFrame(for: lowerScreenGeometry.visibleFrame)
        )

        XCTAssertEqual(adjusted.minY, -578)
        XCTAssertEqual(adjusted.maxY, lowerScreenGeometry.visibleFrame.maxY)

        let upperAppKit = CGRect(x: -488, y: 982, width: 2560, height: 1440)
        let upperQuartz = WindowLiftAvoidance.quartzFrame(
            fromAppKit: upperAppKit,
            primaryScreenHeight: 982
        )
        XCTAssertEqual(upperQuartz, CGRect(x: -488, y: -1440, width: 2560, height: 1440))
        XCTAssertEqual(
            WindowLiftAvoidance.appKitFrame(fromQuartz: upperQuartz, primaryScreenHeight: 982),
            upperAppKit
        )
    }

    func testGeometryRejectsWindowOnAnotherScreen() {
        let otherScreenWindow = CGRect(x: 1600, y: 0, width: 1512, height: 949)
        XCTAssertFalse(geometry.fillsVisibleFrame(otherScreenWindow))
        XCTAssertNil(geometry.adjustedFrame(for: otherScreenWindow))
    }

    // MARK: - Bottom-docked tiles

    /// macOS 27.0 desktop-tiling frames measured on a 1920×1080 display with a 30pt menu bar
    /// (`Docs/05` §「分屏」有两种), converted to AppKit coordinates.
    private let tileGeometry = WindowLiftAvoidance.Geometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
        taskbarTop: 72
    )
    private let leftHalf = CGRect(x: 0, y: 0, width: 960, height: 1050)
    private let rightHalf = CGRect(x: 959, y: 0, width: 960, height: 1050)
    private let leftHalfWithMargins = CGRect(x: 8, y: 8, width: 948, height: 1034)

    func testSystemTilesThatReachTheBottomAreBottomDockedTiles() {
        XCTAssertTrue(tileGeometry.isBottomDockedTile(leftHalf))
        XCTAssertTrue(tileGeometry.isBottomDockedTile(rightHalf))
        XCTAssertTrue(tileGeometry.isBottomDockedTile(leftHalfWithMargins))
        XCTAssertTrue(tileGeometry.isBottomDockedTile(CGRect(x: 963, y: 8, width: 948, height: 1034)))
        // Bottom-right quarter, without and with margins.
        XCTAssertTrue(tileGeometry.isBottomDockedTile(CGRect(x: 959, y: 0, width: 960, height: 525)))
        XCTAssertTrue(tileGeometry.isBottomDockedTile(CGRect(x: 963, y: 8, width: 948, height: 514)))
        // Bottom half, and a centred full-height column (top + bottom flush, neither side).
        XCTAssertTrue(tileGeometry.isBottomDockedTile(CGRect(x: 0, y: 0, width: 1920, height: 525)))
        XCTAssertTrue(tileGeometry.isBottomDockedTile(CGRect(x: 480, y: 0, width: 960, height: 1050)))
    }

    func testWindowsThatAreNotBottomDockedTiles() {
        // Top-right quarter: the bottom edge is nowhere near the taskbar.
        XCTAssertFalse(tileGeometry.isBottomDockedTile(CGRect(x: 959, y: 525, width: 960, height: 525)))
        // Free-floating window.
        XCTAssertFalse(tileGeometry.isBottomDockedTile(CGRect(x: 300, y: 200, width: 900, height: 600)))
        // Bottom flush only — no second flush edge.
        XCTAssertFalse(tileGeometry.isBottomDockedTile(CGRect(x: 300, y: 0, width: 900, height: 600)))
        // Small window resting in the bottom-left corner: under the height floor, then the width floor.
        XCTAssertFalse(tileGeometry.isBottomDockedTile(CGRect(x: 0, y: 0, width: 600, height: 300)))
        XCTAssertFalse(tileGeometry.isBottomDockedTile(CGRect(x: 0, y: 0, width: 400, height: 600)))
        // Hanging off the visible frame.
        XCTAssertFalse(tileGeometry.isBottomDockedTile(CGRect(x: -200, y: 0, width: 960, height: 1050)))
        // Mostly on another screen.
        XCTAssertFalse(tileGeometry.isBottomDockedTile(CGRect(x: 1900, y: 0, width: 960, height: 1050)))
    }

    func testBottomDockedTileUsesTheTwelvePointDetectionTolerance() {
        XCTAssertTrue(tileGeometry.isBottomDockedTile(CGRect(x: 12, y: 12, width: 948, height: 1026)))
        XCTAssertFalse(tileGeometry.isBottomDockedTile(CGRect(x: 12, y: 12.1, width: 948, height: 1026)))
        // Bottom flush, but both the top and the left edge sit just outside the tolerance.
        XCTAssertFalse(tileGeometry.isBottomDockedTile(CGRect(x: 12.1, y: 0, width: 948, height: 1037.9)))
    }

    func testLiftTargetFrameRaisesOnlyTheBottomOfATile() throws {
        let target = try XCTUnwrap(tileGeometry.liftTargetFrame(for: leftHalf, includesTiles: true))
        XCTAssertEqual(target, CGRect(x: 0, y: 74, width: 960, height: 976))

        let marginTarget = try XCTUnwrap(
            tileGeometry.liftTargetFrame(for: leftHalfWithMargins, includesTiles: true)
        )
        XCTAssertEqual(marginTarget, CGRect(x: 8, y: 74, width: 948, height: 968))
    }

    func testTilesAreNotLiftedWhenTheKillSwitchIsOff() throws {
        XCTAssertFalse(tileGeometry.isLiftEligible(leftHalf, includesTiles: false))
        XCTAssertNil(tileGeometry.liftTargetFrame(for: leftHalf, includesTiles: false))

        let full = tileGeometry.visibleFrame
        XCTAssertTrue(tileGeometry.isLiftEligible(full, includesTiles: false))
        XCTAssertEqual(
            tileGeometry.liftTargetFrame(for: full, includesTiles: false),
            tileGeometry.adjustedFrame(for: full)
        )
        XCTAssertEqual(
            tileGeometry.liftTargetFrame(for: full, includesTiles: true),
            tileGeometry.adjustedFrame(for: full)
        )
    }

    func testExternalFrameIsUserEraOnlyAfterTheReassertWindow() {
        let lifted = WindowLiftAvoidance.SessionState.lifted(WindowLiftAvoidance.LiftedSession(
            generation: 1,
            nativeFrame: leftHalf,
            adjustedFrame: CGRect(x: 0, y: 74, width: 960, height: 976),
            reliftCount: 0,
            settledAt: 100,
            standoffRounds: 0
        ))
        XCTAssertFalse(WindowLiftAvoidance.externalFrameIsUserEra(state: lifted, at: 100.2))
        XCTAssertFalse(WindowLiftAvoidance.externalFrameIsUserEra(
            state: lifted,
            at: 100 + WindowLiftAvoidance.appReassertWindow
        ))
        XCTAssertTrue(WindowLiftAvoidance.externalFrameIsUserEra(
            state: lifted,
            at: 100 + WindowLiftAvoidance.appReassertWindow + 0.01
        ))

        let abandoned = WindowLiftAvoidance.SessionState.abandoned(WindowLiftAvoidance.AbandonedSession(
            generation: 1,
            nativeFrame: leftHalf,
            adjustedFrame: CGRect(x: 0, y: 74, width: 960, height: 976),
            reliftCount: 1,
            reason: .reliftLimitReached,
            abandonedAt: 100,
            standoffRounds: 2
        ))
        XCTAssertFalse(WindowLiftAvoidance.externalFrameIsUserEra(state: abandoned, at: 100.5))
        XCTAssertTrue(WindowLiftAvoidance.externalFrameIsUserEra(state: abandoned, at: 102))

        let writing = WindowLiftAvoidance.SessionState.writing(WindowLiftAvoidance.WriteAttempt(
            generation: 1,
            latestObservationGeneration: 1,
            nativeFrame: leftHalf,
            targetFrame: CGRect(x: 0, y: 74, width: 960, height: 976),
            reliftCount: 0,
            standoffRounds: 0
        ))
        XCTAssertFalse(WindowLiftAvoidance.externalFrameIsUserEra(state: writing, at: 500))
        XCTAssertFalse(WindowLiftAvoidance.externalFrameIsUserEra(state: .idle, at: 500))
    }

    func testUserFrameMemoryConfirmsOnlyAFrameThatSatStill() {
        let small = CGRect(x: 300, y: 200, width: 800, height: 600)
        let grown = CGRect(x: 300, y: 200, width: 900, height: 700)
        var memory = WindowLiftAvoidance.UserFrameMemory(frame: small, at: 10)
        XCTAssertNil(memory.confirmed)
        memory.observe(small, at: 10.2)
        XCTAssertNil(memory.confirmed, "0.2s is not still enough")
        memory.observe(small, at: 10 + WindowLiftAvoidance.userFrameConfirmationInterval)
        XCTAssertEqual(memory.confirmed, small)

        // A zoom animation passing through: the candidate restarts, the confirmed frame stays.
        memory.observe(grown, at: 11)
        XCTAssertEqual(memory.confirmed, small)
        memory.observe(grown, at: 11.1)
        XCTAssertEqual(memory.confirmed, small)
        memory.observe(grown, at: 11 + WindowLiftAvoidance.userFrameConfirmationInterval)
        XCTAssertEqual(memory.confirmed, grown)

        // Seeded after a restore with the requested frame: a landing one point off keeps it.
        var seeded = WindowLiftAvoidance.UserFrameMemory(confirmed: small, at: 20)
        XCTAssertEqual(seeded.confirmed, small)
        let landed = CGRect(x: 300, y: 200, width: 801, height: 600)
        seeded.observe(landed, at: 21)
        seeded.observe(landed, at: 22)
        XCTAssertEqual(seeded.confirmed, small, "an in-tolerance landing must not move the target")
        // The window server reports the restore's frames a beat late: the first scan after the
        // pin sees the previous animation frame, the next the landing. Neither moves the target.
        var late = WindowLiftAvoidance.UserFrameMemory(confirmed: small, at: 30)
        late.observe(CGRect(x: 291, y: 192, width: 832, height: 613), at: 30.01)
        late.observe(landed, at: 30.7)
        late.observe(landed, at: 31.5)
        XCTAssertEqual(late.confirmed, small)
        XCTAssertEqual(late.candidate, small)
        let dragged = CGRect(x: 400, y: 200, width: 801, height: 600)
        seeded.observe(dragged, at: 23)
        seeded.observe(dragged, at: 24)
        XCTAssertEqual(seeded.confirmed, dragged)
    }

    func testClickCounterSamplerPairsTwoDownsIntoOneDoubleClick() {
        var sampler = WindowLiftAvoidance.ClickCounterSampler()
        let a = CGPoint(x: 100, y: 900)
        let b = CGPoint(x: 101, y: 901)
        XCTAssertNil(sampler.sample(count: 40, location: a, at: 1, doubleClickInterval: 0.55), "first sample only sets the baseline")
        XCTAssertNil(sampler.sample(count: 40, location: a, at: 1.05, doubleClickInterval: 0.55))
        XCTAssertNil(sampler.sample(count: 41, location: a, at: 1.1, doubleClickInterval: 0.55), "one click is not a double-click")
        XCTAssertEqual(
            sampler.sample(count: 42, location: b, at: 1.3, doubleClickInterval: 0.55),
            WindowLiftAvoidance.DoubleClick(location: b, at: 1.3)
        )
        XCTAssertNil(sampler.sample(count: 43, location: a, at: 1.4, doubleClickInterval: 0.55), "the pair was consumed; a third click starts over")

        // Two downs inside one sampling tick.
        XCTAssertEqual(
            sampler.sample(count: 45, location: b, at: 3, doubleClickInterval: 0.55),
            WindowLiftAvoidance.DoubleClick(location: b, at: 3)
        )

        // Clicks farther apart than the interval never pair.
        XCTAssertNil(sampler.sample(count: 46, location: a, at: 5, doubleClickInterval: 0.55))
        XCTAssertNil(sampler.sample(count: 47, location: a, at: 5.6, doubleClickInterval: 0.55))

        // A reset forgets the baseline: clicks made while sampling paused do not pile up.
        sampler.reset()
        XCTAssertNil(sampler.sample(count: 90, location: a, at: 9, doubleClickInterval: 0.55))
    }

    func testUserZoomToggleNeedsARecentTitleRegionDoubleClickAfterTheSettle() {
        let lifted = CGRect(x: 0, y: 56, width: 1920, height: 994)
        let titleBar = CGPoint(x: 900, y: 1040)
        let settledAt: TimeInterval = 100
        func toggle(_ location: CGPoint, clickAt: TimeInterval, now: TimeInterval) -> Bool {
            WindowLiftAvoidance.isUserZoomToggle(
                WindowLiftAvoidance.DoubleClick(location: location, at: clickAt),
                liftedFrame: lifted,
                settledAt: settledAt,
                at: now
            )
        }
        XCTAssertTrue(toggle(titleBar, clickAt: 105, now: 105.4))
        XCTAssertTrue(toggle(
            CGPoint(x: 900, y: lifted.maxY - WindowLiftAvoidance.zoomToggleRegionHeight),
            clickAt: 105,
            now: 105.4
        ))
        XCTAssertFalse(toggle(titleBar, clickAt: 99.9, now: 100.3), "the click that maximized the window is not its own undo")
        XCTAssertFalse(toggle(titleBar, clickAt: 105, now: 105 + WindowLiftAvoidance.zoomToggleClickWindow + 0.01), "too old")
        XCTAssertFalse(toggle(CGPoint(x: 900, y: 500), clickAt: 105, now: 105.4), "content area, not the title region")
        XCTAssertFalse(toggle(CGPoint(x: 900, y: 1060), clickAt: 105, now: 105.4), "menu bar, outside the window")
        XCTAssertFalse(WindowLiftAvoidance.isUserZoomToggle(nil, liftedFrame: lifted, settledAt: settledAt, at: 105))
    }

    func testUserRestoreFrameMovesAllFourEdgesWithIntegralValues() {
        let maximized = CGRect(x: 0, y: 30, width: 1920, height: 1020)
        let small = CGRect(x: 301, y: 203, width: 803, height: 601)
        XCTAssertEqual(WindowLiftAvoidance.userRestoreFrame(from: maximized, to: small, progress: 0), maximized)
        XCTAssertEqual(WindowLiftAvoidance.userRestoreFrame(from: maximized, to: small, progress: 1), small)
        let mid = WindowLiftAvoidance.userRestoreFrame(from: maximized, to: small, progress: 0.37)
        for value in [mid.minX, mid.minY, mid.width, mid.height] {
            XCTAssertEqual(value, value.rounded())
        }
        XCTAssertGreaterThan(mid.minX, maximized.minX)
        XCTAssertLessThan(mid.minX, small.minX)
        XCTAssertLessThan(mid.width, maximized.width)
        XCTAssertGreaterThan(mid.width, small.width)
        XCTAssertLessThan(
            WindowLiftAvoidance.userRestoreAnimationDuration,
            WindowLiftAvoidance.animationDuration
        )
    }

    func testUserRestoreObservationTellsReachedLateAndTakeoverApart() {
        let maximized = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let small = CGRect(x: 300, y: 200, width: 800, height: 600)
        func observe(_ frame: CGRect) -> WindowLiftAvoidance.UserRestoreObservation {
            WindowLiftAvoidance.userRestoreObservation(frame, from: maximized, to: small)
        }
        // Reached wins even as the "actual" of a failed precondition.
        XCTAssertEqual(observe(small), .reached)
        XCTAssertEqual(observe(CGRect(x: 302, y: 198, width: 801, height: 602)), .reached)
        // Late: anywhere inside the start→end envelope, including the start itself.
        XCTAssertEqual(observe(maximized), .late)
        let midpoint = CGRect(x: 150, y: 115, width: 1360, height: 825)
        XCTAssertEqual(observe(midpoint), .late)
        XCTAssertEqual(observe(CGRect(x: 152, y: 113, width: 1362, height: 823)), .late)
        // Takeover: outside the envelope on any component.
        XCTAssertEqual(observe(CGRect(x: -60, y: 115, width: 1360, height: 825)), .takeover)
        XCTAssertEqual(observe(CGRect(x: 150, y: 115, width: 1990, height: 825)), .takeover)
        XCTAssertEqual(observe(CGRect(x: 150, y: 115, width: 1360, height: 500)), .takeover)
        XCTAssertEqual(observe(CGRect(x: 150, y: 115, width: 0, height: 825)), .takeover)
        // Known boundary of the coarse envelope: a 40pt drag of the midpoint still reads as late and
        // gets overwritten to the end frame. Tightening this changes the documented promise.
        XCTAssertEqual(observe(CGRect(x: 190, y: 115, width: 1360, height: 825)), .late)
    }

    func testSuppressionReleasesOnANewEligibleFrameOnlyInTheUserEra() {
        let full = tileGeometry.visibleFrame
        func releases(_ frame: CGRect, native: CGRect, userEra: Bool = true, tiles: Bool = true) -> Bool {
            tileGeometry.suppressionReleasesOnNewFrame(
                frame,
                suppressedNative: native,
                userEra: userEra,
                includesTiles: tiles
            )
        }

        // Re-tiled somewhere else, maximized ↔ tile, and the same slot after a margin toggle.
        XCTAssertTrue(releases(rightHalf, native: leftHalf))
        XCTAssertTrue(releases(full, native: leftHalf))
        XCTAssertTrue(releases(leftHalf, native: full))
        XCTAssertTrue(releases(leftHalfWithMargins, native: leftHalf))

        // An app's or a window manager's reaction keeps the exact-native rule.
        XCTAssertFalse(releases(rightHalf, native: leftHalf, userEra: false))
        XCTAssertFalse(releases(leftHalfWithMargins, native: leftHalf, userEra: false))

        // Maximized → maximized stays on the old path even when the two frames sit on opposite
        // sides of the detection band.
        XCTAssertFalse(releases(
            CGRect(x: -12, y: 0, width: 1944, height: 1050),
            native: CGRect(x: 12, y: 0, width: 1896, height: 1050)
        ))

        // Not eligible, or the kill switch is off.
        XCTAssertFalse(releases(CGRect(x: 300, y: 200, width: 900, height: 600), native: leftHalf))
        XCTAssertFalse(releases(rightHalf, native: leftHalf, tiles: false))
    }

    func testLiftCandidateGateAddsTilesAndTrackedWindowsToTheWidthGate() {
        let context = WindowLiftAvoidanceContext(
            geometry: tileGeometry,
            screenCGFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleCGFrame: CGRect(x: 0, y: 30, width: 1920, height: 1050),
            primaryScreenHeight: 1080
        )
        func isCandidate(_ quartzFrame: CGRect, tracked: Bool = false, tiles: Bool = true) -> Bool {
            WindowLiftAvoidance.isLiftCandidate(
                quartzFrame: quartzFrame,
                isTracked: tracked,
                context: context,
                includesTiles: tiles
            )
        }
        let wide = CGRect(x: 100, y: 100, width: 1400, height: 700)
        let leftHalfQuartz = CGRect(x: 0, y: 30, width: 960, height: 1050)
        let liftedLeftHalfQuartz = CGRect(x: 0, y: 30, width: 960, height: 976)
        let floating = CGRect(x: 300, y: 200, width: 900, height: 600)

        XCTAssertTrue(isCandidate(wide))
        XCTAssertTrue(isCandidate(leftHalfQuartz))
        XCTAssertFalse(isCandidate(floating))
        // A lifted tile is neither wide nor bottom-docked; only its session keeps it a candidate.
        XCTAssertFalse(isCandidate(liftedLeftHalfQuartz))
        XCTAssertTrue(isCandidate(liftedLeftHalfQuartz, tracked: true))

        // Kill switch off = the 0.7 width gate alone.
        XCTAssertTrue(isCandidate(wide, tiles: false))
        XCTAssertFalse(isCandidate(leftHalfQuartz, tiles: false))
        XCTAssertFalse(isCandidate(liftedLeftHalfQuartz, tracked: true, tiles: false))
    }

    // MARK: - Retry and animation

    func testPollScheduleHasOnlyImmediateHundredAndTwoHundredFiftyMillisecondAttempts() {
        let schedule = WindowLiftAvoidance.PollSchedule.standard

        XCTAssertEqual(schedule.deadlines, [0, 0.1, 0.25])
        XCTAssertEqual(schedule.incrementalDelays[0], 0, accuracy: 0.0001)
        XCTAssertEqual(schedule.incrementalDelays[1], 0.1, accuracy: 0.0001)
        XCTAssertEqual(schedule.incrementalDelays[2], 0.15, accuracy: 0.0001)
        XCTAssertEqual(schedule.remainingDelay(for: 2, elapsed: 0.2) ?? -1, 0.05, accuracy: 0.0001)
        XCTAssertNil(schedule.remainingDelay(for: 3, elapsed: 0))
    }

    func testGlobalAndTrackedSessionCGCadencesStaySeparate() {
        XCTAssertEqual(WindowLiftAvoidance.globalDetectionInterval, 0.2, accuracy: 0.0001)
        XCTAssertEqual(WindowLiftAvoidance.trackedSessionProbeInterval, 0.05, accuracy: 0.0001)
        XCTAssertLessThan(
            WindowLiftAvoidance.trackedSessionProbeInterval,
            WindowLiftAvoidance.globalDetectionInterval
        )
    }

    func testEaseInOutCubicIsClampedMonotonicAndSymmetric() {
        let samples = stride(from: -0.2, through: 1.2, by: 0.05).map {
            WindowLiftAvoidance.easeInOutCubic($0)
        }

        XCTAssertEqual(samples.first, 0)
        XCTAssertEqual(samples.last, 1)
        for pair in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1)
        }
        XCTAssertEqual(WindowLiftAvoidance.easeInOutCubic(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(
            WindowLiftAvoidance.easeInOutCubic(0.25),
            1 - WindowLiftAvoidance.easeInOutCubic(0.75),
            accuracy: 0.0001
        )
    }

    func testInterpolatedFrameKeepsTopStableForLiftGeometry() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))

        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            let sample = WindowLiftAvoidance.interpolatedFrame(
                from: visibleFrame,
                to: target,
                progress: progress
            )
            XCTAssertEqual(sample.maxY, visibleFrame.maxY, accuracy: 0.0001)
            XCTAssertEqual(sample.minX, visibleFrame.minX, accuracy: 0.0001)
            XCTAssertEqual(sample.width, visibleFrame.width, accuracy: 0.0001)
        }
    }

    func testRebasedAnimationProgressUsesRemainingHardDeadline() {
        XCTAssertEqual(
            WindowLiftAvoidance.rebasedAnimationProgress(0.5, startingAt: 0),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rebasedAnimationProgress(0.4, startingAt: 0.4),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rebasedAnimationProgress(0.7, startingAt: 0.4),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rebasedAnimationProgress(1, startingAt: 0.4),
            1,
            accuracy: 0.0001
        )
    }

    func testFrameClassificationUsesTargetNativeTrajectoryExternalPriority() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let midpoint = WindowLiftAvoidance.interpolatedFrame(
            from: visibleFrame,
            to: target,
            progress: 0.5
        )

        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: target,
                nativeFrame: visibleFrame,
                targetFrame: target
            ),
            .target
        )
        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: visibleFrame,
                nativeFrame: visibleFrame,
                targetFrame: target
            ),
            .native
        )
        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: midpoint,
                nativeFrame: visibleFrame,
                targetFrame: target
            ),
            .managedTrajectory
        )
        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: midpoint.offsetBy(dx: 2.1, dy: 0),
                nativeFrame: visibleFrame,
                targetFrame: target
            ),
            .external
        )
        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: CGRect(
                    x: midpoint.minX,
                    y: target.minY + 2.1,
                    width: midpoint.width,
                    height: midpoint.maxY - target.minY - 2.1
                ),
                nativeFrame: visibleFrame,
                targetFrame: target
            ),
            .external
        )
    }

    func testFrameClassificationPrefersTargetWhenEndpointTolerancesOverlap() {
        let native = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 0, y: 3, width: 100, height: 97)
        let matchesBothEndpoints = CGRect(x: 0, y: 1.5, width: 100, height: 98.5)

        XCTAssertTrue(WindowLiftAvoidance.framesMatch(matchesBothEndpoints, native))
        XCTAssertTrue(WindowLiftAvoidance.framesMatch(matchesBothEndpoints, target))
        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: matchesBothEndpoints,
                nativeFrame: native,
                targetFrame: target
            ),
            .target
        )
    }

    func testStableSamplesUseVerificationTolerance() {
        XCTAssertTrue(WindowLiftAvoidance.samplesAreStable(
            visibleFrame.offsetBy(dx: 2, dy: -2),
            comparedTo: visibleFrame
        ))
        XCTAssertFalse(WindowLiftAvoidance.samplesAreStable(
            visibleFrame.offsetBy(dx: 2.1, dy: 0),
            comparedTo: visibleFrame
        ))
        XCTAssertFalse(WindowLiftAvoidance.samplesAreStable(
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            comparedTo: visibleFrame
        ))
    }

    func testThreeWayStableSamplesRejectAccumulatedPairwiseDrift() {
        XCTAssertTrue(WindowLiftAvoidance.samplesAreStable(
            initialCGFrame: visibleFrame,
            confirmedCGFrame: visibleFrame.offsetBy(dx: 1, dy: 0),
            confirmedAXFrame: visibleFrame.offsetBy(dx: -1, dy: 0)
        ))

        XCTAssertFalse(WindowLiftAvoidance.samplesAreStable(
            initialCGFrame: visibleFrame,
            confirmedCGFrame: visibleFrame.offsetBy(dx: 2, dy: 0),
            confirmedAXFrame: visibleFrame.offsetBy(dx: 4, dy: 0)
        ))
    }

    func testMovedCandidateCanBecomeFreshStableCandidateOnNextScan() {
        let settledFrame = visibleFrame.offsetBy(dx: 0, dy: 5)

        XCTAssertFalse(WindowLiftAvoidance.samplesAreStable(
            settledFrame,
            comparedTo: visibleFrame
        ))
        XCTAssertTrue(WindowLiftAvoidance.samplesAreStable(
            settledFrame,
            comparedTo: settledFrame
        ))
    }

    // MARK: - Session reducer

    func testInitialDetectionWritesThenRecordsLift() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        var transition = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 1,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )

        XCTAssertEqual(
            transition.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 1, isRelift: false)
        )
        transition = WindowLiftAvoidance.reduce(
            state: transition.state,
            event: .writeFinished(generation: 1, at: 1000.6, actualFrame: target, reliftCount: 0)
        )

        guard case let .lifted(session) = transition.state else {
            return XCTFail("Expected lifted state")
        }
        XCTAssertEqual(session.reliftCount, 0)
        XCTAssertEqual(session.adjustedFrame, target)
        XCTAssertEqual(session.settledAt, 1000.6)
        XCTAssertEqual(session.standoffRounds, 0)
    }

    func testOneReliftIsAllowedThenThirdMaximizeDetectionAbandons() throws {
        // 全程都在 appReassertWindow(1.0s) 内：铺满重现按应用抢顶处理。
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        var transition = completedLift(generation: 1, target: target)

        transition = WindowLiftAvoidance.reduce(
            state: transition.state,
            event: .maximizedDetected(
                generation: 2,
                at: 1000.9,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(
            transition.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 2, isRelift: true)
        )
        transition = WindowLiftAvoidance.reduce(
            state: transition.state,
            event: .writeFinished(generation: 2, at: 1001.2, actualFrame: target, reliftCount: 1)
        )

        transition = WindowLiftAvoidance.reduce(
            state: transition.state,
            event: .maximizedDetected(
                generation: 3,
                at: 1001.6,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(transition.action, .abandon(.reliftLimitReached))
        guard case let .abandoned(session) = transition.state else {
            return XCTFail("Expected abandoned state")
        }
        XCTAssertEqual(session.reliftCount, 1)
        XCTAssertEqual(session.abandonedAt, 1001.6)

        let repeated = WindowLiftAvoidance.reduce(
            state: transition.state,
            event: .maximizedDetected(
                generation: 4,
                at: 1002.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(repeated.action, .none)
        guard case let .abandoned(repeatedSession) = repeated.state else {
            return XCTFail("Abandoned session must persist while the window remains maximized")
        }
        XCTAssertEqual(repeatedSession.abandonedAt, 1001.6, "后续观察不得刷新 abandonedAt")
    }

    func testLeavingMaximizedClearsLiftedAndAbandonedSessions() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let manualFrame = CGRect(x: 180, y: 140, width: 1000, height: 700)
        let lifted = completedLift(generation: 1, target: target).state

        let clearedLifted = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .nonMaximizedObserved(generation: 2, at: 1000.8, frame: manualFrame)
        )
        XCTAssertEqual(clearedLifted, .init(state: .idle, action: .clear))

        let abandoned = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .maximizedDetected(
                generation: 2,
                at: 1000.9,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        let failed = WindowLiftAvoidance.reduce(
            state: abandoned.state,
            event: .writeFailed(generation: 2, at: 1001.0, reliftCount: 1)
        )
        guard case .abandoned = failed.state else { return XCTFail("Expected failed write to abandon") }

        let clearedAbandoned = WindowLiftAvoidance.reduce(
            state: failed.state,
            event: .nonMaximizedObserved(generation: 3, at: 1001.2, frame: manualFrame)
        )
        XCTAssertEqual(clearedAbandoned, .init(state: .idle, action: .clear))
    }

    func testObservingOurAdjustedFrameDoesNotClearSession() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let lifted = completedLift(generation: 1, target: target).state

        let transition = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .nonMaximizedObserved(
                generation: 2,
                at: 1000.8,
                frame: target.offsetBy(dx: 1, dy: -1)
            )
        )

        XCTAssertEqual(transition.action, .none)
        guard case let .lifted(session) = transition.state else {
            return XCTFail("Expected lifted session to remain active")
        }
        XCTAssertEqual(session.generation, 2)
        XCTAssertEqual(session.settledAt, 1000.6, "target 观察只刷新 generation，不动 settledAt")
    }

    func testStaleWriteCompletionAndObservationCannotChangeNewerSession() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 10,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state

        XCTAssertEqual(
            WindowLiftAvoidance.reduce(
                state: writing,
                event: .writeFinished(generation: 9, at: 1000.3, actualFrame: target, reliftCount: 0)
            ),
            .init(state: writing, action: .none)
        )

        let lifted = WindowLiftAvoidance.reduce(
            state: writing,
            event: .writeFinished(generation: 10, at: 1000.6, actualFrame: target, reliftCount: 0)
        ).state
        XCTAssertEqual(
            WindowLiftAvoidance.reduce(
                state: lifted,
                event: .nonMaximizedObserved(
                    generation: 9,
                    at: 1000.7,
                    frame: CGRect(x: 10, y: 10, width: 500, height: 500)
                )
            ),
            .init(state: lifted, action: .none)
        )
    }

    func testWritingManagedTrajectoryContinuesButExternalFrameClearsAndLateCompletionIsIgnored() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 1,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let midpoint = WindowLiftAvoidance.interpolatedFrame(
            from: visibleFrame,
            to: target,
            progress: 0.5
        )

        let managed = WindowLiftAvoidance.reduce(
            state: writing,
            event: .nonMaximizedObserved(generation: 2, at: 1000.2, frame: midpoint)
        )
        XCTAssertEqual(managed.action, .none)
        guard case let .writing(managedAttempt) = managed.state else {
            return XCTFail("Expected the managed trajectory to keep the write active")
        }
        XCTAssertEqual(managedAttempt.generation, 1)
        XCTAssertEqual(managedAttempt.latestObservationGeneration, 2)

        let manualFrame = CGRect(x: 140, y: 120, width: 900, height: 700)
        let cleared = WindowLiftAvoidance.reduce(
            state: managed.state,
            event: .nonMaximizedObserved(generation: 3, at: 1000.3, frame: manualFrame)
        )
        XCTAssertEqual(cleared, .init(state: .idle, action: .clear))

        XCTAssertEqual(
            WindowLiftAvoidance.reduce(
                state: cleared.state,
                event: .writeFinished(generation: 1, at: 1000.6, actualFrame: target, reliftCount: 0)
            ),
            .init(state: .idle, action: .none)
        )

        let restarted = WindowLiftAvoidance.reduce(
            state: cleared.state,
            event: .maximizedDetected(
                generation: 4,
                at: 1001.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(
            restarted.action,
            .write(
                targetFrame: target,
                rollbackFrame: visibleFrame,
                generation: 4,
                isRelift: false
            )
        )
        guard case let .writing(restartedAttempt) = restarted.state else {
            return XCTFail("Expected a fresh writing session")
        }
        XCTAssertEqual(restartedAttempt.reliftCount, 0)
    }

    func testWritingIgnoresOlderFrameFromTheOtherCGProbeCadence() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let midpoint = WindowLiftAvoidance.interpolatedFrame(
            from: visibleFrame,
            to: target,
            progress: 0.5
        )
        let manualFrame = CGRect(x: 140, y: 120, width: 900, height: 700)
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 1,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let newerManagedObservation = WindowLiftAvoidance.reduce(
            state: writing,
            event: .nonMaximizedObserved(generation: 3, at: 1000.2, frame: midpoint)
        )

        let lateExternalObservation = WindowLiftAvoidance.reduce(
            state: newerManagedObservation.state,
            event: .nonMaximizedObserved(generation: 2, at: 1000.25, frame: manualFrame)
        )
        XCTAssertEqual(lateExternalObservation, .init(
            state: newerManagedObservation.state,
            action: .none
        ))

        let completed = WindowLiftAvoidance.reduce(
            state: newerManagedObservation.state,
            event: .writeFinished(generation: 1, at: 1000.6, actualFrame: target, reliftCount: 0)
        )
        guard case let .lifted(session) = completed.state else {
            return XCTFail("Expected the original serial writer to complete")
        }
        XCTAssertEqual(session.generation, 3)
        XCTAssertEqual(
            WindowLiftAvoidance.reduce(
                state: completed.state,
                event: .nonMaximizedObserved(generation: 2, at: 1000.7, frame: manualFrame)
            ),
            .init(state: completed.state, action: .none)
        )

        XCTAssertEqual(
            WindowLiftAvoidance.reduce(
                state: completed.state,
                event: .nonMaximizedObserved(generation: 4, at: 1000.8, frame: manualFrame)
            ),
            .init(state: .idle, action: .clear)
        )
    }

    func testWriterCanReportOneInternalReliftAndSecondSnapSeparately() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 10,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state

        let completed = WindowLiftAvoidance.reduce(
            state: writing,
            event: .writeFinished(generation: 10, at: 1000.6, actualFrame: target, reliftCount: 1)
        )
        guard case let .lifted(lifted) = completed.state else {
            return XCTFail("Expected internally relifted write to complete")
        }
        XCTAssertEqual(lifted.reliftCount, 1)

        let secondWriting = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 20,
                at: 1002,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let abandoned = WindowLiftAvoidance.reduce(
            state: secondWriting,
            event: .reliftLimitReached(generation: 20, at: 1002.5, reliftCount: 1)
        )
        XCTAssertEqual(abandoned.action, .abandon(.reliftLimitReached))
        guard case let .abandoned(session) = abandoned.state else {
            return XCTFail("Expected second native snap to abandon")
        }
        XCTAssertEqual(session.reliftCount, 1)
        XCTAssertEqual(session.reason, .reliftLimitReached)
        XCTAssertEqual(session.abandonedAt, 1002.5)
    }

    func testTrueWriteFailureHasDedicatedEvent() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 4,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state

        let failed = WindowLiftAvoidance.reduce(
            state: writing,
            event: .writeFailed(generation: 4, at: 1000.4, reliftCount: 0)
        )
        XCTAssertEqual(failed.action, .abandon(.writeFailed))
        guard case let .abandoned(session) = failed.state else {
            return XCTFail("Expected true AX failure to abandon")
        }
        XCTAssertEqual(session.reason, .writeFailed)
        XCTAssertEqual(session.reliftCount, 0)
    }

    func testWriteFinishedEnforcesFinalTwoPointVerificationTolerance() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let withinTolerance = CGRect(
            x: target.minX,
            y: target.minY - 2,
            width: target.width,
            height: target.height + 2
        )
        let acceptedWriting = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 1,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let accepted = WindowLiftAvoidance.reduce(
            state: acceptedWriting,
            event: .writeFinished(generation: 1, at: 1000.6, actualFrame: withinTolerance, reliftCount: 0)
        )
        guard case .lifted = accepted.state else {
            return XCTFail("Expected a final frame at the 2pt boundary to be accepted")
        }

        let outsideTolerance = CGRect(
            x: target.minX,
            y: target.minY - 2.1,
            width: target.width,
            height: target.height + 2.1
        )
        let rejectedWriting = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 2,
                at: 1002,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let rejected = WindowLiftAvoidance.reduce(
            state: rejectedWriting,
            event: .writeFinished(generation: 2, at: 1002.6, actualFrame: outsideTolerance, reliftCount: 0)
        )
        XCTAssertEqual(rejected.action, .abandon(.writeFailed))
        guard case let .abandoned(session) = rejected.state else {
            return XCTFail("Expected a final frame outside 2pt to abandon")
        }
        XCTAssertEqual(session.reason, .writeFailed)
    }

    func testAnimationMismatchDecisionPreservesEveryRecoveryPath() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let midpoint = WindowLiftAvoidance.interpolatedFrame(
            from: visibleFrame,
            to: target,
            progress: 0.5
        )
        let manualFrame = CGRect(x: 140, y: 120, width: 900, height: 700)

        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: target),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0
            ),
            .complete(actualFrame: target)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: midpoint),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0
            ),
            .continueFromActual(actualFrame: midpoint)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: manualFrame),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0
            ),
            .clearSession(preservingFrame: manualFrame)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: visibleFrame),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0
            ),
            .restartFromNative(nativeFrame: visibleFrame, nextReliftCount: 1)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: visibleFrame),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 1
            ),
            .reliftLimitReached(actualFrame: visibleFrame, reliftCount: 1)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .terminalWriteFailure,
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0
            ),
            .abandonWriteFailed
        )
    }

    func testTwentyObservedRestoresEachStartANewNonReliftSession() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let manualFrame = CGRect(x: 160, y: 120, width: 920, height: 720)
        var state: WindowLiftAvoidance.SessionState = .idle
        var generation: UInt64 = 0
        var now: TimeInterval = 1000

        for _ in 0..<20 {
            generation += 1
            now += 0.2
            let writeGeneration = generation
            var transition = WindowLiftAvoidance.reduce(
                state: state,
                event: .maximizedDetected(
                    generation: writeGeneration,
                    at: now,
                    nativeFrame: visibleFrame,
                    targetFrame: target
                )
            )
            XCTAssertEqual(
                transition.action,
                .write(
                    targetFrame: target,
                    rollbackFrame: visibleFrame,
                    generation: writeGeneration,
                    isRelift: false
                )
            )
            now += 0.6
            transition = WindowLiftAvoidance.reduce(
                state: transition.state,
                event: .writeFinished(
                    generation: writeGeneration,
                    at: now,
                    actualFrame: target,
                    reliftCount: 0
                )
            )

            generation += 1
            now += 0.1
            transition = WindowLiftAvoidance.reduce(
                state: transition.state,
                event: .nonMaximizedObserved(generation: generation, at: now, frame: manualFrame)
            )
            XCTAssertEqual(transition, .init(state: .idle, action: .clear))
            state = transition.state
        }
    }

    // MARK: - Time-scale discrimination (app reassert vs user action)

    func testMaximizeReappearingAfterReassertWindowStartsFreshSession() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let lifted = completedLift(generation: 1, target: target).state  // settledAt 1000.6

        // maximizedDetected 路径：写完 1.6s 后重现铺满 = 用户操作，全新会话。
        let viaDetection = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .maximizedDetected(
                generation: 2,
                at: 1002.2,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(
            viaDetection.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 2, isRelift: false)
        )
        guard case let .writing(freshAttempt) = viaDetection.state else {
            return XCTFail("Expected a fresh writing session")
        }
        XCTAssertEqual(freshAttempt.reliftCount, 0)
        XCTAssertEqual(freshAttempt.standoffRounds, 0)

        // native 观察路径（缩放记忆污染时 L↔M 往复不产生 external，只能走这里）：同样全新会话。
        let viaObservation = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .nonMaximizedObserved(generation: 2, at: 1002.2, frame: visibleFrame)
        )
        XCTAssertEqual(
            viaObservation.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 2, isRelift: false)
        )
    }

    func testNativeSnapWithinWindowStillConsumesReliftBudget() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let lifted = completedLift(generation: 1, target: target).state  // settledAt 1000.6

        // 写完 0.4s 内被抢回铺满 = 应用抢顶，走补抬。
        let transition = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .nonMaximizedObserved(generation: 2, at: 1001.0, frame: visibleFrame)
        )
        XCTAssertEqual(
            transition.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 2, isRelift: true)
        )
    }

    func testAbandonedExpiresAfterWindowAndCountsStandoffRound() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 1,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let abandoned = WindowLiftAvoidance.reduce(
            state: writing,
            event: .writeFailed(generation: 1, at: 1000.5, reliftCount: 0)
        ).state  // abandonedAt 1000.5

        // 窗口内的铺满重现：维持 abandoned，abandonedAt 不刷新。
        let held = WindowLiftAvoidance.reduce(
            state: abandoned,
            event: .maximizedDetected(
                generation: 2,
                at: 1001.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(held.action, .none)
        guard case let .abandoned(heldSession) = held.state else {
            return XCTFail("Expected abandoned to hold within the reassert window")
        }
        XCTAssertEqual(heldSession.abandonedAt, 1000.5)

        // 关键：判定基准是最初的 abandonedAt（1000.5），不是上一次观察（1001.0）。
        // 1002.1 距离上次观察只有 1.1s，但距 abandonedAt 已 1.6s → 超时重开，记一轮对峙。
        let reopened = WindowLiftAvoidance.reduce(
            state: held.state,
            event: .maximizedDetected(
                generation: 3,
                at: 1002.1,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(
            reopened.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 3, isRelift: false)
        )
        guard case let .writing(reopenedAttempt) = reopened.state else {
            return XCTFail("Expected an expired abandoned session to reopen")
        }
        XCTAssertEqual(reopenedAttempt.reliftCount, 0)
        XCTAssertEqual(reopenedAttempt.standoffRounds, 1)

        // native 观察路径同样能触发超时重开。
        let reopenedViaObservation = WindowLiftAvoidance.reduce(
            state: held.state,
            event: .nonMaximizedObserved(generation: 3, at: 1002.1, frame: visibleFrame)
        )
        guard case let .writing(observedAttempt) = reopenedViaObservation.state else {
            return XCTFail("Expected native observation to reopen an expired abandoned session")
        }
        XCTAssertEqual(observedAttempt.standoffRounds, 1)
    }

    func testStandoffRoundsCapLocksUntilExternalFrameResets() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let manualFrame = CGRect(x: 160, y: 120, width: 920, height: 720)

        func abandonedState(
            from state: WindowLiftAvoidance.SessionState,
            generation: UInt64,
            detectedAt: TimeInterval,
            failedAt: TimeInterval,
            expectedRounds: Int
        ) throws -> WindowLiftAvoidance.SessionState {
            let writing = WindowLiftAvoidance.reduce(
                state: state,
                event: .maximizedDetected(
                    generation: generation,
                    at: detectedAt,
                    nativeFrame: visibleFrame,
                    targetFrame: target
                )
            )
            guard case let .writing(attempt) = writing.state else {
                throw XCTSkip("precondition failed: expected writing state")
            }
            XCTAssertEqual(attempt.standoffRounds, expectedRounds)
            return WindowLiftAvoidance.reduce(
                state: writing.state,
                event: .writeFailed(generation: generation, at: failedAt, reliftCount: 0)
            ).state
        }

        // 第 0 轮 → abandoned(rounds 0)；两次超时重开（rounds 1、2）后第三次不再重开。
        var state = try abandonedState(
            from: .idle, generation: 1, detectedAt: 1000, failedAt: 1000.5, expectedRounds: 0
        )
        state = try abandonedState(
            from: state, generation: 2, detectedAt: 1002.5, failedAt: 1003.0, expectedRounds: 1
        )
        state = try abandonedState(
            from: state, generation: 3, detectedAt: 1005.0, failedAt: 1005.5, expectedRounds: 2
        )

        let locked = WindowLiftAvoidance.reduce(
            state: state,
            event: .maximizedDetected(
                generation: 4,
                at: 1008.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(locked.action, .none)
        guard case let .abandoned(lockedSession) = locked.state else {
            return XCTFail("Expected the standoff cap to lock the session")
        }
        XCTAssertEqual(lockedSession.standoffRounds, 2)

        // external 帧仍是万能出口：清会话后下一次铺满从零开始。
        let cleared = WindowLiftAvoidance.reduce(
            state: locked.state,
            event: .nonMaximizedObserved(generation: 5, at: 1008.5, frame: manualFrame)
        )
        XCTAssertEqual(cleared, .init(state: .idle, action: .clear))
        let fresh = WindowLiftAvoidance.reduce(
            state: cleared.state,
            event: .maximizedDetected(
                generation: 6,
                at: 1009.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        guard case let .writing(freshAttempt) = fresh.state else {
            return XCTFail("Expected a fresh session after external reset")
        }
        XCTAssertEqual(freshAttempt.standoffRounds, 0)
        XCTAssertEqual(freshAttempt.reliftCount, 0)
    }

    func testAnimationStallIsContinueNotRestart() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let midpoint = WindowLiftAvoidance.interpolatedFrame(
            from: visibleFrame,
            to: target,
            progress: 0.5
        )

        // 第一帧停滞：回读 == 最近确认位置（== native）。1x 屏迟到应用的典型形态，
        // 按继续处理，不得烧补抬额度、不得放弃。
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: visibleFrame),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0,
                lastAcknowledgedFrame: visibleFrame
            ),
            .continueFromActual(actualFrame: visibleFrame)
        )
        // 动画中途真被应用抢回：确认位置已在轨迹内，回读却是 native → 补抬。
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: visibleFrame),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0,
                lastAcknowledgedFrame: midpoint
            ),
            .restartFromNative(nativeFrame: visibleFrame, nextReliftCount: 1)
        )
        // 轨迹中段停滞：回读 == 确认位置 → 继续。
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: midpoint),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0,
                lastAcknowledgedFrame: midpoint
            ),
            .continueFromActual(actualFrame: midpoint)
        )
        // 已到目标优先判完成，即使等于确认位置。
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: target),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0,
                lastAcknowledgedFrame: target
            ),
            .complete(actualFrame: target)
        )
    }

    func testDetourReturnCountsAStandoffRoundAndStopsAtTheCap() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))

        let first = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .detourReturnObserved(
                generation: 1,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target,
                standoffRounds: 0
            )
        )
        guard case let .writing(attempt) = first.state else {
            return XCTFail("Expected a lift that carries the standoff round")
        }
        XCTAssertEqual(attempt.standoffRounds, 1)
        XCTAssertEqual(attempt.reliftCount, 0)
        XCTAssertEqual(
            first.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 1, isRelift: false)
        )

        let capped = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .detourReturnObserved(
                generation: 2,
                at: 1002,
                nativeFrame: visibleFrame,
                targetFrame: target,
                standoffRounds: WindowLiftAvoidance.maximumStandoffRounds - 1
            )
        )
        XCTAssertEqual(capped.action, .abandon(.reliftLimitReached))
        guard case let .abandoned(session) = capped.state else {
            return XCTFail("Expected the cap to park the window without a write")
        }
        XCTAssertEqual(session.standoffRounds, WindowLiftAvoidance.maximumStandoffRounds)

        // Parked at the cap: no reopen however long the window stays maximized…
        let later = WindowLiftAvoidance.reduce(
            state: capped.state,
            event: .maximizedDetected(generation: 3, at: 1030, nativeFrame: visibleFrame, targetFrame: target)
        )
        XCTAssertEqual(later.action, .none)
        // …until an external frame ends the episode.
        let cleared = WindowLiftAvoidance.reduce(
            state: later.state,
            event: .nonMaximizedObserved(
                generation: 4,
                at: 1031,
                frame: CGRect(x: 160, y: 120, width: 920, height: 720)
            )
        )
        XCTAssertEqual(cleared, .init(state: .idle, action: .clear))
    }

    func testDetourReturnIsIgnoredOutsideIdleAndOnlyCountsWithinTheReassertWindow() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let lifted = WindowLiftAvoidance.SessionState.lifted(WindowLiftAvoidance.LiftedSession(
            generation: 1,
            nativeFrame: visibleFrame,
            adjustedFrame: target,
            reliftCount: 0,
            settledAt: 100,
            standoffRounds: 0
        ))
        let ignored = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .detourReturnObserved(
                generation: 2,
                at: 100.5,
                nativeFrame: visibleFrame,
                targetFrame: target,
                standoffRounds: 0
            )
        )
        XCTAssertEqual(ignored, .init(state: lifted, action: .none))

        XCTAssertTrue(WindowLiftAvoidance.isDetourReturn(clearedAt: 100, at: 100.3))
        XCTAssertTrue(WindowLiftAvoidance.isDetourReturn(
            clearedAt: 100,
            at: 100 + WindowLiftAvoidance.appReassertWindow
        ))
        XCTAssertFalse(WindowLiftAvoidance.isDetourReturn(
            clearedAt: 100,
            at: 100 + WindowLiftAvoidance.appReassertWindow + 0.01
        ))
    }

    func testLockedStandoffStopsRetryingAndResetsOnlyOnExternalFrame() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let manualFrame = CGRect(x: 160, y: 120, width: 920, height: 720)

        func failedSession(
            from state: WindowLiftAvoidance.SessionState,
            generation: UInt64,
            detectedAt: TimeInterval,
            failedAt: TimeInterval
        ) -> WindowLiftAvoidance.SessionState {
            let writing = WindowLiftAvoidance.reduce(
                state: state,
                event: .maximizedDetected(
                    generation: generation,
                    at: detectedAt,
                    nativeFrame: visibleFrame,
                    targetFrame: target
                )
            ).state
            return WindowLiftAvoidance.reduce(
                state: writing,
                event: .writeFailed(generation: generation, at: failedAt, reliftCount: 0)
            ).state
        }

        var state = failedSession(from: .idle, generation: 1, detectedAt: 1000, failedAt: 1000.5)
        state = failedSession(from: state, generation: 2, detectedAt: 1002.5, failedAt: 1003.0)
        state = failedSession(from: state, generation: 3, detectedAt: 1005.0, failedAt: 1005.5)
        // rounds 已达上限，abandonedAt 1005.5。

        // 到顶后无论过多久都不再重开（owner 2026-09-18：旧行为是 3s 慢频重开，造成平铺工具下
        // 窗口底边周期性跳）。此处 14.5s 后仍维持 abandoned、无 write。
        let stillLocked = WindowLiftAvoidance.reduce(
            state: state,
            event: .maximizedDetected(
                generation: 4,
                at: 1020.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(stillLocked.action, .none)
        guard case let .abandoned(lockedSession) = stillLocked.state else {
            return XCTFail("Expected the standoff cap to keep the session locked, no slow retry")
        }
        XCTAssertEqual(lockedSession.standoffRounds, WindowLiftAvoidance.maximumStandoffRounds)

        // external 帧（窗口不再铺满）是唯一出口：清会话，下一次铺满从零开始。
        let cleared = WindowLiftAvoidance.reduce(
            state: stillLocked.state,
            event: .nonMaximizedObserved(generation: 5, at: 1021.0, frame: manualFrame)
        )
        XCTAssertEqual(cleared, .init(state: .idle, action: .clear))
        let fresh = WindowLiftAvoidance.reduce(
            state: cleared.state,
            event: .maximizedDetected(
                generation: 6,
                at: 1022.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        guard case let .writing(freshAttempt) = fresh.state else {
            return XCTFail("Expected a fresh session after the external reset")
        }
        XCTAssertEqual(freshAttempt.standoffRounds, 0)
        XCTAssertEqual(freshAttempt.reliftCount, 0)
    }

    func testUserPacedZoomToggleBetweenLiftedAndMaximizedAlwaysRelifts() throws {
        // L↔M 死锁回归测试：缩放记忆被污染后，用户的缩放键只在 target(L) 和 native(M)
        // 之间往复、永不产生 external 帧。用户节奏（超过 appReassertWindow）下每次落 M 都必须开新会话。
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        var state = completedLift(generation: 1, target: target).state
        var generation: UInt64 = 1
        var settledAt: TimeInterval = 1000.6

        for round in 0..<5 {
            // 用户先看到窗口停在 L（target 观察，几秒钟）。
            generation += 1
            var transition = WindowLiftAvoidance.reduce(
                state: state,
                event: .nonMaximizedObserved(generation: generation, at: settledAt + 1.0, frame: target)
            )
            XCTAssertEqual(transition.action, .none, "round \(round): target 观察不应清会话")

            // 用户点缩放 → 窗口回到 M（native），距上次写完超过 appReassertWindow。
            generation += 1
            let reMaximizedAt = settledAt + 2.0
            transition = WindowLiftAvoidance.reduce(
                state: transition.state,
                event: .nonMaximizedObserved(generation: generation, at: reMaximizedAt, frame: visibleFrame)
            )
            XCTAssertEqual(
                transition.action,
                .write(
                    targetFrame: target,
                    rollbackFrame: visibleFrame,
                    generation: generation,
                    isRelift: false
                ),
                "round \(round): 用户节奏落 M 必须开全新会话"
            )

            // 写完 → 回到 lifted，进入下一轮。
            settledAt = reMaximizedAt + 0.6
            transition = WindowLiftAvoidance.reduce(
                state: transition.state,
                event: .writeFinished(
                    generation: generation,
                    at: settledAt,
                    actualFrame: target,
                    reliftCount: 0
                )
            )
            guard case let .lifted(session) = transition.state else {
                return XCTFail("round \(round): expected lifted state")
            }
            XCTAssertEqual(session.reliftCount, 0)
            XCTAssertEqual(session.standoffRounds, 0)
            state = transition.state
        }
    }

    // MARK: - Rollback and pruning

    func testRollbackOnlyRestoresFrameStillOwnedByOurFailedWrite() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))

        XCTAssertEqual(
            WindowLiftAvoidance.rollbackDecision(
                originalFrame: visibleFrame,
                attemptedFrame: target,
                currentFrame: target
            ),
            .restore(visibleFrame)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rollbackDecision(
                originalFrame: visibleFrame,
                attemptedFrame: target,
                currentFrame: visibleFrame
            ),
            .notNeeded
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rollbackDecision(
                originalFrame: visibleFrame,
                attemptedFrame: target,
                currentFrame: CGRect(x: 200, y: 120, width: 900, height: 700)
            ),
            .preserveCurrent
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rollbackDecision(
                originalFrame: visibleFrame,
                attemptedFrame: target,
                currentFrame: nil
            ),
            .preserveCurrent
        )
    }

    func testDeadWindowPruningUsesPidAndWindowIDTogether() {
        let live = WindowLiftAvoidance.WindowKey(pid: 100, cgWindowID: 7)
        let dead = WindowLiftAvoidance.WindowKey(pid: 100, cgWindowID: 8)
        let reusedByOtherProcess = WindowLiftAvoidance.WindowKey(pid: 200, cgWindowID: 8)
        let states = [live: "live", dead: "dead"]

        XCTAssertEqual(
            WindowLiftAvoidance.deadWindowKeys(
                tracked: Set(states.keys),
                live: [live, reusedByOtherProcess]
            ),
            [dead]
        )
        XCTAssertEqual(
            WindowLiftAvoidance.prunedStates(
                states,
                liveWindowKeys: [live, reusedByOtherProcess]
            ),
            [live: "live"]
        )
    }

    func testOlderGlobalDeadSnapshotCannotOverrideNewerTrackedObservation() {
        let tracked = WindowLiftAvoidance.WindowKey(pid: 100, cgWindowID: 7)
        let watermarks: [WindowLiftAvoidance.WindowKey: UInt64] = [tracked: 5]

        XCTAssertEqual(
            WindowLiftAvoidance.prunableDeadWindowKeys(
                tracked: [tracked],
                live: [],
                observationGeneration: 4,
                observationWatermarks: watermarks
            ),
            []
        )
        XCTAssertEqual(
            WindowLiftAvoidance.prunableDeadWindowKeys(
                tracked: [tracked],
                live: [],
                observationGeneration: 6,
                observationWatermarks: watermarks
            ),
            [tracked]
        )
    }

    func testPollCadenceUsesSlowIdleAndPreservesFastTrackedIntervals() {
        XCTAssertEqual(
            WindowLiftAvoidance.PollCadence.interval(
                hasSessions: false,
                hasSuppressedFrames: false,
                isRestoring: false
            ),
            1.0,
            accuracy: 0.0001
        )

        for input in [(true, false, false), (false, true, false), (false, false, true)] {
            XCTAssertEqual(
                WindowLiftAvoidance.PollCadence.interval(
                    hasSessions: input.0,
                    hasSuppressedFrames: input.1,
                    isRestoring: input.2
                ),
                WindowLiftAvoidance.globalDetectionInterval,
                accuracy: 0.0001
            )
        }
    }

    func testEventPollCoalescerStartsLeadingAndOneTrailingPoll() {
        var coalescer = WindowLiftAvoidance.EventPollCoalescer()

        XCTAssertEqual(coalescer.request(at: 10, scanInFlight: false), .start)
        XCTAssertEqual(coalescer.request(at: 10.05, scanInFlight: true), .none)
        XCTAssertTrue(coalescer.pending)

        guard case let .schedule(delay) = coalescer.scanCompleted(at: 10.08) else {
            return XCTFail("an event during the active scan must schedule a trailing poll")
        }
        XCTAssertEqual(delay, 0.12, accuracy: 0.0001)
        XCTAssertEqual(coalescer.cooldownFired(at: 10.2, scanInFlight: false), .start)
        XCTAssertFalse(coalescer.pending)
    }

    func testEventPollCoalescerRetainsEventWhilePeriodicScanIsInFlight() {
        var coalescer = WindowLiftAvoidance.EventPollCoalescer()

        XCTAssertEqual(coalescer.request(at: 20, scanInFlight: true), .none)
        XCTAssertTrue(coalescer.pending)
        XCTAssertEqual(coalescer.scanCompleted(at: 20.05), .start)
        XCTAssertFalse(coalescer.pending)
    }

    func testEventPollCoalescerCollapsesCooldownBurstAndResetClearsIt() {
        var coalescer = WindowLiftAvoidance.EventPollCoalescer()

        XCTAssertEqual(coalescer.request(at: 30, scanInFlight: false), .start)
        guard case let .schedule(firstDelay) = coalescer.request(at: 30.04, scanInFlight: false) else {
            return XCTFail("cooldown event must schedule a trailing poll")
        }
        XCTAssertEqual(firstDelay, 0.16, accuracy: 0.0001)
        guard case let .schedule(secondDelay) = coalescer.request(at: 30.1, scanInFlight: false) else {
            return XCTFail("burst must remain coalesced behind the same cooldown")
        }
        XCTAssertEqual(secondDelay, 0.1, accuracy: 0.0001)

        coalescer.reset()
        XCTAssertFalse(coalescer.pending)
        XCTAssertNil(coalescer.lastStartedAt)
        XCTAssertEqual(coalescer.cooldownFired(at: 30.2, scanInFlight: false), .none)
    }

    /// 默认时间轴：t=1000 检测、t=1000.6 写完（settledAt）。抢顶判定以 settledAt 为基准。
    private func completedLift(
        generation: UInt64,
        target: CGRect,
        detectedAt: TimeInterval = 1000,
        settledAt: TimeInterval = 1000.6
    ) -> WindowLiftAvoidance.Transition {
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: generation,
                at: detectedAt,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        return WindowLiftAvoidance.reduce(
            state: writing.state,
            event: .writeFinished(
                generation: generation,
                at: settledAt,
                actualFrame: target,
                reliftCount: 0
            )
        )
    }

    // MARK: - 多屏归属（③④）

    func testOwningContextIndexPrefersMajorityThenLargestOverlap() {
        let left = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(
            WindowLiftAvoidance.owningContextIndex(for: CGRect(x: 100, y: 100, width: 1200, height: 800), screenCGFrames: [left, right]),
            0
        )
        XCTAssertEqual(
            WindowLiftAvoidance.owningContextIndex(for: CGRect(x: 1600, y: 0, width: 1800, height: 1000), screenCGFrames: [left, right]),
            1
        )
        // 跨屏、都不过半：重叠更大的那块。
        XCTAssertEqual(
            WindowLiftAvoidance.owningContextIndex(for: CGRect(x: 1000, y: 0, width: 1200, height: 900), screenCGFrames: [left, right]),
            1
        )
        XCTAssertNil(
            WindowLiftAvoidance.owningContextIndex(for: CGRect(x: 5000, y: 0, width: 100, height: 100), screenCGFrames: [left, right])
        )
        XCTAssertNil(WindowLiftAvoidance.owningContextIndex(for: .zero, screenCGFrames: [left]))
    }
}
