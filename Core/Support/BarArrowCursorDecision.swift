enum BarArrowCursorDecision: String {
    case allow
    case panelHidden
    case differentWindow
    case outsideContent
    case resizeGrip
    case mouseButtonPressed
    case dragging
    case permissionSuspended
    case heightResizing

    static func evaluate(
        frontmostWindowNumber: Int,
        dockWindowNumber: Int?,
        panelVisible: Bool,
        pointInContent: Bool,
        pointInGrip: Bool,
        pressedMouseButtons: Int,
        hasDraggingPayload: Bool,
        isSuspendedForPermissionLoss: Bool,
        isHeightResizing: Bool
    ) -> Self {
        guard panelVisible else { return .panelHidden }
        guard let dockWindowNumber, dockWindowNumber > 0,
              frontmostWindowNumber == dockWindowNumber else { return .differentWindow }
        guard pointInContent else { return .outsideContent }
        guard !pointInGrip else { return .resizeGrip }
        guard pressedMouseButtons == 0 else { return .mouseButtonPressed }
        guard !hasDraggingPayload else { return .dragging }
        guard !isSuspendedForPermissionLoss else { return .permissionSuspended }
        guard !isHeightResizing else { return .heightResizing }
        return .allow
    }
}
