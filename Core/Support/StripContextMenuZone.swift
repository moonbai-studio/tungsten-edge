import CoreGraphics
import Foundation

/// 右键任务条底板时，该不该弹钨极菜单的**纯决策层**。
///
/// 只认两块地方（owner 2026-08-03 定）：
/// - **两端空白**：最左 chip 左边、最右 chip 右边的内缩边距；
/// - **区域分割线周围**：分割线所在的那道宽缝。
///
/// 刻意**不认 chip 之间的窄缝**：用户瞄图标差几 pt 落进去时弹出钨极菜单
/// （而不是那个 app 自己的菜单）比什么都不弹更糟。代价是窄缝右键完全没反应，这是已知取舍。
///
/// 两种缝靠宽度分辨：分割线两侧的空当是
/// `2(HStack 间距) + 5(1pt 发丝线 + 左右各 2pt 内边距) + 2(HStack 间距) = 9pt`，
/// 普通 chip 间距只有 `2pt`；阈值取两者之间即可，且随档位一起缩放。
///
/// **阈值必须严格落在两者之间，改 `Style.chipSpacing` 就要同步改它。**
/// 2026-08-16 图标间距对齐原生 Dock（中心间距 52→42pt，`chipSpacing` 8→2）时，
/// 分割线缝从 21pt 缩到 9pt，而阈值还是 12pt —— 那会让分割线那道缝也认不出来，
/// 于是整条任务条右键完全失效。
enum StripContextMenuZone {
    /// 中档基线。调用方传 `defaultMinimumGapWidth * scale`。
    /// 5pt：大于普通缝 2pt，小于分割线缝 9pt。
    static let defaultMinimumGapWidth: CGFloat = 5

    /// `point` 与 `chipFrames` 都在 "strip" 坐标空间（左上原点、y 向下）。
    static func claims(
        point: CGPoint,
        chipFrames: [CGRect],
        bounds: CGRect,
        minimumGapWidth: CGFloat
    ) -> Bool {
        guard bounds.contains(point) else { return false }
        // 一个 chip 都还没量到（首帧）时不认：宁可这一次右键没反应，
        // 也不要在"其实点在图标上"的时候抢走那个 app 的菜单。
        guard !chipFrames.isEmpty else { return false }
        guard !chipFrames.contains(where: { $0.contains(point) }) else { return false }

        let sorted = chipFrames.sorted { $0.minX < $1.minX }
        guard let first = sorted.first, let last = sorted.last else { return false }

        // 两端空白。
        if point.x < first.minX || point.x > last.maxX { return true }

        // 中间：只认落进"够宽的那道缝"的点。用 maxX 的滚动最大值而不是前一个 chip 的 maxX——
        // 帧可能有重叠（消息区外扩过的帧、拖动中的临时位置），逐个比才不会把重叠算成缝。
        var gapStart = first.maxX
        for frame in sorted.dropFirst() {
            if point.x < frame.minX {
                let width = frame.minX - gapStart
                return width >= minimumGapWidth && point.x >= gapStart
            }
            gapStart = max(gapStart, frame.maxX)
        }
        return false
    }
}
