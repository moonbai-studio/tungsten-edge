import CoreGraphics

/// 抽屉图标拖进任务条时，这一整块该落在哪张 live 卡的左边还是右边（纯判定）。
///
/// **只看 x，而且永远给得出答案**（只要 live 区有卡）。这两点都是实测逼出来的
/// （2026-08-18，`DOCK_HOVER_TRACE` 拖拽日志）：
///
/// - 转正的判定框刻意在条的**上沿之外再放 16pt**，好让人从抽屉往下拖时早一点看到反应。
///   可原来的落点判定用的是整帧 `contains`——在条外那 16pt 里它**永远不命中**，
///   于是首次落点 100% 退化成「整块落到 live 区末尾」。
/// - 之后每次光标移动虽然会再判一次，但光标压在两张卡之间那 2pt 缝里、
///   或者压在消息区/文件夹区上时，同样不命中 → 那一刻整块**原地不动**。
///
/// 两条加起来，用户看到的就是「缝开在一个跟手指无关的固定位置，而且怎么挪都不动」，
/// 也就是 owner 说的「不容易触发把其他图标挤走的动画」。
///
/// 判据是**到卡中心的距离取近**（不是到卡边）：这里要的是「插到哪两张卡之间」，
/// 而卡中心正好是相邻两个插入位的分界。`StripHoverResolution` 用的是到卡边取近，
/// 因为它回答的是另一个问题（指针压在谁**身上**），两者不能互换。
enum StripBlockLanding {
    /// - Parameter frames: live 区候选卡的帧（已排除被拖的那一块）。顺序无关。
    /// - Returns: `nil` 只在候选为空时出现（live 区真的没有别的卡）。
    static func target(pointerX: CGFloat, frames: [String: CGRect]) -> (id: String, after: Bool)? {
        var best: (id: String, distance: CGFloat, after: Bool)?
        for (id, frame) in frames {
            guard frame.width > 0, frame.height > 0 else { continue }
            let distance = abs(pointerX - frame.midX)
            let after = pointerX > frame.midX
            guard let current = best else { best = (id, distance, after); continue }
            // 距离相同时按 id 定序，保证判定是确定的（字典遍历顺序不定）。
            if distance < current.distance || (distance == current.distance && id < current.id) {
                best = (id, distance, after)
            }
        }
        guard let best else { return nil }
        return (best.id, best.after)
    }
}
