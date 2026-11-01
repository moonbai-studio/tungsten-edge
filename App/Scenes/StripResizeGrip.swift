import AppKit
import SwiftUI

// MARK: - Drag-to-resize grip on the taskbar

/// What the strip reports to `PanelCoordinator`. Points are **screen** coordinates (bottom-left
/// origin): the panel grows and re-centres on every tick, so window-local coordinates drift.
/// `.hover` comes from the strip's pointer tracker: the pointer is on a grip zone (`pointer`)
/// or not (`nil`); the coordinator draws the ▲▼ glyph from it.
enum StripResizeGripEvent {
    case pointerEnteredBar(hitTest: (CGPoint) -> (isInContent: Bool, isInGrip: Bool))
    case hover(CGPoint?)
    case began(pointer: CGPoint)
    case changed(pointer: CGPoint)
    case ended
}

/// Owned by `PanelCoordinator`, handed to the strip so the coordinator can end a drag from
/// outside the view tree (screen topology change, unit rebuild, permission suspension).
/// Relying on `dismantleNSView` alone leaves a pushed cursor and a live session behind when
/// the drag is interrupted while the view stays mounted.
final class StripResizeGripController {
    weak var view: StripResizeGripView?

    func cancel() {
        view?.finishDrag()
    }
}

/// Input only: the coordinator displays the native cursor artwork in a nonactivating panel
/// and owns the system pointer's hide/show lifetime. This view never activates the app.
/// Transparent overlay on the strip that claims a plain left mouse-down inside a grip zone
/// (the wide gap around a zone divider, or the bar's end insets when it has no divider —
/// kept clear of the chips by `StripContextMenuZone.gripClaims`; the same
/// `shouldClaim` also decides the ▲▼ hover) and turns the drag
/// into `StripResizeGripEvent`s. Everything else returns `nil` from `hitTest` and falls
/// through to the chips, the wheel interceptor and `MenuHostNSView`.
final class StripResizeGripView: NSView {
    var shouldClaim: ((CGPoint) -> Bool)?
    var onEvent: ((StripResizeGripEvent) -> Void)?
    weak var controller: StripResizeGripController?
    private var dragActive = false

    /// The panel is never key; without this the first drag while another app is frontmost
    /// is swallowed as an activation click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// `point` is in the superview's coordinate space, so the test goes through
    /// `super.hitTest` — never `bounds` (the bar sits inside 20pt of shadow padding).
    /// AppKit routes the following `mouseDragged` / `mouseUp` to the view that took the
    /// mouse-down, so only `.leftMouseDown` needs claiming.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil, let event = NSApp.currentEvent else { return nil }
        guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control) else { return nil }
        guard let shouldClaim, shouldClaim(NSEvent.mouseLocation) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard !dragActive else { return }
        dragActive = true
        onEvent?(.began(pointer: NSEvent.mouseLocation))
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragActive else { return }
        onEvent?(.changed(pointer: NSEvent.mouseLocation))
    }

    override func mouseUp(with event: NSEvent) {
        finishDrag()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finishDrag() }
    }

    /// The one exit for a drag (mouse-up, cancellation from the coordinator, view leaving the
    /// window). Idempotent. After ending, re-report hover from where the pointer is **now**: a
    /// mouse-up without motion produces no tracker tick, and the glyph must stay if the pointer
    /// is still on a grip zone, or go if the drag ended above the bar.
    func finishDrag() {
        guard dragActive else { return }
        dragActive = false
        onEvent?(.ended)
        let pointer = NSEvent.mouseLocation
        let insideBar = window.map {
            $0.isVisible && $0.convertToScreen(convert(bounds, to: nil)).contains(pointer)
        } ?? false
        onEvent?(.hover(insideBar && (shouldClaim?(pointer) ?? false) ? pointer : nil))
    }
}

struct StripResizeGripHost: NSViewRepresentable {
    let shouldClaim: (CGPoint) -> Bool
    let onEvent: (StripResizeGripEvent) -> Void
    let controller: StripResizeGripController?

    func makeNSView(context: Context) -> StripResizeGripView {
        let view = StripResizeGripView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: StripResizeGripView, context: Context) {
        apply(to: view)   // keep the closures capturing current SwiftUI state
    }

    static func dismantleNSView(_ view: StripResizeGripView, coordinator: ()) {
        view.finishDrag()
        if view.controller?.view === view { view.controller?.view = nil }
        view.onEvent = nil
    }

    private func apply(to view: StripResizeGripView) {
        view.shouldClaim = shouldClaim
        view.onEvent = onEvent
        view.controller = controller
        controller?.view = view
    }
}
