import AppKit
import XCTest

final class DockHeightDragSessionTests: XCTestCase {
    func testPointerUpMakesTheBarTaller() {
        let session = DockHeightDragSession(startHeight: 54, startPointerY: 100)
        XCTAssertEqual(session.height(forPointerY: 110).points, 64)
    }

    func testPointerDownMakesTheBarShorter() {
        let session = DockHeightDragSession(startHeight: 54, startPointerY: 100)
        XCTAssertEqual(session.height(forPointerY: 92).points, 46)
    }

    func testClampsAtBothEnds() {
        let session = DockHeightDragSession(startHeight: 54, startPointerY: 100)
        XCTAssertEqual(session.height(forPointerY: 400).points, DockPanelHeight.maximum)
        XCTAssertEqual(session.height(forPointerY: -400).points, DockPanelHeight.minimum)
    }

    func testSubPointTravelRoundsToWholePoints() {
        let session = DockHeightDragSession(startHeight: 54, startPointerY: 100)
        XCTAssertEqual(session.height(forPointerY: 100.4).points, 54)
        XCTAssertEqual(session.height(forPointerY: 100.5).points, 55)
        XCTAssertEqual(session.height(forPointerY: 99.5).points, 54, "round-half-to-even is not used: .rounded() is schoolbook")
    }

    func testPastTheClampThePointerMustComeBackBeforeTheBarShrinks() {
        // Stateless formula, like the native divider: 60pt past the cap, then 40pt back down —
        // still at the cap; only once the raw value is under the cap does the height move.
        let session = DockHeightDragSession(startHeight: 100, startPointerY: 100)
        XCTAssertEqual(session.height(forPointerY: 180).points, DockPanelHeight.maximum)
        XCTAssertEqual(session.height(forPointerY: 140).points, DockPanelHeight.maximum)
        XCTAssertEqual(session.height(forPointerY: 119).points, 119)
    }
}

@MainActor
final class ResizeCursorTests: XCTestCase {
    func testOtherScreenCannotRevealCursorAndHandoffKeepsOneHide() {
        var hides = 0
        var shows = 0
        let hider = SystemCursorHider(hideCursor: { hides += 1; return .success },
                                     showCursor: { shows += 1; return .success })
        XCTAssertTrue(hider.hide(owner: "screen-a"))
        hider.show(owner: "screen-b")
        XCTAssertTrue(hider.isHidden)
        XCTAssertEqual(shows, 0)

        XCTAssertTrue(hider.hide(owner: "screen-b"))
        hider.show(owner: "screen-a")
        XCTAssertTrue(hider.isHidden)
        XCTAssertEqual(hides, 1)
        XCTAssertEqual(shows, 0)

        hider.show(owner: "screen-b")
        hider.show(owner: "screen-b")
        hider.show()
        XCTAssertFalse(hider.isHidden)
        XCTAssertEqual(shows, 1)
    }

    func testFailedHideDoesNotClaimOwnershipOrShowReplacement() {
        var shows = 0
        let hider = SystemCursorHider(hideCursor: { .failure },
                                     showCursor: { shows += 1; return .success })
        XCTAssertFalse(hider.hide(owner: "screen-a"))
        XCTAssertFalse(hider.isHidden)
        hider.show()
        XCTAssertEqual(shows, 0)
    }

    func testTerminationCanReleaseCursorAndFailedShowCanRetry() {
        var shows = 0
        let hider = SystemCursorHider(hideCursor: { .success }, showCursor: {
            shows += 1
            return shows == 1 ? .failure : .success
        })
        XCTAssertTrue(hider.hide(owner: "screen-a"))
        hider.show(owner: "screen-a")
        XCTAssertTrue(hider.isHidden)
        hider.show()
        XCTAssertFalse(hider.isHidden)
        XCTAssertEqual(shows, 2)
    }

