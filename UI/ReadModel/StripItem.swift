import Foundation

struct StripItem: Hashable {
    let id: String
    let title: String
    let status: String
    let appID: String
    let bundleIdentifier: String?
    let sameAppCardCount: Int
    let showsTitle: Bool
    let isAppLevelFallback: Bool
    let canMinimize: Bool
    let canHide: Bool
    let canClose: Bool
    let isOnDesktop: Bool
    /// Window the显隐类动作 (toggle/activate/minimize/hide/newWindow) routes to, and the key
    /// the乐观态 overlay is read/written under. For a 原生标签组 this is the focused (active)
    /// tab; for a plain window it equals `id`.
    let actionWindowID: String
    /// All real windows behind this chip. A single window → `[id]`; a 标签组 → every tab,
    /// so「关闭窗口」can close the whole group (2026-06-14 拍板「整组关闭」).
    let memberWindowIDs: [String]

    /// Builds a chip from one or more window records. ≥2 records means a 原生标签组
    /// (same app + identical frame) collapsed into a single chip.
    init(members: [WindowRecord], sameAppCardCount: Int = 1) {
        // Stable SwiftUI identity: the smallest CGWindowID in the group. It does NOT change
        // when the focused tab switches, so the merged chip never churns / re-animates.
        let anchor = members.min { ($0.cgWindowID ?? .max) < ($1.cgWindowID ?? .max) } ?? members[0]
        // Display + action representative = the **visible** tab of the group. In a 原生标签组 the
        // non-current tabs report to AX as `.minimized`; exactly one tab is on-screen. Prefer the
        // truly-focused tab (`.active`, only set while the app is frontmost), else the lone visible
        // (non-minimized) tab, else — whole group minimized/hidden — the stable anchor.
        //
        // Keying on visibility (min flag) rather than focus is what makes tab-switching feel instant:
        // switching tabs fires Deminiaturized for the new tab (min→false) promptly, whereas the
        // .active/focus flag lags. So the title follows the Deminiaturized notification, not focus.
        let representative = members.first { $0.status == .active }
            ?? members.first { $0.status != .minimized && $0.status != .hidden }
            ?? anchor

        self.id = anchor.id.rawValue
        self.actionWindowID = representative.id.rawValue
        self.memberWindowIDs = members.map(\.id.rawValue)
        self.title = representative.title
        self.status = representative.status.rawValue
        self.appID = representative.appID.rawValue
        self.bundleIdentifier = representative.bundleIdentifier
        self.sameAppCardCount = sameAppCardCount
        self.showsTitle = sameAppCardCount >= 2
        self.isAppLevelFallback = anchor.id.rawValue.hasPrefix("app-")
        self.canMinimize = self.isAppLevelFallback == false
        self.canHide = true
        self.canClose = self.isAppLevelFallback == false
        self.isOnDesktop = representative.isOnDesktop
    }

    init(record: WindowRecord, sameAppCardCount: Int = 1) {
        self.init(members: [record], sameAppCardCount: sameAppCardCount)
    }

    static func items(from snapshot: DockSnapshot) -> [StripItem] {
        let records = snapshot.orderedWindowIDs.compactMap { snapshot.windows[$0] }

        // Collapse 原生标签组 (same app + identical frame) into one slot, preserving
        // first-appearance order. Non-groupable records (app-* fallback, frameless) stay solo.
        var slots: [[WindowRecord]] = []
        var slotIndexByKey: [String: Int] = [:]
        for record in records {
            let key = tabGroupKey(for: record)
            if let key, let idx = slotIndexByKey[key] {
                slots[idx].append(record)
            } else {
                if let key { slotIndexByKey[key] = slots.count }
                slots.append([record])
            }
        }

        let countByApp = Dictionary(grouping: slots) { appGroupingKey(for: $0[0]) }
            .mapValues(\.count)

        return slots.map { members in
            StripItem(members: members, sameAppCardCount: countByApp[appGroupingKey(for: members[0])] ?? 1)
        }
    }

    private static func appGroupingKey(for record: WindowRecord) -> String {
        record.bundleIdentifier ?? record.appID.rawValue
    }

    /// Identity of the 原生标签组 a record belongs to: `pid | bundle | exact frame`. Returns
    /// nil for records that must never merge (app-* fallback, no CGWindowID, or no frame).
    /// Frame match is **exact** (rounded to int) — near-equal windows (e.g. two browser
    /// windows differing by a few px) must stay separate (验证 2026-06-13).
    private static func tabGroupKey(for record: WindowRecord) -> String? {
        guard record.cgWindowID != nil, let bounds = record.bounds else { return nil }
        let bundle = record.bundleIdentifier ?? record.appID.rawValue
        let x = Int(bounds.origin.x.rounded())
        let y = Int(bounds.origin.y.rounded())
        let w = Int(bounds.size.width.rounded())
        let h = Int(bounds.size.height.rounded())
        return "\(record.pid)|\(bundle)|\(x):\(y):\(w):\(h)"
    }
}

/// 任务条拖动重排 · A 路线（会话内防打乱）的纯排序原语。
///
/// 设计见 `03 设计决策#任务条拖动重排`。本层只对一串 chip id 做无状态变换：
/// 不接 UI、不落盘、不碰窗口身份模型。有状态的排序层（`StripOrderStore`）与拖动手势
/// 在后续切片接入，复用这里的原语。
///
/// 关键前提：**座位生命周期在上游 `DockSnapshot` 已保证**——最小化 / 隐藏 / CG 临时消失
/// 的窗口都保留在 snapshot 里（座位不释放），只有「真关闭」才从 snapshot 消失。所以本层
/// 「当前列表里不在」即等于「座位真结束」，无需也不应在此重新判断窗口在不在。
enum StripOrdering {
    /// 把「记住的显示顺序」和「当前还活着的 chip」对账，产出新的显示顺序。
    ///
    /// - 已记住且仍在 → 保持记住的相对顺序（**防打乱核心**：邻居增删不动既有排好的卡）。
    /// - 新出现（当前有、没记过）→ 追加到末尾，按 `current` 的自然顺序。
    /// - 记住的但当前已不在 → 丢弃（座位真结束，见类型注释）。
    static func reconcile(remembered: [String], current: [String]) -> [String] {
        let currentSet = Set(current)
        let rememberedSet = Set(remembered)
        let survivors = remembered.filter { currentSet.contains($0) }
        let newcomers = current.filter { !rememberedSet.contains($0) }
        return survivors + newcomers
    }

    /// 应用一次拖动：把 `id` 移到目标下标。`targetIndex` 以「移除 `id` 之后」的数组下标为准，
    /// 越界自动夹紧。`id` 不在序列中则原样返回。
    static func move(_ order: [String], id: String, to targetIndex: Int) -> [String] {
        guard let from = order.firstIndex(of: id) else { return order }
        var result = order
        result.remove(at: from)
        let clamped = max(0, min(targetIndex, result.count))
        result.insert(id, at: clamped)
        return result
    }

    /// 用 `newID` 顶替 `oldID`，**继承其位置（rank）**。用于：app-\* 占位升级成真窗口、
    /// 标签组 anchor 因成员关闭而迁移。`oldID` 不在序列、或 `newID` 已在序列中（防重复）→ 原样返回。
    static func substituting(_ order: [String], oldID: String, newID: String) -> [String] {
        guard order.contains(oldID), !order.contains(newID) else { return order }
        return order.map { $0 == oldID ? newID : $0 }
    }
}
