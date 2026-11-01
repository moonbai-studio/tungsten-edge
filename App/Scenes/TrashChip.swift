import AppKit
import SwiftUI

struct TrashChip: View {
    let isFull: Bool
    let isDropTargeted: Bool
    let showsEject: Bool
    let scale: CGFloat
    let hoverStyle: HoverStyle
    let isHovered: Bool
    let menuItems: [TrashMenuPlan.Item]
    let onTap: () -> Void
    let onOpen: () -> Void
    let onEmpty: () -> Void
    @State private var isPressed = false
    @Environment(\.displayScale) private var displayScale
    /// A height drag is a new icon size every tick: reuse the rendered bitmap until it ends.
    @Environment(\.isPanelHeightResizing) private var isPanelHeightResizing

    var body: some View {
        Image(nsImage: TrashIconArt.image(isFull: isFull, ejects: showsEject,
                                          points: ChipPillMetrics.bareIconSlot * scale,
                                          displayScale: displayScale, allowsRendering: !isPanelHeightResizing))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: ChipPillMetrics.bareIconSlot * scale, height: ChipPillMetrics.bareIconSlot * scale)
            .frame(width: ChipPillMetrics.cardWidth * scale, height: ChipPillMetrics.chipHeight * scale)
            .scaleEffect(isDropTargeted ? 1.08 : 1, anchor: .bottom)
            .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
            .chipQuietHoverScale(hoverStyle.showsQuietHoverFeedback(isHovering: isHovered),
                                 cardWidth: ChipPillMetrics.cardWidth * scale, scale: scale)
            .chipPressScale(isPressed)
            .contentShape(Rectangle())
            // Same order as LauncherChip: the tap sits inside the press gesture. Reversed, the
            // inner zero-distance drag outranks the outer tap and clicks stop opening the Trash.
            .onTapGesture(perform: onTap)
            .chipPressGesture(isPressed: $isPressed)
            .nativeContextMenu { buildMenu() }
            .help(String(localized: "Trash"))
            .accessibilityLabel(String(localized: "Trash"))
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in menuItems {
            switch item {
            case .open:
                menu.addItem(ClosureMenuItem(String(localized: "Open Trash"), handler: onOpen))
            case let .empty(enabled):
                let row = ClosureMenuItem(String(localized: "Empty Trash…"), handler: onEmpty)
                row.isEnabled = enabled
                menu.addItem(row)
            }
        }
        return menu
    }
}

/// The Trash icon is the light rendition in both appearances, as on the native Dock. The system
/// image carries a dark rendition that AppKit picks under `darkAqua` — and SwiftUI's `colorScheme`
/// environment does not override that choice — so the bitmap is always rendered under `aqua`.
/// Rendered at the exact pixel size (`IconBitmapRenderer`): a single-`CGImage` copy of the light
/// rendition is minified by the layer from 1024px in one bilinear step — that was the 锯齿.
enum TrashIconArt {
    @MainActor private static let bitmaps = IconBitmapCache()

    @MainActor
    static func image(isFull: Bool, ejects: Bool, points: CGFloat, displayScale: CGFloat,
                      allowsRendering: Bool) -> NSImage {
        if ejects {
            return bitmaps.image(name: "eject", points: points, displayScale: displayScale,
                                 appearance: NSAppearance(named: .aqua), allowsRendering: allowsRendering) {
                NSImage(contentsOfFile: ejectIconPath) ?? NSImage(named: NSImage.trashEmptyName) ?? NSImage()
            }
        }
        let name = isFull ? NSImage.trashFullName : NSImage.trashEmptyName
        return bitmaps.image(name: name, points: points, displayScale: displayScale,
                             appearance: NSAppearance(named: .aqua), allowsRendering: allowsRendering) {
            NSImage(named: name) ?? NSImage()
        }
    }

    /// The system's eject artwork — the icon the native Dock's Trash turns into under a dragged volume.
    private static let ejectIconPath = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/EjectMediaIcon.icns"
}
