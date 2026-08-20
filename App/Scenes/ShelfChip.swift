import AppKit
import SwiftUI

/// 中转格：固定在文件夹区头位的暂存格。
/// 拖文件到格上松手即暂存（引用不搬家），点击弹出暂存网格。**不可拖拽**（固定头位）。
/// 视觉上采用普通 app 图标的圆角与阴影风格，不再使用文件夹的堆叠样式。
/// 数量**不做外凸角标**，改成悬停名字气泡里的文字，避免与固定区其余 chip 的"零装饰"视觉基调冲突。
struct ShelfChip: View {
    let itemCount: Int
    let isDropTargeted: Bool
    /// 任务条尺寸档位的缩放系数。中档 = 1.0，此时所有尺寸与历史字面值逐像素相同。
    /// **故意不给默认值**——漏传必须是编译错误，见 AGENTS《Taskbar Size Tiers》。
    let scale: CGFloat
    /// 悬停效果档位。**同样故意不给默认值**——漏传必须是编译错误，理由同 `scale`。
    let hoverStyle: HoverStyle
    /// 指针在不在这格上。由任务条整条那块跟踪区算好后传进来（见 `StripHoverResolution`）。
    let isHovered: Bool
    let onTap: () -> Void
    let onClear: () -> Void
    let onAddFolder: () -> Void

    private let theme = DockThemeTokens.standard

    /// 悬停视觉的总闸：「安静」档下恒 false，图标不缩、名字气泡不出。
    /// 投放反馈（`isDropTargeted` 的提亮/描边/发光）不受它管。
    private var showsHover: Bool { hoverStyle.isExpressive && isHovered }
    /// 安静档的悬停反馈（标准档恒 false）。见 `HoverStyle.showsQuietHoverFeedback`。
    private var quietHoverFeedback: Bool {
        hoverStyle.showsQuietHoverFeedback(isHovering: isHovered)
    }

    /// 件数原本只写在悬停名字里，安静档下那行不出现，所以并进系统 tooltip 兜底。
    /// 两档都生效，条上不改变任何像素。
    private var helpText: String {
        itemCount > 0
            ? String(format: String(localized: "Shelf · %d — drag files here to park them"), itemCount)
            : String(localized: "Shelf — drag files here to park them")
    }

    var body: some View {
        VStack(spacing: 2 * scale) {
            Spacer(minLength: 0)
            shelfIcon
            Spacer(minLength: 0)
        }
        .frame(width: ChipPillMetrics.cardWidth * scale,
               height: ChipPillMetrics.chipHeight * scale)
        .chipQuietHoverScale(quietHoverFeedback,
                             cardWidth: ChipPillMetrics.cardWidth * scale,
                             scale: scale)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .nativeContextMenu { buildMenu() }
        .help(helpText)
        .animation(.easeInOut(duration: 0.18), value: showsHover)
        .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
    }

    /// 固定入口图标。
    ///
    /// **必须是不透明的实心块。** 2026-08-16 之前它是「半透明染色底板 + 符号」，
    /// 而底板的填充在浅色主题里是**加黑的低透明度**——玻璃底下一暗，黑压黑就没了
    /// （owner 报「中转站在深色底看不清」）。条上别的 chip 全是不透明满色的应用图标，
    /// 它是唯一一个不是的，所以只有它会消失。
    ///
    /// 改法照原生 Dock 的「下载」：和邻居同一种物质——不透明、满色，而不是半透明染色底板。
    ///
    /// **尺寸要按 `bareIconVisibleSlot`（32.5pt）画，不是槽位的 40pt。** 苹果的图标资源自带
    /// 约 18% 透明边距，条上的图标间缝就是这么来的；我们自绘的图形没有那圈边距，
    /// 按 40 画就会比邻居明显大一圈（owner 报的「太突兀」有一半是大小，不只是颜色）。
    ///
    /// 默认档是矢量自绘的 `ShelfTrayArt`（owner 给了参考图）；另外三档是「纯色瓷砖 + SF 符号」
    /// 的退路，`DOCK_SHELF_TILE=graphite|blue|light` 现场换，不用重编译。
    private var shelfIcon: some View {
        let art = ChipPillMetrics.bareIconVisibleSlot * scale
        let style = theme.effectiveShelfTile
        return Group {
            if style.isIllustration {
                ShelfTrayArt(size: art, lifted: isDropTargeted)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: art * 0.215, style: .continuous)
                        .fill(style.gradient(lifted: isDropTargeted))
                    Image(systemName: "tray.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: art * 0.5, height: art * 0.5)
                        .foregroundStyle(style.glyphColor)
                }
                .frame(width: art, height: art)
            }
        }
        // 槽位仍是 40pt，与所有图标卡一致——只有画出来的方块缩到 32.5。
        .frame(width: ChipPillMetrics.bareIconSlot * scale,
               height: ChipPillMetrics.bareIconSlot * scale)
        // 和图标一样不带外投影（owner 2026-08-19）。这块比图标更容易让人想「加点投影托一下」——
        // 它本来就靠不透明 + 自绘底板站住（见 `DockThemeTokens.shelfTile`），不靠投影。
        .dockGlow(theme.shelfDropGlow, radius: 3, active: isDropTargeted)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "Open Shelf")) { onTap() })
        if itemCount > 0 {
            menu.addItem(ClosureMenuItem(String(localized: "Clear Shelf")) { onClear() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Add Folder…")) { onAddFolder() })
        return menu
    }
}
