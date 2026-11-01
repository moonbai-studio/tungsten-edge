import SwiftUI

extension DockStripView {
    func trashChip(hovered: Bool) -> some View {
        TrashChip(isFull: trashStore.isFull,
                  isDropTargeted: externalDropTarget == .trash,
                  // While a volume is dragged over the bar the Trash offers to eject it, as on the native Dock.
                  showsEject: externalDropHoverActive && StripFileDropDelegate.DragPasteboardInspector.ejectsVolumes(),
                  scale: dockScale,
                  hoverStyle: hoverStyle,
                  isHovered: hovered,
                  menuItems: TrashMenuPlan.items(status: trashStore.status, isEmptying: trashStore.isEmptying),
                  onTap: { trashChipTapped() },
                  onOpen: { TrashStateStore.openTrashWindow(runtime: runtime, store: trashStore) },
                  onEmpty: { trashStore.emptyTrash() })
    }

    /// A click opens the Trash popup — Tungsten Edge's own panel, so no Finder window is opened,
    /// closed or minimized by the click. Same anchoring as the shelf, on `trashFrame`.
    func trashChipTapped() {
        guard trashFrame != .zero, stripRootScreenRect != .zero else { return }
        onTrashPopupToggle(stripFrameToScreen(trashFrame))
    }
}
