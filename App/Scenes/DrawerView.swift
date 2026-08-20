import AppKit
import os
import SwiftUI

/// 抽屉 = **app 视角**：一个 bundleID 一个图标，顺序由 [[DrawerOrderStore]] 统一供给、永久记住
/// （2026-06-21 重做）。两区仍按"在不在运行"分：
/// - 运行区：收纳的、且进程在跑的 app（亮图标 + 圆点）。点击 = app 级唤出/收起（`LauncherChip.handleTap`）。
/// - 启动区：没在跑、但有 kept / messaging 永久身份的 app（暗图标，点击启动）。
///
/// DrawerStore 只记 placement，KeptAppStore 决定退出后是否继续显示。排序始终按完整
/// placement 集合记，隐藏成员下次启动仍回原位。
///
/// 两者**不再完全正交**（owner 2026-08-06）：**拖入**方向落定后会顺手打开 kept——不打开的话，
/// 拖进抽屉的普通应用一退出就从抽屉里消失了，不符合「收进抽屉 = 我要它一直在那儿」的心智。
/// **拖回任务条**方向仍然一律不动 kept。转换预览与回滚阶段也一律不碰 kept，只有 `endDrag()`
/// 落定那一刻才写。判据与完整语义见 `DragConversionPlan.enablesKeptOnDrop`。
struct DrawerView: View {
    /// 抽屉内容区最大高度（胶囊上方锚点 → 屏幕上沿可用高度，PanelCoordinator 开抽屉时算好传入）。
    /// 内容超过它就内部滚动,绝不靠下压底边塞下（防与下方胶囊/任务条重叠）。
    let maxContentHeight: CGFloat
    /// 底板走不走原生 Liquid Glass。**显式传入、无默认值**（同 `scale` / `hoverStyle`）——
    /// 每个面板都是独立的 hosting 根视图，漏传就会出现「这个面板是玻璃、旁边那个还是
    /// 毛玻璃」这种一眼可见的不一致。
    let usesLiquidGlass: Bool
    /// 点击 app 图标执行「唤出」或「启动」后回调。由 PanelCoordinator 注入，用于关闭抽屉。
    /// 「最小化（前台 → 收起）」不触发——抽屉保持打开。右键菜单、拖动操作同样不触发。
    var onPrimaryAction: () -> Void = {}

    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var drawerOrderStore: DrawerOrderStore
    @EnvironmentObject var dragController: DragController
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var runningApplicationStore: RunningApplicationStore
    @EnvironmentObject var appMembershipController: AppMembershipController

    private let theme = DockThemeTokens.standard

    /// 抽屉图标在 `"drawer"` 坐标空间里的位置，喂给起拖抓取偏移 + 同区落点命中。
    @State private var drawerFrames: [String: CGRect] = [:]

    /// 抽屉根视图的屏幕 frame（bottom-left），判"光标在不在抽屉体" + 屏幕坐标→`"drawer"` 空间换算。
    @State private var drawerRootScreenRect: CGRect = .zero

    /// 入场动画：onAppear 翻 true,内容从胶囊那角轻微放大入场（配合面板 alpha 淡入）。
    @State private var isPresented = false
    /// 网格自然高度（量出来）。超过 maxContentHeight 就内部滚动。
    @State private var contentHeight: CGFloat = 0

    private let columns = Array(repeating: GridItem(.fixed(44 * 0.7), spacing: 8), count: 5)

    // MARK: - 成员与分区（全 bundleID 级）

    /// Placement 全集喂给顺序层，绝不按当前可见项裁。
    private var allMembers: [String] {
        AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
    }

    private var displayOrder: [String] { drawerOrderStore.reconciled(members: allMembers) }

