import Foundation

/// 任务条拖动重排 · A 路线（会话内防打乱）的**显示顺序状态层**，只管主任务条的
/// **实时窗口区**（live zone）。持有一串 chip id 的顺序；每次渲染用 `reconciled(current:)`
/// 与「当前还活着的 chip」对账（已有保序、新窗口进末尾、真关闭丢弃），拖动用 `move` 改顺序。
///
/// 边界：消息固定区的顺序归 `MessagingAppStore` 自己管，本 store **只管 live 区、绝不跨界**。
/// 排序原语在 `StripOrdering`（`UI/ReadModel/StripItem.swift`），本类只是它的有状态壳。
///
/// 落盘（slice 4）：**只为抗任务条 App 自身重启**把活窗口顺序洗掉，**不做**仿 Dock 的跨关闭/
/// 重启布局恢复。机制：
/// - 主键 = chip id 里的 `cgw-*`（内嵌 cgWindowID，开机周期内对同一窗口稳定）；**只落 `cgw-*`，
///   app-* 占位是临时键、只活在内存**。
/// - `kern.boottime` 守卫：开机时间变了（=重启过机器，旧 cgWindowID 已重排/复用）整份丢弃。
/// - 启动只把存档当"记忆"喂给 reconcile，仍活着的窗口接回原序、其余自然丢——不复活已关窗口。
@MainActor
final class StripOrderStore: ObservableObject {
    @Published private(set) var liveOrder: [String] = []

    private let orderKey = "stripLiveOrder"
    private let bootKey = "stripLiveOrderBootTime"
    /// 本次开机时间（秒）。开机周期内不变，缓存一次即可。
    private let bootTime = StripOrderStore.bootTimeSeconds()

    init() {
        // 仅当存档来自**同一开机周期**才信任（cgWindowID 跨重启会重排/复用）。
        guard UserDefaults.standard.object(forKey: bootKey) != nil,
              UserDefaults.standard.integer(forKey: bootKey) == bootTime,
              let saved = UserDefaults.standard.stringArray(forKey: orderKey) else { return }
        liveOrder = saved   // reconcile 会在首帧把已不在的窗口丢掉、新窗口进末尾
    }

    /// 显示顺序 = 记住的顺序与当前活着的 chip id 对账后的结果（不改自身状态，可在 body 里读）。
    func reconciled(current: [String]) -> [String] {
        StripOrdering.reconcile(remembered: liveOrder, current: current)
    }

    /// 把记住的顺序与当前 live 集合收敛（丢掉真关闭的、追加新出现的），保留手动排好的相对序。
    /// **作为快照变化的副作用调用，绝不在 body 求值期间调**。
    func sync(current: [String]) {
        let next = StripOrdering.reconcile(remembered: liveOrder, current: current)
        if next != liveOrder { liveOrder = next; persist() }
    }

    /// 拖动落位：把 `draggedID` 落到 `targetID` 的左/右边。先 reconcile 定下当前显示序，再插位；
    /// 顺序没变就不发布（拖动中 `dropUpdated` 高频调用，挡掉无谓 churn）。
    func reorder(draggedID: String, relativeTo targetID: String, after: Bool, current: [String]) {
        let base = StripOrdering.reconcile(remembered: liveOrder, current: current)
        let next = StripOrdering.reordering(base, move: draggedID, relativeTo: targetID, after: after)
        if next != liveOrder { liveOrder = next; persist() }
    }

    /// 落盘当前顺序：只存 `cgw-*`（真实窗口键）+ 本次开机时间。app-* 临时键不落。
    private func persist() {
        UserDefaults.standard.set(StripOrdering.persistableLiveOrder(liveOrder), forKey: orderKey)
        UserDefaults.standard.set(bootTime, forKey: bootKey)
    }

    /// `kern.boottime` 的秒数；读不到给 0（=不信任任何存档，安全降级）。
    private static func bootTimeSeconds() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        return sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 ? Int(tv.tv_sec) : 0
    }
}
