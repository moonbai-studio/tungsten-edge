import AppKit
import SwiftUI

/// How a pinned folder's chip looks while its popup is open, as on the native Dock: fan and grid
/// swap the cover for the Dock's 「square + arrow」; the list keeps the cover and dims it.
enum FolderChipOpenStyle: Equatable {
    /// The popup is ordered in but not revealed yet: the chip still looks closed (and pressed).
    case opening
    case pileArrow
    case dimmedOnly
    /// A fan of a folder shown as a stack is closing: the slot stays empty, because the items
    /// flying back land as the pile itself.
    case landing
}

/// Which folder's popup is open on this unit and how its chip should look. One per
/// `PanelCoordinator` unit, so on mirrored bars only the screen that opened it changes. Written
/// and cleared by popup sessions only; a clear from a session that has already been replaced
/// leaves the newer value alone.
@MainActor
final class FolderPopupPresence: ObservableObject {
    struct State: Equatable {
        var path: String
        var style: FolderChipOpenStyle
        var sessionID: Int
    }

    @Published private(set) var state: State?
    /// The closing fan whose items are still on their way into the chip; separate from `state`,
    /// which the next popup takes over while this one is still landing.
    @Published private(set) var landing: State?

    func show(path: String, style: FolderChipOpenStyle, sessionID: Int) {
        state = State(path: path, style: style, sessionID: sessionID)
    }

    func clear(sessionID: Int) {
        guard state?.sessionID == sessionID else { return }
        state = nil
    }

    func beginLanding(path: String, sessionID: Int) {
        landing = State(path: path, style: .landing, sessionID: sessionID)
    }

    func endLanding(sessionID: Int) {
        guard landing?.sessionID == sessionID else { return }
        landing = nil
    }

    /// Open beats landing: a folder reopened mid-landing shows its open look.
    func style(for path: String) -> FolderChipOpenStyle? {
        if state?.path == path { return state?.style }
        return landing?.path == path ? .landing : nil
    }

    func isOpen(_ path: String) -> Bool { state?.path == path }
}

