import CoreGraphics

/// 载体图层的坐标换算（纯判定）。
///
/// 这里同时有**三套**坐标系，混起来的后果是图标朝屏幕另一头飞，而那种错误在肉眼验收里
/// 只会被说成「动画怪怪的」。所以单独抽出来钉死：
///
/// | 坐标系 | 原点 | y 方向 | 谁在用 |
/// |---|---|---|---|
/// | 屏幕 | 主屏左下 | 向上 | `NSEvent.mouseLocation`、各面板 frame、`sourceScreenRect` |
/// | 载体面板内 | 面板 frame 左下 | 向上 | `CALayer.position`（宿主视图非 flipped） |
/// | `"strip"` / `"drawer"` | 面板内容左上 | **向下** | `grabOffset`、`DragLandingPlan` 的起点与终点 |
enum DragCarrierGeometry {
    /// **载体面板一次只铺一块屏**：包含 `point` 的那块；都不包含就取第一块（面板还没建起来时
    /// 调用方按 `.zero` 处理）。
    ///
    /// 不铺「所有屏的并集」的理由（2026-08-19 踩过）：macOS 默认「显示器具有单独的空间」，一个
    /// 窗口只属于一块显示器，越出那块屏的部分**根本不绘制**——并集窗口被系统归给面积大的那块屏，
    /// 任务条在另一块屏上时载体整段拖动都不上屏，就是 owner 报的「内置屏上拖动图标会消失」
    ///（外接屏 5K 更大，所以外接屏一切正常）。跨屏拖动改成「指针进了另一块屏就把面板挪过去」。
    static func screenFrame(containing point: CGPoint, in frames: [CGRect]) -> CGRect {
        frames.first { $0.contains(point) } ?? frames.first ?? .zero
    }

    /// 把一个中心点挪到「图层左下角落在整数设备像素上」的最近位置。
    ///
    /// 位图和条上那张卡逐像素一致的前提是它没有被重采样：图层尺寸 = 位图像素 / scale
    ///（`CarrierSnapshot.size` 就是这么算的），再加上原点对齐到像素格，CA 就是 1:1 搬像素。
    /// 落地终点若落在半个像素上，最后一帧是一张略糊的图，卡一显形就「突然变清晰」
    ///（owner 2026-08-19 报的瑕疵）。
    static func pixelAligned(center: CGPoint, size: CGSize, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return center }
        let originX = (center.x - size.width / 2) * scale
        let originY = (center.y - size.height / 2) * scale
        return CGPoint(x: originX.rounded() / scale + size.width / 2,
                       y: originY.rounded() / scale + size.height / 2)
    }

    /// 屏幕点（左下原点）→ 载体面板内 AppKit 点（左下原点）。
    static func panelPoint(screen point: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - panelFrame.minX, y: point.y - panelFrame.minY)
    }

    /// 屏幕矩形的中心 → 载体面板内 AppKit 点。起拖时载体就摆在这儿（卡槽原位）。
    static func panelCenter(ofScreenRect rect: CGRect, panelFrame: CGRect) -> CGPoint {
        panelPoint(screen: CGPoint(x: rect.midX, y: rect.midY), panelFrame: panelFrame)
    }

    /// 「拎在手里」时载体该在的位置：指针 + 抓取偏移。
    ///
    /// `grabOffset` 是在 `"strip"` / `"drawer"` 那种 **y 向下**的空间里量的
    ///（`frame.midY - value.startLocation.y`），所以纵向必须反号。
    static func carriedCenter(pointer: CGPoint, grabOffset: CGSize, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: pointer.x - panelFrame.minX + grabOffset.width,
                y: pointer.y - panelFrame.minY - grabOffset.height)
    }

    /// `carriedCenter` 的逆运算：已知载体此刻的中心（面板内左下原点）和指针，反推 `grabOffset`
    /// ——归位飞行途中被重新抓住时用（`DragController.regrabLanding`），从图标当前位置接着拖，
    /// 不跳。纵向反号那条坑和 `carriedCenter` 是同一处：单测锁往返闭合。
    static func grabOffset(pointer: CGPoint, carriedCenter: CGPoint, panelFrame: CGRect) -> CGSize {
        CGSize(width: carriedCenter.x - (pointer.x - panelFrame.minX),
               height: (pointer.y - panelFrame.minY) - carriedCenter.y)
    }

    /// `DragLandingPlan` 算出来的点是「面板内左上原点、y 向下」，翻成 AppKit 的左下原点。
    static func panelPoint(fromTopLeft point: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x, y: panelFrame.height - point.y)
    }

    /// 反过来：当前载体中心 → 「面板内左上原点、y 向下」，喂 `DragLandingPlan.flight` 的起点。
    static func topLeftCarriedCenter(pointer: CGPoint, grabOffset: CGSize, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: pointer.x - panelFrame.minX + grabOffset.width,
                y: panelFrame.maxY - pointer.y + grabOffset.height)
    }

    // MARK: - 起拖那一刻的姿态

    /// 载体在卡槽原位出现时该长什么样：整体缩放多少、视觉中心比卡槽中心高多少。
    ///
    /// **载体第一帧必须和卡槽此刻的渲染逐像素重合**——真机拖动永远是「先悬停、再按下、再拖」，
    /// 起拖那一刻卡槽里那张卡并不是静息态：安静档悬停会以**底边**为锚放大（`chipQuietHoverScale`），
    /// 按压再以**中心**为锚缩到 0.93（`chipPressScale`）。载体若按静息态 0.93 摆在卡槽中心，
    /// 重叠那一两帧就是两份图标尺寸差一成、上下错开两三个 pt——owner 2026-08-19 报的
    /// 「上下残影」正是它（第一版位图载体只对了按压、没对悬停）。
    struct PickUpPose: Equatable {
        /// 相对卡槽静息尺寸的整体缩放。
        let scale: CGFloat
        /// 视觉中心比卡槽中心**高**多少（pt，正 = 向上）。底锚放大把重心往上顶出来的那一截。
        let dy: CGFloat

        static let resting = PickUpPose(scale: 1, dy: 0)
    }

    /// - Parameters:
    ///   - chipHeight: 卡槽的布局高度（悬停放大的锚点在它的底边、按压缩放的锚点在它的中心）。
    ///   - pressedScale: 卡此刻按压缩到的倍数；`nil` = 没有按压（文件夹 chip 没有按压反馈）。
    ///   - hoverScale: 卡此刻底锚放大的倍数；`nil` = 没有放大（标准档 / 未悬停）。
    ///
    /// 推导：底锚放大 s_h 把中心抬高 (s_h − 1)·h/2；随后关于布局中心的按压 s_p 把这段位移也
    /// 乘上 s_p。两次都是竖直中线上的等比缩放，合成后仍是「关于中心的等比缩放 + 竖直平移」，
    /// 一个 `CALayer` 的 transform + position 就能精确复现。
    static func pickUpPose(chipHeight: CGFloat,
                           pressedScale: CGFloat?,
                           hoverScale: CGFloat?) -> PickUpPose {
        let hover = max(0, hoverScale ?? 1)
        let press = max(0, pressedScale ?? 1)
        let dy = (hover - 1) * chipHeight / 2 * press
        return PickUpPose(scale: hover * press, dy: dy)
    }
}
