import SwiftUI

/// 中转格的图标画法：深色收纳袋 + 露出上沿的几张白纸（owner 2026-08-16 指定的参考图）。
///
/// **是矢量自绘，不是贴图。** 一来四档缩放都得清晰，二来参考图是一张来路不明的渲染图，
/// 本项目是公开发布的 GPL 应用，不能把别人的图标资源打进包里。所以这里照着那张图的
/// 结构重画：后板 + 三张纸 + 前袋，比例都是相对边长的归一化值，换尺寸不用重调。
///
/// 尺寸由调用方给（`ChipPillMetrics.bareIconVisibleSlot`），画满整个画布——外面的透明边距
/// 由调用方的槽位负责，和苹果的图标资源对齐。
struct ShelfTrayArt: View {
    let size: CGFloat
    /// 外部文件拖到格上时整体提亮。
    var lifted: Bool = false

    var body: some View {
        ZStack {
            backPlate
            papers
            frontPocket
        }
        .frame(width: size, height: size)
        .brightness(lifted ? 0.08 : 0)
    }

    // MARK: 后板

    private var backPlate: some View {
        RoundedRectangle(cornerRadius: size * 0.215, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(white: 0.30), Color(white: 0.19)],
                startPoint: .top,
                endPoint: .bottom
            ))
    }

    // MARK: 纸

    /// 三张白纸，中间那张最高、两侧略矮并向外倾——参考图里的扇形。
    /// 画在后板范围内并整体裁掉，免得倾斜的角戳出圆角外面。
    private var papers: some View {
        ZStack {
            paper(offsetX: -0.085, offsetY: 0.010, rotation: -7, scale: 0.94)
            paper(offsetX: 0.085, offsetY: 0.020, rotation: 7, scale: 0.94)
            paper(offsetX: 0, offsetY: -0.005, rotation: 0, scale: 1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.215, style: .continuous))
    }

    private func paper(offsetX: CGFloat, offsetY: CGFloat, rotation: Double, scale: CGFloat) -> some View {
        let width = size * 0.46 * scale
        let height = size * 0.56 * scale
        return RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(white: 0.99), Color(white: 0.90)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(width: width, height: height)
            .rotationEffect(.degrees(rotation))
            // 纸的下半截被前袋盖住，所以整体上移：露出的只是上沿。
            .offset(x: size * offsetX, y: size * (offsetY - 0.10))
    }

    // MARK: 前袋

    /// 前袋是半透明的深灰，上沿是参考图里那道「左高右低再回收」的曲线。
    /// 半透明是关键：纸从它背后透出来一点，才有"装在袋子里"的层次。
    private var frontPocket: some View {
        PocketShape()
            .fill(LinearGradient(
                colors: [Color(white: 0.46).opacity(0.94), Color(white: 0.22).opacity(0.97)],
                startPoint: .topLeading,
                endPoint: .bottom
            ))
            .frame(width: size, height: size)
    }
}

/// 前袋轮廓。所有控制点都是归一化坐标（0…1 乘边长），照参考图的走向摆。
private struct PocketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }

        let radius = w * 0.19
        var path = Path()
        // 左上角起手，沿上沿向右：先平缓，再下探，最后略回收到右边。
        path.move(to: p(0.045, 0.345))
        path.addCurve(to: p(0.52, 0.395), control1: p(0.20, 0.300), control2: p(0.36, 0.345))
        path.addCurve(to: p(0.955, 0.455), control1: p(0.68, 0.445), control2: p(0.83, 0.505))
        // 右边下行 → 底部圆角 → 左边回到起点。
        path.addLine(to: p(0.955, 0.80))
        path.addQuadCurve(to: p(0.955 - radius / w, 0.955), control: p(0.955, 0.955))
        path.addLine(to: p(0.045 + radius / w, 0.955))
        path.addQuadCurve(to: p(0.045, 0.80), control: p(0.045, 0.955))
        path.closeSubpath()
        return path
    }
}
