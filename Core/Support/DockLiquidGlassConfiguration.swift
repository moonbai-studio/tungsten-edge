import CoreGraphics
import Foundation

enum DockLiquidGlassRenderPath: Equatable {
    case visualEffectFallback
    case layeredTaskbar
}

/// 液态玻璃底板的可调参数。
///
/// **这里只放「玻璃这块底板怎么画」，不放几何。** 面板高度、圆角、离屏底距一律来自
/// `DockSize.metrics` 与 `DockShape.panelCornerRadius`（`AGENTS.md`：几何的唯一来源）——
/// 玻璃自带第二套尺寸会让四档缩放失效，因为 `scale` 的定义本身就是 `panelHeight / 52`。
///
/// **也不放阴影。** 落地阴影由 SwiftUI 侧的 `.dockShadow(theme.stripShadow)` 画在内容窗口的
/// 20pt 透明边里；曾经试过改画到背景窗口的图层上，但那个窗口的 frame 正好等于底板本身，
/// 图层阴影画在窗口外会被整个裁掉 —— 净效果是玻璃态没有阴影。别再往回改。
struct DockLiquidGlassConfiguration: Equatable {
    let isEnabled: Bool
    /// `Glass.clear` 的灰色染色强度。玻璃本身太透，图标会认不出来（owner 2026-07-30 否掉
    /// 纯原生玻璃的原因），这一层是把通透度压回可用范围的主要手柄。
    let clearTintOpacity: Double
    /// 玻璃**之下**的一层加白。默认 0。
    let whiteOverlayOpacity: Double
    /// 背景窗口里那层压暗/提亮（按深浅色取黑或白）。默认 0。
    ///
    /// **只在背景窗口画一次。** 曾经内容窗口也叠了一层写死的黑，两处颜色还不一致
    /// （SwiftUI 侧恒为黑、背景窗口侧按外观切换），默认值 0 时看不出来，一调就露馅。
    let dimmingOpacity: Double
    /// 边缘高光的**峰值** alpha，出现在左上 / 右下两个角。整圈按它画，再由蒙版压下来。
    ///
    /// **不能按 `α = 78/171 ≈ 0.45` 直接算**：直边上 0.5pt 的描边正好压在一整行像素上，
    /// 圆角上它是斜的、被抗锯齿摊薄，同样的 alpha 在角上只出到约 2/3。0.75 是实测调出来的
    /// （0.45 → 角上只有 +52，0.62 → +64，0.75 → +73，配合左侧壁纸把底板基准抬高约 8，
    /// 实际已经落在原生的 +76 / +81 上）。
    ///
    /// **这是「像不像原生」最贵重的一档。** 原生 Dock 靠这一圈把轮廓从背景里勾出来；
    /// 缺了它条会糊进背景、像直接刷在屏幕上，连圆角都显得比实际方
    /// （实测钨极圆角 16pt 其实比原生的 14pt 还大，但看着更方）。
    let borderPeakOpacity: Double
    /// 四条长边相对峰值的比例。长边要的绝对 alpha 是 0.375（比底板高 +67），
    /// 除以峰值 0.75 得 0.5。**改峰值必须同步改它**，否则长边会跟着一起变亮。
    let borderEdgeLevel: Double
    /// 右上 / 左下两个角的挖除量（作用在 `borderEdgeLevel` 上）。
    /// 原生这两个角的亮线比底板只高 +5 / +7，几乎等于没有。
    let borderCornerCut: Double
    /// 角落调制的作用半径，单位是**圆角半径的倍数**（所以随档位一起缩放）。
    let borderCornerSpread: Double
    /// 描边宽度。原生实测最外那道是 1px @2x = **0.5pt**，比直觉细得多。
    let borderLineWidth: Double
    /// 紧贴外圈**内侧**再画一道更暗的，凑出原生那条两像素的亮边。
    ///
    /// 原生实测顶边剖面是 `148 → 120 → 81(底板)`：一个满像素 + 一个半档，共两像素。
    /// 只画一道时峰值一样是 148，但**视觉分量只有一半，肉眼就是「没原生亮」**
    /// （owner 2026-08-16 反馈，量出来才发现峰值其实早就对上了，差的是宽度）。
    /// 反推：底板 84 打到 120 需要 `α = (120 − 84) / (255 − 84) ≈ 0.21`。
    let borderInnerOpacity: Double
    /// 背景窗口里那层 `.menu` 材质的不透明度，用来在玻璃之外再补一点实心感。默认 0。
    let backgroundMaterialOpacity: Double
    /// 背景窗口的 WindowServer 模糊半径（SkyLight）。**默认 0 = 不用。**
    ///
    /// 这个值是照抄 BestDock 的实机层级带进来的（它那边是 6pt）。在钨极这套合成里它
    /// **只带来坏处**：WindowServer 的窗口背景模糊按**窗口矩形**生效，不跟着我们画的圆角走，
    /// 于是四个角上「圆角外、包围矩形内」那块被糊成方的，模糊本身的扩散再往外溢一圈 ——
    /// owner 2026-08-16 报「圆角外面这里会有一些问题」，A/B 到 0 之后当场消失。
    ///
    /// 而通透度**不靠它**：底板亮度由 `.glassEffect(.clear)` 加 `clearTintOpacity` 决定，
    /// 实测 blur 6 → 0 底板只从 138.4 变到 138.5。
    ///
    /// 若将来要重新启用：**必须先解决圆角** —— 要么让背景窗口本身带上圆角形状
    /// （现在只是内容图层圆角，窗口形状仍是矩形），要么别用窗口级模糊。
    /// 另外它**必须画在与玻璃宿主分离的窗口上**：直接给承载 SwiftUI glass 的同一个窗口
    /// 设这个值，会二次合成纵向光照（受控彩条实测：顶部/底部平均亮度从约 131/127
    /// 放大成 101/163）。
    let windowBlurRadius: Double
    /// 玻璃形状先外扩再内缩的量，给玻璃自己的边缘渲染留余量。
    let contentInset: Double
    /// 背景窗口根图层的黑底不透明度。**不是观感参数**：WindowServer 需要一块非零 alpha 的
    /// 形状才肯对这个窗口做背景模糊，这是给它的最小锚点。
    let backgroundPlateOpacity: Double

