import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chip View

struct ChipView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var appMembershipController: AppMembershipController
    private let theme = DockThemeTokens.standard
    let item: StripItem
    /// 卡上要显示的那行字，由投影层算好（去掉应用名后缀 + 同一应用几张卡的公共段，issue #41）。
    /// **故意不给默认值**：漏传会静默显示成未处理的长标题，而这里所有测试都是纯几何、
    /// 没有一个检查 SwiftUI 调用点——缺的那个默认值就是回归测试本身（同 `scale` 那条铁律）。
    /// 完整标题走 `fullTitle`，只给 `.help()` 的系统 tooltip。
    let labelTitle: String
    /// 档位系数（`DockSize.scale`）。**故意不给默认值**：消息区曾因为它有默认值 1.0 而静默漏传，
    /// 在非中档下渲染成中档尺寸（见 AGENTS《Taskbar Size Tiers》）。漏传必须是编译错误。
    let scale: CGFloat
    /// 悬停效果档位。**同样故意不给默认值**——漏传是编译错误，理由见上面 `scale` 那条。
    /// `.quiet` 下悬停不产生任何视觉变化；长标题的全文浮层不受影响（它跟的是裸 `isHovering`）。
    let hoverStyle: HoverStyle
    /// 指针在不在这张卡上。**由任务条整条那块跟踪区算好后传进来**，卡片自己不再挂 `.onHover`
    /// （漏格 + 边界带方向，成因与实测见 `StripHoverResolution`）。同样故意不给默认值。
    let isHovered: Bool
    /// 右键菜单顶部要不要列 Dock 式窗口列表。只有「一个图标代表整个应用」的入口才 true
    ///（live 区 = `item.isAppLevelFallback`，消息区主窗卡 = 恒 true）；普通窗口卡自己就是
    /// 那个窗口，恒 false。**故意不给默认值**——漏传必须是编译错误（同 `scale` 那条铁律）。
    let showsWindowListInMenu: Bool
    var iconOnly: Bool = false
    var showRunningDot: Bool = false
    /// 见 `EnvironmentValues.isDragCarrierSnapshot`：拍副本时不画圆点、不烘投影。
    @Environment(\.isDragCarrierSnapshot) private var isDragCarrierSnapshot
    var drawerTap: (() -> Void)? = nil
    /// 外部手势（重击/中键预览）触发的脉冲信号：nonce 变化即触发一次 fireTapPulse，
    /// 给活访达窗口预览那 ~200ms 反查延迟一个"点到了"的即时确认。默认 0 = 不脉冲。
    var pulseNonce: Int = 0
    /// 未读角标文本（消息应用的卡：消息区那枚图标，或常规区最左那张），`nil` = 不画。默认 `nil` 是**正确**的省略语义
    /// （绝大多数 chip 本来就没有角标），所以这一个可以有默认值——和 `scale` /
    /// `hoverStyle` 那种"漏传即静默渲染错"的性质不同。
    /// 画在 chip 内部而不是由调用方叠 ZStack，理由见 `ChipBadgeView`。
    var badgeText: String? = nil
    /// 这张卡的卡槽此刻是不是因为**正被拎在手里**而空着（`DragController.hiddenSlotPayload`）。
    /// 一变 true 就把按压缩放清掉：条内重排会挪动这张卡、SwiftUI 随即取消按压手势，
    /// `isTapPressed` 只能靠 1s 看门狗复位——落地显形那一刻它可能还是 0.93 或正在弹回，
    /// 和以 1.0 停稳的载体差一截（owner 2026-08-19「落位抖动」的成分之一）。卡藏着时清，
    /// 显形时必是 1.0。默认 `false` 是正确的省略语义（不拖动的卡不需要它），同 `badgeText`。
    var slotHidden: Bool = false
    /// 点击确认脉冲：与状态无关的按压回弹。激活「已可见」窗口在亮/暗轴上零变化,
    /// 没有它就"毫无反应"（owner 2026-07-06）。纯视图层信号,永不喂 planner/frontmost 轴（AGENTS）。
    /// 声明式 .animation(value:) 驱动（LauncherChip 僵尸动画教训:禁 repeatForever+复位）。
    @State private var isTapPressed = false

    /// Visual hover state: the real pointer hover OR forced (drag copy)，再受悬停档位一道总闸。
    /// 「安静」档下恒 false，于是图标不缩、应用名不冒、胶囊底色不提亮、整行不重排。
    private var showsHover: Bool { hoverStyle.showsExpressiveHover(isHovering: isHovered) }
    /// 安静档的悬停反馈（标准档恒 false，那一档的反馈是名字气泡）。
    private var quietHoverFeedback: Bool {
        hoverStyle.showsQuietHoverFeedback(isHovering: isHovered)
    }
    private var animationTraceKind: String {
        !iconOnly && (item.showsTitle || isMessagingAppWindow) ? "window" : "icon"
    }

    /// 按压状态的诊断出口。状态机本身在 `ChipPressFeedback` 里，这里只补 trace。
    private func recordPressEvent(_ pressed: Bool) {
        ChipAnimationTrace.event(
            chipID: item.id,
            kind: animationTraceKind,
            event: ChipAnimationTraceEvent.tap(pressed),
            isTapPressed: pressed,
            showsHover: showsHover
        )
    }

    private func recordHoverEvent(_ hovering: Bool) {
        ChipAnimationTrace.event(
            chipID: item.id,
            kind: animationTraceKind,
            event: ChipAnimationTraceEvent.hover(hovering),
            isTapPressed: isTapPressed,
            showsHover: hoverStyle.isExpressive && hovering
        )
    }

    /// 乐观态优先（交互打磨 2026-06-13）：点击瞬间 chip 立刻按预测态渲染
    ///（minimize → 变暗），不等快照 round-trip，也不再转圈。
    private var effectiveStatus: String {
        runtime.optimisticStatesByWindowID[item.actionWindowID]?.status.rawValue ?? item.status
    }

    private var effectiveIsOnDesktop: Bool {
        guard let optimistic = runtime.optimisticStatesByWindowID[item.actionWindowID] else {
            return item.isOnDesktop
        }
        return optimistic.status == .active
    }

    private var isMessagingAppWindow: Bool {
        guard let bid = item.bundleIdentifier else { return false }
        return !item.isAppLevelFallback && messagingStore.contains(bid)
    }

    var body: some View {
        Group {
            if !iconOnly && (item.showsTitle || isMessagingAppWindow) {
                multiWindowChip
            } else {
                bareIconChip
            }
        }
        .animation(.easeInOut(duration: 0.2), value: item.showsTitle)
        // 卡槽一空就清按压（理由见 `slotHidden`）。卡此刻透明，这次回弹没人看得见。
        .onChange(of: slotHidden) { hidden in
            if hidden, isTapPressed { isTapPressed = false }
        }
    }

    // MARK: - Icon-only chip

    private var bareIconChip: some View {
        let capturedFullTitle = fullTitle
        // **纯图标卡的悬停不改变任何像素**，所以这里不挂动画驱动器。
        //
        // 应用名挪进图标上方的气泡之后，图标不再缩、槽位不再变，图标也从不按状态淡化
        // （owner 2026-08-02）——`ChipHoverProgress` 剩下的唯一作用是让一个可动画标量
        // 跑满 0.18s，每次悬停进出白白重算十来帧。横扫一排图标时这笔开销叠在主线程上，
        // 而主线程一忙 macOS 就**合并鼠标移动事件**，中间掠过的格子根本收不到悬停回调
        // ——正是 owner 说的「匀速划过很多来不及显示」。同一个机制在菜单上咬过一次，
        // 见 AGENTS《Menus, Panels, And Screens》那条 100ms 粘滞。
        //
        // 带标题的卡仍然要它：药丸底与描边的提亮是真的在动。
        let hover = ChipHoverVisual.resolve(progress: 0, scale: scale)
        let _ = ChipAnimationTrace.record(
            chipID: item.id,
            kind: "icon",
            visual: hover,
            isTapPressed: isTapPressed,
            showsHover: showsHover
        )
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            appIcon(size: hover.bareIconSize)
            // 槽位高度必须等于**静息**图标尺寸：这个 ZStack 是 .top 对齐的，
            // 槽位小于图标就会整块往下溢出（写死 36 而图标改成 40 时实测下移 4pt）。
            .frame(width: ChipPillMetrics.cardWidth * scale,
                   height: ChipPillMetrics.bareIconSlot * scale,
                   alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(width: ChipPillMetrics.cardWidth * scale,
               height: ChipPillMetrics.chipHeight * scale)
        // 拖起来的副本不画圆点（原生 Dock 同款：拖动时圆点消失，落位才回来）。
        // 位图在圆点那块因此是**透明**的，交接那一轮条上卡的圆点直接透出来——不会闪也不会晚。
        .overlay(alignment: .bottom) {
            if showRunningDot && !isDragCarrierSnapshot {
                Circle()
                    .fill(theme.runningDot.color)
                    .frame(width: 4, height: 4)
                    .padding(.bottom, 2)
            }
        }
        // 未读角标：**必须挂在两个缩放之前**，否则图标放大 / 按下回缩时它一动不动
        // （owner 2026-08-17 报「图标变大后数字红点是不是也要有变化」）。
        .overlay(alignment: .topTrailing) {
            if let badgeText {
                ChipBadgeView(text: badgeText, scale: scale)
            }
        }
        // 安静档的悬停反馈：整块轻微放大。放在运行点 overlay **之后**，图标和点一起放大；
        // 放在 `chipPressScale` 之前，按下去时两个缩放叠乘，像同一块东西被按住。
        // 卡宽 40 → 封顶规则算出 1.15、被上限截回 1.10，图标卡的观感一个像素不变。
        .chipQuietHoverScale(quietHoverFeedback,
                             cardWidth: ChipPillMetrics.cardWidth * scale,
                             scale: scale)
        .chipPressScale(isTapPressed)
        // 悬停既不由这张卡自己测、气泡也不由它自己发——两件事都归任务条那块整条跟踪区
        // （`StripHoverResolution`）。卡片这里只剩"照着 `isHovered` 画"。
        .contentShape(Rectangle())
        .onChange(of: isHovered) { recordHoverEvent($0) }
        .onTapGesture {
            if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.actionWindowID) }
        }
        // 按压跟着**按下**走，不再等 onTapGesture（那是鼠标抬起才触发的）。挂在 contentShape
        // 之后，命中区域与点击完全一致。
        .chipPressGesture(
            isPressed: $isTapPressed,
            pulseNonce: pulseNonce,
            onEvent: recordPressEvent
        )
        .nativeContextMenu { buildChipMenu() }
        .help(capturedFullTitle)
    }

    // MARK: - Labeled chip

    /// 药丸的底 + 描边，是这张卡上**唯一**还随悬停变化的东西。
    /// 逐帧插值的范围就到这里为止，理由见 `multiWindowChip` 里的注释。
    private var pillEmphasisBackground: some View {
        ChipHoverProgress(progress: showsHover ? 1 : 0) { progress in
            let shape = RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
            // 悬停进度的诊断采样点必须留在这里——它要的就是逐帧的 progress
            //（`DOCK_CHIP_ANIM_TRACE=1`，默认关）。
            let _ = ChipAnimationTrace.record(
                chipID: item.id,
                kind: "window",
                visual: ChipHoverVisual.resolve(progress: progress, scale: scale),
                isTapPressed: isTapPressed,
                showsHover: showsHover
            )
            shape
                .fill(theme.effectiveChipPillFill.color(emphasisProgress: Double(progress)))
                .overlay(
                    shape.strokeBorder(
                        theme.chipPillRimStyle(emphasisProgress: Double(progress)),
                        lineWidth: 0.5
                    )
                )
        }
        .animation(.easeInOut(duration: 0.18), value: showsHover)
    }

    private var multiWindowChip: some View {
        // 图标恒为原色（不按状态淡化，owner 2026-08-02）；「在不在桌面上」只由标题颜色表达。
        let titleColor: Color = effectiveIsOnDesktop ? theme.labelActive.color : theme.effectiveLabelInactive.color
        let capturedDisplayTitle = displayTitle
        let capturedFullTitle = fullTitle
        // **可动画标量只包住药丸的底和描边，不包整张卡。**
        //
        // `ChipHoverProgress` 是 `Animatable` 视图：它的 `animatableData` 每变一次就重跑一次
        // 内容闭包。以前它裹着整张卡，于是 0.18s 动画的**每一帧**都要把图标、文字、
        // 内边距、布局整套重算，而真正在动的只有药丸底色和描边——`ChipHoverVisual` 的
        // 其余字段（图标尺寸、药丸高度）在 2026-08-16 冻结悬停几何之后全是常量。
        // 横扫一排标题卡时这笔开销是乘以卡数的。
        //
        // 缩进 `.background` 之后逐帧重算的只剩两个 shape，插值函数和数值一模一样，
        // 所以观感逐像素不变（那是签收过的观感）。
        let metrics = ChipHoverVisual.resolve(progress: 0, scale: scale)
        let pill = HStack(spacing: ChipPillMetrics.iconSpacing * scale) {
            appIcon(size: metrics.pillIconSize)
                .frame(width: ChipPillMetrics.iconSlot * scale, height: ChipPillMetrics.iconSlot * scale)
                // 未读角标（2026-08-23 起常规区的卡也画）：压在药丸里那枚小图标的右上角，按
                // `titledCardBadgeScale` 缩一档——16pt 的角标盖在 22pt 的图标上太满。
                // 同样挂在两个缩放之前，随悬停 / 按压 / 档位一起动。
                .overlay(alignment: .topTrailing) {
                    if let badgeText {
                        ChipBadgeView(text: badgeText, scale: scale * ChipPillMetrics.titledCardBadgeScale)
                    }
                }
            Text(capturedDisplayTitle)
                .font(.system(size: max(10, 12 * scale), weight: .medium, design: .rounded))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .frame(maxWidth: WindowTitleTextMetrics.maximumWidth(for: scale), alignment: .leading)
        }
        .padding(.horizontal, ChipPillMetrics.horizontalPadding * scale)
        .frame(height: metrics.pillHeight)
        .background(pillEmphasisBackground)

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            pill
                .frame(height: ChipPillMetrics.boxHeight * scale, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(height: ChipPillMetrics.chipHeight * scale)
        .padding(.horizontal, ChipPillMetrics.titledCardInset * scale)
        // 安静档的悬停反馈：整块轻微放大（标准档那一档的反馈是名字气泡 + 药丸提亮）。
        //
        // **卡宽必须传这张卡自己的**：等比放大在宽卡上外扩得多得多（实测 168.5pt 的卡
        // 每侧外扩 8.4pt，把 10pt 的卡间缝挤到只剩 3.5pt，owner 2026-08-17 报）。
        // 宽度用渲染药丸的同一个 `ChipPillMetrics.width`，不另写一份。
        .chipQuietHoverScale(
            quietHoverFeedback,
            cardWidth: ChipPillMetrics.width(title: capturedDisplayTitle, scale: scale)
                + 2 * ChipPillMetrics.titledCardInset * scale,
            scale: scale
        )
        .chipPressScale(isTapPressed)
        // 同 bareIconChip：悬停与气泡都归任务条那块整条跟踪区，这里只照着 `isHovered` 画。
        .contentShape(Rectangle())
        .onChange(of: isHovered) { recordHoverEvent($0) }
        .onTapGesture {
            if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.actionWindowID) }
        }
        .chipPressGesture(
            isPressed: $isTapPressed,
            pulseNonce: pulseNonce,
            onEvent: recordPressEvent
        )
        .nativeContextMenu { buildChipMenu() }
        // 标签在 140pt 处截断，而这张卡上的标题还去掉了应用名后缀——完整标题只剩这一个出口。
        // （悬停气泡不算：它显示的是应用名，而且新装用户默认是 `.quiet`、根本没有气泡。）
        .help(capturedFullTitle)
    }

    // MARK: - Shared Icon

    private func appIcon(size: CGFloat) -> some View {
        Image(nsImage: AppIconResolver.icon(for: item.bundleIdentifier ?? item.appID))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            // 我们**不额外加**外投影（owner 2026-08-19）：加过的那层是净多出来的，
            // 条上量到图标正下方比两侧空隙暗 18–24。中转格方块、文件夹封面同此。
            //
            // ⚠️ 这里原先还写着「实测 macOS 图标资源自己不投影，主体下方 alpha 恰好 0」——
            // **那条是错的，2026-08-20 已证伪**：它只量了图标正下方一条线，而素材自带的那圈
            // 阴影在**四周**。逐像素实测（预览的图标，32pt）：本体外侧约 5px 是半透明纯黑，
            // alpha 从 0.004 一路升到 0.102，亮度恒为 0。数据与教训见
            // `Docs/Archive/Engineering/24-guardrail-provenance.md`。
            // 所以静息时图标四周那圈暗边是**苹果画在素材里的**，不是我们画的。
    }

    // MARK: - Context Menu

    // 可打断（2026-06-13）：菜单项不再按 pending 置灰；显隐类动作随时可点
    //（乐观 overlay 保证一致性），close / quit 的防重入由 runtime.trigger 兜底。
    // 状态分支读 effectiveStatus，刚点过最小化立刻右键也能看到「还原」。
    private var isFinderChip: Bool { FinderTaskbarPolicy.isFinder(item.bundleIdentifier) }

    /// Native AppKit menu rebuilt fresh on each right-click (captures live runtime
    /// + store + optimistic state). See AppMenuFragments for why this isn't SwiftUI.
    private func buildChipMenu() -> NSMenu {
        let menu = NSMenu()
        let bid = item.bundleIdentifier
        // 窗口列表最前（仅应用级入口；次序见 Docs/27 2026-08-24）：✓ 前台窗，◇ 已最小化。
        // 只读快照——菜单在右键瞬间同步构建，这条路径上不做任何 AX。
        if showsWindowListInMenu, let listBid = bid {
            AppMenuBuilder.appendWindowList(
                to: menu,
                entries: WindowListMenuPlan.entries(
                    snapshot: runtime.snapshot,
                    bundleID: listBid,
                    fallbackTitle: AppDisplayNameResolver.displayName(for: listBid)
                ),
                activate: { runtime.activate(windowID: $0) }
            )
        }
        // 最近项置顶：Finder 显示「最近使用的文件夹」（FXRecentFolders），其余 app 显示「最近使用的文件」。
        if isFinderChip {
            AppMenuBuilder.appendFinderRecentFolders(to: menu)
        } else {
            AppMenuBuilder.appendRecentDocuments(to: menu, bundleID: bid)
        }
        if item.isAppLevelFallback {
            if isFinderChip { AppMenuBuilder.appendFinderItems(to: menu) }
            if effectiveStatus == "hidden" {
                menu.addItem(ClosureMenuItem(String(localized: "Show")) { runtime.activate(windowID: item.actionWindowID) })
            } else {
                menu.addItem(ClosureMenuItem(String(localized: "Hide")) { runtime.hide(windowID: item.actionWindowID) })
            }
            // 成员项在前、退出恒为末项——与下面的窗口卡片分支保持一致。
            appendMembershipItems(to: menu)
            menu.addItem(.separator())
            AppMenuBuilder.appendQuitItems(to: menu, bundleID: bid) {
                runtime.quit(windowID: item.actionWindowID)
            }
        } else {
            if isFinderChip { AppMenuBuilder.appendFinderItems(to: menu) }
            menu.addItem(ClosureMenuItem(String(localized: "New Window")) { runtime.newWindow(windowID: item.actionWindowID) })
            if effectiveStatus == "minimized" {
                menu.addItem(ClosureMenuItem(String(localized: "Restore")) { runtime.activate(windowID: item.actionWindowID) })
            } else {
                menu.addItem(ClosureMenuItem(String(localized: "Minimize")) { runtime.minimize(windowID: item.actionWindowID) })
            }
            if effectiveStatus == "hidden" {
                menu.addItem(ClosureMenuItem(String(localized: "Show")) { runtime.activate(windowID: item.actionWindowID) })
            } else {
                menu.addItem(ClosureMenuItem(String(localized: "Hide App")) { runtime.hide(windowID: item.actionWindowID) })
            }
            appendMembershipItems(to: menu)
            menu.addItem(.separator())
            // 整组关闭（2026-06-14）：标签组的「关闭窗口」关掉组内每个标签；
            // 普通窗口 memberWindowIDs == [id]，行为不变。
            menu.addItem(ClosureMenuItem(String(localized: "Close Window")) {
                for wid in item.memberWindowIDs { runtime.close(windowID: wid) }
            })
            AppMenuBuilder.appendQuitItems(to: menu, bundleID: bid) {
                runtime.quit(windowID: item.actionWindowID)
            }
        }
        return menu
    }

    /// Kept membership conversions go through the controller. Messaging remains
    /// mutually exclusive with kept membership. 收纳（进抽屉）不给菜单入口——
    /// 唯一路径是拖拽到胶囊/抽屉（owner 2026-07-10：右键只留「在程序坞中保留」与消息标记）。
    private func appendMembershipItems(to menu: NSMenu) {
        guard let bid = item.bundleIdentifier else { return }
        let items = LauncherMembershipItem.items(
            surface: .strip,
            bundleID: bid,
            isKept: keptAppStore.contains(bid),
            isMessaging: messagingStore.contains(bid),
            controller: appMembershipController
        )
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        for descriptor in items {
            menu.addItem(AppMenuBuilder.membershipItem(descriptor))
        }
    }

    // MARK: - Helpers

    /// 卡上渲染的标签（投影层算好的 `labelTitle`）。
    ///
    /// **这一个字符串同时喂三处**——渲染的 `Text`、`ChipPillMetrics.width(title:scale:)` 派生的
    /// `chipQuietHoverScale`、以及 `ChipPillMetrics.pillRect` 算出的气泡锚点。任何一处改回
    /// `fullTitle`，悬停缩放上限和气泡尾巴就锚在一个不存在的宽度上。
    private var displayTitle: String { labelTitle }

    /// 未截短的完整标题，只给系统 tooltip 用：纯图标卡不显示任何文字，截短了应用名就哪儿都看不到。
    private var fullTitle: String {
        WindowDisplayTitle.resolve(rawTitle: item.title, fallbackName: appName)
    }

    private var appName: String {
        let name = item.bundleIdentifier.map(AppDisplayNameResolver.displayName(for:)) ?? item.appID
        return WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: name)
    }
}
