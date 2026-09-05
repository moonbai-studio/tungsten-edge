import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drawer Capsule Button

struct DrawerCapsuleButton: View {
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var runningApplicationStore: RunningApplicationStore
    @EnvironmentObject var drawerOrderStore: DrawerOrderStore
    @EnvironmentObject var settingsStore: AppSettingsStore
    /// 拖卡进抽屉的投放反馈：手指压在投放区时胶囊放大 + 高亮描边。
    @EnvironmentObject var dragController: DragController
    private let theme = DockThemeTokens.standard
    /// 右键胶囊 → 弹钨极菜单。胶囊是设置的**主要后路入口**：它恒在、位置固定、尺寸等于面板高度，
    /// 而且是钨极自己的部件（不属于任何 app），不像任务条底板那样只剩几条缝可点。
    var onRequestTaskbarMenu: (NSEvent, NSView) -> Void = { _, _ in }
    /// 底板走不走原生 Liquid Glass。**显式传入、无默认值**（同 `scale` / `hoverStyle`）——
    /// 胶囊是另一棵长期存活的 hosting 根视图，漏传就会出现「条是玻璃、紧挨着的胶囊还是
    /// 毛玻璃」这种一眼可见的不一致。
    let usesLiquidGlass: Bool
    let action: () -> Void

    @State private var isHovering = false
    /// 点击确认脉冲：按压回弹，纯视图层信号，不喂 planner/frontmost（照搬 ChipView）。
    @State private var isTapPressed = false

    // 九宫格 3 列：3×icon + 2×spacing + 2×padding 必须塞得进胶囊宽度（= 面板高度）。
    // 中档 3×9 + 2×4 + 2×6 = 47pt，小档胶囊只有 44pt，所以这三个值都必须跟着缩。
    private static let iconSize: CGFloat = 9
    private static let gridSpacing: CGFloat = 4
    private static let gridPadding: CGFloat = 6

    private var iconSize: CGFloat { Self.iconSize * dockScale }
    private var gridSpacing: CGFloat { Self.gridSpacing * dockScale }

    private var folderIDs: [String] {
        let placements = AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
        let ordered = drawerOrderStore.reconciled(members: placements)
        return AppMembershipProjection.drawerPreview(
            drawerIDs: ordered,
            keptIDs: keptAppStore.bundleIDs,
            runningIDs: runningApplicationStore.runningBundleIDs
        )
    }

    /// 胶囊是**另一棵**长期存活的 NSHostingView 根视图，必须自己观察同一个 store，
    /// 否则换档时任务条变了、胶囊里的九宫格还停在旧尺寸。
    private var dockScale: CGFloat { settingsStore.dockSize.scale }

    var body: some View {
        // 拖动时 hover 让位给拖入反馈：draggingPayload 非空则不弹（drag 优先）。
        let showsHover = isHovering && dragController.draggingPayload == nil
        return ZStack {
            DockPanelBackdrop(theme: theme,
                              cornerRadius: DockShape.panelCornerRadius * dockScale,
                              usesLiquidGlass: usesLiquidGlass)

            // 悬停 + 点击反馈只作用在内层预览内容（九宫格 / 空态符号）上，外框（毛玻璃 + 描边）不动。
            // 围绕胶囊中心原地缩放，动画结束精确归位、不留持久位移。
            Group {
                if folderIDs.isEmpty {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 20 * dockScale, weight: .medium))
                        .foregroundStyle(theme.capsuleGlyph.color)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(iconSize), spacing: gridSpacing), count: 3),
                        spacing: gridSpacing
                    ) {
                        ForEach(folderIDs, id: \.self) { id in
                            Image(nsImage: AppIconResolver.icon(for: id))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: iconSize / 4, style: .continuous))
                        }
                    }
                    .padding(Self.gridPadding * dockScale)
                }
            }
            .scaleEffect(showsHover ? 1.07 : 1.0)
            .animation(.easeOut(duration: 0.12), value: showsHover)
            // 按压只作用在里面的九宫格上、外框保持静止（owner 2026-06-21）——所以缩放挂在这里，
            // 手势挂在最外层（见下方 chipPressGesture）。
            .chipPressScale(isTapPressed)
        }
        .dockPanelRim(cornerRadius: DockShape.panelCornerRadius * dockScale,
                      style: theme.panelRimStyle,
                      lineWidth: theme.panelRimLineWidth,
                      usesLiquidGlass: usesLiquidGlass)
        // 反馈仅作用于内层预览内容（见上方 Group）；这里与面板同高的可见层只负责 hover 命中——
        // 鼠标移到胶囊任意处都触发，动的是里面的九宫格，外框保持静止。
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // 拖卡悬到胶囊上：**微微发光 + 极轻微放大**（去掉原来生硬的白圈描边,owner 2026-06-21）。
        .scaleEffect(dragController.isOverStashZone ? 1.04 : 1.0)
        .dockGlow(theme.capsuleStashGlow, radius: 5, active: dragController.isOverStashZone)
        .animation(.easeInOut(duration: DrawerAnimation.duration), value: dragController.isOverStashZone)
        .dockShadow(theme.stripShadow)
        .padding(PanelCoordinator.shadowPadding)
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .chipPressGesture(isPressed: $isTapPressed)
        // MenuHostNSView 只认右键 / Control-click，左键一律返回 nil 穿透下去，
        // 所以上面那条「点胶囊开抽屉」不受影响。
        .overlay(NativeMenuHost(popUpHandler: onRequestTaskbarMenu))
    }
}
