import CoreGraphics

/// 任务条尺寸档位。**按面板高度定档，缩放系数反推**——反过来（先定 0.85 这类系数再算高度）
/// 会得到 44.2 这种高度，圆角、图标和分隔线全落在半像素上。
enum DockSize: String, CaseIterable {
    case small
    case medium
    case large
    case extraLarge

    static let `default` = DockSize.medium

    /// 四档相差 8pt，中档对齐原生 Dock。
    ///
    /// **中档 2026-08-16 由 52 改成 54，对齐原生 macOS 26 Dock 实测值**（owner 拍板）。
    /// 同一轮里图标从 36 跟到 40（`ChipHoverVisual.bareIconSize`），两者要一起改：
    /// 原生实测 @2x 截图为条高 108px = 54pt、图标上下留白各 21px = 10.5pt，
    /// 而 (54 − 40) / 2 = 7pt 标称留白 + 苹果图标资源自带的约 18% 透明边距，正好还原 10.5pt。
    /// 单改一个会让图标/条高比偏离原生的 0.741。
    ///
    /// 这推翻了此前「中档必须逐字节等于 2026-07-30 之前」的冻结契约。
    var panelHeight: CGFloat {
        switch self {
        case .small: return 46
        case .medium: return 54
        case .large: return 62
        case .extraLarge: return 70
        }
    }

    /// 所有随档位缩放的尺寸都乘它。中档恒为 `1.0`。
    var scale: CGFloat { panelHeight / DockSize.medium.panelHeight }

    var title: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        case .extraLarge: return String(localized: "Extra Large")
        }
    }

    /// 面板几何的唯一来源：AppKit 侧（PanelCoordinator）和 SwiftUI 侧都从这里取，
    /// 不各自算一份。
    var metrics: PanelLayoutMetrics {
        PanelLayoutMetrics(
            panelHeight: panelHeight,
            // 阴影边距**不随档位缩放**：阴影 token 是冻结的（深色那套本来就已经超预算 3pt），
            // 跟着缩会动到已经定稿的观感。
            shadowPadding: PanelLayoutMetrics.shadowPadding,
            // 写成表达式而不是字面值：以前 52 + 2×20 = 92 这层关系只存在于注释里，
            // 改高度时极易漏掉窗口高度。
            windowHeight: panelHeight + 2 * PanelLayoutMetrics.shadowPadding,
            bottomGap: 8,
            outerMargin: 12,
            capsuleWidth: panelHeight,
            capsuleGap: 8,
            minimumDockWidth: 120 * scale,
            minimumDrawerExtent: 120
        )
    }
}

struct PanelLayoutMetrics: Equatable {
    var panelHeight: CGFloat
    var shadowPadding: CGFloat
    var windowHeight: CGFloat
    var bottomGap: CGFloat
    var outerMargin: CGFloat
    var capsuleWidth: CGFloat
    var capsuleGap: CGFloat
    var minimumDockWidth: CGFloat
    var minimumDrawerExtent: CGFloat

    /// 固定值，不随档位变（见 `DockSize.metrics` 的说明）。
    static let shadowPadding: CGFloat = 20

    /// 中档，仅作为既有默认参数与单测的基线；真正的取值走 `DockSize.metrics`。
    static let tungstenEdge = DockSize.medium.metrics
}

struct PanelScreenGeometry: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat

    /// The drawer's top cap still follows top system UI. On displays without a notch,
    /// this usually tracks visibleFrame.maxY and may change when the menu bar auto-hides.
    /// On notched displays, the safe-area cap can take over once the menu bar is hidden,
    /// so the same known edge can be smaller there than on external displays.
    var topUsableY: CGFloat {
        min(visibleFrame.maxY, frame.maxY - safeAreaTop)
    }
}

enum PanelGeometry {
    static let windowTitleTooltipScreenMargin: CGFloat = 8
    /// 阴影留白**不随档位缩放**：气泡的阴影 token 本身是固定的，跟着缩会动到定稿的观感。
    /// 视图侧和这里必须用同一个值（视图 `.padding(它)`，这里再减回去）。
    static let windowTitleTooltipShadowPadding: CGFloat = 8