    func renderPath(
        isGlassAPIAvailable: Bool,
        isCompositeAvailable: Bool
    ) -> DockLiquidGlassRenderPath {
        guard isEnabled, isGlassAPIAvailable, isCompositeAvailable else {
            return .visualEffectFallback
        }
        return .layeredTaskbar
    }

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        Self(
            // **默认开**（owner 2026-08-17 转正）。此前是「默认关 + `DOCK_LIQUID_GLASS=1` 才开」，
            // 那是探路期该有的样子；观感验收通过之后再留着默认关，只会造成"跑错实例"——
            // 系统重启后自动拉起的进程不带环境变量，看到的就是没有玻璃的旧观感（真发生过）。
            // `=0` 仍是关掉它的开关，macOS 12–25 走 `renderPath` 里的毛玻璃回退，与此无关。
            isEnabled: trimmed(environment["DOCK_LIQUID_GLASS"]) != "0",
            clearTintOpacity: boundedDouble(
                environment["DOCK_LIQUID_GLASS_CLEAR_TINT"],
                range: 0 ... 1,
                fallback: 0.4
            ),
            whiteOverlayOpacity: boundedDouble(
                environment["DOCK_LIQUID_GLASS_WHITE_OVERLAY"],
                range: 0 ... 1,
                fallback: 0
            ),
            dimmingOpacity: boundedDouble(
                environment["DOCK_LIQUID_GLASS_DIMMING"],
                range: 0 ... 1,
                fallback: 0
            ),
            borderPeakOpacity: boundedDouble(
                environment["DOCK_LIQUID_GLASS_BORDER"],
                range: 0 ... 1,
                fallback: 0.75
            ),
            borderEdgeLevel: boundedDouble(
                environment["DOCK_LIQUID_GLASS_BORDER_EDGE"],
                range: 0 ... 1,
                fallback: 0.5
            ),
            borderCornerCut: boundedDouble(
                environment["DOCK_LIQUID_GLASS_BORDER_CUT"],
                range: 0 ... 1,
                fallback: 0.92
            ),
            borderCornerSpread: boundedDouble(
                environment["DOCK_LIQUID_GLASS_BORDER_SPREAD"],
                range: 0.5 ... 6,
                fallback: 2.2
            ),
            borderLineWidth: boundedDouble(
                environment["DOCK_LIQUID_GLASS_BORDER_WIDTH"],
                range: 0 ... 4,
                fallback: 0.5
            ),
            borderInnerOpacity: boundedDouble(
                environment["DOCK_LIQUID_GLASS_BORDER_INNER"],
                range: 0 ... 1,
                fallback: 0.21
            ),
            backgroundMaterialOpacity: boundedDouble(
                environment["DOCK_LIQUID_GLASS_BACKGROUND_OPACITY"],
                range: 0 ... 1,
                fallback: 0
            ),
            windowBlurRadius: boundedDouble(
                environment["DOCK_LIQUID_GLASS_WINDOW_BLUR"],
                range: 0 ... 64,
                fallback: 0
            ),
            contentInset: boundedDouble(
                environment["DOCK_LIQUID_GLASS_CONTENT_INSET"],
                range: 0 ... 12,
                fallback: 4
            ),
            backgroundPlateOpacity: 0.001
        )
    }

    private static func boundedDouble(
        _ raw: String?,
        range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard let raw = trimmed(raw),
              let value = Double(raw),
              value.isFinite,
              range.contains(value) else { return fallback }
        return value
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

enum DockLiquidGlassPanelGeometry {
    /// 背景窗口的 frame = 内容窗口去掉 20pt 阴影透明边后的**可视底板矩形**。
    ///
    /// 内容窗口保留透明边（阴影住在那里，且一批投放区/命中判定都按「窗口 frame 减
    /// shadowPadding」换算），背景窗口则要严丝合缝贴着底板，否则 WindowServer 的模糊会
    /// 从玻璃边缘漏出来。
    static func backgroundFrame(
        for contentPanelFrame: CGRect,
        shadowPadding: CGFloat
    ) -> CGRect {
        guard shadowPadding > 0 else { return contentPanelFrame }
        return contentPanelFrame.insetBy(dx: shadowPadding, dy: shadowPadding)
    }
}

enum DockLiquidGlassPanelRole: Equatable {
    case background
    case content
}

enum DockLiquidGlassPanelLifecyclePlan {
    static func ordering(
        isCompositeActive: Bool,
        shouldShow: Bool
    ) -> [DockLiquidGlassPanelRole] {
        guard isCompositeActive else { return [.content] }
        return shouldShow ? [.background, .content] : [.content, .background]
    }
}
