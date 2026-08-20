import AppKit
import SwiftUI

/// 固定文件夹 chip：扁平单封面（无堆叠纸片），尺寸与其他 chip 一致。
/// 封面是该文件夹当前排序第一张文件的缩略图（PinnedFolderCoverStore 供图；空文件夹/无缩略图时是图标）。
/// 名称常驻在封面下方，长名截断并用 .help 提供全名。
/// 点击一律 onTapGesture（nonactivatingPanel 上勿用 Button）；右键 = 手搓 NSMenu。
struct PinnedFolderChip: View {
    /// 文件夹卡宽度。**不等于条高**——它是文件夹名的容身空间（名字截断上限 48pt）。
    static let chipWidth: CGFloat = 52

    let path: String
    let cover: FolderCover?
    /// 当前排序方式（菜单打勾用;menu builder 每次右键现建,读到的总是最新值）。
    let sortOrder: FolderSortOrder
    let onTap: () -> Void
    /// 内容预览（右键「预览内容」；左键在 preview 模式下也走这个）。
    let onPreview: () -> Void
    /// 打开该路径访达窗口（右键「在访达中打开」；左键在 openFinderWindow 模式下也走这个）。
    let onOpenInFinder: () -> Void
    let onAddFolder: () -> Void
    let onRemove: () -> Void
    let onSetSortOrder: (FolderSortOrder) -> Void
    var isDropTarget = false
    /// 任务条尺寸档位的缩放系数。中档 = 1.0，此时所有尺寸与历史字面值逐像素相同。
    /// **故意不给默认值**——漏传必须是编译错误，见 AGENTS《Taskbar Size Tiers》。
    let scale: CGFloat
    /// 悬停效果档位。**同样故意不给默认值**——漏传必须是编译错误，理由同 `scale`。
    let hoverStyle: HoverStyle
    /// 指针在不在这张卡上。由任务条整条那块跟踪区算好后传进来（见 `StripHoverResolution`）；
    /// 拖动载体传 `false`。**故意不给默认值**，理由同 `scale` / `hoverStyle`。
    let isHovered: Bool

    private let theme = DockThemeTokens.standard

    /// 悬停视觉的总闸：「安静」档下恒 false，整块放大不再发生。
    /// 投放高亮（`isDropTarget`）不受它管——那是拖放反馈，不是悬停。
    private var showsHover: Bool { hoverStyle.isExpressive && isHovered }
    /// 本格**两档都放大**：安静档 2026-08-17 补悬停反馈时选的形式正好就是整块放大，
    /// 和这里既有的做法撞在一起，那就用同一条，不必为安静档另叠一个缩放。
    /// 幅度也不分档——分了反而要解释「为什么关掉名字之后放大得少一点」。
    private var showsHoverScale: Bool { showsHover || hoverStyle.showsQuietHoverFeedback(isHovering: isHovered) }
    /// 悬停整块放大的倍数（底锚）。**起拖姿态也读它**（`DockStripView.pickUpPose`）：
    /// 载体第一帧要按卡槽此刻的放大摆，写成两份数字就会漂。
    static let hoverScale: CGFloat = 1.12

    private var folderName: String {
        FileManager.default.displayName(atPath: path)
    }

    var body: some View {
        let coverSize: CGFloat = 26 * scale
        VStack(spacing: 2 * scale) {
            Spacer(minLength: 0)
            coverImage(size: coverSize)
                .overlay {
                    RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                        .strokeBorder(theme.folderDropRing.color(active: isDropTarget), lineWidth: 1.5)
                }
                .scaleEffect(isDropTarget ? 1.08 : 1)
            Text(folderName)
                .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(theme.labelHover.color)
                // **常驻**的裸文字，受背景影响比那些悬停标签更久。见 DockThemeTokens.labelHalo
                .dockShadow(theme.labelHalo)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 48 * scale)
            Spacer(minLength: 0)
        }
        // 高度跟着条高走（卡必须撑满条高）；宽度是文件夹名的容身空间，与条高无关，
        // 所以 2026-08-16 条高 52→54 时**只动高度**，不跟着变宽——加宽会挪动整个文件夹区
        // 和外部拖放的命中带。
        .frame(width: Self.chipWidth * scale, height: ChipPillMetrics.chipHeight * scale)
        .contentShape(Rectangle())
        // 悬停：整个 chip 放大上顶（原生 Dock 手感）。anchor .bottom 让底部名称基本不动、封面往上顶起。
        // scaleEffect 只是渲染变换，不改布局 frame——拖放命中读的是 .background GeometryReader 上报的未缩放 frame，不受影响。
        .scaleEffect(showsHoverScale ? Self.hoverScale : 1, anchor: .bottom)
        .onTapGesture { onTap() }
        .nativeContextMenu { buildMenu() }
        .help(folderName)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .animation(.easeOut(duration: 0.12), value: showsHoverScale)
    }

    /// 封面：真缩略图方形裁切 + 细描边（深色下是白、浅色下是黑）；文件图标 / 空文件夹图标 fit 渲染不裁不描边。
    /// 缩略图**满铺无留白**,视觉比 app 图标(.fit 自带约 20% 留白)大,故按 5/6 缩到其可见方块尺寸；
    /// 图标自带留白、本就与 app 图标同口径,维持 size 不缩。
    @ViewBuilder
    private func coverImage(size: CGFloat) -> some View {
        if let cover, cover.isThumbnail {
            // 真缩略图：方形裁切 + 细描边（缩到 app 图标可见方块尺寸;圆角 thumb/4）。
            let thumb = size * 5 / 6
            Image(nsImage: cover.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: thumb, height: thumb)
                .clipShape(RoundedRectangle(cornerRadius: thumb / 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: thumb / 4, style: .continuous)
                        .strokeBorder(theme.folderThumbHairline.color, lineWidth: 0.5)
                )
                .frame(width: size, height: size)
        } else {
            // 图标（文件图标垫底 / 空文件夹的文件夹图标）：fit 渲染,不裁不描边。
            Image(nsImage: cover?.image ?? PinnedFolderCoverStore.icon(forPath: path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "Preview Contents")) { onPreview() })
        menu.addItem(ClosureMenuItem(String(localized: "Open in Finder")) { onOpenInFinder() })
        menu.addItem(.separator())
        // 排序方式 ▸（原生 Stacks 同款）：弹窗网格与 chip 封面都跟随,逐文件夹记忆。
        let sortItem = NSMenuItem(title: String(localized: "Sort by"), action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        for order in FolderSortOrder.allCases {
            let item = ClosureMenuItem(order.menuTitle) { onSetSortOrder(order) }
            item.state = order == sortOrder ? .on : .off
            sortMenu.addItem(item)
        }
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Add Folder…")) { onAddFolder() })
        menu.addItem(ClosureMenuItem(String(localized: "Remove from Taskbar")) { onRemove() })
        return menu
    }
}