    func testNativeCursorReassertsAndOtherScreenCannotResetIt() {
        var sets = 0
        var arrows = 0
        let cursor = SystemResizeCursor(setResize: { sets += 1; return true },
                                        setArrow: { arrows += 1; return true },
                                        readBackMatches: { true })
        XCTAssertTrue(cursor.set(owner: "screen-a"))
        XCTAssertTrue(cursor.set(owner: "screen-a"))
        XCTAssertEqual(sets, 2, "every call re-asserts: menu tracking resets the cursor behind us")
        cursor.reset(owner: "screen-b")
        XCTAssertTrue(cursor.isActive)
        XCTAssertEqual(arrows, 0)
        cursor.reset(owner: "screen-a")
        cursor.reset(owner: "screen-a")
        cursor.reset()
        XCTAssertFalse(cursor.isActive)
        XCTAssertEqual(arrows, 1)
    }

    func testNativeCursorTurnsItselfOffWhenTheSetFailsOrReadsBackWrong() {
        for (setSucceeds, readBack) in [(false, true), (true, false)] {
            var sets = 0
            var arrows = 0
            let cursor = SystemResizeCursor(setResize: { sets += 1; return setSucceeds },
                                            setArrow: { arrows += 1; return true },
                                            readBackMatches: { readBack })
            XCTAssertTrue(cursor.isAvailable)
            XCTAssertFalse(cursor.set(owner: "screen-a"))
            XCTAssertFalse(cursor.isAvailable)
            XCTAssertFalse(cursor.isActive)
            XCTAssertEqual(arrows, 1, "a half-applied cursor is put back")
            XCTAssertFalse(cursor.set(owner: "screen-a"))
            XCTAssertEqual(sets, 1, "ruled out for the process, never retried")
        }
    }

    func testNativeCursorReadsBackOnlyOnce() {
        var reads = 0
        let cursor = SystemResizeCursor(setResize: { true }, setArrow: { true },
                                        readBackMatches: { reads += 1; return true })
        for _ in 0..<5 { XCTAssertTrue(cursor.set(owner: "screen-a")) }
        XCTAssertEqual(reads, 1)
    }

    func testIdleArrowSetsOnceWithoutOwnershipOrVerification() {
        var arrows = 0
        var reads = 0
        let cursor = SystemResizeCursor(setResize: { true },
                                        setArrow: { arrows += 1; return true },
                                        readBackMatches: { reads += 1; return true })
        cursor.assertArrowIfIdle()
        XCTAssertEqual(arrows, 1)
        XCTAssertEqual(reads, 0)
        XCTAssertFalse(cursor.isActive)
        cursor.reset()
        XCTAssertEqual(arrows, 1)
        XCTAssertTrue(cursor.set(owner: "screen-a"))
        XCTAssertEqual(reads, 1)
    }

    func testIdleArrowDoesNotReplaceAnOwnedResizeCursor() {
        var arrows = 0
        let cursor = SystemResizeCursor(setResize: { true },
                                        setArrow: { arrows += 1; return true },
                                        readBackMatches: { true })
        XCTAssertTrue(cursor.set(owner: "screen-a"))
        cursor.assertArrowIfIdle()
        XCTAssertEqual(arrows, 0)
        XCTAssertTrue(cursor.isActive)
        cursor.reset(owner: "screen-b")
        XCTAssertEqual(arrows, 0)
        cursor.reset(owner: "screen-a")
        XCTAssertEqual(arrows, 1)
    }

    func testIdleArrowDoesNothingWhenNativeChannelIsDisabled() {
        for (setSucceeds, readBack) in [(false, true), (true, false)] {
            var arrows = 0
            let cursor = SystemResizeCursor(setResize: { setSucceeds },
                                            setArrow: { arrows += 1; return true },
                                            readBackMatches: { readBack })
            XCTAssertFalse(cursor.set(owner: "screen-a"))
            XCTAssertFalse(cursor.isAvailable)
            let arrowsBefore = arrows
            cursor.assertArrowIfIdle()
            XCTAssertEqual(arrows, arrowsBefore)
            XCTAssertFalse(cursor.isActive)
        }
    }

