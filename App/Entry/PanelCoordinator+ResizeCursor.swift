import AppKit
import SwiftUI

// PanelCoordinator · the ▲▼ cursor for drag-to-resize.
//
// Primary path: `SystemResizeCursor` sets the real system cursor, so the ▲▼ is the pointer
// itself — no follow lag, nothing to hide. Fallback, only when that private path is unavailable:
// hide the system cursor (`SystemCursorHider`) and float a tiny glyph panel under the pointer
// (`Docs/05` §「后台应用改不了系统光标」). Kill switch `DOCK_RESIZE_CURSOR=0`; every exit path
// (hover leave, drag end, teardown, app termination) restores the arrow / re-shows the pointer.

extension PanelCoordinator {
    static let resizeCursorEnabled = DebugSwitch.resizeCursor.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let barArrowCursorEnabled = DebugSwitch.barArrowCursor.isEnabled(in: ProcessInfo.processInfo.environment)

    func assertBarArrowCursor(hitTest: (CGPoint) -> (isInContent: Bool, isInGrip: Bool)) {
        guard Self.resizeCursorEnabled, Self.barArrowCursorEnabled else {
            HoverTrace.barArrowCursor(surface: stripSurfaceID,
                                      decision: Self.resizeCursorEnabled ? "barArrowDisabled" : "resizeCursorDisabled")
            return
        }
        // An enter callback can arrive after the pointer has left; test the current point synchronously.
        let pointer = NSEvent.mouseLocation
        let frontmostWindow = NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0)
        let hit = hitTest(pointer)
        let decision = BarArrowCursorDecision.evaluate(
            frontmostWindowNumber: frontmostWindow,
            dockWindowNumber: dockPanel?.windowNumber,
            panelVisible: dockPanel?.isVisible == true,
            pointInContent: hit.isInContent,
            pointInGrip: hit.isInGrip,
            pressedMouseButtons: NSEvent.pressedMouseButtons,
            hasDraggingPayload: dragController.draggingPayload != nil,
            isSuspendedForPermissionLoss: isSuspendedForPermissionLoss,
            isHeightResizing: interactiveHeightResizeActive
        )
        HoverTrace.barArrowCursor(surface: stripSurfaceID, decision: decision.rawValue)
        guard decision == .allow else { return }
        SystemResizeCursor.shared.assertArrowIfIdle()
    }

    /// How long after a menu opens or closes the ▲▼ keeps being re-asserted: menu tracking
    /// resets a background app's cursor to the arrow at both ends, the closing one anywhere
    /// from 2ms to never after `didEndTracking`.
    private static let resizeCursorReassertWindow: TimeInterval = 0.4

    /// Pointer (AppKit screen coordinates) is on a grip zone, or a drag is in progress. Called
    /// on every hover report and drag tick, which is also what re-asserts the system cursor.
    func showResizeCursor(at pointer: CGPoint) {
        guard Self.resizeCursorEnabled, !isSuspendedForPermissionLoss else { return }
        if SystemResizeCursor.shared.set(owner: stripSurfaceID) { return }
        showResizeCursorGlyph(at: pointer)
    }

    private func showResizeCursorGlyph(at pointer: CGPoint) {
        let panel: NSPanel
        if let existing = resizeCursorPanel {
            panel = existing
        } else {
            let created = makeFloatingPanel(contentRect: NSRect(origin: .zero, size: ResizeCursorGlyph.size),
                                            usesLiquidGlass: false)
            configurePanel(created, backgroundColor: .clear, appliesLevelOverride: false)
            created.ignoresMouseEvents = true
            // Above the bar and the drag carriers, like the carriers themselves.
            created.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            let hosting = NSHostingView(rootView: ResizeCursorGlyph())
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            resizeCursorHost = ManualPanelHost(contentView: hosting, in: created)
            resizeCursorPanel = created
            panel = created
        }
        let size = ResizeCursorGlyph.size
        let hotSpot = ResizeCursorGlyph.hotSpot
        panel.setFrame(NSRect(x: pointer.x - hotSpot.x, y: pointer.y - (size.height - hotSpot.y),
                              width: size.width, height: size.height), display: true)
        guard SystemCursorHider.shared.hide(owner: stripSurfaceID) else {
            panel.orderOut(nil)
            return
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            pinOverlappingPanelIfNeeded(panel)
        }
    }

    /// Pointer left the grip zones with no drag in progress, or the drag ended off the bar.
    func hideResizeCursor() {
        SystemResizeCursor.shared.reset(owner: stripSurfaceID)
        resizeCursorPanel?.orderOut(nil)
        SystemCursorHider.shared.show(owner: stripSurfaceID)
    }

    /// The ▲▼ stays up while a Tungsten menu is open — but only as the real system cursor. The
    /// fallback glyph cannot: menu tracking un-hides the arrow, and the two read as two cursors.
    private var resizeCursorSuppressedByMenu: Bool {
        isTaskbarMenuOpen && !SystemResizeCursor.shared.isAvailable
    }

    /// Right before the taskbar menu pops up. Fallback glyph only: release the pointer ahead of
    /// `didBeginTracking`, or the glyph and the arrow menu tracking shows overlap for a moment.
    func prepareResizeCursorForMenu() {
        guard !SystemResizeCursor.shared.isAvailable else { return }
        hideResizeCursor()
    }

    /// Strip hover report: `pointer` while on a grip zone, `nil` otherwise. Ignored during a
    /// drag — the pointer runs above the bar then and the drag path keeps the cursor itself.
    /// The strip's poll keeps reporting during menu tracking, so moving off the zone towards a
    /// menu item restores the arrow.
    func gripHoverChanged(_ pointer: CGPoint?) {
        gripHoverPointer = pointer
        guard !interactiveHeightResizeActive, !resizeCursorSuppressedByMenu else { return }
        if let pointer, !isPointInsideOpenMenu(pointer) {
            showResizeCursor(at: pointer)
        } else {
            hideResizeCursor()
        }
    }

    /// A Tungsten menu opened (status item or taskbar right-click, on any unit) or closed. The
    /// poll reports only on motion, so a parked pointer needs the ▲▼ put back here: menu
    /// tracking resets the cursor at both ends (see `resizeCursorReassertWindow`).
    func resizeCursorMenuVisibilityChanged(_ open: Bool) {
        resizeCursorReassertTimer?.invalidate()
        resizeCursorReassertTimer = nil
        if open, resizeCursorSuppressedByMenu {
            hideResizeCursor()
            return
        }
        guard gripHoverPointer != nil else { return }
        let deadline = CACurrentMediaTime() + Self.resizeCursorReassertWindow
        // 120Hz keeps a reset arrow under one display frame.
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, CACurrentMediaTime() < deadline else {
                    timer.invalidate()
                    return
                }
                self.reassertResizeCursor()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeCursorReassertTimer = timer
        reassertResizeCursor()
    }

    private func reassertResizeCursor() {
        guard !interactiveHeightResizeActive, !resizeCursorSuppressedByMenu,
              let pointer = gripHoverPointer, !isPointInsideOpenMenu(pointer) else { return }
        showResizeCursor(at: pointer)
    }

    /// The right-click menu opens with its corner on the pointer, so part of the grip zone sits
    /// under it; menu items get the arrow.
    private func isPointInsideOpenMenu(_ point: CGPoint) -> Bool {
        guard isTaskbarMenuOpen else { return false }
        return NSApp.windows.contains {
            $0.isVisible && $0.level >= .popUpMenu && $0.frame.contains(point)
        }
    }

    func tearDownResizeCursor() {
        resizeCursorReassertTimer?.invalidate()
        resizeCursorReassertTimer = nil
        gripHoverPointer = nil
        hideResizeCursor()
        resizeCursorHost = nil
        if let panel = resizeCursorPanel {
            panel.contentView = NSView()
            panel.close()
        }
        resizeCursorPanel = nil
    }
}
