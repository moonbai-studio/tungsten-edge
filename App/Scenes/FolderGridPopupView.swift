import AppKit
import QuickLookThumbnailing
import SwiftUI

/// 固定文件夹弹窗的数据层：后台枚举 + 目录监视实时刷新。
/// generation 防串线（评审 P1）：下钻/刷新连发时，旧结果回来一律丢弃。
@MainActor
final class FolderPopupModel: ObservableObject {
    @Published private(set) var entries: [FolderContentsLoader.Entry] = []
    @Published private(set) var loadFailed = false
    @Published private(set) var didFirstLoad = false

    private var watcher: DirectoryWatcher?
    private var generation = 0
    /// 该文件夹的排序方式（开窗时定死；改排序走协调器原地切换重开,不在窗内热切）。
    var sortOrder: FolderSortOrder = .default

    /// 预载路径：开窗前协调器已在后台读好内容，首帧即完整网格（散装感根因修复）。
    func seed(entries: [FolderContentsLoader.Entry]) {
        self.entries = entries
        didFirstLoad = true
    }

    func display(url: URL) {
        watcher?.stop()
        watcher = DirectoryWatcher(path: url.path) { [weak self] in
            Task { @MainActor [weak self] in self?.reload(url: url) }
        }
        reload(url: url)
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// 目录读取走自己的串行队列而不是 `Task.detached`：点开弹窗是用户动作，扔进 Swift 协作线程池
    /// 会排在 `AppTracker` 后台 AX 批读（N×100ms 串行）后面（`AGENTS.md` 铁律）。
    private static let reloadQueue = DispatchQueue(label: "com.caye.macosdockcc.v2.folder-popup-reload",
                                                   qos: .userInitiated)

    private func reload(url: URL) {
        generation += 1
        let expected = generation
        Self.reloadQueue.async { [weak self] in
            let result = Result { try FolderContentsLoader.load(directory: url) }
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                switch result {
                case .success(let list):
                    // 内容没变就不发布——预载后 watcher 挂载时的首次 reload 多为同内容,
                    // 不触发任何刷新/动画（入场期间内容零变化是验收标准）。
                    let sorted = FolderContentsLoader.sorted(list, by: self.sortOrder)
                    if sorted != self.entries { self.entries = sorted }
                    if self.loadFailed { self.loadFailed = false }
                case .failure:
                    if !self.entries.isEmpty { self.entries = [] }
                    if !self.loadFailed { self.loadFailed = true }
                }
                if !self.didFirstLoad { self.didFirstLoad = true }
            }
        }
    }
}

