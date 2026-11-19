import CoreGraphics
import Foundation

/// Pass B「最小化折叠」的纯决策层：一个未被认领、AX 报最小化的合格窗口，到底是某个已落座
/// 物理窗口的后台标签（→ 折叠、不另建座位），还是真正独立的窗口（→ 新建座位）？
///
/// 背景：最小化一个多标签窗口时，Ghostty 会把该窗口的所有标签一下子暴露成 AX 窗口，全报
/// min=true。后台标签是 order-out 窗口，收不到 moved/resized 通知——窗口被移动/缩放过之后，
/// 它们的 AX 坐标和尺寸都停留在过时值，纯几何匹配会失效（一个标签裂一张卡）。
///
/// 判定四级，从强到弱：
/// 1. **成员关系**：候选 cgID 曾是某已放置座位的 activeCgID（标签创建即成为活跃标签 ⇒ 每个
///    后台标签都进过所属座位的历史）。与几何、min 标志完全无关——同时豁免「移动/缩放后
///    AX 几何过时」和「min 滞后竞态」两类折叠失效。注意历史是**会话态**（dock 重启清零）。
/// 2. **影子标签池**：候选 cgID 上一轮対账时「在 CG 全列表、却不在 AXWindows」——这是
///    order-out 后台标签的签名。(Not unique: a window on another Space also leaves AXWindows
///    while staying in CG — seated ids are kept out of the pool for that reason.) 池子每轮从活信号重建，**天然免疫 dock 重启**，是成员历史清零后的重启安全层。
///    仅当已有落座座位时生效：零座位时不折（真最小化窗口组的代表标签必须能建座位）。
/// 3. **frame 精确匹配**：后台标签与所属窗口逐像素同 frame（窗口没动过时成立）。
/// 4. **尺寸兜底**：同宽高 ±3 + 屏幕外 + 对应座位已标最小化（窗口移动过、但没缩放过时成立）。
/// 四级全失败 → 新建座位（对 min=true 候选这是潜在分裂点，调用方打诊断日志）。
enum TabFoldDecision {

    /// 本轮对账已放置座位的折叠视角摘要。`activeCgID` 仅作回写索引（成员学习），不是身份。
    struct PlacedSeat {
        let activeCgID: CGWindowID
        let bounds: CGRect?
        let isMinimized: Bool
        let formerCgIDs: Set<CGWindowID>
    }

    enum Reason: String {
        case membership   // 曾是该座位的活跃标签
        case shadowPool   // 上一轮在 CG 却不在 AX（order-out 后台标签签名）
        case exactFrame   // frame 逐像素匹配
        case sameSize     // 同尺寸 + 屏幕外兜底
    }

    enum Verdict: Equatable {
        /// 折叠进已有座位，不另建。`ownerActiveCgID` 非 nil = 归属唯一确定，调用方可把候选
        /// cgID 记入该座位历史（成员学习：下次折叠不再依赖几何）；nil = 归属歧义，只折叠不学习。
        case fold(ownerActiveCgID: CGWindowID?, reason: Reason)
        case newSeat
    }

    static func verdict(
        candidateCgID: CGWindowID,
        candidateBounds: CGRect?,
        candidateIsMinimized: Bool,
        candidateIsOnScreen: Bool,
        candidateIsKnownShadow: Bool,
        placedSeats: [PlacedSeat],
        frameKey: (CGRect?) -> String?
    ) -> Verdict {
        // 非 min 的未认领窗口是合法新窗口（含"两个独立窗口重叠"和"拽出标签变可见"场景），
        // 照常新建座位——影子池对 min=false 候选一律不生效。
        guard candidateIsMinimized else { return .newSeat }

        // 1. 成员关系
        let owners = placedSeats.filter { $0.formerCgIDs.contains(candidateCgID) }
        if owners.count == 1 { return .fold(ownerActiveCgID: owners[0].activeCgID, reason: .membership) }
        if owners.count > 1 { return .fold(ownerActiveCgID: nil, reason: .membership) }

        // 2. 影子标签池：唯一座位 → 归属 + 学习；多座位 → 只折叠不学习（宁可少学不误记）。
        // 零座位不折——否则真最小化窗口组连一张卡都建不出来。
        if candidateIsKnownShadow, !placedSeats.isEmpty {
            if placedSeats.count == 1 { return .fold(ownerActiveCgID: placedSeats[0].activeCgID, reason: .shadowPool) }
            return .fold(ownerActiveCgID: nil, reason: .shadowPool)
        }

        // 3. frame 精确匹配
        if let key = frameKey(candidateBounds) {
            let matches = placedSeats.filter { frameKey($0.bounds) == key }
            if matches.count == 1 { return .fold(ownerActiveCgID: matches[0].activeCgID, reason: .exactFrame) }
            if matches.count > 1 { return .fold(ownerActiveCgID: nil, reason: .exactFrame) }
        }

        // 4. 尺寸兜底：屏幕外（非活跃标签）+ 与某已放置的最小化座位宽高相同
        if !candidateIsOnScreen, let sb = candidateBounds {
            let matches = placedSeats.filter { seat in
                guard seat.isMinimized, let pb = seat.bounds else { return false }
                return abs(pb.size.width - sb.size.width) < 3 &&
                       abs(pb.size.height - sb.size.height) < 3
            }
            if matches.count == 1 { return .fold(ownerActiveCgID: matches[0].activeCgID, reason: .sameSize) }
            if matches.count > 1 { return .fold(ownerActiveCgID: nil, reason: .sameSize) }
        }

        return .newSeat
    }
}

