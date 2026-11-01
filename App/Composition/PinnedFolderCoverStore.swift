import AppKit
import OSLog
import QuickLookThumbnailing

/// A pinned folder chip's cover: the first items of the folder's current sort, stacked like a
/// native Dock stack (front first). Enumeration runs on a background queue; each folder carries
/// a generation counter and an async Quick Look result publishes only while it is unchanged, so
/// a stale thumbnail cannot overwrite a fresh cover. `@Published` is written on the MainActor only.
struct FolderCover: Equatable {
    struct Layer: Equatable {
        var image: NSImage
        /// A real Quick Look thumbnail (drawn at its own aspect with a hairline) rather than an
        /// icon, which carries its own transparent margin.
        var isThumbnail: Bool
    }
    /// Front first. Empty = the folder's own icon, drawn at full icon size like the native Dock's
    /// empty stack — not as a one-layer pile, whose front-layer geometry shrinks and lowers it.
    var layers: [Layer]
}

@MainActor
final class PinnedFolderCoverStore: ObservableObject {
    /// path → cover. Per layer: Quick Look thumbnail → the item's icon; an empty folder shows its own icon.
    @Published private(set) var covers: [String: FolderCover] = [:]

    private struct CacheEntry {
        let order: FolderSortOrder
        let entries: [FolderContentsLoader.Entry]
    }
    /// 后台主动预读并缓存的文件夹完整内容，专供弹窗零延迟提取。热缓存优先，不带 @Published 避免全局不必要重绘。
    private var cache: [String: CacheEntry] = [:]