/// Icons for the popup's cells, cached apart from the views (same shape as `AppIconResolver`).
/// Two levels: the type icon (`NSWorkspace`, cheap, warmed before the popup shows so the first
/// frame is whole) and the content thumbnail (QuickLook, async, shown the moment it arrives —
/// never faded in cell by cell, which read as "the popup appears from the top-left").
enum FolderIconResolver {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 512
        return c
    }()
    private static let thumbnails: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()
    /// Set by `StackPopupSnapshotProbe` to hear why a thumbnail did not come back.
    static var onThumbnailFailure: ((String) -> Void)?

    static func cached(_ path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    static func discard(paths: [String]) {
        for path in paths { cache.removeObject(forKey: path as NSString) }
    }

    static func resolve(_ path: String, size: CGFloat = StackPopupMetrics.iconSize) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let img = makeIcon(path, size: size)
        cache.setObject(img, forKey: path as NSString)
        return img
    }

    /// Warms the first screenful of type icons before the popup shows, blocking at most `timeout`
    /// (a cold-path trade for a whole first frame; warm path ≈ 0ms). Anything it misses is filled
    /// by the cell's own `.task`.
    static func warm(paths: [String], timeout: TimeInterval) {
        let pending = paths.filter { cache.object(forKey: $0 as NSString) == nil }
        guard !pending.isEmpty else { return }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            for path in pending {
                cache.setObject(makeIcon(path), forKey: path as NSString)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// A shared cached image must be copied before its size is changed.
    private static func makeIcon(_ path: String, size: CGFloat = StackPopupMetrics.iconSize) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        guard let copy = icon.copy() as? NSImage else { return icon }
        copy.size = NSSize(width: size, height: size)
        return copy
    }

    // MARK: Content thumbnails

    /// One rendering of one version of one file: the modification date gives an edited file a
    /// fresh preview, the scale keeps a 1× screen's bitmap off a 2× screen.
    struct ThumbnailID: Hashable {
        var path: String
        var stamp: Date?
        var scale: CGFloat
        /// Points: the grid's 100pt cells and the fan's 64pt items never share a bitmap.
        var side: CGFloat = StackPopupMetrics.iconSize

        fileprivate var cacheKey: NSString {
            "\(path)|\(stamp?.timeIntervalSinceReferenceDate ?? 0)|\(scale)|\(side)" as NSString
        }
    }

    static func cachedThumbnail(_ id: ThumbnailID) -> NSImage? {
        thumbnails.object(forKey: id.cacheKey)
    }

    /// Generates the thumbnail the native Dock shows — QuickLook's icon mode at the cell's icon
    /// size — into the cache; read it back with `cachedThumbnail`. Runs on QuickLook's own queue,
    /// not the Swift cooperative pool (`AGENTS.md`: a click must not queue behind inventory reads).
    static func loadThumbnail(_ id: ThumbnailID) async {
        let key = id.cacheKey
        guard thumbnails.object(forKey: key) == nil else { return }
        let side = id.side
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: id.path),
                                                   size: CGSize(width: side, height: side),
                                                   scale: max(1, id.scale),
                                                   representationTypes: .thumbnail)
        request.iconMode = true
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            // A failure is not remembered: QuickLook also fails transiently, and a remembered miss
            // would pin the type icon for the life of the process.
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let representation {
                    thumbnails.setObject(NSImage(cgImage: representation.cgImage, size: NSSize(width: side, height: side)),
                                         forKey: key)
                } else {
                    onThumbnailFailure?("\(id.path): \(error.map { String(describing: $0) } ?? "no representation")")
                }
                done.resume()
            }
        }
    }
}

/// The pinned-folder popup, laid out as the native Dock's stack grid (`StackPopupChrome`): the
/// folder's name on top, cells, 「Open in Finder」 as the tail cell, a back button once drilled in.
/// Sort follows the folder's own setting, the same one its chip cover uses.
struct FolderGridPopupView: View {
    let rootURL: URL
    let context: StackPopupContext
    /// Explicit, no default: every panel is its own hosting root (`AGENTS.md` no-default rule).
    let usesLiquidGlass: Bool
    /// Called after a file is opened (the coordinator closes the popup); the context menu's
    /// "open" actions use it too.
    var onFileOpened: () -> Void = {}
    /// The content's size changed (drill-in, live refresh): the coordinator re-anchors the panel
    /// at the window size given.
    var onContentResize: (CGSize) -> Void = { _ in }
    /// 「Pin」 on a directory cell's menu. nil = not offered.
    var onPinFolder: ((URL) -> Void)?
    var isFolderPinned: ((URL) -> Bool)?

    @StateObject private var model: FolderPopupModel
    /// Empty = the root folder.
    @State private var drillStack: [URL] = []
    /// Off until the first content is in: the first population appears whole, never cell by cell.
    @State private var animatesGridChanges = false

