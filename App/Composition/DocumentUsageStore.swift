import AppKit
import Foundation

/// 「最常用的文件」的计数账本（右键菜单最近区的排序数据源）。
///
/// macOS 只记「最近打开」不记次数，次数由钨极从功能上线起自己数，两路来源：
/// ① **系统最近列表的榜首变化**：sfl 目录监视（`DirectoryWatcher`）+ 应用激活 /
///    菜单打开时的重采样。目录监视对「sfl 是不是原子替换写入」没有保证（TCC 目录、
///    无法在开发机上探针验证），所以它只是**加速器**；重采样才是兜底正确性——
///    最迟在下一次右键该应用时，上一次的榜首变化会被补记上。
/// ② **从钨极菜单里打开**（`recordOpen`）：直接 +1，并顺手把 `lastTop` 设为该文件，
///    避免随后 sfl 更新再被 ① 重复计数。
///
/// 存储：JSON 文件（Application Support/<bundle id>/document-usage.json），**不进
/// UserDefaults**——最坏 40 bundle × 200 条是数百 KB，塞偏好文件会拖慢每一次 defaults 写。
/// 纯逻辑（排序 / 淘汰 / 计数判定）在 `DocumentUsageRanking`（有单测），这里只管副作用。
@MainActor
final class DocumentUsageStore {
    /// 菜单构建是 AppKit 副作用路径，照 `AppDisplayNameResolver` 的先例用共享实例，
    /// 不再往三个 NSHostingView 各注入一份环境对象。
    static let shared = DocumentUsageStore()

    private var usageByBundle: [String: BundleDocumentUsage]
    private var watcher: DirectoryWatcher?
    private var activationObserver: NSObjectProtocol?
    /// 目录监视触发时按 mtime 圈出「哪个 bundle 的 sfl 变了」，只重采样变了的那些。
    private var mtimeByFile: [String: Date] = [:]
    private var saveWork: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "com.caye.macosdockcc.v2.document-usage", qos: .utility)

    private init() {
        // 同步载入：文件封顶数百 KB、一次性，首次访问（右键菜单或 start）付几毫秒可接受。
        usageByBundle = DocumentUsageDisk.load()
    }

    // MARK: 生命周期（AppDelegate：任务条运行期开，suspend / 退出时停）

    func start() {
        guard watcher == nil else { return }
        watcher = DirectoryWatcher(path: DocumentUsageDisk.sharedListDir) { [weak self] in
            self?.directoryChanged()
        }
        // 立 mtime 基线（known 为空的那一轮只记不采）。
        directoryChanged()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bid = app?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.resampleInBackground(bundleIDs: [bid]) }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    // MARK: 菜单侧入口

    /// 菜单打开时的同步采样：调用方刚读过该 bundle 的最近列表，把榜首顺手交进来。
    func noteRecentSample(bundleID: String, topPath: String?) {
        var usage = usageByBundle[bundleID] ?? BundleDocumentUsage()
        let previous = usage.lastTop
        usage.lastTop = topPath
        if DocumentUsageRanking.shouldCountTopChange(previousTop: previous, newTop: topPath), let topPath {
            usage.files = DocumentUsageRanking.bumped(usage.files, path: topPath, at: Date())
            usage.touchedAt = Date()
        } else if previous != topPath {
            usage.touchedAt = Date()
        }
        guard usageByBundle[bundleID] != usage else { return }
        usageByBundle[bundleID] = usage
        usageByBundle = DocumentUsageRanking.prunedBundles(usageByBundle)
        scheduleSave()
    }

    /// 从钨极菜单里打开了某文件：直接 +1，并把 lastTop 设为它（防 ① 路重复计数）。
    func recordOpen(bundleID: String, path: String) {
        var usage = usageByBundle[bundleID] ?? BundleDocumentUsage()
        usage.files = DocumentUsageRanking.bumped(usage.files, path: path, at: Date())
        usage.lastTop = path
        usage.touchedAt = Date()
        usageByBundle[bundleID] = usage
        usageByBundle = DocumentUsageRanking.prunedBundles(usageByBundle)
        scheduleSave()
    }

    /// 榜单（次数降序 → 最近打开降序 → 系统最近序）。只对「仅计数来源」的路径做存在性
    /// 检查（系统最近列表那侧 `RecentDocumentsReader` 已查过），已删文件顺手清出账本。
    func ranked(bundleID: String, recentPaths: [String], limit: Int = 10) -> [String] {
        let counts = usageByBundle[bundleID]?.files ?? [:]
        let candidates = DocumentUsageRanking.ranked(
            counts: counts,
            recentPaths: recentPaths,
            limit: limit + 8
        )
        let recentSet = Set(recentPaths)
        var removedDead = false
        let alive = candidates.filter { path in
            if recentSet.contains(path) { return true }
            if FileManager.default.fileExists(atPath: path) { return true }
            usageByBundle[bundleID]?.files.removeValue(forKey: path)
            removedDead = true
            return false
        }
        if removedDead { scheduleSave() }
        return Array(alive.prefix(limit))
    }

    // MARK: 采样

    private func directoryChanged() {
        let known = mtimeByFile
        ioQueue.async { [weak self] in
            let fm = FileManager.default
            let dir = DocumentUsageDisk.sharedListDir
            var next: [String: Date] = [:]
            var changed: [String] = []
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for name in names where name.contains(".sfl") {
                let path = dir + "/" + name
                guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
                next[name] = mtime
                if known[name] != mtime {
                    changed.append((name as NSString).deletingPathExtension)
                }
            }
            DispatchQueue.main.async { [weak self, next, changed] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.mtimeByFile = next
                    guard !known.isEmpty else { return } // 首轮只立基线
                    self.resampleInBackground(bundleIDs: changed)
                }
            }
        }
    }

    private func resampleInBackground(bundleIDs: [String]) {
        guard !bundleIDs.isEmpty else { return }
        ioQueue.async { [weak self] in
            var tops: [String: String?] = [:]
            for bid in Set(bundleIDs) {
                tops[bid] = RecentDocumentsReader.recentDocuments(for: bid, maxCount: 1).first?.path
            }
            DispatchQueue.main.async { [weak self, tops] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (bid, top) in tops { self.noteRecentSample(bundleID: bid, topPath: top) }
                }
            }
        }
    }

    // MARK: 落盘（合并 1s，utility 队列，原子写）

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = usageByBundle
        let work = DispatchWorkItem { DocumentUsageDisk.write(snapshot) }
        saveWork = work
        ioQueue.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

/// 磁盘与路径（file 级私有）：放在 @MainActor 类外面，io 队列直接调、不沾隔离。
private enum DocumentUsageDisk {
    static let sharedListDir =
        ("~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
            as NSString).expandingTildeInPath

    struct Archive: Codable {
        var version: Int
        var bundles: [String: BundleDocumentUsage]
    }

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundleID = Bundle.main.bundleIdentifier ?? "com.caye.macosdockcc.v2"
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("document-usage.json")
    }

    static func load() -> [String: BundleDocumentUsage] {
        guard let data = try? Data(contentsOf: storeURL),
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == 1 else { return [:] }
        return archive.bundles
    }

    static func write(_ bundles: [String: BundleDocumentUsage]) {
        let archive = Archive(version: 1, bundles: bundles)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        let url = storeURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