    static func dockTargetFrame(
        contentWidth: CGFloat,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGRect {
        let maxWidth = screen.frame.width - 2 * (metrics.outerMargin + metrics.capsuleGap + metrics.capsuleWidth)
        let panelWidth = max(min(contentWidth, maxWidth), metrics.minimumDockWidth)
        let x = screen.frame.minX + (screen.frame.width - panelWidth) / 2
        return CGRect(
            x: x - metrics.shadowPadding,
            y: screen.frame.minY + metrics.bottomGap - metrics.shadowPadding,
            width: panelWidth + metrics.shadowPadding * 2,
            height: metrics.windowHeight
        )
    }

    static func capsuleTargetFrame(
        forDock dockFrame: CGRect,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGRect {
        let rawX = dockFrame.maxX - metrics.shadowPadding + metrics.capsuleGap
        let rawY = dockFrame.minY + metrics.shadowPadding + (metrics.panelHeight - metrics.capsuleWidth) / 2
        let clampedX = min(max(rawX, screen.frame.minX), screen.frame.maxX - metrics.capsuleWidth)
        let clampedY = min(max(rawY, screen.frame.minY), screen.frame.maxY - metrics.capsuleWidth)
        return CGRect(
            x: clampedX - metrics.shadowPadding,
            y: clampedY - metrics.shadowPadding,
            width: metrics.capsuleWidth + metrics.shadowPadding * 2,
            height: metrics.capsuleWidth + metrics.shadowPadding * 2
        )
    }

    /// 弹窗锚定+钳位的**单一真相**：给定"期望中心 X / 期望底边 Y / 尺寸"，算出贴屏钳位后的 origin。
    /// folderPopupTargetFrame（首帧/重定位）和切换动画的每帧插值都走它，避免钳位规则在两处各写一份漂移。
    static func folderPopupClampedOrigin(
        desiredCenterX: CGFloat,
        desiredBottomY: CGFloat,
        size: CGSize,
        on screen: PanelScreenGeometry
    ) -> CGPoint {
        let bottom = max(desiredBottomY, screen.frame.minY)
        let x = min(max(desiredCenterX - size.width / 2, screen.frame.minX), screen.frame.maxX - size.width)
        return CGPoint(x: x, y: bottom)
    }

    /// 固定文件夹弹窗：锚点（chip 可视矩形，屏幕坐标）上方 8pt，水平居中钳进屏，
    /// 只向上生长、topUsableY 封顶——同 drawer 的底锚策略。`size` 为含阴影的整面板尺寸。
    static func folderPopupTargetFrame(
        anchorVisibleRect: CGRect,
        size: CGSize,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGRect {
        let origin = folderPopupClampedOrigin(
            desiredCenterX: anchorVisibleRect.midX, desiredBottomY: anchorVisibleRect.maxY + 8,
            size: size, on: screen)
        let height = min(size.height, max(metrics.minimumDrawerExtent, screen.topUsableY - origin.y))
        return CGRect(x: origin.x, y: origin.y, width: size.width, height: height)
    }

    static func maxFolderPopupContentHeight(
        anchorVisibleRect: CGRect,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGFloat {
        let bottom = anchorVisibleRect.maxY + 8
        return max(metrics.minimumDrawerExtent, (screen.topUsableY - bottom) - 2 * metrics.shadowPadding)
    }

    /// Window-title tooltip panel frame. The panel includes transparent padding for its SwiftUI
    /// shadow, while the visible bubble stays 8pt above the pill and 8pt inside the screen edges.
    /// `tipGap` = 气泡**尖端**到锚点顶边的距离，随档位缩放，由调用方从
    /// `WindowTitleTooltipStyle.tipGap` 传进来——系数只在样式那一处算，这里不再算第二遍。
    static func windowTitleTooltipTargetFrame(
        anchorVisibleRect: CGRect,
        size: CGSize,
        tipGap: CGFloat,
        on screen: PanelScreenGeometry
    ) -> CGRect {
        let inset = windowTitleTooltipShadowPadding
        let visibleWidth = max(0, size.width - 2 * inset)
        let visibleHeight = max(0, size.height - 2 * inset)
        let minVisibleX = screen.frame.minX + windowTitleTooltipScreenMargin
        let maxVisibleX = screen.frame.maxX - windowTitleTooltipScreenMargin - visibleWidth
        let desiredVisibleX = anchorVisibleRect.midX - visibleWidth / 2
        let visibleX = min(max(desiredVisibleX, minVisibleX), maxVisibleX)
        let desiredVisibleY = anchorVisibleRect.maxY + tipGap
        let maxVisibleY = screen.topUsableY - visibleHeight
        let visibleY = min(desiredVisibleY, maxVisibleY)

        return CGRect(
            x: visibleX - inset,
            y: visibleY - inset,
            width: size.width,
            height: size.height
        )
    }

    static func drawerTargetFrame(
        forCapsule capsuleFrame: CGRect,
        size: CGSize,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGRect {
        let bottom = max(capsuleFrame.maxY - metrics.shadowPadding + 8, screen.frame.minY)
        let height = min(size.height, max(metrics.minimumDrawerExtent, screen.topUsableY - bottom))
        let rawX = capsuleFrame.maxX - size.width
        let clampedX = min(max(rawX, screen.frame.minX), screen.frame.maxX - size.width)
        return CGRect(x: clampedX, y: bottom, width: size.width, height: height)
    }

    static func maxDrawerContentHeight(
        forCapsule capsuleFrame: CGRect,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGFloat {
        let drawerBottomY = capsuleFrame.maxY - metrics.shadowPadding + 8
        return max(metrics.minimumDrawerExtent, (screen.topUsableY - drawerBottomY) - 2 * metrics.shadowPadding)
    }
}
