import Foundation

/// 任务条拖动重排 · A 路线（会话内防打乱）的**显示顺序状态层**，只管主任务条的
/// **实时窗口区**（live zone）。持有一串 chip id 的顺序；每次渲染用 `reconciled(current:)`
/// 与「当前还活着的 chip」对账（已有保序、新窗口进末尾、真关闭丢弃），拖动用 `move` 改顺序。
///
/// 边界：消息固定区的顺序归 `MessagingAppStore` 自己管，本 store **只管 live 区、绝不跨界**。
/// 排序原语在 `StripOrdering`（`UI/ReadModel/StripItem.swift`），本类只是它的有状态壳。
///
/// 切片进度：
/// - slice 2（本次）：**纯内存**，不写 UserDefaults。接进 `DockStripView` 的 live 区，
///   用当前序播种 → 视觉上无变化，只把「单一显示顺序漏斗」立起来。
/// - slice 3：拖动手势调 `move`。
/// - slice 4：落盘 —— cgWindowID 主键 + `kern.boottime` 守卫，只为抗任务条 App 自身重启
///   把活窗口顺序洗掉，**不做**仿 Dock 的跨关闭/重启布局恢复。
@MainActor
final class StripOrderStore: ObservableObject {
    @Published private(set) var liveOrder: [String] = []

    /// 显示顺序 = 记住的顺序与当前活着的 chip id 对账后的结果（不改自身状态，可在 body 里读）。
    func reconciled(current: [String]) -> [String] {
        StripOrdering.reconcile(remembered: liveOrder, current: current)
    }

    /// 把记住的顺序与当前 live 集合收敛（丢掉真关闭的、追加新出现的），保留手动排好的相对序。
    /// **作为快照变化的副作用调用，绝不在 body 求值期间调**。
    func sync(current: [String]) {
        let next = StripOrdering.reconcile(remembered: liveOrder, current: current)
        if next != liveOrder { liveOrder = next }
    }

    /// 拖动落位：把 `draggedID` 落到 `targetID` 的左/右边。先 reconcile 定下当前显示序，再插位；
    /// 顺序没变就不发布（拖动中 `dropUpdated` 高频调用，挡掉无谓 churn）。
    func reorder(draggedID: String, relativeTo targetID: String, after: Bool, current: [String]) {
        let base = StripOrdering.reconcile(remembered: liveOrder, current: current)
        let next = StripOrdering.reordering(base, move: draggedID, relativeTo: targetID, after: after)
        if next != liveOrder { liveOrder = next }
    }
}
