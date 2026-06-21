import Foundation

/// 抽屉显示顺序层（抽屉内拖动排序，2026-06-21）。抽屉是 **app 视角**：一个 bundleID 一个图标，
/// 顺序按 bundleID 永久记住——bundleID 跨重启稳定，不像任务条 cgWindowID 有开机周期顾虑，所以
/// 抽屉顺序可无条件落盘、永久保留。
///
/// **命门：按"成员全集"记顺序，不按"当前可见图标"裁。** 纯固定 app 运行时离开抽屉、退出才回启动区
/// （[[LaunchFavoriteStore]] 规则）；若只同步当前显示的 bundleID，它一运行就被删、退出又当新图标
/// 追加末尾 → 顺序记忆丢。故 `sync(members:)` 吃的是 `DrawerStore ∪ LaunchFavoriteStore` 全集，
/// 运行/未运行只在渲染时分区过滤。
///
/// 与 `StripOrderStore` 同形但更简单：没有开机周期守卫（bundleID 不复用）、没有缺席 grace
/// （成员集合稳定、不像窗口会闪断）。
@MainActor
final class DrawerOrderStore: ObservableObject {
    @Published private(set) var order: [String] = []
    private let key = "drawerDisplayOrder"

    init() {
        order = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// 显示顺序 = 记住的顺序 ∩ 当前成员全集，新成员追加末尾。纯函数，可在 body 里读。
    func reconciled(members: [String]) -> [String] {
        let memberSet = Set(members)
        var result = order.filter { memberSet.contains($0) }
        let known = Set(result)
        for m in members where !known.contains(m) { result.append(m) }
        return result
    }

    /// 成员全集变化时收敛持久顺序。**作为副作用调用，绝不在 body 求值期间调。**
    func sync(members: [String]) {
        let next = reconciled(members: members)
        if next != order { order = next; persist() }
    }

    /// 拖动落位：把 `draggedID` 落到 `targetID` 左/右。先按成员全集 reconcile 定基线，再插位。
    /// 调用方负责把 `targetID` 限制在与 `draggedID` 同一显示区内（同区排序，见 DrawerView）。
    func reorder(draggedID: String, relativeTo targetID: String, after: Bool, members: [String]) {
        guard draggedID != targetID else { return }
        var base = reconciled(members: members)
        guard let from = base.firstIndex(of: draggedID) else { return }
        base.remove(at: from)
        guard let t = base.firstIndex(of: targetID) else { return }
        base.insert(draggedID, at: after ? t + 1 : t)
        if base != order { order = base; persist() }
    }

    private func persist() {
        UserDefaults.standard.set(order, forKey: key)
    }
}
