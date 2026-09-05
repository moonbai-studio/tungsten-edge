import Foundation

/// 用户给的文件 / 文件夹路径的统一口径：展开 `~`、折叠 `..`、去尾斜杠（根目录 `/` 除外）。
/// 中转站（`ShelfStore`）与固定文件夹（`PinnedFolderStore`）共用，两边的存量键按同一口径去重。
enum FilePathNormalization {
    nonisolated static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