    init(rootURL: URL,
         initialEntries: [FolderContentsLoader.Entry]?,
         sortOrder: FolderSortOrder = .default,
         context: StackPopupContext,
         usesLiquidGlass: Bool,
         onFileOpened: @escaping () -> Void = {},
         onContentResize: @escaping (CGSize) -> Void = { _ in },
         onPinFolder: ((URL) -> Void)? = nil,
         isFolderPinned: ((URL) -> Bool)? = nil) {
        self.rootURL = rootURL
        self.context = context
        self.usesLiquidGlass = usesLiquidGlass
        self.onFileOpened = onFileOpened
        self.onContentResize = onContentResize
        self.onPinFolder = onPinFolder
        self.isFolderPinned = isFolderPinned
        _model = StateObject(wrappedValue: {
            let model = FolderPopupModel()
            model.sortOrder = sortOrder
            if let initialEntries { model.seed(entries: initialEntries) }
            return model
        }())
    }

    private var currentURL: URL { drillStack.last ?? rootURL }

    /// Entries plus the 「Open in Finder」 tail cell.
    private var layout: StackGridLayout.Result {
        StackGridLayout.resolve(cellCount: model.entries.count + 1, limits: context.limits, hasNote: note != nil)
    }
    private var note: String? {
        model.loadFailed ? String(localized: "Can’t read this folder") : nil
    }

    var body: some View {
        StackPopupChrome(title: FileManager.default.displayName(atPath: currentURL.path),
                         note: note,
                         layout: layout,
                         plate: .stack,
                         usesLiquidGlass: usesLiquidGlass,
                         appearance: .followsAppearance,
                         arrow: context.arrow,
                         onPanelSizeChange: onContentResize,
                         onBack: drillStack.isEmpty ? nil : { _ = drillStack.removeLast() },
                         gridAnimation: animatesGridChanges ? .easeInOut(duration: DrawerAnimation.duration) : nil,
                         gridAnimationKey: model.entries.map(\.url.path)) {
            ForEach(model.entries, id: \.url) { entry in
                FolderGridCell(iconPath: entry.url.path,
                               staticIcon: nil,
                               label: entry.name,
                               preview: entry.isDirectory ? nil : .init(stamp: entry.dateModified),
                               dragURL: entry.url,
                               contextMenu: { cellMenu(for: entry) }) { open(entry) }
            }
            FolderGridCell.openInFinder {
                NSWorkspace.shared.open(currentURL)
                onFileOpened()
            }
        }
        // The panel as a whole fades in and out in AppKit (`panel.alphaValue`); the content adds
        // no scale or opacity of its own.
        .onAppear {
            model.display(url: rootURL)
            if model.didFirstLoad { animatesGridChanges = true }
        }
        .onDisappear { model.stop() }
        .onChange(of: model.didFirstLoad) { loaded in
            guard loaded else { return }
            // Timeout path: the first fill lands unanimated; animation opens one turn later.
            DispatchQueue.main.async { animatesGridChanges = true }
        }
        .onChange(of: drillStack) { _ in model.display(url: currentURL) }
    }

    private func open(_ entry: FolderContentsLoader.Entry) {
        if entry.isDirectory {
            drillStack.append(entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
            onFileOpened()
        }
    }

    /// Hand-built `NSMenu` (rule file). 「Pin」 only for a directory that is not pinned yet.
    private func cellMenu(for entry: FolderContentsLoader.Entry) -> NSMenu {
        let canPin = entry.isDirectory && !(isFolderPinned?(entry.url) ?? true)
        return FileItemMenuBuilder.menu(for: .init(
            url: entry.url,
            isDirectory: entry.isDirectory,
            closePopup: onFileOpened,
            pinFolder: canPin ? { onPinFolder?(entry.url) } : nil
        ))
    }
}

/// One cell of the stack grid, to the native measurements in `StackPopupMetrics`: a 100pt icon
/// and one line of name. No hover highlight — the native grid has none. Shared by the folder,
/// shelf and Trash popups.
/// `dragURL` non-nil attaches the system file drag (dragging a real file out to another app).
struct FolderGridCell: View {
    /// Asks for a QuickLook content thumbnail on top of the type icon.
    struct Preview: Equatable {
        /// The file's modification date: a changed file gets a new thumbnail.
        var stamp: Date?
    }