    private var watchers: [String: DirectoryWatcher] = [:]
    private var generations: [String: Int] = [:]
    /// One counter for all folders, never reset: a per-folder count restarts at 1 when a folder
    /// is unpinned and pinned again, and a callback from before would pass the check.
    private var lastGeneration = 0
    /// coverFilePath|modDate → 缩略图；封面文件没变就不再生成。
    private let thumbnailCache = NSCache<NSString, NSImage>()
    /// path → the folder's own icon as last handed out. Every redraw must get the same object
    /// while the icon looks the same: a fresh `NSImage` is a different SwiftUI `Image`, and inside
    /// a reorder's spring transaction SwiftUI crossfades it — the chip dims for ~0.2s while its
    /// neighbours slide. `NSWorkspace` returns a new object on every call, so sameness is decided
    /// by `iconFingerprint`, never by identity.
    private var folderIcons: [String: HeldFolderIcon] = [:]
    private struct HeldFolderIcon {
        let dark: Bool
        let fingerprint: [UInt8]
        let image: NSImage
    }
    /// 逐文件夹排序方式（AppDelegate 注入,读 PinnedFolderStore）：封面 = 当前排序下最前的几项,
    /// 与弹窗网格同口径（原生 Stacks 同款：改排序,chip 封面跟着换）。
    private let sortOrderProvider: (String) -> FolderSortOrder
    /// `PinnedFolderStore.isUnopenedSeed`: such a folder shows its plain icon and is not read or
    /// watched until the user opens it (reading Downloads raises the system's access prompt).
    private let isUnopenedSeed: (String) -> Bool
    /// path → { package layer → its `AppIconStamp` as enumerated }. A custom icon set in Finder
    /// rewrites the bundle, not the pinned folder, so no watcher fires; the stamps are re-`stat`ed
    /// on app activation instead (never on a timer, `Docs/26`). Packages only: `AppIconStamp` looks
    /// inside the directory, and a plain subfolder may be a privacy-protected one — Downloads, an
    /// unopened seed included.
    private var layerStamps: [String: [String: AppIconStamp?]] = [:]
    private static let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "PinnedFolderCoverStore")
    private var activationObserver: NSObjectProtocol?
    private lazy var layerIconChecker = AppIconFreshnessChecker(
        snapshot: { [weak self] in
            guard let self else { return [] }
            return self.layerStamps.flatMap { folder, layers in
                layers.map { AppIconFreshnessChecker.Entry(key: folder, path: $0.key, stamp: $0.value) }
            }
        },
        didCheck: { [weak self] entries in self?.refreshFolders(withChangedLayers: entries) }
    )

    init(sortOrderProvider: @escaping (String) -> FolderSortOrder = { _ in .default },
         isUnopenedSeed: @escaping (String) -> Bool = { _ in false },
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.sortOrderProvider = sortOrderProvider
        self.isUnopenedSeed = isUnopenedSeed
        activationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.layerIconChecker.requestCheck() }
        }
    }

    /// 提取命中且排序一致的热缓存。如果为 nil，调用方应执行同步的 preload 兜底。
    func cachedEntries(for path: String, order: FolderSortOrder) -> [FolderContentsLoader.Entry]? {
        guard let entry = cache[path], entry.order == order else { return nil }
        return entry.entries
    }

    /// 与 PinnedFolderStore.folderPaths 对账：多退少补 watcher，全量刷新一次封面。
    func sync(paths: [String]) {
        let wanted = Set(paths)
        for gone in Array(folderIcons.keys) where !wanted.contains(gone) {
            folderIcons[gone] = nil
        }
        for gone in Array(watchers.keys) where !wanted.contains(gone) {
            watchers[gone]?.stop()
            watchers[gone] = nil
            covers[gone] = nil
            cache[gone] = nil
            generations[gone] = nil
            layerStamps[gone] = nil
        }
        for path in paths {
            if isUnopenedSeed(path) {
                covers[path] = FolderCover(layers: [])
                layerStamps[path] = nil
                continue
            }
            if watchers[path] == nil {
                // DirectoryWatcher 回调已在主线程；Task 包一层过 MainActor 隔离。
                watchers[path] = DirectoryWatcher(path: path) { [weak self] in
                    Task { @MainActor [weak self] in self?.refresh(path: path) }
                }
            }
            refresh(path: path)
        }
    }

    private func refresh(path: String) {
        lastGeneration += 1
        let generation = lastGeneration
        generations[path] = generation
        let folderURL = URL(fileURLWithPath: path)
        let order = sortOrderProvider(path)   // MainActor 上读定,后台块用值

        Task.detached(priority: .utility) { [weak self] in
            let entries = (try? FolderContentsLoader.load(directory: folderURL)) ?? []
            let sortedEntries = FolderContentsLoader.sorted(entries, by: order)
            let stack = FolderContentsLoader.coverEntries(in: sortedEntries)
            // Stamped before `publishCover` reads the icons: a change landing in between costs
            // one extra refresh on the next activation, never a missed one.
            let stamps = Dictionary(
                PinnedFolderCoverFreshness.packageLayerPaths(in: stack).map { ($0, AppIconStamp.stamp(atPath: $0)) },
                uniquingKeysWith: { first, _ in first }
            )
            await MainActor.run { [weak self] in
                guard let self, self.generations[path] == generation else { return }
                self.cache[path] = CacheEntry(order: order, entries: sortedEntries)
                self.layerStamps[path] = stamps.isEmpty ? nil : stamps
                self.publishCover(path: path, stack: stack, generation: generation)
            }
        }
    }

    private func refreshFolders(withChangedLayers checked: [AppIconFreshnessChecker.Entry]) {
        for folder in PinnedFolderCoverFreshness.foldersNeedingRefresh(recorded: layerStamps, checked: checked) {
            // Record the new stamps before the enumeration: when it is slower than the next app
            // switch, the same change would otherwise restart it and void the pending result.
            guard var layers = layerStamps[folder] else { continue }
            var changed: [String] = []
            for entry in checked where entry.key == folder {
                guard let recorded = layers[entry.path], recorded != entry.stamp else { continue }
                layers.updateValue(entry.stamp, forKey: entry.path)
                changed.append(entry.path)
            }
            layerStamps[folder] = layers
            // The popup caches the same icons by path; without this it still shows the old one.
            FolderIconResolver.discard(paths: changed)
            Self.logger.debug("封面图标变了：\(folder, privacy: .public)")
            refresh(path: folder)
        }
    }

    private func publishCover(path: String, stack: [FolderContentsLoader.Entry], generation: Int) {
        guard !stack.isEmpty else {
            covers[path] = FolderCover(layers: [])
            return
        }
        var pending: [(index: Int, url: URL, cacheKey: String)] = []
        let layers = stack.enumerated().map { index, entry -> FolderCover.Layer in
            // Folders (and bundles) keep their icon, as on a native stack.
            guard !entry.isDirectory else {
                return .init(image: Self.icon(forPath: entry.url.path), isThumbnail: false)
            }
            let cacheKey = "\(entry.url.path)|\(entry.dateModified?.timeIntervalSince1970 ?? 0)"
            if let cached = thumbnailCache.object(forKey: cacheKey as NSString) {
                return .init(image: cached, isThumbnail: true)
            }
            // The file's icon stands in until its Quick Look thumbnail arrives.
            pending.append((index, entry.url, cacheKey))
            return .init(image: Self.icon(forPath: entry.url.path), isThumbnail: false)
        }
        covers[path] = FolderCover(layers: layers)

        for (index, url, cacheKey) in pending {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 64, height: 64),
                scale: 2,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let cgImage = representation?.cgImage else { return }  // keep the icon on failure
                let image = NSImage(cgImage: cgImage, size: .zero)
                Task { @MainActor [weak self] in
                    guard let self, self.generations[path] == generation,
                          var cover = self.covers[path], cover.layers.indices.contains(index) else { return }
                    self.thumbnailCache.setObject(image, forKey: cacheKey as NSString)
                    cover.layers[index] = .init(image: image, isThumbnail: true)
                    self.covers[path] = cover
                }
            }
        }
    }

    /// The folder's own icon for the chip: re-read on every call, so a custom icon set in Finder
    /// shows on the next redraw — unopened seeds included, which no watcher covers — but the held
    /// object is returned while the icon looks the same. Reads only the icon, never the contents,
    /// so an unopened seed stays unread.
    func folderIcon(forPath path: String, dark: Bool) -> NSImage {
        let fresh = Self.icon(forPath: path)
        let fingerprint = Self.iconFingerprint(fresh, dark: dark)
        if let held = folderIcons[path], held.dark == dark, held.fingerprint == fingerprint {
            return held.image
        }
        folderIcons[path] = HeldFolderIcon(dark: dark, fingerprint: fingerprint, image: fresh)
        return fresh
    }

    /// The icon drawn at 16×16 under a fixed appearance: tells a changed icon from a re-fetched
    /// identical one for ~0.06ms, where comparing `tiffRepresentation`s costs ~37ms.
    private static func iconFingerprint(_ image: NSImage, dark: Bool) -> [UInt8] {
        let side = 16
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return }
            appearance.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        return bytes
    }

    /// NSWorkspace 图标是共享缓存对象，必须 `.copy()` 再改 size（AppMenuFragments 同款惯例）。
    static func icon(forPath path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        guard let copy = icon.copy() as? NSImage else { return icon }
        copy.size = NSSize(width: 64, height: 64)
        return copy
    }
}
