import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// One slot in the strip: a concrete window chip, an app-level leading entry,
/// a pinned folder/shelf entry, or a zone divider.
enum StripEntry: Identifiable, Hashable {
    case window(StripItem)
    /// Constant app-icon chip for a pinned messaging app. Carries the main window's
    /// StripItem when it exists (the chip then *is* that window: toggle + full window
    /// menu); when the main window is gone, tap sends a reopen (Dock-icon-click
    /// equivalent) so the app recreates it — verified to work for WeChat even with
    /// other chat windows visible.
    case messagingApp(bundleID: String, mainWindow: StripItem?)
    /// 「在程序坞中保留」的应用：运行时照常窗口卡片；退出后收敛成一个 app 图标留在原位。
    /// id 恒为 "app-\(bid)"——与 AppTracker rebuildSnapshot() 的无窗口 fallback token 同串，
    /// 是退出↔占位切换时 live 序连续的命门。
    case keptApp(bundleID: String)
    /// 固定文件夹区的一格（消息区右侧、窗口区左侧）。path 即身份。
    case pinnedFolder(path: String)
    /// 中转格：文件夹区固定头位的暂存格（不可拖拽,常驻——它也是文件夹区永不为空的保证,
    /// 让「拖目录进来固定」在还没固定过任何文件夹时就有落区）。
    case shelf
    /// Visual separator between zones. 现在最多两条（消息|文件夹、文件夹|窗口），id 必须唯一。
    case divider(id: String)

    var id: String {
        switch self {
        case let .window(item): return item.id
        // Stable id regardless of main-window presence, so the chip doesn't churn
        // when the main window opens/closes.
        case let .messagingApp(bid, _): return "msg-app-\(bid)"
        case let .keptApp(bid): return "app-\(bid)"
        case let .pinnedFolder(path): return "folder-\(path)"
        case .shelf: return "shelf"
        case let .divider(id): return id
        }
    }
}

struct StripProjection {
    let snapshotItems: [StripItem]
    let snapshotBundleIDs: Set<String>
    let hiddenBundleIDs: Set<String>
    let messaging: [StripEntry]
    let liveNatural: [StripEntry]
    let liveOrderIDs: [String]
    let appKeyByChipID: [String: String]
    /// 每张窗口卡最终显示的标签（去掉应用名后缀 + 同组公共段，issue #41）。
    /// 按**这条 bar 上实际显示的卡**算出来的，所以只能来自投影层，不能在 `StripItem` 里算。
    let labelTitleByChipID: [String: String]
    let entries: [StripEntry]
    let layoutKeys: [StripLayoutKey]
    let messagingIDs: [String]
    let draggingID: String?
    /// 每个 app 在常规区**最靠左**那张卡的 entry id——未读角标只画在这一张上
    /// （一个未读数不能变成三个红点）。消息区成员不在这里：它们的角标画在区里那枚图标上。
    let badgeEntryIDByBundle: [String: String]

    func hasRealWindow(bundleID: String) -> Bool {
        snapshotItems.contains {
            $0.bundleIdentifier == bundleID && !$0.isAppLevelFallback
        }
    }

    func item(forID id: String) -> StripItem? {
        guard let entry = liveNatural.first(where: { $0.id == id }),
              case let .window(item) = entry else { return nil }
        return item
    }

    func liveChipIDs(bundleID: String) -> [String] {
        entries.compactMap { entry -> String? in
            guard case let .window(item) = entry,
                  item.bundleIdentifier == bundleID,
                  !item.isAppLevelFallback else { return nil }
            return item.id
        }
    }

    /// 该 app 在 live 区占了位置的**所有卡**，显示序，**不排除 app 级兜底卡与 `.keptApp` 占位**。
    ///
    /// 和 `liveChipIDs` 是两个口径，不要合并：那个回答「载体该画哪张窗口卡」，
    /// 这个回答「条上哪张卡要让位」。兜底卡和占位卡画不成载体，但它们实实在在占着一格——
    /// 早先两个问题共用前一个口径，`keepPlacement` 路径就永远不让位（双影，owner 2026-08-18）。
    func liveEntryIDs(bundleID: String) -> [String] {
        entries.compactMap { entry -> String? in
            switch entry {
            case let .window(item):
                return item.bundleIdentifier == bundleID ? item.id : nil
            case let .keptApp(bid):
                return bid == bundleID ? entry.id : nil
            default:
                return nil
            }
        }
    }
}

// MARK: - Messaging zone diagnostics

/// 永久的异常路径诊断（同 `[tabfold]`：单窗口、认得出的正常路径零输出）：消息区成员**认不出主窗口**，
/// 或者**有不止一扇真窗口**（这时「挑中了哪扇」本身就是要查的事）时，记一行这个 app 的每扇窗
/// （id + 原始标题）、挑中的主窗口和名字表此刻认得的写法。按签名去重——同一组窗口 + 同一个
/// 结论只记一次，变了才再记。走 `Logger` 不走 `print`：`open` 起的构建 stdout 是
/// 丢掉的，而 `log show --predicate 'category == "MessagingZone"'` 事后随时能读（notice 级才落盘）。
///
/// 2026-08-23 加：owner 报「微信消息区一张卡、常规区一张卡」，调试台窗口又有一半在屏幕外，
/// 三轮追问都定不了是「标题不是微信」还是「名字表没认出微信」——有这一行当场就知道。
enum MessagingZoneDiagnostics {
    private static let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "MessagingZone")
    private static let lock = NSLock()
    private static var lastSignatureByBundle: [String: String] = [:]

    static func record(bundleID: String, windows: [StripItem], mainID: String?) {
        let described = windows.map { "\($0.id):\($0.title.isEmpty ? "<empty>" : $0.title)" }
        let signature = described.joined(separator: "|") + "→" + (mainID ?? "none")
        lock.lock()
        let unchanged = lastSignatureByBundle[bundleID] == signature
        if !unchanged { lastSignatureByBundle[bundleID] = signature }
        lock.unlock()
        guard !unchanged else { return }
        let known = AppDisplayNameResolver.knownAppNames(for: bundleID).sorted().joined(separator: ", ")
        // notice 而不是 info：info 级默认不落盘，`log show` 事后读不到（只有 `log stream` 当场能看）。
        logger.notice("[msgmain] bid=\(bundleID, privacy: .public) windows=[\(described.joined(separator: ", "), privacy: .public)] known=[\(known, privacy: .public)] main=\(mainID ?? "none", privacy: .public)")
    }
}

// MARK: - Layout Animation Key

struct StripLayoutKey: Equatable {
    let id: String
    let form: Form

    enum Form: Equatable { case zero, single, multi, launcher }

    init(_ entry: StripEntry) {
        id = entry.id
        switch entry {
        case let .window(item):
            if item.isAppLevelFallback { form = .zero }
            else if item.showsTitle    { form = .multi }
            else                        { form = .single }
        case .messagingApp:
            form = .launcher    // both states render as a fixed-size icon chip
        case .keptApp:
            form = .launcher    // fixed-size kept-app icon chip
        case .pinnedFolder:
            form = .launcher    // fixed-size folder chip
        case .shelf:
            form = .launcher    // fixed-size shelf chip
        case .divider:
            form = .launcher    // fixed-size separator, no animation form change
        }
    }
}