    let iconPath: String?
    let staticIcon: NSImage?
    /// `staticIcon` is a template glyph drawn the way the native grid draws 「Open in Finder」:
    /// added to the plate (plus-lighter), so it takes the backdrop's hue.
    let staticIconIsGlyph: Bool
    let label: String
    let preview: Preview?
    var dragURL: URL? = nil
    var contextMenu: (() -> NSMenu)? = nil
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }
    private typealias Metrics = StackPopupMetrics

    @Environment(\.displayScale) private var displayScale
    @State private var resolvedIcon: NSImage?
    @State private var thumbnail: NSImage?

    init(iconPath: String?,
         staticIcon: NSImage?,
         staticIconIsGlyph: Bool = false,
         label: String,
         preview: Preview? = nil,
         dragURL: URL? = nil,
         contextMenu: (() -> NSMenu)? = nil,
         onTap: @escaping () -> Void) {
        self.iconPath = iconPath
        self.staticIcon = staticIcon
        self.staticIconIsGlyph = staticIconIsGlyph
        self.label = label
        self.preview = preview
        self.dragURL = dragURL
        self.contextMenu = contextMenu
        self.onTap = onTap
        // Read both caches synchronously: the coordinator warmed the type icons before showing
        // the popup, so the first frame already has them. Without this every icon arrives async
        // and they surface one by one from the top-left.
        _resolvedIcon = State(initialValue: iconPath.flatMap { FolderIconResolver.cached($0) })
        // The scale is not known before the view is in a window; the main screen's is the one
        // the popup almost always opens on. A wrong guess only costs the first-frame hit.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        _thumbnail = State(initialValue: iconPath.flatMap { path in
            preview.flatMap { FolderIconResolver.cachedThumbnail(.init(path: path, stamp: $0.stamp, scale: scale)) }
        })
    }

    /// What the icon task is keyed on: a rewritten file or another screen's scale restarts it.
    private var thumbnailID: FolderIconResolver.ThumbnailID? {
        guard let iconPath else { return nil }
        return .init(path: iconPath, stamp: preview?.stamp, scale: displayScale)
    }

    var body: some View {
        if let dragURL {
            core.onDrag { FileDragItemProvider.make(for: dragURL) }
        } else {
            core
        }
    }

    private var core: some View {
        VStack(spacing: 0) {
            iconImage
                .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                .opacity(thumbnail == nil && resolvedIcon == nil && staticIcon == nil ? 0 : 1)
                .task(id: thumbnailID) { await loadIcons() }
            StackCellLabel(text: label, metrics: .native)
        }
        .padding(.top, Metrics.iconTop)
        .frame(width: Metrics.cell, height: Metrics.cell, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .nativeContextMenu { contextMenu?() ?? NSMenu() }
        .help(label)
    }

    /// Fallback for cells the warm-up missed (deep scroll, drill-in), then the thumbnail. Images
    /// never cross actors: each step writes a thread-safe cache and reads it back here.
    private func loadIcons() async {
        guard let path = iconPath else { return }
        if resolvedIcon == nil {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = FolderIconResolver.resolve(path)
                    done.resume()
                }
            }
            resolvedIcon = FolderIconResolver.cached(path)
        }
        guard preview != nil, let id = thumbnailID else { return }
        await FolderIconResolver.loadThumbnail(id)
        // A newer version's task may already be running: this one must not write over it.
        guard !Task.isCancelled else { return }
        // No preview for the new version keeps the old picture rather than flashing the type icon.
        if let fresh = FolderIconResolver.cachedThumbnail(id) { thumbnail = fresh }
    }

    @ViewBuilder
    private var iconImage: some View {
        if staticIconIsGlyph, let staticIcon {
            // Native reading: the glyph is the plate plus 124 per channel, on any backdrop.
            Image(nsImage: staticIcon)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(theme.stackPopupGlyph.color)
                .blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
        } else {
            Image(nsImage: staticIcon ?? thumbnail ?? resolvedIcon ?? Self.placeholderIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }

    private static let placeholderIcon = NSImage(size: NSSize(width: StackPopupMetrics.iconSize,
                                                              height: StackPopupMetrics.iconSize))
}

/// The one-line name under a stack-grid icon; file cells and the drawer's app cells share it.
struct StackCellLabel: View {
    let text: String
    let metrics: StackCellMetrics

    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }
    var body: some View {
        Text(text)
            .font(.system(size: metrics.labelSize))
            .foregroundStyle(theme.stackPopupText.color)
            .lineLimit(1)
            .truncationMode(metrics.truncatesLabelTail ? .tail : .middle)
            .fixedSize(horizontal: fits, vertical: false)
            .frame(width: fits ? metrics.cellSize.width : metrics.labelWidth, height: metrics.labelHeight)
    }

    /// The native rule has two widths: a name as wide as the cell is shown whole; a longer one is
    /// cut to the narrower `labelWidth`.
    private var fits: Bool {
        let font = NSFont.systemFont(ofSize: metrics.labelSize)
        return (text as NSString).size(withAttributes: [.font: font]).width <= metrics.cellSize.width
    }
}

