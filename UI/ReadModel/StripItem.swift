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