/// Pass A「并入标签」的纯决策层：一个已落座、**未最小化、app 未隐藏**的座位，其 activeCgID 这轮
/// 离开了 AX 却仍在 CG 且没有 destroy tombstone——它是被合并进了另一扇窗（「合并所有窗口」/ 把标签
/// 拖进别的窗的标签栏），还是只是一次 AX 漏读？
///
/// 原生标签 = N 个真实 NSWindow；合并后原窗成为 order-out 后台标签：离开 AX、仍在 CG、`onscreen=false`，
/// 且 CG bounds 被系统改成了所属窗口的 frame。原来这条路无条件保座位（「AX 缺席不能证明关窗」），于是
/// 一扇窗两张卡；接着同 frame 有两个老座位，切标签的顶替规则拒绝接手，每切一次再裂一张（2026-09-12 实测）。
///
/// 释放条件（全满足）：候选在 CG 里 **不在屏上**（真可见窗口漏读时 CG 说 onscreen=true，不释放）；
/// 候选的 **CG bounds**（不是座位里过时的 AX 帧）与至少一个 **AX 在场且 min=false** 的兄弟座位逐像素同
/// frame。IntelliJ 合并后可能保留旧坐标，此时可凭原生标签栏确认归属。
/// 归属唯一时回传 owner，调用方把候选记入其历史（下次最小化爆发按成员秒折）。
enum TabMergeDecision {

    /// 本轮 AX 在场（activeCgID 仍在 eligible 里）的兄弟座位摘要；`bounds` 取本轮 AX 快照的帧。
    struct AXPresentSeat {
        let activeCgID: CGWindowID
        let bounds: CGRect?
        let isMinimized: Bool
        var containsCandidateTab = false
    }

    enum Verdict: Equatable {
        /// 并入了标签 → 释放座位。`ownerActiveCgID` 非 nil = 归属唯一，调用方做成员学习。
        case release(ownerActiveCgID: CGWindowID?)
        case retain
    }

    static func verdict(
        candidateIsOnScreen: Bool,
        candidateCGBounds: CGRect?,
        candidateSeatBounds: CGRect?,
        axPresentSeats: [AXPresentSeat],
        frameKey: (CGRect?) -> String?
    ) -> Verdict {
        guard !candidateIsOnScreen else { return .retain }
        let tabOwners = axPresentSeats.filter { !$0.isMinimized && $0.containsCandidateTab }
        if tabOwners.count == 1 { return .release(ownerActiveCgID: tabOwners[0].activeCgID) }
        guard let key = frameKey(candidateCGBounds ?? candidateSeatBounds) else { return .retain }
        let owners = axPresentSeats.filter { !$0.isMinimized && frameKey($0.bounds) == key }
        if owners.count == 1 { return .release(ownerActiveCgID: owners[0].activeCgID) }
        if owners.count > 1 { return .release(ownerActiveCgID: nil) }
        return .retain
    }
}

/// 幽灵座位自愈的纯决策层。
///
/// 幽灵座位 = 折叠判定失手时从 min=true 爆发候选里裂出来的多余座位（典型：dock 启动时窗口
/// 已最小化，seed 无历史无影子池可用）。它标着 min=true，被「最小化不释放座位」的保留规则
/// 永久扣住——还原窗口后它的 cgID 只是离开 AX、仍在 CG，卡就一直裂着。
///
/// 自愈判定五门槛（全满足才释放，宁可不愈不误删）：
/// - `everSeenVisible == false`：该座位的 activeCgID 在本会话从未以 min=false 出现在 AX 里。
///   真窗口几乎必然可见过；这门槛保护 Safari 式「一最小化就整个离开 AX」的真窗口。
/// - AX 连续缺席 ≥ threshold：不是一两轮漏读。
/// - cgID 仍在 CG：不在就是真关闭，走既有删除路径，轮不到自愈。
/// - 本轮 AX 读到了该 app 的窗口：app 挂死/AX 读失败时按兵不动。
/// - 同 pid 至少一个座位当前在 AX 里：孤座位永不自愈（防误删 app 仅有的卡）。
enum PhantomSeatDecision {
    enum HoldReason: String, Codable, Hashable {
        case everSeenVisible
        case absenceGraceNotElapsed
        case cgMissing
        case noEligibleWindows
        case noAXPresentSibling
    }

    struct Evaluation: Equatable {
        let shouldRelease: Bool
        let holdReasons: Set<HoldReason>
    }

    static func evaluate(
        everSeenVisible: Bool,
        axAbsentFor: TimeInterval,
        threshold: TimeInterval,
        cgStillPresent: Bool,
        axReadSawWindows: Bool,
        axPresentSiblingCount: Int
    ) -> Evaluation {
        var reasons: Set<HoldReason> = []
        if everSeenVisible { reasons.insert(.everSeenVisible) }
        if axAbsentFor < threshold { reasons.insert(.absenceGraceNotElapsed) }
        if !cgStillPresent { reasons.insert(.cgMissing) }
        if !axReadSawWindows { reasons.insert(.noEligibleWindows) }
        if axPresentSiblingCount < 1 { reasons.insert(.noAXPresentSibling) }
        return Evaluation(shouldRelease: reasons.isEmpty, holdReasons: reasons)
    }

    static func shouldRelease(
        everSeenVisible: Bool,
        axAbsentFor: TimeInterval,
        threshold: TimeInterval,
        cgStillPresent: Bool,
        axReadSawWindows: Bool,
        axPresentSiblingCount: Int
    ) -> Bool {
        evaluate(
            everSeenVisible: everSeenVisible,
            axAbsentFor: axAbsentFor,
            threshold: threshold,
            cgStillPresent: cgStillPresent,
            axReadSawWindows: axReadSawWindows,
            axPresentSiblingCount: axPresentSiblingCount
        ).shouldRelease
    }
}
