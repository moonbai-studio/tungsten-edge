import CoreGraphics

/// 拖动时手里那张浮动副本的**位图**。
///
/// 载体从 2026-08-18 起不再是一棵独立的 SwiftUI 树，而是一张在起拖那一刻拍下来的图
/// （见 `ChipSnapshotter`）。理由是结构性的：条上那张卡和载体原来归两个互不同步的渲染器管，
/// 起拖和落地各要做一次「谁显谁藏」的交接，而两边什么时候真正上屏只有 SwiftUI 自己知道——
/// 每次交接都是一场赛跑，赢了重叠、输了空档。四轮标志位补丁（`carrierReady` / `onAppear`
/// 回报 / 兜底计时器 / 提前淡出）都是在给赛跑加裁判，没有收敛。改成位图之后，载体的每一个
/// 像素都由 `DragController` 在收到鼠标事件的同一轮 run loop 里同步决定，交接不复存在。
struct CarrierSnapshot {
    /// 位图本身。像素尺寸 = `size × scale`。
    let image: CGImage
    /// 逻辑尺寸（pt），**含外扩**——载体图层的 `bounds` 就是它。
    /// 外扩的理由见 `ChipSnapshotter.bleed`：卡片内部的图标投影会溢出布局帧，
    /// 按布局帧裁会把那圈投影切掉，落地时就和条上那张卡对不上。
    let size: CGSize
    /// 卡槽自己的尺寸（pt，不含外扩）。只用于诊断：它和起拖时上报的 `sourceScreenRect`
    /// 尺寸对不上，就说明快照画的不是卡槽同款视图。
    let contentSize: CGSize
    /// 渲染时用的 backing scale。载体图层的 `contentsScale` 取它，否则 Retina 上会糊。
    let scale: CGFloat
}
