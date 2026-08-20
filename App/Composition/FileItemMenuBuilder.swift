import AppKit
import UniformTypeIdentifiers

/// 弹窗格子（文件/文件夹）的右键菜单：手搓 NSMenu（AGENTS：不用 SwiftUI contextMenu）。
///
/// 关闭语义（评审拍板，勿改回「全部关」或「全部不关」）：
/// - 打开 / 打开方式 / 在访达中显示 → 动作后**关弹窗**（与点击格子打开文件的既有行为一致）；
/// - 拷贝 / 复制路径 / 固定到固定区 / 移出中转 → **不关**；
/// - 移到废纸篓 → **不关**（DirectoryWatcher 自动刷新网格，用户常连删多个）。
///
/// 明确不做：快速查看（nonactivating 面板做不了 key window）、显示简介、重命名。
@MainActor
enum FileItemMenuBuilder {
    struct Context {
        var url: URL
        var isDirectory: Bool
        /// 打开类动作后关弹窗（协调器的 close 回调）。
        var closePopup: () -> Void
        /// 目录条目「固定到固定区」；nil = 不显示（非目录或已固定）。
        var pinFolder: (() -> Void)?
        /// 中转弹窗「移出中转」；nil = 非中转弹窗。
        var removeFromShelf: (() -> Void)?
        /// 移到废纸篓成功后的额外收尾（中转弹窗同步移出暂存条目）。
        var onTrashed: (() -> Void)?

        init(url: URL,
             isDirectory: Bool,
             closePopup: @escaping () -> Void,
             pinFolder: (() -> Void)? = nil,
             removeFromShelf: (() -> Void)? = nil,
             onTrashed: (() -> Void)? = nil) {
            self.url = url
            self.isDirectory = isDirectory
            self.closePopup = closePopup
            self.pinFolder = pinFolder
            self.removeFromShelf = removeFromShelf
            self.onTrashed = onTrashed
        }
    }

    static func menu(for context: Context) -> NSMenu {
        let menu = NSMenu()
        let url = context.url
        let closePopup = context.closePopup

        menu.addItem(ClosureMenuItem(String(localized: "Open")) {
            NSWorkspace.shared.open(url)
            closePopup()
        })
        menu.addItem(openWithItem(url: url, closePopup: closePopup))
        menu.addItem(ClosureMenuItem(String(localized: "Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            closePopup()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Copy")) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
        })
        menu.addItem(ClosureMenuItem(String(localized: "Copy Path")) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.path, forType: .string)
        })
        if context.pinFolder != nil || context.removeFromShelf != nil {
            menu.addItem(.separator())
            if let pinFolder = context.pinFolder {
                menu.addItem(ClosureMenuItem(String(localized: "Pin to Taskbar")) { pinFolder() })
            }
            if let removeFromShelf = context.removeFromShelf {
                menu.addItem(ClosureMenuItem(String(localized: "Remove from Shelf")) { removeFromShelf() })
            }
        }
        menu.addItem(.separator())
        let onTrashed = context.onTrashed
        menu.addItem(ClosureMenuItem(String(localized: "Move to Trash")) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                onTrashed?()
            } catch {
                NSSound.beep()   // 失败（权限/只读卷等）不弹框,与访达的静默拒绝一致
            }
        })
        return menu
    }

    /// 「打开方式 ▸」子菜单：系统登记的可打开应用，默认应用置顶标注。菜单每次右键现建，
    /// 列表现查（urlsForApplications 本地查询,量级毫秒）。查不到 → 单条置灰「无可用应用」。
    private static func openWithItem(url: URL, closePopup: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        // 去重（同一 app 多个安装路径按标准化路径去重），默认应用置顶，其余按显示名排序。
        var seen = Set<String>()
        apps = apps.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let defaultPath = defaultApp?.standardizedFileURL.path
        apps.sort { a, b in
            if a.standardizedFileURL.path == defaultPath { return true }
            if b.standardizedFileURL.path == defaultPath { return false }
            return displayName(a).localizedStandardCompare(displayName(b)) == .orderedAscending
        }

        if apps.isEmpty {
            let none = NSMenuItem(title: String(localized: "No Apps Available"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for appURL in apps {
            let isDefault = appURL.standardizedFileURL.path == defaultPath
            let title = isDefault
                ? String(format: String(localized: "%@ (default)"), displayName(appURL))
                : displayName(appURL)
            let appItem = ClosureMenuItem(title) {
                NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                        configuration: NSWorkspace.OpenConfiguration(),
                                        completionHandler: nil)
                closePopup()
            }
            // copy() 再改 size：icon(forFile:) 是共享缓存对象（AppMenuFragments 惯例）。
            let icon = NSWorkspace.shared.icon(forFile: appURL.path).copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            appItem.image = icon
            submenu.addItem(appItem)
        }
        item.submenu = submenu
        return item
    }

    private static func displayName(_ appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path)
    }
}
