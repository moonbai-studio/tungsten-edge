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

    /// 位置记忆粘性（slice ①）。一个 chip id 从当前快照里**短暂消失**时（Safari 偶发 AX 漏读、
    /// 标签组锚点迁移等），不立刻把它从记忆顺序里删掉——记下消失时刻，grace 内仍当它「在场」
    /// 保住 rank，只是显示层不渲染它（`reconciled` 用真实 current 过滤）。超过 grace 仍没返场
    /// 才真丢弃。这样闪断回来的卡接回原位，而不是被当新卡甩到同 app 同伴右边。
    private var absentSince: [String: Date] = [:]
    private static let rankRetentionGrace: TimeInterval = 5.0

    /// 抽屉拖回任务条·精确落点的**外部块暂存**。转正那帧窗口卡还没进 live 区（`drawerStore.remove`
    /// 要下一轮才放回），拿不到卡 id；故只记 `bundleID + 目标`，卡 id 在下一次 `sync` 里用 `appKeyOf`
    /// 现解析、`movingBlock` 落子，解析出的 id 回填 `boundIDs` 供撤销精确清除。
    private var externalBlock: (bundleID: String, target: String?, after: Bool, boundIDs: [String])?

    init() {
        // 仅当存档来自**同一开机周期**才信任（cgWindowID 跨重启会重排/复用）。
        guard UserDefaults.standard.object(forKey: bootKey) != nil,
              UserDefaults.standard.integer(forKey: bootKey) == bootTime,
              let saved = UserDefaults.standard.stringArray(forKey: orderKey) else { return }
        liveOrder = saved   // reconcile 会在首帧把已不在的窗口丢掉、新窗口进末尾
    }

    /// 显示顺序 = 记住的顺序与当前活着的 chip id 对账后的结果（不改自身状态，可在 body 里读）。
    /// `appKeyOf`（chip id → 所属 app 键）让新窗口插到同 app 同伴旁，而非任务条最右。
    func reconciled(current: [String], appKeyOf: [String: String] = [:]) -> [String] {
        StripOrdering.reconcile(remembered: liveOrder, current: current, appKeyOf: appKeyOf)
    }

    /// 把记住的顺序与当前 live 集合收敛（丢掉真关闭的、新窗口插到同 app 同伴旁），保留手动排好的相对序。
    /// **作为快照变化的副作用调用，绝不在 body 求值期间调**。`appKeyOf` 必须与 `reconciled` 同源，
    /// 否则落盘的记忆序与显示序不一致，下一帧新窗口会从同伴旁跳回末尾。
    func sync(current: [String], appKeyOf: [String: String] = [:]) {
        let now = Date()
        let currentSet = Set(current)

        // 返场的 id：清掉缺席戳。
        for id in current { absentSince.removeValue(forKey: id) }
        // 刚从记忆顺序里消失的 id：打上缺席戳（已在册的才记）。
        for id in liveOrder where !currentSet.contains(id) && absentSince[id] == nil {
            absentSince[id] = now
        }
        // grace 内的缺席 id 视作「仍在场」→ 保住 rank；过期的不再保留 → 交给 reconcile 丢弃。
        let retainedAbsent = liveOrder.filter { id in
            guard !currentSet.contains(id), let t = absentSince[id] else { return false }
            return now.timeIntervalSince(t) <= Self.rankRetentionGrace
        }
        let effectiveCurrent = current + retainedAbsent
        var next = StripOrdering.reconcile(remembered: liveOrder, current: effectiveCurrent, appKeyOf: appKeyOf)
        absentSince = absentSince.filter { now.timeIntervalSince($0.value) <= Self.rankRetentionGrace }
        // 消费外部块暂存：当被拖 app 的窗口卡都进了 current（reconcile 已纳入 next），用 appKeyOf 解出这组
        // 卡、整块落到暂存目标，**在一次发布里完成**——无尾部闪入、不被对账规则挪走。排除 app-* 兜底卡。
        if var ext = externalBlock {
            let blockIDs = next.filter { appKeyOf[$0] == ext.bundleID && !$0.hasPrefix("app-") }
            if !blockIDs.isEmpty {
                next = StripOrdering.movingBlock(next, move: blockIDs, relativeTo: ext.target, after: ext.after)
                ext.boundIDs = blockIDs
                externalBlock = ext
            }
        }
        if next != liveOrder { liveOrder = next; persist() }
    }

    // MARK: - 外部块落点（抽屉拖回任务条·精确落点）

    /// 转正进任务条：暂存"这个 app 的窗口卡整块落到 `target` 左/右（`target==nil` 末尾）"，下一次 `sync` 消费。
    func stageExternalBlock(bundleID: String, relativeTo target: String?, after: Bool) {
        externalBlock = (bundleID, target, after, [])
    }

    /// 连续重排（窗口卡已实体化、暂存已消费后）：把这组 id 整块移到 `targetID` 处。变化才发布。
    func reorderBlock(ids: [String], relativeTo targetID: String, after: Bool) {
        let next = StripOrdering.movingBlock(liveOrder, move: ids, relativeTo: targetID, after: after)
        if next != liveOrder { liveOrder = next; persist() }
    }

    /// 落定：仅清暂存追踪，`boundIDs` 留在 `liveOrder`（已是正常成员）。
    func commitExternalBlock() { externalBlock = nil }

    /// 撤销转正：从 `liveOrder` 删 `boundIDs`、清它们的 `absentSince`（否则 5s rank 粘性会复活成幽灵排名）、
    /// 清暂存。**必须在 `revertDrawerToStrip` 的 `drawerStore.add` 触发 sync 之前调**。
    func cancelExternalBlock() {
        guard let ext = externalBlock else { return }
        let ids = Set(ext.boundIDs)
        if !ids.isEmpty {
            let next = liveOrder.filter { !ids.contains($0) }
            for id in ids { absentSince.removeValue(forKey: id) }
            if next != liveOrder { liveOrder = next; persist() }
        }
        externalBlock = nil
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
