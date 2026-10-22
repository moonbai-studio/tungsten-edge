import CoreGraphics

/// Whether a press closes the open drawer. Pure; the drawer's event monitors feed it.
///
/// A plain left press on the bar does not close on the press: a chip drag into the drawer is not a
/// drag yet when the button goes down, so closing there lets the capsule's spring reopen it — a
/// flash. The press is remembered and closes on release only if it never left `tapSlop`.
enum DrawerClickAway {
    enum Verdict: Equatable {
        case ignore
        case closeNow
        /// A plain left press on the bar's visible area: decided on release through `Press`.
        case armBarPress
    }

    /// Must equal the bar chips' `DragGesture(minimumDistance: 8)`. Smaller, and a press that
    /// moved 4–8pt — still a click to the chip — would leave the drawer open; larger, and a drag
    /// that already started could close it on release.
    static let tapSlop: CGFloat = 8

    /// - Parameters:
    ///   - isSecondary: right button, or left button with Control (the bar's menu click).
    ///   - plate: the drawer's visible plate, never its window frame.
    ///   - barVisible: the bar window inset by its shadow padding.
    ///   - capsule: the capsule window. A plain left click there toggles the drawer on release;
    ///     closing it on the press would reopen it.
    static func verdict(at point: CGPoint, isSecondary: Bool,
                        plate: CGRect, barVisible: CGRect, capsule: CGRect) -> Verdict {
        if plate.contains(point) { return .ignore }
        if isSecondary { return .closeNow }
        if capsule.contains(point) { return .ignore }
        if barVisible.contains(point) { return .armBarPress }
        return .closeNow
    }

    static func stillTap(pressOrigin: CGPoint, point: CGPoint) -> Bool {
        hypot(point.x - pressOrigin.x, point.y - pressOrigin.y) < tapSlop
    }

    /// One left press on the bar. Leaving `tapSlop` once voids it, even if it is released back
    /// where it started.
    struct Press: Equatable {
        private(set) var origin: CGPoint?

        mutating func begin(at point: CGPoint) { origin = point }

        mutating func moved(to point: CGPoint) {
            guard let origin, !DrawerClickAway.stillTap(pressOrigin: origin, point: point) else { return }
            self.origin = nil
        }

        /// Whether this release ends a tap that began on the bar. Clears the press either way.
        mutating func released(at point: CGPoint) -> Bool {
            defer { origin = nil }
            guard let origin else { return false }
            return DrawerClickAway.stillTap(pressOrigin: origin, point: point)
        }

        mutating func cancel() { origin = nil }
    }
}
