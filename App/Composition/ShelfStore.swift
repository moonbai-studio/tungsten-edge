import Foundation

/// 中转格（临时文件中转）的持久层：路径列表，**引用不搬家**——文件留在原处，拖出时由
/// 目的地按系统语义拷贝/移动。新暂存插头部（最新在前）；v1 存裸路径不存 bookmark，
/// 文件被移走/删除即失效，由 `prune()`（弹窗打开时调）剔除。
/// 列表操作是纯静态函数（stashing/pruned），进单测。
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var itemPaths: [String] = []
    private let key = "shelfItemPaths"

    init() {
        itemPaths = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func stash(paths: [String]) {
        let next = Self.stashing(itemPaths, adding: paths.map(Self.normalized))
        guard next != itemPaths else { return }
        itemPaths = next
        persist()
    }

    func remove(_ path: String) {
        let normalized = Self.normalized(path)
        guard itemPaths.contains(normalized) else { return }
        itemPaths.removeAll { $0 == normalized }
        persist()
    }

    func clear() {
        guard !itemPaths.isEmpty else { return }
        itemPaths = []
        persist()
    }

    /// 剔除已不存在的路径（打开中转弹窗时调）。返回是否有变化。
    @discardableResult
    func prune() -> Bool {
        let kept = Self.pruned(itemPaths) { FileManager.default.fileExists(atPath: $0) }
        guard kept != itemPaths else { return false }
        itemPaths = kept
        persist()
        return true
    }

    private func persist() {
        UserDefaults.standard.set(itemPaths, forKey: key)
    }

    // MARK: - 纯逻辑（单测覆盖）

    /// 标准化：展开 ~ / 折叠 .. 并去尾斜杠（与 PinnedFolderStore 同一口径，实现在 `FilePathNormalization`）。
    nonisolated static func normalized(_ path: String) -> String {
        FilePathNormalization.normalized(path)
    }

    /// 暂存合并：新条目（自身去重、去空）插头部；已在列表里的移到头部（重复暂存 = 提到最前）。
    nonisolated static func stashing(_ current: [String], adding: [String]) -> [String] {
        var seen = Set<String>()
        let incoming = adding.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !incoming.isEmpty else { return current }
        return incoming + current.filter { !seen.contains($0) }
    }

    /// 剔除不存在的路径（exists 注入，测试不碰真文件系统）。
    nonisolated static func pruned(_ paths: [String], exists: (String) -> Bool) -> [String] {
        paths.filter(exists)
    }
}