    /// 唯一可见漏斗：运行中，或有 kept / messaging 永久身份。输入用显示顺序，
    /// 因此隐藏 placement 再出现时仍回到原来的相对位置。
    private var visibleMembers: [String] {
        AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: displayOrder,
            keptIDs: keptAppStore.bundleIDs,
            runningIDs: runningApplicationStore.runningBundleIDs
        )
    }

    /// 有真窗口的 app（用于启动门控判定）。
    private var windowBackedIDs: Set<String> {
        Set(StripItem.items(from: runtime.snapshot).filter { !$0.isAppLevelFallback }.compactMap(\.bundleIdentifier))
    }

    /// 窗口出现门控（2026-06-18）：刚点启动、进程已起但还没真窗口，视作仍在启动 → 留启动区弹跳。
    private func isLaunchingWithoutWindow(_ id: String) -> Bool {
        runtime.launchingBundleIDs.contains(id) && !windowBackedIDs.contains(id)
    }

    /// 运行判定走 RunningApplicationStore（NSWorkspace 进程投影），与任务条 pinned dot 同口径。
    private func isRunning(_ id: String) -> Bool { runningApplicationStore.isRunning(id) }

    /// 隐藏判定同口径：同 bundle 所有进程都 hidden 才算 hidden。
    private func isHiddenInSnapshot(_ id: String) -> Bool { runningApplicationStore.isHidden(id) }

    /// 运行区 = 收纳 + 在跑 + 不在启动门控期。
    private var runningZoneIDs: [String] {
        visibleMembers.filter { isRunning($0) && !isLaunchingWithoutWindow($0) }
    }

    /// 启动区 = 已 kept / messaging 且没在跑（或仍在启动门控期）的可见项。
    private var launchZoneIDs: [String] {
        visibleMembers.filter { !isRunning($0) || isLaunchingWithoutWindow($0) }
    }

    // MARK: - Body

    var body: some View {
        // 底部对齐：抽屉面板向上长时,内容底边钉死在锚点(胶囊上方)、只向上揭开,
        // 不会像顶部对齐那样底边先垂到锚点下方(向下压胶囊)再升回来（owner 2026-06-21：避让该直接向上扩展）。
        ZStack(alignment: .bottomLeading) {
            DockPanelBackdrop(theme: theme,
                              cornerRadius: DockShape.panelCornerRadius,
                              usesLiquidGlass: usesLiquidGlass)

            // 内容超过可用高度就内部滚动（封顶,不下压底边）；否则正常贴合内容。
            Group {
                if contentHeight > maxContentHeight + 0.5 {
                    ScrollView(.vertical, showsIndicators: false) { gridStack }
                        .frame(height: maxContentHeight)
                } else {
                    gridStack
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DockShape.panelCornerRadius, style: .continuous))
        }
        .dockPanelRim(cornerRadius: DockShape.panelCornerRadius,
                      style: theme.panelRimStyle,
                      lineWidth: theme.panelRimLineWidth,
                      usesLiquidGlass: usesLiquidGlass)
        // 抽屉根视图的屏幕 frame（AppKit 换算,绕开 .global/y 翻转/shadowPadding 的坑,Codex 二审 P1-3）。
        // 与 `"drawer"` 命名空间挂在同一视图上 → 既能判"光标在不在抽屉里",又能把屏幕坐标映回 drawer 空间命中格子。
        .background(ScreenRectReader { rect in
            if rect != drawerRootScreenRect { drawerRootScreenRect = rect }
        })
        .coordinateSpace(name: "drawer")
        // 入场：从贴胶囊的右下角轻微放大入场（配合面板 alpha 淡入）。scaleEffect 是渲染变换,不改布局/命中。
        .scaleEffect(isPresented ? 1 : 0.96, anchor: .bottomTrailing)
        // 阴影延伸(radius+|y|)必须 ≤ shadowPadding(20),否则底部在透明边处被硬切（同弹窗）。
        // 数值见 DockThemeTokens.popupShadow（浅/深各一套）。
        .dockShadow(theme.popupShadow)
        .padding(PanelCoordinator.shadowPadding)
        // 入场用弹窗同款快出缓停参数（PopoverAnimation）;网格重排等内容动画仍用 DrawerAnimation.duration。
        .onAppear { withAnimation(.easeOut(duration: PopoverAnimation.openDuration)) { isPresented = true } }
        // 格子帧变了就重报落点锚点（理由同任务条那侧：松手后指针没事件了，网格还在重排）。
        .onPreferenceChange(DrawerChipFramePreferenceKey.self) { frames in
            drawerFrames = frames
            updateLandingAnchor()
        }
        .onPreferenceChange(DrawerContentHeightKey.self) { contentHeight = $0 }
        // 拖动中被拖图标的 app 从成员里消失（外部移除等）→ 取消拖动，免得空位卡死。
        // 例外：转正进任务条（抽屉拖回任务条·精确落点）会**主动**把它移出抽屉，不算异常消失，不取消。
        .onChange(of: visibleMembers) { members in
            if let p = dragController.draggingPayload, p.source == .drawer,
               !dragController.isConvertedToStrip, !members.contains(p.id) {
                dragController.cancelDrag()
            }
        }
        // 任务条卡拖进抽屉时跟光标算运行区落点；抽屉内拖动时跟光标做重排。都由全局鼠标位置驱动,
        // 不在 body 里发布(用 onChange + 去重,Codex 二审 P2-6)。
        // `onReceive` 而不是 `onChange(of: globalLocation)`，理由同 `DockStripView`：
        // 那个值一旦是 `@Published`，每动一下鼠标就要把整个面板打翻重算。
        .onReceive(dragController.pointerMoves) { _ in
            updateStripDropPreview(); updateDrawerReorder(); updateLandingAnchor()
        }
        .onChange(of: dragController.draggingPayload?.id) { id in
            if id == nil { convertedCarrierID = nil }   // 拖动结束：下一次同一应用再进来要重新换图
            updateStripDropPreview()
        }
        // 归位飞行途中点了一下抽屉图标 = 点了这个格子：走格子自己的默认左键行为（同一份静态逻辑）。
        .onReceive(dragController.carrierClicks) { payload in
            guard payload.source == .drawer, !runtime.launchingBundleIDs.contains(payload.id) else { return }
            LauncherChip.performDefaultTap(
                bundleID: payload.id,
                isRunning: isRunning(payload.id),
                launch: { if runtime.beginLaunch(payload.id) { onPrimaryAction() } },
                onOpen: onPrimaryAction)
        }
    }

    /// 两区网格本体。`.background` 量自然高度喂滚动判定；每区按各自 ID 列表做动画——增删/换行/重排都平滑。
    /// 任务条卡拖进抽屉是"即时转正成成员"（见 updateStripDropPreview），就是运行区多一个 id,无需占位格。
    private var gridStack: some View {
        let runningIDs = runningZoneIDs
        let launchIDs = launchZoneIDs
        let hasRunningZone = !runningIDs.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            if runningIDs.isEmpty && launchIDs.isEmpty {
                emptyHint
            }
            if hasRunningZone {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(runningIDs.enumerated()), id: \.element) { index, id in 
                        drawerChip(id, index: index, zone: runningIDs, running: true) 
                    }
                }
                .animation(.easeInOut(duration: DrawerAnimation.duration), value: runningIDs)
            }
            if !launchIDs.isEmpty {
                if hasRunningZone {
                    Spacer().frame(height: 12)
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(launchIDs.enumerated()), id: \.element) { index, id in 
                        drawerChip(id, index: index, zone: launchIDs, running: false) 
                    }
                }
                .animation(.easeInOut(duration: DrawerAnimation.duration), value: launchIDs)
            }
        }
        .padding(12)
        .background(GeometryReader { g in
            Color.clear.preference(key: DrawerContentHeightKey.self, value: g.size.height)
        })
    }

    /// 空抽屉提示。没有它时两区都空 → `VStack` 零子视图 → 内容只剩 12pt padding，
    /// 面板缩成 24×24 的毛玻璃小方块：既看不出这是干嘛的，也几乎没法当拖放目标。
    ///
    /// 宽度写死 186pt = **满行 5 列网格的宽度**（`5 × 44×0.7 + 4 × 8`），这样第一次
    /// 拖进应用、提示换成网格时面板宽度不跳变。颜色必须走 token（浅深各一套），
    /// 不许写字面量 opacity。
    ///
    /// 拖动预览期间无需特判：任务条卡一进抽屉体就被 `convertStripToDrawer` 转成真成员，
    /// `runningZoneIDs` 立刻非空，提示自然让位给网格。
    private var emptyHint: some View {
        Text("Drag apps here")
            .font(.system(size: 11))
            .foregroundStyle(theme.labelInactive.color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 5 * 44 * 0.7 + 4 * 8)
            .padding(.vertical, 10)
    }

    // MARK: - 单个图标（含拖动）

    /// `carriedPayload` 而不是 `draggingPayload`：松手后还有一段归位飞行，
    /// 那段时间格子必须继续空着，否则图标先在格子里显形、载体还在往这儿飞。
    private func isDragging(_ id: String) -> Bool {
        guard let p = dragController.hiddenSlotPayload else { return false }
        return p.source == .drawer && p.id == id
    }

    /// 松手时浮动副本该飞回抽屉哪一格（屏幕坐标）。任务条侧同样在写它那一份，靠 owner 标签分开。
    /// 任务条卡收进抽屉（来源已翻成 `.drawer`）也走这里 —— 图标会直接飞进它落定的格子。
    private func updateLandingAnchor() {
        let anchor: CGRect? = {
            // `carriedPayload`：飞行途中也要继续报，网格重排落定后才纠得了偏。
            guard let p = dragController.carriedPayload, p.source == .drawer,
                  !dragController.isConvertedToStrip,
                  drawerRootScreenRect != .zero,
                  let frame = drawerFrames[p.id] else { return nil }
            return drawerFrameToScreen(frame)
        }()
        dragController.setLandingAnchor(anchor, owner: .drawer)
    }

    private func membershipItems(for id: String) -> [LauncherMembershipItem] {
        LauncherMembershipItem.items(
            surface: .drawer,
            bundleID: id,
            isKept: keptAppStore.contains(id),
            isMessaging: messagingStore.contains(id),
            controller: appMembershipController
        )
    }

    /// `running` 按**区**传（运行区 true / 启动区 false），保证外观、点击与菜单都服从当前显示区。
    /// 启动后的进程在真窗口出现前仍留在启动区；runtime 的启动会话直接驱动弹跳。
    /// 抽屉格子里**画什么**。拆出来的唯一理由：载体位图要从这里出
    /// （`ChipSnapshotter`），渲染格子和渲染载体必须是同一份代码、同一批参数。
    /// 外面那层入场动画 / 拖动时置 0 的透明度 / 手势都不能进快照，所以留在 `drawerChip` 里。
    private func drawerChipContent(_ id: String, running: Bool) -> some View {
        LauncherChip(bundleID: id,
                     isRunning: running,
                     isHidden: running ? isHiddenInSnapshot(id) : false,
                     isLaunching: runtime.launchingBundleIDs.contains(id),
                     scale: 0.7,
                     // 抽屉有意不受「悬停效果」设置影响（owner 2026-08-02），但**固定成安静档**
                     // （owner 2026-08-17 要「抽屉图标悬停微微放大」）。
                     //
                     // 当年写 `.standard` 是为了「悬停冒名字」，那个理由 2026-08-16 就没了：
                     // 名字挪进了图标上方的气泡，而抽屉这个调用处**根本没接气泡回调**——
                     // 于是 `.standard` 在这里等于「什么都不做」，抽屉悬停零反馈。
                     // `.quiet` 恰好就是「没有名字，所以给一个轻微放大」那一档，语义对得上。
                     // 网格是 30.8pt 的格子配 8pt 间距，放大 1.10 后每侧只涨 1.5pt，撞不到邻居。
                     hoverStyle: .quiet,
                     // 抽屉这块面板没有整条那样的跟踪区，图标各自挂 `.onHover`。
                     // 格子 30.8pt、指针在里面停留的时间远长于条上横扫，漏格不成问题。
                     hoverInput: .selfTracked,
                     membershipItems: membershipItems(for: id),
                     slotHidden: isDragging(id),
                     hoverSuppressed: isHoverSuppressed(id),
                     onLaunch: { runtime.beginLaunch(id) },
                     onPrimaryAction: onPrimaryAction)
    }

    /// 这一格的悬停反馈是不是该按住：正被拎着（`.onHover` 在透明期间照样为 true）、
    /// 或刚落定而指针还没动（`DragController.hoverHoldPayload`）。任务条那边由整条跟踪区在源头压住，
    /// 抽屉的 `LauncherChip` 各自挂 `.onHover`，只能在这里按格子压。
    private func isHoverSuppressed(_ id: String) -> Bool {
        if let p = dragController.hoverHoldPayload, p.source == .drawer, p.id == id { return true }
        return isDragging(id)
    }

    /// 抽屉格子起拖那一刻的姿态：抽屉恒安静档、指针必在格子上（mouse-down 就发生在它上面），
    /// 所以是 1.10 底锚放大 × 0.93 按压——除非悬停正被按住。倍数用渲染格子的同一个函数算。
    private func pickUpPose(for id: String, slot: CGRect?) -> DragCarrierGeometry.PickUpPose {
        let height = slot?.height ?? ChipPillMetrics.chipHeight * 0.7
        let width = slot?.width ?? ChipPillMetrics.cardWidth * 0.7
        let hoverScale: CGFloat? = isHoverSuppressed(id)
            ? nil
            : ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: 0.7)
        return DragCarrierGeometry.pickUpPose(
            chipHeight: height,
            pressedScale: ChipPressSwitches.pressDownEnabled ? ChipPressDecision.pressedScale : nil,
            hoverScale: hoverScale)
    }

    /// 屏幕坐标的格子帧；抽屉根帧还没量到就给 nil（起拖时会退回「摆在指针下」）。
    private func slotScreenRect(_ id: String) -> CGRect? {
        guard drawerRootScreenRect != .zero, let slot = drawerFrames[id] else { return nil }
        return drawerFrameToScreen(slot)
    }

    /// 松手时浮动副本该飞回抽屉哪一格 / 起拖时载体从哪一格接手：`"drawer"` 空间帧 → 屏幕坐标。
    private func drawerFrameToScreen(_ frame: CGRect) -> CGRect {
        CGRect(x: drawerRootScreenRect.minX + frame.minX,
               y: drawerRootScreenRect.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    @ViewBuilder
    private func drawerChip(_ id: String, index: Int, zone: [String], running: Bool) -> some View {
        let delay = Double(min(index, 6)) * 0.018
        drawerChipContent(id, running: running)
            .offset(y: isPresented ? 0 : 20)
            .opacity(isPresented ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.8).delay(delay), value: isPresented)
            .opacity(isDragging(id) ? 0 : 1)
            // `"drawer"` 空间里的 frame，背景 GeometryReader（不夺点击），喂抓取偏移 + 同区落点。
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: DrawerChipFramePreferenceKey.self,
                                           value: [id: geo.frame(in: .named("drawer"))])
                }
            )
            // 本手势**只负责起拖一次**：拿到"是哪张卡 + 抓取偏移"后交给 DragController。
            // 重排**不在这里做**——第一次重排会把被拖图标在网格里挪位,SwiftUI 随即取消这个手势、
            // onChanged 不再触发 → "挤一下就卡住"（owner 2026-06-22）。重排改由 updateDrawerReorder()
            // 按 DragController 的全局鼠标位置驱动（见 onChange(globalLocation)），图标怎么换位都不受影响。
            // **按下即预备**（`DragController.prepareCandidate`）：mouse-down 那一刻就把这格的位图
            // 挂上载体图层预热纹理，起拖当轮才能「点亮 + 藏格」同帧。松手没起拖就撤掉。
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("drawer"))
                    .onChanged { _ in
                        guard let rect = slotScreenRect(id) else { return }
                        dragController.prepareCandidate(
                            payloadID: id,
                            sourceScreenRect: rect,
                            snapshot: ChipSnapshotter.snapshot(of: drawerChipContent(id, running: running),
                                                             screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)))
                    }
                    .onEnded { _ in dragController.clearCandidate(payloadID: id) }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("drawer"))
                    .onChanged { value in
                        guard dragController.draggingPayload == nil else { return }
                        let slot = drawerFrames[id]
                        let grab: CGSize = slot.map {
                            CGSize(width: $0.midX - value.startLocation.x,
                                   height: $0.midY - value.startLocation.y)
                        } ?? .zero
                        let payload = DragPayload(source: .drawer, id: id, bundleID: id, item: nil,
                                                  visualKind: .drawerIcon, canExternalDrop: true)
                        dragController.beginDrag(
                            payload: payload,
                            startScreenLocation: NSEvent.mouseLocation,
                            grabOffset: grab,
                            sourceScreenRect: slotScreenRect(id) ?? .zero,
                            pose: pickUpPose(for: id, slot: slot),
                            snapshot: ChipSnapshotter.snapshot(of: drawerChipContent(id, running: running),
                                                             screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)))
                    }
            )
    }

    /// 抽屉内重排：按 DragController 全局鼠标位置驱动（替代会被取消的逐图标手势）。把屏幕坐标映回 `"drawer"`
    /// 空间,命中同区目标后让位。抽屉内重排不改成员数 → 抽屉不缩放 → 用实时 drawerRootScreenRect 映射即可。
    private func updateDrawerReorder() {
        guard let p = dragController.draggingPayload, p.source == .drawer,
              !dragController.isOverDropZone,            // 光标已在任务条上 = 移回,不重排
              drawerRootScreenRect != .zero else { return }
        let pt = CGPoint(x: dragController.globalLocation.x - drawerRootScreenRect.minX,
                         y: drawerRootScreenRect.maxY - dragController.globalLocation.y)   // 屏幕(左下) → drawer(左上)
        let zone = runningZoneIDs.contains(p.id) ? runningZoneIDs : launchZoneIDs
        reorderTarget(at: pt, dragging: p.id, zone: zone)
    }

    /// 抽屉内排序：只在**同一区**内命中落点（Codex 二审 ⑤——跨区改顺序会"偷偷"改、状态变才显现）。
    private func reorderTarget(at point: CGPoint, dragging id: String, zone: [String]) {
        // 命中 frame 外扩一圈(覆盖 8pt 格间空隙)→ 判定区更大、好定位(owner 2026-06-21 反馈太小)。
        // 按 zone 顺序遍历:dict.first(where:) 顺序不定,外扩后相邻格会重叠 → 必须有序取最左。
        for tid in zone where tid != id {
            guard let f = drawerFrames[tid], f.insetBy(dx: -6, dy: -6).contains(point) else { continue }
            drawerOrderStore.reorder(draggedID: id, relativeTo: tid, after: point.x > f.midX)
            return
        }
    }

    // MARK: - 任务条卡进抽屉体 → 转成抽屉内拖动 / 拖出还原

    /// 任务条卡拖进**打开的抽屉体** → 即时转成抽屉内拖动（DragController.convertStripToDrawer：加入抽屉成员、
    /// 来源改 `.drawer`）。此后这张卡就是普通抽屉成员,由全局鼠标驱动的 `updateDrawerReorder` 重排——与抽屉内
    /// 拖动**完全同一套**(owner 2026-06-22：统一手感)。彻底绕开旧的"占位空格 + 面板反复缩放"机制（闪烁/卡顿源）。
    /// 底边/侧边留容差：载体相对鼠标有抓取偏移,鼠标常落在抽屉底边附近,容差让贴边也能稳定判"进了抽屉体"。
    private func updateStripDropPreview() {
        let dc = dragController
        guard dc.draggingPayload != nil, drawerRootScreenRect != .zero else { return }
        let g = dc.globalLocation
        let r = drawerRootScreenRect
        // 进入阈值松（容差大,好进）；撤销阈值更靠外（迟滞带,防边缘反复转正/撤销 → 抽屉一胀一缩抖）。
        let enterBody = g.x >= r.minX - 8  && g.x <= r.maxX + 8  && g.y >= r.minY - 28
        let clearlyOut = g.x < r.minX - 20 || g.x > r.maxX + 20 || g.y < r.minY - 48
        if let p = dc.draggingPayload, p.canExternalDrop, enterBody {
            switch p.source {
            case .strip:     dc.convertStripToDrawer()      // 进抽屉体 → 临时转正(挤开别人=预览)
            case .messaging: dc.convertMessagingToDrawer()  // 消息 chip 同一套收纳预览手感
            case .drawer, .folder: break
            }
            syncConvertedCarrier()
        } else if clearlyOut {
            if dc.isConvertedFromStrip {
                dc.revertStripFromDrawer()          // 拖出抽屉体 → 撤销还原(抽屉缩回最初样子)
            } else if dc.isConvertedFromMessaging {
                dc.revertMessagingFromDrawer()      // 消息 chip 拖出 → 还原回消息区原位
            }
            syncConvertedCarrier()
        }
    }

    /// 任务条卡 / 消息 chip 一进抽屉体，载体就换成**抽屉格子的位图**（`drawerChipContent` 同款、0.7 倍、
    /// 无角标），并按尺寸比例把抓取点重新锚到指针上；拖出抽屉体还原成起拖那张。
    /// 反方向（抽屉图标转正进任务条）早就换图（`DockStripView.syncConvertedCarrier`），这个方向之前漏了：
    /// 载体一直是 40pt 图标甚至 168pt 标题卡，压在抽屉边上（owner 2026-08-19 截图）。
    /// 落进格子那一帧才能逐像素一致——位图必须由渲染格子的同一份代码出。
    @State private var convertedCarrierID: String?
    private func syncConvertedCarrier() {
        let dc = dragController
        let converted = dc.isConvertedFromStrip || dc.isConvertedFromMessaging
        if converted, let p = dc.draggingPayload, p.source == .drawer {
            guard convertedCarrierID != p.id else { return }
            convertedCarrierID = p.id
            // 刚 add 进成员的那一轮两个区列表可能还没算上它：不在启动区就按进程状态判。
            let running = runningZoneIDs.contains(p.id) || (!launchZoneIDs.contains(p.id) && isRunning(p.id))
            dc.setCarrierSnapshot(
                ChipSnapshotter.snapshot(of: drawerChipContent(p.id, running: running),
                                         screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)),
                reanchor: true)
        } else if !converted, convertedCarrierID != nil {
            convertedCarrierID = nil
            dc.setCarrierSnapshot(nil, reanchor: true)   // 换回起拖那张；拖动已结束时里面直接不动
        }
    }
}

// MARK: - Drawer drag-reorder preference

private struct DrawerChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 网格自然高度（量出来,喂"超高内部滚动"判定）。
private struct DrawerContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