/// Pinned folder chip: the cover alone, at app-icon size in an icon-card slot, like a native
/// Dock stack. The name lives in the hover bubble (`DockStripView.bubbleTitle`) and in `.help`.
///
/// No name row under the cover: it shrank the cover to ~22pt against the neighbours' 32.5pt,
/// widened the card, and its black text with a white halo turned into a smudge on dark glass.
/// 点击一律 onTapGesture（nonactivatingPanel 上勿用 Button）；右键 = 手搓 NSMenu。
struct PinnedFolderChip: View {
    let path: String
    let cover: FolderCover?
    /// The folder's own icon, held by `PinnedFolderCoverStore.folderIcon`; a fresh image on every
    /// redraw makes the chip crossfade during a reorder.
    let folderIcon: NSImage
    /// 当前排序方式（菜单打勾用;menu builder 每次右键现建,读到的总是最新值）。
    let sortOrder: FolderSortOrder
    /// "Display as": folder = the folder's own icon only; stack = a pile of its first items.
    let displayMode: FolderDisplayMode
    /// "View content as": how the popup shows the folder (fan / grid / list / automatic).
    let viewMode: FolderViewMode
    let onTap: () -> Void
    /// 内容预览（右键「预览内容」；左键在 preview 模式下也走这个）。
    let onPreview: () -> Void
    /// 打开该路径访达窗口（右键「在访达中打开」；左键在 openFinderWindow 模式下也走这个）。
    let onOpenInFinder: () -> Void
    let onAddFolder: () -> Void
    let onRemove: () -> Void
    let onSetSortOrder: (FolderSortOrder) -> Void
    let onSetDisplayMode: (FolderDisplayMode) -> Void
    let onSetViewMode: (FolderViewMode) -> Void
    var isDropTarget = false
    /// The look while this folder's popup is open; nil = closed. No default: the drag carrier is
    /// drawn through the same call and must show what the chip shows.
    let openStyle: FolderChipOpenStyle?
    /// 任务条尺寸档位的缩放系数。中档 = 1.0，此时所有尺寸与历史字面值逐像素相同。
    /// **故意不给默认值**——漏传必须是编译错误，见 AGENTS《Taskbar Size Tiers》。
    let scale: CGFloat
    /// 悬停效果档位。**同样故意不给默认值**——漏传必须是编译错误，理由同 `scale`。
    let hoverStyle: HoverStyle
    /// 指针在不在这张卡上。由任务条整条那块跟踪区算好后传进来（见 `StripHoverResolution`）；
    /// 拖动载体传 `false`。**故意不给默认值**，理由同 `scale` / `hoverStyle`。
    let isHovered: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }
    /// Mouse down on the chip: the native tile darkens at once and stays dark until the popup's
    /// first frame swaps it — `.opening` carries the dimming from the click to the reveal.
    @State private var isPressed = false
    /// The popup took over during this press: the open look replaces the dimming at once.
    @State private var pressSawPopup = false

    private var showsPressed: Bool {
        (isPressed && !pressSawPopup) || openStyle == .opening
    }

    /// Hover behaves exactly like an app icon card: the standard tier changes no pixels (the
    /// name bubble is the feedback), the quiet tier gets the shared 1.10 bottom-anchored lift.
    /// `DockStripView.pickUpPose` reads the same rule for the drag carrier's first frame.
    private var quietHoverFeedback: Bool {
        hoverStyle.showsQuietHoverFeedback(isHovering: isHovered)
    }

    private var folderName: String {
        FileManager.default.displayName(atPath: path)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            coverSlot
            Spacer(minLength: 0)
        }
        .frame(width: ChipPillMetrics.cardWidth * scale,
               height: ChipPillMetrics.chipHeight * scale)
        .chipQuietHoverScale(quietHoverFeedback,
                             cardWidth: ChipPillMetrics.cardWidth * scale,
                             scale: scale)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        // After the tap, as on the other chips: attached before it, it takes the click.
        .chipPressGesture(isPressed: $isPressed)
        .nativeContextMenu { buildMenu() }
        .help(folderName)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .onChange(of: isPressed) { pressed in
            if pressed { pressSawPopup = false }
        }
        .onChange(of: openStyle) { style in
            if style != .opening, isPressed { pressSawPopup = true }
        }
    }

    /// The icon-card slot (40pt) with the cover and the drop-target ring, lifted as one piece.
    private var coverSlot: some View {
        let slot = ChipPillMetrics.bareIconSlot * scale
        let visible = ChipPillMetrics.bareIconVisibleSlot * scale
        // Folder mode, an empty folder and a cover not loaded yet all show the folder's own icon.
        let layers = displayMode == .folder ? [] : (cover?.layers ?? [])
        return ZStack {
            if openStyle == .landing {
                Color.clear
            } else if openStyle == .pileArrow, let pile = NativeStackArtwork.pileArrow(dark: colorScheme == .dark) {
                // Open as fan or grid: the Dock's square + arrow, swapped in on the same frame.
                Image(nsImage: pile)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: slot, height: slot)
            } else if layers.isEmpty {
                // The folder's own icon fills the slot like an app icon, as on the native Dock;
                // the stack's front-layer geometry would draw it a size smaller and lower than
                // its neighbours.
                Image(nsImage: folderIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: slot, height: slot)
            } else {
                // Back to front: the first item of the sort is drawn last, on top.
                ForEach(Array(layers.prefix(FolderCoverPile.depths.count).enumerated()).reversed(), id: \.offset) { index, layer in
                    layerImage(layer, canvas: slot * FolderCoverPile.depths[index].canvas)
                        .offset(y: slot * FolderCoverPile.depths[index].centerY)
                }
            }
        }
        .frame(width: slot, height: slot)
        // The list leaves the cover and dims it; fan and grid show the square + arrow undimmed
        // (native reads it at the art's own brightness).
        .colorMultiply(openStyle == .dimmedOnly || showsPressed ? Color(white: Self.openDimming) : .white)
        .overlay {
            RoundedRectangle(cornerRadius: visible * Self.visibleCornerFraction, style: .continuous)
                .strokeBorder(theme.folderDropRing.color(active: isDropTarget), lineWidth: 1.5)
                .frame(width: visible, height: visible)
        }
        .scaleEffect(isDropTarget ? 1.08 : 1)
    }

    /// The native list's dimmed tile and the pressed tile, read off the screen: ×0.476–0.48 on
    /// every channel (the Dock's code multiplies by 0.4, but that is not what reaches the screen).
    private static let openDimming: CGFloat = 0.476

    /// Same squircle fraction as the self-drawn shelf tile (drop-target ring only).
    private static let visibleCornerFraction: CGFloat = 0.215

    /// The pile's layer geometry is `FolderCoverPile` (shared with the fan's flight).
    private enum StackLayout {
        /// A thumbnail has no transparent margin of its own, so it fits a smaller box than an icon.
        static let thumbnailFraction: CGFloat = 0.87
        static let thumbnailCornerFraction: CGFloat = 0.05
    }

    /// One item of the pile. Icons carry their own margin and fit the canvas; a thumbnail keeps
    /// its own aspect ratio (never cropped square), with a hairline so a white page reads on glass.
    @ViewBuilder
    private func layerImage(_ layer: FolderCover.Layer, canvas: CGFloat) -> some View {
        if layer.isThumbnail {
            let box = canvas * StackLayout.thumbnailFraction
            let corner = canvas * StackLayout.thumbnailCornerFraction
            Image(nsImage: layer.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(theme.folderThumbHairline.color, lineWidth: 0.5)
                )
                .frame(width: box, height: box)
        } else {
            Image(nsImage: layer.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: canvas, height: canvas)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "Preview Contents")) { onPreview() })
        menu.addItem(ClosureMenuItem(String(localized: "Open in Finder")) { onOpenInFinder() })
        menu.addItem(.separator())
        // Flat titled groups, as on the native stack menu. Sort drives both the popup grid and
        // the cover; both settings are remembered per folder.
        menu.addItem(Self.sectionHeader(String(localized: "Sort by")))
        for order in FolderSortOrder.allCases {
            let item = ClosureMenuItem(order.menuTitle) { onSetSortOrder(order) }
            item.state = order == sortOrder ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(Self.sectionHeader(String(localized: "Display as")))
        for mode in FolderDisplayMode.allCases {
            let item = ClosureMenuItem(mode.menuTitle) { onSetDisplayMode(mode) }
            item.state = mode == displayMode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(Self.sectionHeader(String(localized: "View content as")))
        for mode in FolderViewMode.allCases {
            let item = ClosureMenuItem(mode.menuTitle) { onSetViewMode(mode) }
            item.state = mode == viewMode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Add Folder…")) { onAddFolder() })
        menu.addItem(ClosureMenuItem(String(localized: "Remove from Taskbar")) { onRemove() })
        return menu
    }

    /// The system's own group title (small, bold, grey — the native Dock menu's look) on macOS 14+;
    /// below that, the greyed non-clickable item `AppMenuFragments` already uses.
    static func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        return header
    }
}
