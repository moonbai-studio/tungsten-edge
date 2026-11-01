import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Trash chip's popup: what is in the Trash, by name and type icon. No thumbnails — the Trash
/// is readable only with Full Disk Access, which the product never asks for; the listing comes from
/// Finder automation. Same panel, grid and cells as the folder and shelf popups.
struct TrashGridPopupView: View {
    @ObservedObject var trashStore: TrashStateStore
    let context: StackPopupContext
    let usesLiquidGlass: Bool
    var onClosePopup: () -> Void = {}
    var onContentResize: (CGSize) -> Void = { _ in }
    var onOpenInFinder: () -> Void = {}

    private var items: [TrashItem] {
        if case let .loaded(items, _) = trashStore.listing { return items }
        return []
    }
    /// Denied automation leaves only Open in Finder, as the chip menu does.
    private var canEmpty: Bool { trashStore.status != .denied }
    private var tailCellCount: Int { canEmpty ? 2 : 1 }

    private var layout: StackGridLayout.Result {
        StackGridLayout.resolve(cellCount: items.count + tailCellCount, limits: context.limits, hasNote: note != nil)
    }

    private var note: String? {
        switch trashStore.listing {
        case .idle, .loading:
            return String(localized: "Reading Trash…")
        case .unavailable:
            return String(localized: "Allow Finder automation to see what’s in the Trash")
        case let .loaded(items, hidden):
            if items.isEmpty { return String(localized: "Trash is empty") }
            return hidden > 0 ? String(localized: "Open in Finder to see the rest") : nil
        }
    }

    var body: some View {
        StackPopupChrome(title: String(localized: "Trash"),
                         note: note,
                         layout: layout,
                         plate: .stack,
                         usesLiquidGlass: usesLiquidGlass,
                         appearance: .followsAppearance,
                         arrow: context.arrow,
                         onPanelSizeChange: onContentResize,
                         gridAnimation: .easeInOut(duration: DrawerAnimation.duration),
                         gridAnimationKey: items.map(\.url.path)) {
            ForEach(items, id: \.url) { item in
                FolderGridCell(iconPath: nil,
                               staticIcon: TrashItemIcon.icon(for: item),
                               label: item.name,
                               contextMenu: { itemMenu(for: item) }) { reveal(item) }
            }
            FolderGridCell.openInFinder {
                onOpenInFinder()
            }
            if canEmpty {
                FolderGridCell(iconPath: nil, staticIcon: emptyIcon, label: String(localized: "Empty Trash…")) {
                    // The confirmation is modal; the popup's click-away monitor would close it anyway.
                    onClosePopup()
                    trashStore.emptyTrash()
                }
            }
        }
    }

    /// A click selects the item in the Trash window: Finder exposes no put-back command, so that
    /// window (⌘⌫ there) is the road to it.
    private func reveal(_ item: TrashItem) {
        onClosePopup()
        trashStore.revealItem(item.url)
    }

    /// Only actions that never touch the item: Finder performs moves and deletes of a Trash item on
    /// the sender's Full Disk Access (denied, with Finder's own error dialog blocking the reply), and
    /// opening a document there does nothing. Deleting or putting back happens in the Trash window.
    private func itemMenu(for item: TrashItem) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "Show in Finder")) { reveal(item) })
        menu.addItem(ClosureMenuItem(String(localized: "Copy Name")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.name, forType: .string)
        })
        return menu
    }

    @Environment(\.displayScale) private var displayScale
    /// The light rendition on purpose, whatever the app's appearance (`TrashIconArt`), at the cell's pixel size.
    private var emptyIcon: NSImage {
        TrashIconArt.image(isFull: true, ejects: false, points: StackPopupMetrics.iconSize, displayScale: displayScale, allowsRendering: true)
    }
}

/// Type icons by extension: the files themselves cannot be read without Full Disk Access.
enum TrashItemIcon {
    private static var cache: [String: NSImage] = [:]

    @MainActor
    static func icon(for item: TrashItem) -> NSImage {
        let ext = item.url.pathExtension.lowercased()
        let key = (item.isDirectory ? "d:" : "f:") + ext
        if let cached = cache[key] { return cached }
        let type: UTType
        if item.isDirectory {
            type = ext == "app" ? .applicationBundle : .folder
        } else {
            type = UTType(filenameExtension: ext) ?? .data
        }
        let icon = NSWorkspace.shared.icon(for: type)
        cache[key] = icon
        return icon
    }
}