    func testFailedIdleArrowLeavesResizeChannelAvailableAndUnverified() {
        var arrows = 0
        var sets = 0
        var reads = 0
        let cursor = SystemResizeCursor(setResize: { sets += 1; return true },
                                        setArrow: { arrows += 1; return false },
                                        readBackMatches: { reads += 1; return true })
        cursor.assertArrowIfIdle()
        XCTAssertEqual(arrows, 1)
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(cursor.isAvailable)
        XCTAssertFalse(cursor.isActive)
        XCTAssertTrue(cursor.set(owner: "screen-a"))
        XCTAssertEqual(sets, 1)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(cursor.isActive)
    }

    func testGlyphUsesUnscaledSystemFrameResizeArtworkAndHotspot() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("System frame cursor requires macOS 15") }
        _ = NSApplication.shared
        let native = NSCursor.frameResize(position: .top, directions: .all)
        XCTAssertEqual(ResizeCursorGlyph.size, native.image.size)
        XCTAssertEqual(ResizeCursorGlyph.hotSpot, native.hotSpot)
        XCTAssertEqual(try XCTUnwrap(ResizeCursorGlyph.image.tiffRepresentation),
                       try XCTUnwrap(native.image.tiffRepresentation))
    }
}

final class BarArrowCursorDecisionTests: XCTestCase {
    private func decision(
        frontmostWindowNumber: Int = 42,
        dockWindowNumber: Int? = 42,
        panelVisible: Bool = true,
        pointInContent: Bool = true,
        pointInGrip: Bool = false,
        pressedMouseButtons: Int = 0,
        hasDraggingPayload: Bool = false,
        isSuspendedForPermissionLoss: Bool = false,
        isHeightResizing: Bool = false
    ) -> BarArrowCursorDecision {
        BarArrowCursorDecision.evaluate(
            frontmostWindowNumber: frontmostWindowNumber,
            dockWindowNumber: dockWindowNumber,
            panelVisible: panelVisible,
            pointInContent: pointInContent,
            pointInGrip: pointInGrip,
            pressedMouseButtons: pressedMouseButtons,
            hasDraggingPayload: hasDraggingPayload,
            isSuspendedForPermissionLoss: isSuspendedForPermissionLoss,
            isHeightResizing: isHeightResizing
        )
    }

    func testAllowsOnlyWhenAllConditionsAreMet() {
        XCTAssertEqual(decision(), .allow)
    }

    func testRejectsHiddenPanel() {
        XCTAssertEqual(decision(panelVisible: false), .panelHidden)
    }

    func testRejectsPointerOutsideOrCoveredByAnotherWindow() {
        XCTAssertEqual(decision(frontmostWindowNumber: 0), .differentWindow)
        XCTAssertEqual(decision(frontmostWindowNumber: 99), .differentWindow)
        XCTAssertEqual(decision(dockWindowNumber: nil), .differentWindow)
        XCTAssertEqual(decision(frontmostWindowNumber: 0, dockWindowNumber: 0), .differentWindow)
    }

    func testRejectsShadowOutsideContent() {
        XCTAssertEqual(decision(pointInContent: false), .outsideContent)
    }

    func testRejectsResizeGrip() {
        XCTAssertEqual(decision(pointInGrip: true), .resizeGrip)
    }

    func testRejectsAnyPressedMouseButton() {
        for buttons in [1, 2, 4, 8, 3] {
            XCTAssertEqual(decision(pressedMouseButtons: buttons), .mouseButtonPressed)
        }
    }

    func testRejectsDraggingPayloadEvenWithoutPressedButton() {
        XCTAssertEqual(decision(hasDraggingPayload: true), .dragging)
    }

    func testRejectsPermissionSuspension() {
        XCTAssertEqual(decision(isSuspendedForPermissionLoss: true), .permissionSuspended)
    }

    func testRejectsHeightResize() {
        XCTAssertEqual(decision(isHeightResizing: true), .heightResizing)
    }

    func testBarArrowSwitchDefaultsOnAndCanBeDisabled() {
        XCTAssertEqual(DebugSwitch.barArrowCursor.kind, .killSwitch)
        XCTAssertTrue(DebugSwitch.barArrowCursor.isEnabled(in: [:]))
        XCTAssertFalse(DebugSwitch.barArrowCursor.isEnabled(in: [DebugSwitch.barArrowCursor.rawValue: "0"]))
    }
}
