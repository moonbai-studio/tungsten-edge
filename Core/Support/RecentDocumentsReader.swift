import Foundation

/// One recent-menu row: a display title plus the URL to open.
struct RecentMenuEntry {
    let title: String
    let url: URL
}

/// Reads an app's "Open Recent" documents, and Finder's recent folders — best-effort.
///
/// macOS stores each app's recent documents at
/// `~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/<bundleID>.sfl4`
/// (newer systems `.sfl4`, older `.sfl3`/`.sfl2`/`.sfl`). The file is an
/// `NSKeyedArchiver` archive whose root dict has an `items` array; each item's
/// `Bookmark` (bookmark data) resolves to a real file URL.
///
/// Finder is special: it has no per-app `.sfl`; its "最近使用的文件夹" live in
/// `com.apple.finder` defaults under `FXRecentFolders` (array of `{name, file-bookmark}`).
///
/// None of this is a public/stable API (formats could change), so every step is
/// wrapped in `do/catch` and any failure returns `[]` — a bad archive must never
/// break the right-click menu. Verified on macOS 12+ (2026-06-26 spike).
enum RecentDocumentsReader {

    private static let sharedDir =
        ("~/Library/Application Support/com.apple.sharedfilelist" as NSString).expandingTildeInPath

    /// Defensive cap: archive decoding reads the whole file; real `.sfl` files are a few KB.
    private static let maxFileBytes = 1_000_000

    // MARK: - Per-app recent documents

    static func recentDocuments(for bundleID: String, maxCount: Int = 10) -> [URL] {
        let dir = URL(fileURLWithPath: sharedDir)
            .appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
        return parseSFL(in: dir, basename: bundleID, maxCount: maxCount, foldersOnly: false)
    }

    // MARK: - Finder recent folders

    /// Finder's recent folders. Primary source = `FXRecentFolders` (the actual Finder
    /// 「最近使用的文件夹」, with localized display names). Falls back to the global
    /// recent-documents list filtered to directories.
    static func recentFinderFolders(maxCount: Int = 12) -> [RecentMenuEntry] {
        if let fx = fxRecentFolders(maxCount: maxCount), !fx.isEmpty { return fx }
        let urls = parseSFL(in: URL(fileURLWithPath: sharedDir),
                            basename: "com.apple.LSSharedFileList.RecentDocuments",
                            maxCount: maxCount, foldersOnly: true)
        return urls.map { RecentMenuEntry(title: $0.lastPathComponent, url: $0) }
    }

    private static func fxRecentFolders(maxCount: Int) -> [RecentMenuEntry]? {
        guard let defaults = UserDefaults(suiteName: "com.apple.finder"),
              let arr = defaults.array(forKey: "FXRecentFolders") else { return nil }
        var seen = Set<String>()
        var out: [RecentMenuEntry] = []
        for case let entry as [String: Any] in arr {
            guard let bm = entry["file-bookmark"] as? Data,
                  let url = resolve(bm) else { continue }
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), isDirectory(url) else { continue }
            seen.insert(key)
            out.append(RecentMenuEntry(title: (entry["name"] as? String) ?? url.lastPathComponent, url: url))
            if out.count >= maxCount { break }
        }
        return out
    }

    // MARK: - Shared .sfl parsing

    private static func parseSFL(in dir: URL, basename: String, maxCount: Int, foldersOnly: Bool) -> [URL] {
        var fileURL: URL?
        for ext in ["sfl4", "sfl3", "sfl2", "sfl"] {
            let candidate = dir.appendingPathComponent("\(basename).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { fileURL = candidate; break }
        }
        guard let f = fileURL else { return [] }

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: f.path)
            if let size = attrs[.size] as? Int, size > maxFileBytes { return [] }

            let data = try Data(contentsOf: f)
            let classes: [AnyClass] = [NSDictionary.self, NSArray.self, NSData.self,
                                       NSString.self, NSNumber.self, NSDate.self,
                                       NSURL.self, NSUUID.self]
            guard let root = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSDictionary,
                  let items = root["items"] as? NSArray else { return [] }

            var seen = Set<String>()
            var result: [URL] = []
            for case let item as NSDictionary in items {
                guard let bm = item["Bookmark"] as? Data, let url = resolve(bm) else { continue }
                let key = url.standardizedFileURL.path
                guard !seen.contains(key), FileManager.default.fileExists(atPath: url.path) else { continue }
                if foldersOnly, !isDirectory(url) { continue }
                seen.insert(key)
                result.append(url)
                if result.count >= maxCount { break }
            }
            return result
        } catch {
            return []
        }
    }

    // MARK: - Helpers

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark,
                        options: [.withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Robust directory check (not `hasDirectoryPath`, which depends on a trailing
    /// slash that resolved bookmark URLs don't guarantee).
    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