extension FolderGridCell {
    /// The tail cell shared by the folder and Trash popups. Uses the Dock's own
    /// `openinfinder` artwork (ring + turn arrow), read from the system at runtime rather than
    /// copied into the bundle; falls back to the Finder icon if a future macOS drops the file.
    static func openInFinder(onTap: @escaping () -> Void) -> FolderGridCell {
        let label = String(localized: "Open in Finder")
        if let glyph = NativeStackArtwork.openInFinder {
            return FolderGridCell(iconPath: nil, staticIcon: glyph, staticIconIsGlyph: true,
                                  label: label, onTap: onTap)
        }
        return FolderGridCell(iconPath: nil, staticIcon: NativeStackArtwork.finderAppIcon,
                              label: label, onTap: onTap)
    }
}

/// The Dock's own stack artwork, read from `Dock.app` at runtime — never copied into the bundle.
enum NativeStackArtwork {
    private static let dockBundle = Bundle(path: "/System/Library/CoreServices/Dock.app")

    static let openInFinder: NSImage? = {
        guard let image = dockBundle?.image(forResource: "openinfinder") else { return nil }
        image.isTemplate = true
        return image
    }()

    /// Dark: a grey plate with a lighter chevron, composited plus-lighter. Light: a white plate
    /// with a darker chevron, composited plus-darker.
    static func backButton(dark: Bool) -> NSImage? { dark ? backButtonDark : backButtonLight }
    private static let backButtonDark: NSImage? = dockBundle?.image(forResource: "back-button-dark")
    private static let backButtonLight: NSImage? = dockBundle?.image(forResource: "back-button-light")

    static let finderAppIcon: NSImage = FolderIconResolver.resolve("/System/Library/CoreServices/Finder.app")

    /// The square + arrow a stack's tile shows while it is open as a fan or grid.
    static func pileArrow(dark: Bool) -> NSImage? { dark ? pileArrowDark : pileArrowLight }
    private static let pileArrowLight: NSImage? = dockBundle?.image(forResource: "s-pileArrow")
    private static let pileArrowDark: NSImage? = dockBundle?.image(forResource: "s-pileArrow2")

    /// The soft shadow under each fan item.
    static let stackItemShadow: NSImage? = dockBundle?.image(forResource: "stackitemshadow")

    /// The fan's top cell (「Open in Finder」 / 「N More in Finder」): a template, tinted and blended
    /// onto its round plate.
    static let openInFinder64: NSImage? = {
        guard let image = dockBundle?.image(forResource: "openinfinder64") else { return nil }
        image.isTemplate = true
        return image
    }()
}
