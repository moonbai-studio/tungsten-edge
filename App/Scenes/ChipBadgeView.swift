import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chip Badge

/// Classic Dock-style unread badge: red capsule, white text, top-right of the chip.
/// Renders whatever string the app put on its Dock tile ("3", "99+", "•") as-is.
/// Not a hit target — taps fall through to the chip underneath.
///
/// **它由 chip 自己画（`ChipView.bareIconChip` / `LauncherChip` 的 overlay），不是由调用方
/// 套一层 ZStack 叠上去的。** 2026-08-17 之前是后者，于是它落在 `chipQuietHoverScale` 的
/// **外面**：安静档悬停时图标放大 10%，红点纹丝不动（owner 实测两帧都是 16×15pt），
/// 看着像图标从红点底下鼓出来。放进 chip 里之后，悬停放大、按压回缩、档位缩放它全都跟着走。
///
/// 尺寸常量在 `ChipPillMetrics.badge*`，中档与历史字面值逐字相同。
struct ChipBadgeView: View {
    let text: String
    /// 档位系数。**故意不给默认值**——同 `scale` / `hoverStyle` 那条铁律。
    let scale: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: ChipPillMetrics.badgeFontSize * scale, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, ChipPillMetrics.badgeHorizontalPadding * scale)
            .frame(minWidth: ChipPillMetrics.badgeMinimumSize * scale,
                   minHeight: ChipPillMetrics.badgeMinimumSize * scale)
            .background(
                Capsule().fill(Color(red: 1.0, green: 0.23, blue: 0.19))   // Apple badge red
            )
            .overlay(
                // 0.5pt 是发丝线，和分隔线同理，不随档位缩放。
                Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
            )
            // 原生的角标大部分压在图标上，只稍稍探出圆角：卡片 40×54、可见图标方块 32.5，
            // 这个下推量让角标中心正好落在图标右上角内侧。
            .offset(x: 0, y: ChipPillMetrics.badgeTopOffset * scale)
            .allowsHitTesting(false)
    }
}
