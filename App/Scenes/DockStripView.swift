import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct DockStripView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var badgeStore: BadgeStore
    @EnvironmentObject var stripOrderStore: StripOrderStore
    @EnvironmentObject var pinnedFolderStore: PinnedFolderStore
    @EnvironmentObject var folderCoverStore: PinnedFolderCoverStore
    @EnvironmentObject var shelfStore: ShelfStore
    @EnvironmentObject var settingsStore: AppSettingsStore
    @EnvironmentObject var displayTopologyStore: DisplayTopologyStore

    /// 这条任务条的底板是不是原生 Liquid Glass。由 `PanelCoordinator` 在建面板时一次定死
    /// （背景窗口建成功才为 true），**显式传入、没有默认值**：同 `scale` / `hoverStyle`，
    /// 漏传是编译错误。不要退回读全局静态量 —— SwiftUI 观察不到它，面板拆除后会读到旧值。
    let usesLiquidGlass: Bool
    /// 本条任务条在 `DragController` 里的表面身份（多屏 ③④ 下每块屏一条、内容相同，见
    /// `DragController.activeStripSurfaceID`）。**显式传入、无默认值**：漏传就是两条同时写回落点。
    let stripSurfaceID: String
    /// 本条所在的屏（③④ 的固定单元传 display UUID；①② 的跟随单元传 nil）。多屏 ④ 下只画属于
    /// 这块屏的窗口卡。**显式传入、无默认值**：漏传就是每块屏都画全部窗口、④ 静默退化成 ③。
    /// ③↔④ 切换不重建单元（key 列表相同），所以是否过滤看 `settingsStore.taskbarScreenPlacement`。
    let displayUUID: String?

    /// 本条是不是当前拖动的活动表面。没人认领（抽屉起拖尚未转正）时人人可动——谁的条框含着指针谁转正并认领。
    var ownsActiveDrag: Bool {
        guard let active = dragController.activeStripSurfaceID else { return true }
        return active == stripSurfaceID
    }

    /// 当前尺寸档位派生的面板几何与缩放系数。**条内不写裸尺寸数字**——凡是随任务条一起
    /// 放大缩小的值都乘 `dockScale`；发丝线（分隔线宽、描边）保持 1pt 不缩。
    private var metrics: PanelLayoutMetrics { settingsStore.dockSize.metrics }
    var dockScale: CGFloat { settingsStore.dockSize.scale }
    /// 任务条圆角。**玻璃态与毛玻璃态同一个值** —— 几何只有 `DockSize.metrics` /
    /// `DockShape` 一个来源，换底板材质不改尺寸（否则四档缩放失效，`scale` 的定义
    /// 就是 `panelHeight / 52`）。
    private var taskbarCornerRadius: CGFloat { Style.cornerRadius * dockScale }
    /// 悬停效果档位。条内每个 chip 都显式接收它（同 `dockScale`，漏传是编译错误）；
    /// 抽屉面板与抽屉入口胶囊有意不受它影响（owner 2026-08-02）。
    var hoverStyle: HoverStyle { settingsStore.hoverStyle }
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var runningApplicationStore: RunningApplicationStore
    @EnvironmentObject var appMembershipController: AppMembershipController

    /// 浅 / 深色两套视觉数值（见 `DockThemeTokens`）。深色列是冻结的历史值，调观感只动浅色列。
    private let theme = DockThemeTokens.standard

    /// 文件夹 chip 点击 → 弹窗 toggle（path + chip 可视矩形·屏幕坐标）。PanelCoordinator 注入。
    var onFolderPopupToggle: (String, CGRect) -> Void = { _, _ in }
    /// 中转格点击 → 中转弹窗 toggle（chip 可视矩形·屏幕坐标）。PanelCoordinator 注入。
    var onShelfPopupToggle: (CGRect) -> Void = { _ in }
    /// 「添加文件夹…」统一入口（NSOpenPanel 归 AppDelegate 管）。
    var onAddFolder: () -> Void = {}
    /// 外部文件命中固定文件夹 chip 后，上抛给 composition 层在后台执行搬运。
    var onMoveExternalFiles: ([URL], String) -> Void = { _, _ in }
    /// 悬停名气泡的**唯一**出口（整条只有这一个发送方，见 `bubbleRequest`）。
    /// PanelCoordinator 负责那块独立面板的呈现与收尾。
    var onWindowTitleTooltipEvent: (WindowTitleTooltipEvent) -> Void = { _ in }
    /// 右键任务条底板 → 弹钨极菜单（`StatusMenuController` 持有那个菜单）。
    var onRequestTaskbarMenu: (NSEvent, NSView) -> Void = { _, _ in }
    /// 跨面板拖动权威（拖卡进抽屉 路线 C）：起拖 → beginDrag；读 draggingItem 隐藏原位卡片、
    /// 读 isOverDropZone 在进投放区时停掉条内重排。载体面板/监视器/收尾都在它里面，本视图不碰。
    @EnvironmentObject var dragController: DragController

    /// Live chip frames by id in the `"strip"` space (含滚动偏移后的屏上位置), collected via
    /// preference — feeds the grab offset at drag start and the full-frame landing hit-test.
    /// `.background` GeometryReader (not overlay) so it never steals chip clicks.
    @State var chipFrames: [String: CGRect] = [:]
    /// 手势预览触发的按 chip 脉冲计数（重击/中键活访达窗口时 +1，给 ~200ms 反查一个即时"点到了"）。
    @State var chipPulseNonces: [String: Int] = [:]

    /// 文件夹 chip 帧（弹窗锚点 + 外部拖入的 pin 落点路由）。**独立字典,绝不混入 chipFrames**——
    /// 那是 live 窗口区拖拽重排与抽屉拖回落点的输入,混入会让窗口拖动命中文件夹区、落点 no-op（评审 P1）。
    @State var folderChipFrames: [String: CGRect] = [:]

    /// 消息区 chip 帧（bundleID → "strip" 空间 frame）。**独立字典,同文件夹 chip 的理由绝不混入
    /// chipFrames**——喂消息区内重排 hit-test + 抽屉拖出的"消息区范围"释放判定。
    @State var messagingChipFrames: [String: CGRect] = [:]
    /// 载体此刻画的是哪张消息区图标（释放回消息区那条路的换图去重）。见 `syncReleasedMessagingCarrier`。
    @State private var carriedMessagingChipID: String?
    /// 上一轮 body 见到的 `stripSlotCollapsed`（`.onChange` 里晚一轮更新）。body 里两者不等 = 这次
    /// `layoutKeys` 变化就是空位合拢 / 重开，条内动画要和面板窗口动画**同一条曲线同一时长**——
    /// 弹簧（0.28s）叠在 AppKit easeInEaseOut（0.22s）上，图标相对底板忽前忽后，就是 owner 2026-09-03
    /// 录屏里「没有原生丝滑」的那一下。
    @State private var renderedCollapsed = false

    /// 中转格 frame（"strip" 空间）。**独立上报,不塞进 folderChipFrames**（评审：那个字典专属
    /// 文件夹 chip,后续还喂文件夹重排 hit-test,不能混 sentinel）。喂中转弹窗锚点 + drop 路由。
    @State var shelfFrame: CGRect = .zero

    /// 外部文件拖入的实时落点目标（悬停高亮用;nil = 没有外部拖拽悬停）。
    @State var externalDropTarget: StripDropRouting.Target?

    /// 外部拖入高亮的「拖放结束看门狗」+「点亮门控」。SwiftUI 文件 drop 有两种收尾异常:
    /// ①拖放在最后一次 dropUpdated 后不给任何 performDrop/dropExited 收尾回调 → 高亮遗留在 .pin;
    /// ②成功 drop 后 ~330ms 会补发一次孤立的 dropUpdated 把高亮重新点亮。
    /// 门控:高亮只能由 dropEntered 点亮（hoverActive），落定/离开后孤立的 dropUpdated 一律忽略（治②回闪）。
    /// 看门狗:可取消的 .common Timer,拖放悬停停更超时即清遗留高亮（治①永久白边）;generation 防旧 timer 误清。
    /// 逻辑见 externalDropHoverBegan/Moved/Ended + setExternalDropTarget。
    @State var externalDropWatchdog: Timer?
    @State var externalDropGeneration = 0
    @State var externalDropHoverActive = false

    /// 任务条内容区（"strip" 空间）在屏幕坐标系的 frame（bottom-left）。抽屉拖回任务条·精确落点用它把
    /// 全局鼠标位置映回 "strip" 空间命中卡片，并判进/出任务条区（迟滞）。与 "strip" 命名空间挂同一视图。
    @State var stripRootScreenRect: CGRect = .zero

    /// 悬停命中帧（`StripEntry.id` → "strip" 空间帧）。**又一本独立字典**，理由同上面那三本：
    /// 它们各有各的用途（重排 / 弹窗锚点 / 释放判定），谁也不能替谁。这一本是「指针落在谁身上」
    /// 的唯一依据，所以**四个区的卡全收进来**，由 `stripEntryView` 一处统一上报。
    @State var stripHoverFrames: [String: CGRect] = [:]

    /// 指针当前压在哪张卡上。**全条唯一的悬停真相**——悬停视觉和名字气泡都读它。
    /// 每张卡不再各自挂 `.onHover`，成因与实测见 `StripHoverResolution`。
    @State var hoveredEntryID: String?

    /// 最后一次指针位置（屏幕坐标）。**刻意放在引用盒里而不是 `@State` 值**：
    /// 指针每动一次都写 `@State` 就会以指针的频率重算整条 body，而真正需要重算的
    /// 只有「拥有者变了」那一刻——那一刻写的是上面的 `hoveredEntryID`。
    @State var pointerBox = PointerBox()

    /// 当前占着气泡面板的 chip。只用来在收气泡时报出正确的 id（`.exit` 要匹配才生效）。
    @State private var bubbleOwnerID: String?

    /// 记录已经播放过入场动画的固定区元素 ID（避免重复播，且支持新增元素播动画）。
    @State private var animatedEntryIDs: Set<String> = []

    var body: some View {
        let projection = makeProjection()
        // 「一次点击让整条重算了几次」——`DockStripView` 订阅整个 `AppRuntime`，
        // 任何一个 `@Published` 变化都会打翻整条。默认关，`DOCK_HOVER_TRACE=1` 才记。
        let _ = HoverTrace.stripBody(items: projection.entries.count)
        return ZStack {
            // macOS 26 的 Liquid Glass 由统一底板接管；默认关闭，旧系统与未开关时仍是原毛玻璃。
            DockPanelBackdrop(theme: theme,
                              cornerRadius: taskbarCornerRadius,
                              usesLiquidGlass: usesLiquidGlass)

            // 玻璃厚度感：材质之上、内容之下。**默认关**，`DOCK_PANEL_THICKNESS=1` 才开
            //（未验收的效果一律 opt-in，见 DockEffectSwitches）。深色则两层保险都不画，
            // 整层不进视图树，保证深色逐像素冻结。
            // 原生玻璃有真的边缘处理，这层「假厚度」叠上去没有意义，玻璃态一律不画。
            if theme.drawsEffectiveThickness && !usesLiquidGlass {
                theme.panelThicknessLayer(cornerRadius: taskbarCornerRadius)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: Style.chipSpacing * dockScale) {
                    ForEach(projection.entries) { entry in
                        chipWithReorder(entry, projection: projection)
                            .transition(.scale(scale: 0.88).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Style.chipContentInset * dockScale)
                .frame(height: metrics.panelHeight)
                .animation(renderedCollapsed != dragController.stripSlotCollapsed
                               ? .easeInOut(duration: DrawerAnimation.duration)          // 合拢 / 重开：跟面板走
                               : .spring(response: 0.28, dampingFraction: 0.82),         // 让位：签收过的弹簧
                           value: projection.layoutKeys)
            }
            .clipShape(RoundedRectangle(cornerRadius: taskbarCornerRadius, style: .continuous))
            .compatLeadingScrollAnchor()
            .mask(alignment: .center) {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Style.edgeFadeWidth * dockScale)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Style.edgeFadeWidth * dockScale)
                }
            }
            .overlay(alignment: .topLeading) {
                WheelScrollInterceptorRepresentable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // 右键任务条底板弹钨极菜单。
            //
            // **必须挂成 `.overlay` 而不是 `.background`**：SwiftUI 的 ScrollView 背后是真的
            // `NSScrollView`，它自己就会接住命中测试，放在它下面的 host 永远收不到事件
            // （实测过：两端空白右键毫无反应）。放到上层是安全的，因为 `shouldClaim` 只在
            // 「两端空白 + 分割线」认领，其余一律返回 nil 穿透下去，chip / 文件夹 / 中转格
            // 右键仍是各自的菜单。范围判定在纯 `StripContextMenuZone` 里（chip 之间那 8pt
            // 窄缝刻意不认，理由见那个类型）。
            //
            // overlay 与 background 一样都不影响父视图尺寸——任务条宽度靠 `fittingSize` 量，
            // 千万别改成 ZStack 的兄弟节点，那会把条撑宽。
            .overlay(NativeMenuHost(
                popUpHandler: onRequestTaskbarMenu,
                shouldClaim: { taskbarMenuZoneClaims(atScreen: $0) }
            ))
        }
        // 外部拖目录悬停文件夹区（pin 落点）时整条高亮：在平时那圈边**之上**再叠一圈更亮的，
        // 不再把玻璃亮边换掉（那正是「一圈黑边」的成因，见 `DockPanelRimPlan`）。
        .dockPanelRim(
            cornerRadius: taskbarCornerRadius,
            style: theme.panelRimStyle(highlighted: stripHighlighted),
            lineWidth: theme.panelRimLineWidth(highlighted: stripHighlighted),
            usesLiquidGlass: usesLiquidGlass,
            highlighted: stripHighlighted
        )
        .animation(.easeOut(duration: 0.15), value: stripHighlighted)
        // 跨面板后，被拖的卡片改由 DragController 的全屏载体面板绘制（不再画在任务条 overlay 上 —
        // 任务条窗口只有 92pt 高，自绘 overlay 会被裁掉，飘不出去）。这里只保留"让出空位"的原位隐藏。
        .coordinateSpace(name: "strip")
        // 外部文件拖入（系统拖放目的地）：**必须挂在定义 "strip" coordinateSpace 的同一层**——
        // DropDelegate 的 location 要与 folderChipFrames/shelfFrame 同源,挂到 .padding(shadowPadding)
        // 之后坐标就错位（评审拍板）。路由是纯函数 StripDropRouting.route,落点见 handleExternalDrop。
        .onDrop(of: [UTType.fileURL], delegate: StripFileDropDelegate(
            // 关掉中转格后直接传 nil：ShelfFramePreferenceKey.reduce 刻意忽略 .zero，
            // 旧帧不会被清掉，只看帧的话落在原位置仍会误判成暂存。
            shelfFrame: settingsStore.showShelf ? shelfFrame : nil,
            folderFrames: folderChipFrames,
            orderedPaths: pinnedFolderStore.folderPaths,
            // chip 间距随档位缩放，「插到最前面」那段 slack 也得跟着缩，否则小档时它相对更宽、
            // 会吃掉首个文件夹左半边的移入区。
            headSlack: StripDropRouting.defaultHeadSlack * dockScale,
            onHoverBegan: { externalDropHoverBegan($0) },
            onHoverMoved: { externalDropHoverMoved($0) },
            onHoverEnded: { externalDropHoverEnded() },
            onCommit: { target, urls in handleExternalDrop(target, urls: urls) }
        ))
        // 与 "strip" 命名空间同一视图 → 屏幕 frame 即 "strip" 空间原点，供抽屉拖回任务条做坐标映射 + 进出判定。
        // **面板自己挪了也要重报落点锚点**：所有锚点都是 `stripFrameToScreen` 拿这个 rect 换算的。
        // 松手时 `teardown` 清掉 `conversion` → 条宽解冻 → 整条重新居中，消息区（在最左端）
        // 整体左移 0.22s；不接这一条，归位飞行就一直朝面板挪走**之前**那个位置飞。
        .background(ScreenRectReader { rect in
            guard rect != stripRootScreenRect else { return }
            stripRootScreenRect = rect
            refreshHoveredEntry(frames: stripHoverFrames, origin: rect)
            updateLandingAnchor()
        })
        // **整条一块跟踪区**：指针每动一次就上报一次屏幕坐标，落在谁身上由纯判定
        // `StripHoverResolution` 算。每张卡各自挂 `.onHover` 的老做法漏格又带方向性，
        // 成因与实测数据见那个类型的注释。
        .background(StripPointerTracker { pointer in
            pointerBox.value = pointer
            refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
            HoverTrace.pointer(x: pointer?.x ?? -1, chip: hoveredEntryID)
        })
        // 重击(触控板)/中键(鼠标) → 内容预览：本地事件监视器 → 命中反查（handleGesturePreview）。
        .background(GestureMonitorInstaller(onGesture: { handleGesturePreview(atScreen: $0) }))
        // 落地阴影住在窗口的 20pt 透明边里，玻璃态同样走这条 —— 曾经试过改画到背景窗口的
        // 图层上，但那个窗口的 frame 正好等于底板，阴影画在窗口外会被整个裁掉。
        .dockShadow(theme.stripShadow)
        .padding(PanelCoordinator.shadowPadding)
        // 抽屉图标拖到任务条上：进任务条区即转正成窗口卡、跟光标整块实时让位（镜像 DrawerView 的全局鼠标驱动）。
        // 消息区的重排/释放同样由全局鼠标驱动——重排会挪动被拖 chip,SwiftUI 会取消原手势,
        // 不能依赖 chip 自己的 .onChanged（同抽屉教训,owner 2026-06-22 / Codex 评审 P1-4）。
        // **`onReceive` 而不是 `onChange(of: globalLocation)`**：后者要求那个值是 `@Published`，
        // 而那正是「动一下鼠标就打翻整条任务条」的来源（实测 1.2 秒拖动 46 次整条重算）。
        // `onReceive` 照跑闭包，但不给本视图建立依赖——只有下面这些副作用真的改了什么才重画。
        .onReceive(dragController.pointerMoves) { _ in
            updateStripPresence()                 // 进出条：让位复原 / 合拢，认领换手——要在门控之前判
            guard ownsActiveDrag else { return }   // 别的屏上那条正拖着：本条不写回任何东西
            updateDrawerToMessagingRelease(projection: projection)
            updateDrawerToStripConvert(projection: projection)
            updateStripBlockReorder(projection: projection)
            updateLiveReorder(projection: projection)
            updateMessagingReorder(messagingIDs: projection.messagingIDs)
            updateFolderReorder()
            syncConvertedCarrier(projection: projection)
            syncReleasedMessagingCarrier(projection: projection)
            updateFolderDragZone()
            updateLandingAnchor()
        }
        // 归位飞行途中点了一下图标 = 点了这张卡（owner 2026-08-19：「落地前点它没反应」）。
        // 按 entry 分派、逐字镜像 `stripEntryContent` 各分支的 tap；用**此刻**的投影，不用载荷里起拖时那份。
        .onReceive(dragController.carrierClicks) { payload in
            guard ownsActiveDrag else { return }
            performCarrierClick(payload, projection: freshProjection())
        }

        // 转正那一刻上面那个闭包手里的 projection 还是**旧的**（app 还在抽屉里），代表卡/让位卡都算不出来。
        // 光靠鼠标驱动就意味着「光标停在边界不动 = 一直双影」。store 一变就再算一次，把那一帧补上。
        .onChange(of: projection.liveOrderIDs) { _ in
            guard ownsActiveDrag else { return }
            syncConvertedCarrier(projection: freshProjection())
        }
        // 同上，消息区那一侧：释放那一刻手里的 projection 里还没有这张 chip。
        .onChange(of: projection.messagingIDs) { _ in
            guard ownsActiveDrag else { return }
            syncReleasedMessagingCarrier(projection: freshProjection())
        }
        // 悬停压制的开关翻转时重判一次：起拖藏卡那一刻清掉旧悬停；落地按住期结束（指针动了）
        // 那一刻按当前指针位置补上悬停。**不再在「手里空了」那一刻重判**——那正是落地一停稳
        // 就往上长一截的来源（见 `refreshHoveredEntry`）。
        .onChange(of: dragController.stripSlotCollapsed) { renderedCollapsed = $0 }
        .onChange(of: dragController.hoverGate) { _ in
            refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
        }
        // 拖动中消息 chip 的 app 从消息区消失（退出/外部 unmark/快照丢）→ 取消拖动，免得空位卡死。
        // 收纳预览（messagingToDrawer）不误判：转换后载荷来源已是 .drawer（Codex 评审 P2-5）。
        .onChange(of: projection.messagingIDs) { ids in
            if let p = dragController.draggingPayload, p.source == .messaging, !ids.contains(p.bundleID) {
                dragController.cancelDrag()
            }
        }
        // Converge the remembered live order with the current snapshot (drop closed, append
        // new) as a side-effect — never during body eval. The `.onAppear` seed mirrors the old
        // `initial: true` so the very first render's reconcile (empty → current) is a no-op.
        // 名字气泡的**唯一**驱动点。指针压在谁身上、锚点在哪、写什么字，全由 `bubbleRequest`
        // 一处推出来，所以锚点漂移 / 应用名变化 / 换档全都自动跟上——每张卡各自补发
        // `.refresh` 的那一套，连同「谁有资格占用这块面板」的守卫，一起没了：
        // 现在只有一个人能发请求，抢不起来。
        .onChange(of: bubbleRequest(projection: projection)) { request in
            if let request {
                onWindowTitleTooltipEvent(.update(request))
            } else if let previous = bubbleOwnerID {
                onWindowTitleTooltipEvent(.exit(chipID: previous))
            }
            bubbleOwnerID = request?.chipID
        }
        .onDisappear {
            if let previous = bubbleOwnerID { onWindowTitleTooltipEvent(.exit(chipID: previous)) }
            bubbleOwnerID = nil
        }
        .onChange(of: projection.liveOrderIDs) { _ in reconcileLiveOrder(freshProjection()) }
        .onChange(of: keptAppStore.bundleIDs) { _ in reconcileLiveOrder(freshProjection()) }
        .onChange(of: messagingStore.bundleIDs) { _ in reconcileLiveOrder(freshProjection()) }
        .onAppear { reconcileLiveOrder(projection) }
        // 卡帧变了就重报落点锚点。**光靠 `globalLocation` 驱动不够**：松手之后指针不再有事件，
        // 而让位弹簧还在跑，卡槽要再过一两百毫秒才停。归位飞行的中途纠偏就靠这条。
        .onPreferenceChange(ChipFramePreferenceKey.self) { frames in
            chipFrames = frames
            updateLandingAnchor()
        }
        // 条重排 / 换档时指针没动，但它脚下的卡换人了——同一处重判。
        .onPreferenceChange(StripHoverFramePreferenceKey.self) { frames in
            stripHoverFrames = frames
            refreshHoveredEntry(frames: frames, origin: stripRootScreenRect)
        }
        // 这两处的帧同样是落点锚点的输入源（`.folder` / `.messaging` 载荷各取一份），
        // 变了就得回报——理由同上面的 `ChipFramePreferenceKey`。
        .onPreferenceChange(FolderChipFramePreferenceKey.self) { frames in
            folderChipFrames = frames
            updateLandingAnchor()
        }
        .onPreferenceChange(MessagingChipFramePreferenceKey.self) { frames in
            messagingChipFrames = frames
            updateLandingAnchor()
        }
        .onPreferenceChange(ShelfFramePreferenceKey.self) { shelfFrame = $0 }
        .onChange(of: pinnedFolderStore.folderPaths) { currentPaths in
            let validIDs = Set(["shelf"] + currentPaths.map { "folder-\($0)" })
            animatedEntryIDs.formIntersection(validIDs)
        }
        // 中转格显隐会改变整个固定区的落点几何：正在进行的外部拖放悬停立即收掉，不留高亮。
        // 入场动画只摘 "shelf" 这一个 id——整片清掉会让重新勾上时所有文件夹 chip 一起重放入场。
        .onChange(of: settingsStore.showShelf) { visible in
            if !visible { animatedEntryIDs.remove("shelf") }
            externalDropHoverEnded()
        }
        // No .frame(maxWidth: .infinity) here — lets NSHostingView.fittingSize reflect
        // the natural content width so AppDelegate can read it for panel sizing.
    }

    /// 正在拖动的文件夹 chip path（nil = 没有）。拖动中原位隐藏成空位,副本由载体面板画。
    private var draggingFolderPath: String? {
        guard ownsActiveDrag else { return nil }
        if let p = dragController.hiddenSlotPayload, p.source == .folder { return p.id }
        return nil
    }

    /// 文件夹区内重排：命中其他文件夹 chip 的全帧,按落点左/右半落位（镜像 live 区 reorderTarget,
    /// hit-test 只查 folderChipFrames——绝不查 chipFrames）。
    private func folderReorderTarget(at point: CGPoint, dragging path: String) {
        let draggedID = "folder-" + path
        guard let hit = folderChipFrames.first(where: { kv in
            kv.key != draggedID && kv.value.contains(point)
        }) else { return }
        let targetPath = String(hit.key.dropFirst("folder-".count))
        pinnedFolderStore.reorder(draggedPath: path, relativeTo: targetPath,
                                  after: point.x > hit.value.midX)
    }

    /// 固定区右边界（"strip" 局部坐标）：中转格 + 所有文件夹 chip 里最靠右的那个的右缘。
    /// 拖动中的 chip 本身位置不受隐藏影响（opacity 不改变布局），帧照常报,不需要排除自身。
    ///
    /// nil = 边界算不出来（首帧未测量，或中转格关着且暂无文件夹帧）。**不能把 nil 当成 0 或
    /// 当成"没有固定区"**：拖文件夹时固定区必然存在，边界缺失只说明还没量到，此时若判成
    /// 窗口区，原位松手会误删固定并打开 Finder。调用方遇到 nil 直接不装 geometry。
    private var folderZoneMaxX: CGFloat? {
        if let framesMaxX = folderChipFrames.values.map(\.maxX).max() { return framesMaxX }
        guard settingsStore.showShelf, shelfFrame != .zero else { return nil }
        return shelfFrame.maxX
    }

    /// 文件夹 chip 拖动中的实时落点分类,写进 DragController 供载体视图（跨 SwiftUI 树）读取做淡出。
    /// 最终落定也复用同一份屏幕坐标几何,由 DragController.endDrag 的 mouseUp/轮询兜底路径提交。
    private func updateFolderDragZone() {
        guard let p = dragController.draggingPayload, p.source == .folder,
              stripRootScreenRect != .zero,
              // 边界没量到就别装 geometry：DragController 对 nil geometry 回退 .folderZone（原位无动作），
              // 那是这里唯一安全的默认。
              let folderZoneMaxX else {
            dragController.setFolderDragZone(nil)
            dragController.setFolderDropGeometry(nil)
            return
        }
        let geometry = FolderChipDropGeometry(stripScreenRect: stripRootScreenRect,
                                              folderZoneMaxX: folderZoneMaxX)
        dragController.setFolderDropGeometry(geometry)
        dragController.setFolderDragZone(geometry.classify(screenPoint: dragController.globalLocation))
    }

    /// Converge the remembered live order with the current snapshot (drop closed, append new).
    /// Called on every `liveOrderIDs` change **and** once on appear (the latter mirrors the old
    /// `onChange(of:initial:)` seed that pre-macOS-14 `onChange` doesn't provide).
    func reconcileLiveOrder(_ projection: StripProjection) {
        let current = projection.liveOrderIDs
        let appKeys = projection.appKeyByChipID
        // 诊断载荷含整份 appKey 字典，**日志关着就别构造**（同 AppTracker 的 isEnabled 门控）。
        let sample: InventoryOrderProjectionSample? = stripOrderStore.isInventoryLogEnabled
            ? InventoryOrderProjectionSample(
                currentLiveIDs: current,
                absorbedMessagingMainIDs: projection.messaging.compactMap { entry in
                    guard case let .messagingApp(_, mainWindow) = entry else { return nil }
                    return mainWindow?.id
                },
                visibleMessagingBundleIDs: projection.messaging.compactMap { entry in
                    guard case let .messagingApp(bundleID, _) = entry else { return nil }
                    return bundleID
                },
                drawerBundleIDs: drawerStore.bundleIDs,
                appKeyByChipID: appKeys
              )
            : nil
        if HoverTrace.isEnabled, let p = dragController.carriedPayload {
            HoverTrace.orderSync(count: current.count,
                                 carriedID: p.bundleID,
                                 hasCarried: current.contains("app-\(p.bundleID)"))
        }
        stripOrderStore.sync(current: current, appKeyOf: appKeys,
                             headPreferred: Set(messagingStore.bundleIDs),
                             projectionSample: sample)
        // 拖动中被拖窗口消失 → 取消拖动，免得空位卡死。(松手无回调那条由 DragController 的轮询兜底。)
        if let p = dragController.draggingPayload, p.source == .strip, !current.contains(p.id) {
            dragController.cancelDrag()
        }
    }

    /// Live-zone reorder during a drag: find the chip whose **full frame** the finger is over
    /// (excluding the dragged chip itself), and place the dragged chip on the half the finger is
    /// in. Drives the existing `stripLayoutKeys` spring so the others slide aside as the gap moves.
    /// 全帧命中（不只看 x）：手指抬向胶囊/抽屉时 y 已离开条内行，contains 不命中 → 不误改顺序（Codex 二审）。
    private func reorderTarget(at point: CGPoint, dragging id: String, current: [String]) {
        guard let hit = chipFrames.first(where: { kv in
            kv.key != id && kv.value.contains(point)
        }) else { return }
        stripOrderStore.reorder(draggedID: id, relativeTo: hit.key,
                                after: point.x > hit.value.midX, current: current)
    }

    /// live 区（窗口卡 / 保留占位）重排的**唯一**驱动：指针位置，不是 chip 自己的手势
    ///（2026-08-19 起与消息区 / 抽屉 / 转正块同一条规矩）。归位飞行中被重新抓住的拖动
    /// 没有 SwiftUI 手势（`DragController.regrabLanding`），只有这条路能让它重排。
    /// 悬在投放区（胶囊 / 抽屉）时不重排——手指抬向胶囊时 y 已离开条内行，
    /// `contains` 也不会命中（Codex 二审第 4 条的两道闸都保留）。
    private func updateLiveReorder(projection: StripProjection) {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .strip, !dc.isOverDropZone,
              let pt = stripPoint(from: dc.globalLocation) else { return }
        reorderTarget(at: pt, dragging: p.id, current: projection.liveOrderIDs)
    }

    /// 文件夹区内重排的唯一驱动，同上。
    private func updateFolderReorder() {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .folder,
              let pt = stripPoint(from: dc.globalLocation) else { return }
        folderReorderTarget(at: pt, dragging: p.id)
    }

    // MARK: - 抽屉图标拖回任务条·精确落点（运行中应用，全局鼠标驱动，镜像 DrawerView）

    /// 抽屉拖出模式（判定是纯函数 `DragConversionPlan.drawerDragOutMode`，单测覆盖；这里只喂当前事实）。
    private func currentDrawerDragOutMode(_ bid: String, projection: StripProjection) -> DrawerDragOutMode {
        DragConversionPlan.drawerDragOutMode(
            bundleID: bid,
            isMessagingMember: messagingStore.contains(bid),
            isInSnapshot: projection.snapshotBundleIDs.contains(bid),
            // 与消息区可见性同源（NSWorkspace 进程投影），**不是**窗口清单——理由见 `drawerDragOutMode`。
            isRunningProcess: runningApplicationStore.isRunning(bid),
            hasRealWindow: projection.hasRealWindow(bundleID: bid),
            isKept: keptAppStore.contains(bid)
        )
    }

    /// 转正后同步两件**不同**的事，所以算两个值（分开的理由见 `DragController.convertedChipID`）：
    ///
    /// - `rep`：载体改画哪张卡。只能是真窗口卡；没有就保持 nil，载体继续画抽屉小图标。
    /// - `chipID`：条上隐藏哪张卡让出空位。**含 `.keptApp` 占位与 app 级兜底卡**——
    ///   `keepPlacement` 路径物化的正是这两种，漏了它们就是 owner 2026-08-18 报的「两个影子」。
    ///
    /// 由 `onChange(globalLocation)` 和 `onChange(liveOrderIDs)` 两处驱动。后者不能省：
    /// 转正和这里在同一个闭包里跑，用的是**上一帧**的 projection（那时 app 还在抽屉里），
    /// 只靠鼠标驱动的话，光标停在边界不动就会一直双影。
    func syncConvertedCarrier(projection: StripProjection) {
        let dc = dragController
        guard dc.isConvertedToStrip, let p = dc.draggingPayload, p.source == .drawer else { return }
        let rep = projection.liveChipIDs(bundleID: p.bundleID).first
            .flatMap { projection.liveOrderIDs.contains($0) ? projection.item(forID: $0) : nil }
        let chipID = projection.liveEntryIDs(bundleID: p.bundleID).first
        // **按 chip id 判有没有变，不按代表卡**：`keepPlacement` 路径物化的是 `.keptApp` 占位或
        // app 级兜底卡，代表卡恒为 nil，按它判就永远「没变」——于是那条路全程拎着一个 0.7 倍的
        // 抽屉小图标在 54pt 的卡片之间走，从来不变成卡片（owner 2026-08-20）。
        let changed = dc.convertedChipID != chipID
        dc.setConvertedRepresentative(rep, chipID: chipID)
        guard changed else { return }
        // 载体改画条上那张卡（与条内拖动同款）；`chipID` 变回 nil = 回滚，传 nil 让载体换回起拖那张图。
        let entry = chipID.flatMap { id in projection.entries.first { $0.id == id } }
        dc.setCarrierSnapshot(entry.flatMap { carrierSnapshot(for: $0, projection: projection) },
                              reanchor: true)
    }

    /// 飞行途中被点了一下的那张卡该干什么：和它在条上被点一下**完全一样**。
    /// 窗口卡 → 切换那个窗口；保留应用 / 无主窗的消息应用 → 运行中唤主窗、未运行启动、启动中不动。
    /// 文件夹 chip 不做（弹窗锚在还空着的格上，图标半秒后才到）；找不到 entry（已经不在条上）不做。
    private func performCarrierClick(_ payload: DragPayload, projection: StripProjection) {
        guard let entryID = carriedStripEntryID(for: payload),
              let entry = projection.entries.first(where: { $0.id == entryID }) else { return }
        switch entry {
        case let .window(item):
            runtime.toggle(windowID: item.actionWindowID)
        case let .messagingApp(bid, main):
            if let main {
                runtime.toggle(windowID: main.actionWindowID)
            } else {
                launcherTap(bid, hasRealWindow: projection.hasRealWindow(bundleID: bid))
            }
        case let .keptApp(bid):
            launcherTap(bid, hasRealWindow: false)   // 保留占位只在没有真窗口时存在
        case .pinnedFolder, .shelf, .divider:
            return
        }
    }

    /// 载荷 → 条上那张卡的 entry id。`nil` = 这份载荷不属于任务条（抽屉图标 / 文件夹 chip）。
    /// **两处共用**：飞行中点一下要找到它做动作、飞行中悬停要豁免它——两边算法必须是同一份。
    /// 同上，但先认「转正进任务条」的那张卡。转正的载荷来源**一直是 `.drawer`**
    /// （`convertDrawerToStrip` 有意不翻 source），静态那份对 `.drawer` 返回 nil——
    /// 于是落地那一刻悬停豁免失效，指针正压在刚显形的卡上、安静档当场放大到 1.10，
    /// 就是当年治过的「落位抖动」在这条路径上的形态（owner 2026-08-20）。
    func carriedStripEntryID(for payload: DragPayload) -> String? {
        if payload.source == .drawer, let cid = dragController.convertedChipID { return cid }
        return Self.stripEntryID(for: payload)
    }

    static func stripEntryID(for payload: DragPayload) -> String? {
        switch payload.source {
        case .strip: return payload.id                       // 窗口卡 = chip token；保留占位 = "app-<bid>"
        case .messaging: return "msg-app-\(payload.bundleID)"
        case .drawer, .folder: return nil
        }
    }

    /// `LauncherChip` 在条上的两条 tap 路径（`onTap: reopen` / `onLaunch`），加上它自己的「启动中不动」闸。
    private func launcherTap(_ bid: String, hasRealWindow: Bool) {
        guard !runtime.launchingBundleIDs.contains(bid) else { return }
        if runningApplicationStore.isRunning(bid) {
            Self.messagingFallbackTap(bundleID: bid, hasRealWindow: hasRealWindow)
        } else {
            _ = runtime.beginLaunch(bid)
        }
    }

    /// 松手时浮动副本该飞回哪一格（屏幕坐标）。**每次光标更新都写，包括写 nil**——
    /// 抽屉侧也在写它自己那一份，靠 owner 标签互不覆盖；不写 nil 的话，抽屉图标转正进任务条之后，
    /// 抽屉留下的旧锚点会让图标往已经关掉的抽屉里飞（见 `DragController.setLandingAnchor`）。
    ///
    /// 条内重排 / 消息区重排能给出准确落点：让位在拖动过程中就实时发生了，松手那一刻
    /// 这张卡的帧**就是**它的最终槽位。转正进任务条那一支给 nil——松手会解冻条宽、
    /// 整条重新居中，落点在飞行途中还会漂。
    private func updateLandingAnchor() {
        guard ownsActiveDrag else { return }
        let anchor: CGRect? = {
            // `carriedPayload`：飞行途中也要继续报，卡槽落定后 `DragController` 才纠得了偏。
            guard let p = dragController.carriedPayload, stripRootScreenRect != .zero else { return nil }
            // 已转正进任务条：锚点就是条上那张卡（`convertedChipID` 同时覆盖真窗口卡和
            // `keepPlacement` 物化出来的 `app-<bid>` 占位，两者都上报进 `chipFrames`）。
            // **2026-08-20 之前这里返回 nil，于是抽屉拖进任务条根本没有归位飞行**，图标从光标
            // 瞬移到槽位——当时的理由是「松手会解冻条宽、整条重新居中，落点在飞行途中会漂」，
            // 而那个漂已经不存在了：条宽不再钳（拖出即合拢后，条宽随时跟着渲染内容走）。
            // 认 `convertedChipID` 而不是 `isConvertedToStrip`：后者读的是 `conversion`，
            // 而 `conversion` 在 `teardown` 就清了，飞行途中会失去锚点、纠不了偏。
            if let cid = dragController.convertedChipID {
                return chipFrames[cid].map(stripFrameToScreen)
            }
            switch p.source {
            case .strip:  return chipFrames[p.id].map(stripFrameToScreen)
            case .folder: return folderChipFrames[p.id].map(stripFrameToScreen)
            case .messaging: return messagingChipFrames[p.bundleID].map(stripFrameToScreen)
            case .drawer: return nil   // 还没转正 → 落点在抽屉里，抽屉侧自己写
            }
        }()
        dragController.setLandingAnchor(anchor, owner: .strip)
    }

    /// 拍一张载体位图。**画的就是 `stripEntryContent` 那一份**——渲染卡槽和渲染载体是
    /// 同一个函数、同一批参数，只把「悬停」和「入场动画」按 false 传。所以「载体和卡槽同款」
    /// 是构造上成立的，不靠一张要人工维持的对照表（那种表这个仓库已经漏过两次：
    /// `ChipView.scale` 静默按中档渲染、消息区整个没有名字气泡）。
    ///
    /// 环境对象要在这里重新注入：`ChipView` 有五个 `@EnvironmentObject`，少一个就崩。
    private func carrierSnapshot(for entry: StripEntry, projection: StripProjection) -> CarrierSnapshot? {
        ChipSnapshotter.snapshot(
            of: stripEntryContent(entry, projection: projection, hovered: false, entrance: false)
                .environmentObject(runtime)
                .environmentObject(drawerStore)
                .environmentObject(messagingStore)
                .environmentObject(keptAppStore)
                .environmentObject(runningApplicationStore)
                .environmentObject(appMembershipController)
                .environmentObject(settingsStore)
                .environmentObject(badgeStore)
                .environmentObject(pinnedFolderStore)
                .environmentObject(folderCoverStore),
            screenPoint: CGPoint(x: stripRootScreenRect.midX, y: stripRootScreenRect.midY)
        )
    }

    /// 卡槽**此刻**的姿态：悬停放大（安静档底锚 1.10 / 文件夹 chip 底锚 1.12）× 按压 0.93（中心）。
    /// 载体第一帧按它摆才和卡槽逐像素重合——推导与数值见 `DragCarrierGeometry.pickUpPose`。
    /// 悬停放大的倍数用渲染卡片的**同一个** `ChipPillMetrics.quietHoverScale(forCardWidth:scale:)` 算，
    /// 卡宽取量到的帧宽（宽标题卡的封顶规则才对得上）。
    private func pickUpPose(for entry: StripEntry, slot: CGRect?) -> DragCarrierGeometry.PickUpPose {
        let hovered = hoveredEntryID == entry.id
        let height = slot?.height ?? ChipPillMetrics.chipHeight * dockScale
        switch entry {
        case .window, .messagingApp, .keptApp:
            let width = slot?.width ?? ChipPillMetrics.cardWidth * dockScale
            let hoverScale: CGFloat? = hoverStyle.showsQuietHoverFeedback(isHovering: hovered)
                ? ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: dockScale)
                : nil
            return DragCarrierGeometry.pickUpPose(
                chipHeight: height,
                pressedScale: ChipPressSwitches.pressDownEnabled ? ChipPressDecision.pressedScale : nil,
                hoverScale: hoverScale)
        case .pinnedFolder:
            // 文件夹 chip 两档都是 1.12 底锚放大，且没有按压反馈（AGENTS《Taskbar Size Tiers》）。
            return DragCarrierGeometry.pickUpPose(chipHeight: height, pressedScale: nil,
                                                  hoverScale: hovered ? PinnedFolderChip.hoverScale : nil)
        case .shelf, .divider:
            return .resting
        }
    }

    /// 按下那一刻给 `DragController` 预备候选（位图 + 卡槽帧）。帧还没量到就不预备，
    /// 起拖时会退回「先压着卡等两个显示帧」那条路。
    private func prepareDragCandidate(_ entry: StripEntry, id: String, slot: CGRect?,
                                      projection: StripProjection) {
        guard let slot, stripRootScreenRect != .zero else { return }
        dragController.prepareCandidate(payloadID: id,
                                        sourceScreenRect: stripFrameToScreen(slot),
                                        snapshot: carrierSnapshot(for: entry, projection: projection))
    }

    /// 屏幕坐标（bottom-left）→ "strip" 空间点（top-left, y-down）。
    func stripPoint(from global: CGPoint) -> CGPoint? {
        guard stripRootScreenRect != .zero else { return nil }
        return CGPoint(x: global.x - stripRootScreenRect.minX,
                       y: stripRootScreenRect.maxY - global.y)
    }

    /// 抽屉整块落点：**只看 x、永远给得出答案**。判据与理由（以及为什么不能用整帧 `contains`）
    /// 见纯类型 `StripBlockLanding`——简单说，转正判定框故意伸到条上沿之外 16pt，
    /// 而整帧命中在那里永远失败，首次落点因此 100% 退化成末尾。
    private func blockTarget(atX x: CGFloat, excluding block: Set<String>) -> (id: String, after: Bool)? {
        StripBlockLanding.target(pointerX: x,
                                 frames: chipFrames.filter { !block.contains($0.key) })
    }

    /// 条上起拖的载荷（窗口卡 / 占位 / 消息 chip / 文件夹 chip）进出本条判定框 → 告诉控制器：
    /// 进 = 让位复原（`.strip` 顺带认领换手——跨屏拖窗 ③④：空槽在这儿开、重排落这儿、落点锚点由这儿报）；
    /// 清楚出 = 空位合拢、条缩短（owner 2026-09-03，对齐原生 Dock）。判定框与抽屉转正同一个
    /// （`StripPointerBox`）。跑在 owner 门控之前：换手和「离开」都得由不认领的那条也能判。
    private func updateStripPresence() {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source != .drawer, dc.conversion == nil,
              stripRootScreenRect != .zero else { return }
        // 跨屏拖窗（③④）的认领按**指针所在的屏**，不看条的判定框（owner 2026-09-03：「拖到 B 屏幕就落到
        // B 条，拖到 A 屏幕就落到 A 条」；之前要压进另一条的框才换手，B 屏空处松手会飞回 A）。
        // 认领决定空槽开在哪条、落点锚点谁报、松手搬不搬窗；判定框只管空位合拢 / 重开。
        if p.source == .strip, let displayUUID,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(dc.globalLocation) }),
           DisplayIdentity.uuidString(for: screen) == displayUUID {
            dc.claimStripSurface(stripSurfaceID, displayUUID: displayUUID)
        }
        let box = StripPointerBox.classify(pointer: dc.globalLocation, stripRect: stripRootScreenRect,
                                           rightReach: metrics.capsuleGap + metrics.capsuleWidth,
                                           profile: .stripPresence)
        if box.enter {
            dc.noteStripEntered(surfaceID: stripSurfaceID, displayUUID: displayUUID)
        } else if box.clearlyOut {
            dc.noteStripLeft(surfaceID: stripSurfaceID)
        }
    }

    /// 进/出任务条区驱动转正/还原（迟滞防边界抖）。
    /// unstash 路径：进 → convertDrawerToStrip + 暂存落点；出 → cancelExternalBlock + revertDrawerToStrip。
    /// keepPlacement 路径：无真窗口时用现有 app fallback / kept placeholder 落位；全程不修改 kept。
    func updateDrawerToStripConvert(projection: StripProjection) {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .drawer, p.canExternalDrop,
              stripRootScreenRect != .zero else { return }
        let bid = p.bundleID
        let g = dc.globalLocation
        let r = stripRootScreenRect
        // 右侧容差伸到胶囊外缘的理由见 `StripPointerBox`（对抽屉来源的载荷胶囊没有别的语义，
        // 它的投放区只有任务条面板，并进来不会和收纳打架）。
        let box = StripPointerBox.classify(pointer: g, stripRect: r,
                                           rightReach: metrics.capsuleGap + metrics.capsuleWidth,
                                           profile: .drawerConversion)
        let enter = box.enter, clearlyOut = box.clearlyOut
        if HoverTrace.isEnabled {
            HoverTrace.drawerToStrip(x: g.x, y: g.y, strip: r, enter: enter, clearlyOut: clearlyOut,
                                     mode: "\(currentDrawerDragOutMode(bid, projection: projection))",
                                     converted: dc.isConvertedToStrip)
        }
        if !dc.isConvertedToStrip {
            guard enter else { return }
            let mode = currentDrawerDragOutMode(bid, projection: projection)
            // reject 留在抽屉；releaseToMessaging 由 updateDrawerToMessagingRelease 按消息区范围处理。
            guard mode == .unstash || mode == .keepPlacement else { return }
            // 此刻本组窗口卡还没出现在 live 区，命中目标只在**已有**卡里找（exclude 空集即可）。
            let target = stripPoint(from: g).flatMap { blockTarget(atX: $0.x, excluding: []) }
            dc.claimStripSurface(stripSurfaceID)   // 转正的这条从此独占写回，直到落地 / 撤销转正
            dc.convertDrawerToStrip()
            stripOrderStore.stageExternalBlock(bundleID: bid, relativeTo: target?.id, after: target?.after ?? false)
            HoverTrace.drawerToStripStage(bundleID: bid, target: target?.id, after: target?.after ?? false)
        } else if clearlyOut {
            stripOrderStore.cancelExternalBlock()
            dc.revertDrawerToStrip()
        }
    }

    // MARK: - 消息区拖拽（区内重排 + 抽屉消息应用的释放/回滚，全局鼠标驱动）

    /// 正在拖动的消息区 chip 的 bundleID（nil = 没有）。起拖后原位 opacity 隐藏、布局空位保留
    /// （空位即落点反馈）。收纳预览期载荷来源翻成 .drawer,此值自动归 nil——chip 那时已从区里消失。
    private var draggingMessagingBundleID: String? {
        guard ownsActiveDrag else { return nil }
        if let p = dragController.hiddenSlotPayload, p.source == .messaging { return p.bundleID }
        return nil
    }

    /// 当前消息区可见 chip 的 bundleID（区内显示序）。喂重排遍历 + 拖动中消失清理。
    /// 消息区范围（"strip" 空间）：现有消息 chip 帧的并集；区空时退化为条头一小段
    /// （释放后消息区在条头物化）。抽屉消息应用的释放判定用它,不认"离开抽屉体"（Codex 评审 P1-3）。
    private func messagingReleaseZone(messagingIDs: [String]) -> CGRect? {
        let frames = messagingIDs.compactMap { messagingChipFrames[$0] }
        if let first = frames.first {
            return frames.dropFirst().reduce(first) { $0.union($1) }
        }
        guard stripRootScreenRect != .zero else { return nil }
        return CGRect(x: 0, y: 0, width: 56, height: stripRootScreenRect.height)
    }

    /// 消息区内重排：命中其他消息 chip 帧（外扩 6pt 盖住格间空隙）,按左/右半落位。
    /// 按区内显示序遍历取最左（dict 顺序不定,外扩后相邻帧会重叠——同抽屉）。悬在投放区（胶囊/抽屉）时不重排。
    private func updateMessagingReorder(messagingIDs: [String]) {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .messaging,
              !dc.isOverDropZone,
              let pt = stripPoint(from: dc.globalLocation) else { return }
        for bid in messagingIDs where bid != p.bundleID {
            guard let f = messagingChipFrames[bid], f.insetBy(dx: -6, dy: -6).contains(pt) else { continue }
            messagingStore.reorder(draggedID: p.bundleID, relativeTo: bid, after: pt.x > f.midX)
            return
        }
    }

    /// 抽屉里的**运行中消息应用**拖到消息区范围 → 临时释放回消息区；离开范围（或进胶囊/抽屉投放区）→
    /// 回滚回抽屉。进 8pt / 出 24pt 迟滞防边界抖。释放后载荷来源是 .messaging,区内重排自动接管精确落位;
    /// 松手即落定（endDrag 决策见 DragConversionPlan.endAction）。桌面/文件夹区/live 区都不触发释放。
    private func updateDrawerToMessagingRelease(projection: StripProjection) {
        let dc = dragController
        if dc.isReleasedToMessaging {
            guard let pt = stripPoint(from: dc.globalLocation),
                  let zone = messagingReleaseZone(messagingIDs: projection.messagingIDs),
                  zone.insetBy(dx: -24, dy: -24).contains(pt),
                  !dc.isOverDropZone else {
                dc.revertDrawerToMessaging()
                return
            }
            return
        }
        // 这条路径以前一条日志都没有，所以「拖过去完全没反应」无从定因（对照：unstash 那条
        // 每 tick 都记 `d2s`，上一轮正是靠它一次定因）。逐条 guard 记下卡在哪里。
        guard let p = dc.draggingPayload, p.source == .drawer, p.canExternalDrop else { return }
        // 只有消息成员才记：普通应用每 tick 都记会把日志淹掉（它们本来就该走 unstash，有 `d2s`）。
        let isMessagingMember = messagingStore.contains(p.bundleID)
        func trace(_ stop: String, pt: CGPoint? = nil, zone: CGRect? = nil,
                   fallback: Bool = false, mode: String = "-", inZone: Bool = false) {
            HoverTrace.drawerToMessaging(
                bid: p.bundleID, x: pt?.x ?? -1, y: pt?.y ?? -1, zone: zone,
                fallback: fallback, mode: mode,
                inSnapshot: projection.snapshotBundleIDs.contains(p.bundleID),
                running: runningApplicationStore.isRunning(p.bundleID),
                inZone: inZone, released: false, stop: stop)
        }
        guard !dc.isConvertedToStrip else {
            if isMessagingMember { trace("convertedToStrip") }
            return
        }
        let mode = currentDrawerDragOutMode(p.bundleID, projection: projection)
        guard mode == .releaseToMessaging else {
            if isMessagingMember { trace("mode", mode: "\(mode)") }
            return
        }
        guard let pt = stripPoint(from: dc.globalLocation) else { return trace("noStripRect", mode: "\(mode)") }
        let fallback = projection.messagingIDs.compactMap { messagingChipFrames[$0] }.isEmpty
        guard let zone = messagingReleaseZone(messagingIDs: projection.messagingIDs) else {
            return trace("noZone", pt: pt, mode: "\(mode)")
        }
        let inZone = zone.insetBy(dx: -8, dy: -8).contains(pt)
        guard inZone else {
            return trace("outsideZone", pt: pt, zone: zone, fallback: fallback, mode: "\(mode)")
        }
        HoverTrace.drawerToMessaging(
            bid: p.bundleID, x: pt.x, y: pt.y, zone: zone, fallback: fallback, mode: "\(mode)",
            inSnapshot: projection.snapshotBundleIDs.contains(p.bundleID),
            running: runningApplicationStore.isRunning(p.bundleID),
            inZone: true, released: true, stop: "ok")
        // 释放到本条消息区后本条独占写回，直到落地 / 撤销释放（`revertDrawerToMessaging` 放手）。
        // 与 `updateDrawerToStripConvert` 同一句：③④ 下两条 strip 都跑这段，不认领的话另一条
        // 每 tick 按自己的消息区判「已释放但不在区内」→ 撤销，两条互相翻转，松手落谁看订阅顺序。
        dc.claimStripSurface(stripSurfaceID)
        dc.convertDrawerToMessaging()
    }

    /// 释放回消息区之后，把载体从抽屉小图标换成**消息区那张图标**，与转正进任务条那条同款。
    ///
    /// 漏了这一步的症状：全程拎着 30.8pt 的抽屉小图标，松手交接那一刻条上冒出 44pt 的消息区图标，
    /// 中间没有任何过渡 ——「从很小突然变大，大小过渡生硬」（owner 2026-08-20 报，微信）。
    ///
    /// **不能在 `convertDrawerToMessaging()` 当轮换**：那一刻 chip 还没物化进投影（手里是上一帧的），
    /// 所以和 `syncConvertedCarrier` 一样挂两处驱动（指针 + `messagingIDs` 变化）。
    private func syncReleasedMessagingCarrier(projection: StripProjection) {
        let dc = dragController
        let entry: StripEntry? = {
            guard dc.isReleasedToMessaging, let p = dc.draggingPayload, p.source == .messaging else { return nil }
            return projection.messaging.first { $0.id == "msg-app-\(p.bundleID)" }
        }()
        guard entry?.id != carriedMessagingChipID else { return }
        carriedMessagingChipID = entry?.id
        // entry 变回 nil = 回滚回抽屉，传 nil 让载体换回起拖时那张抽屉图。
        dc.setCarrierSnapshot(entry.flatMap { carrierSnapshot(for: $0, projection: projection) },
                              reanchor: true)
    }

    /// 转正后整块连续重排：本组窗口卡都进了 live 区（已实体化）才动；初次落点由暂存在 sync 内完成。
    /// keepPlacement 路径无窗口卡，用占位 id "app-\(bid)" 做单元素块重排。
    private func updateStripBlockReorder(projection: StripProjection) {
        let dc = dragController
        guard dc.isConvertedToStrip, let p = dc.draggingPayload, p.source == .drawer else { return }
        let ids = projection.liveChipIDs(bundleID: p.bundleID)
        let blockIDs = ids.isEmpty ? ["app-\(p.bundleID)"] : ids
        guard !blockIDs.isEmpty, blockIDs.allSatisfy(projection.liveOrderIDs.contains) else {
            HoverTrace.stripBlockReorder(target: nil, after: false, why: "notMaterialized")
            return
        }
        guard let pt = stripPoint(from: dc.globalLocation) else {
            HoverTrace.stripBlockReorder(target: nil, after: false, why: "noStripRect")
            return
        }
        guard let target = blockTarget(atX: pt.x, excluding: Set(blockIDs)) else {
            HoverTrace.stripBlockReorder(target: nil, after: false, why: "liveZoneEmpty")
            return
        }
        HoverTrace.stripBlockReorder(target: target.id, after: target.after, why: "ok")
        stripOrderStore.reorderBlock(ids: blockIDs, relativeTo: target.id, after: target.after)
    }

    /// Wraps a chip with in-app drag-reorder for the **live zone only** (路线 A 自绘拖动).
    /// Pinned messaging chips don't participate (no gesture → can't land in that zone, 拖动分区内进行).
    ///
    /// Native-Dock feel: while dragging, the in-place chip is hidden (`opacity 0`) so its slot
    /// becomes the landing **gap**; what you carry is the self-rendered `floatingDragCopy` (fully
    /// ours → 松手零残影, unlike the old system `.onDrag` image that faded in place). Pointer over a
    /// target's left/right half → land left/right. A plain tap (< minimumDistance) still falls
    /// through to the chip's `onTapGesture`; right-click still opens the menu; horizontal scroll
    /// is wheel/trackpad so it never fights this click-drag.
    @ViewBuilder
    private func chipWithReorder(_ entry: StripEntry, projection: StripProjection) -> some View {
        switch entry {
        case let .window(item):
            stripEntryView(entry, projection: projection)
                .opacity(projection.draggingID == item.id ? 0 : 1)
                // Frame in the shared `"strip"` space via a **background** GeometryReader — doesn't
                // affect layout and doesn't steal clicks (an overlay with a hittable Color.clear
                // intercepts taps — the original slice-3 bug). Feeds both the floating copy's
                // position and the left/right-half landing decision.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChipFramePreferenceKey.self,
                                               value: [item.id: geo.frame(in: .named("strip"))])
                    }
                )
                // simultaneousGesture so the chip's own onTapGesture / contextMenu stay intact.
                // minimumDistance: 8 → a click never starts a drag (no misfire).
                // 起拖交给 DragController（载体面板 + 监视器全程接管跟手/落点/收尾）；本手势只负责
                // **起拖一次**（算 grabOffset，取屏幕坐标起点）。条内重排自 2026-08-19 起也由指针驱动
                //（`updateLiveReorder`，同消息区 / 抽屉 / 转正块）：归位飞行中被重新抓住的拖动没有手势。
                // onEnded 是监视器 mouseUp 之外的幂等兜底。
                // **按下即预备**（`DragController.prepareCandidate`）：mouse-down 那一刻就把这张卡的位图
                // 挂上载体图层预热纹理，起拖当轮才能「点亮 + 藏卡」同帧。松手没起拖就撤掉。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: item.id, slot: chipFrames[item.id], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: item.id) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            if dragController.draggingPayload == nil {
                                let slot = chipFrames[item.id]
                                let grab: CGSize = slot.map {
                                    CGSize(width: $0.midX - value.startLocation.x,
                                           height: $0.midY - value.startLocation.y)
                                } ?? .zero
                                let payload = DragPayload(source: .strip, id: item.id,
                                                          bundleID: item.bundleIdentifier ?? "",
                                                          item: item, visualKind: .stripChip,
                                                          canExternalDrop: DragController.canStash(item))
                                dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                         startScreenLocation: NSEvent.mouseLocation,
                                                         grabOffset: grab,
                                                         sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                         pose: pickUpPose(for: entry, slot: slot),
                                                         snapshot: carrierSnapshot(for: entry, projection: projection))
                            }
                            // 条内重排**不在这里**：由 `updateLiveReorder`（指针驱动）统一做——
                            // 归位飞行中被重新抓住的拖动没有这个手势（见 `DragController.regrabLanding`）。
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case let .messagingApp(bid, _):
            // 消息区 chip 可拖：区内重排 + 拖进抽屉收纳（owner 2026-07-11）。帧上报进**独立**的
            // MessagingChipFramePreferenceKey（绝不混 chipFrames,同文件夹 chip 的隔离理由）。
            // 手势**只负责起拖一次**：重排会挪动本 chip、SwiftUI 随即取消手势 → 区内重排由
            // updateMessagingReorder() 按全局鼠标驱动（同抽屉教训,Codex 评审 P1-4）。
            stripEntryView(entry, projection: projection)
                .opacity(draggingMessagingBundleID == bid ? 0 : 1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: MessagingChipFramePreferenceKey.self,
                                               value: [bid: geo.frame(in: .named("strip"))])
                    }
                )
                // **按下即预备**（`DragController.prepareCandidate`）：mouse-down 那一刻就把这张卡的位图
                // 挂上载体图层预热纹理，起拖当轮才能「点亮 + 藏卡」同帧。松手没起拖就撤掉。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: bid, slot: messagingChipFrames[bid], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: bid) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            guard dragController.draggingPayload == nil else { return }
                            let slot = messagingChipFrames[bid]
                            let grab: CGSize = slot.map {
                                CGSize(width: $0.midX - value.startLocation.x,
                                       height: $0.midY - value.startLocation.y)
                            } ?? .zero
                            let payload = DragPayload(source: .messaging, id: bid,
                                                      bundleID: bid, item: nil,
                                                      visualKind: .messagingIcon,
                                                      canExternalDrop: true)
                            dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                     startScreenLocation: NSEvent.mouseLocation,
                                                     grabOffset: grab,
                                                     sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                     pose: pickUpPose(for: entry, slot: slot),
                                                     snapshot: carrierSnapshot(for: entry, projection: projection))
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case let .keptApp(bid):
            // 保留应用占位可拖：镜像 .window 卡的拖动重排 + 可拖进抽屉（canExternalDrop=true）。
            let chipID = "app-\(bid)"
            stripEntryView(entry, projection: projection)
                .opacity(projection.draggingID == chipID ? 0 : 1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChipFramePreferenceKey.self,
                                               value: [chipID: geo.frame(in: .named("strip"))])
                    }
                )
                // **按下即预备**（`DragController.prepareCandidate`）：mouse-down 那一刻就把这张卡的位图
                // 挂上载体图层预热纹理，起拖当轮才能「点亮 + 藏卡」同帧。松手没起拖就撤掉。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: chipID, slot: chipFrames[chipID], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: chipID) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            if dragController.draggingPayload == nil {
                                let slot = chipFrames[chipID]
                                let grab: CGSize = slot.map {
                                    CGSize(width: $0.midX - value.startLocation.x,
                                           height: $0.midY - value.startLocation.y)
                                } ?? .zero
                                let payload = DragPayload(source: .strip, id: chipID,
                                                          bundleID: bid, item: nil,
                                                          visualKind: .keptAppIcon,
                                                          canExternalDrop: true)
                                dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                         startScreenLocation: NSEvent.mouseLocation,
                                                         grabOffset: grab,
                                                         sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                         pose: pickUpPose(for: entry, slot: slot),
                                                         snapshot: carrierSnapshot(for: entry, projection: projection))
                            }
                            // 条内重排见 `updateLiveReorder`（指针驱动，同 .window 分支）。
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case let .pinnedFolder(path):
            // 文件夹 chip：区内拖拽重排 + 拖出移除 + 拖回窗口区打开（owner 2026-07-06 反馈落地）。
            // 帧上报进**独立**的 FolderChipFramePreferenceKey（弹窗锚点 + 外部 pin 路由 + 本区重排
            // hit-test）,绝不混入 live 重排的 chipFrames（评审 P1）。手势镜像 .window 卡:起拖交
            // DragController（.folder 来源,与 strip/drawer 收纳语义隔离）；区内重排与
            // FolderChipDropGeometry 由指针驱动；最终移除/打开由 DragController.endDrag 的兜底收尾触发。
            stripEntryView(entry, projection: projection)
                .opacity(draggingFolderPath == path ? 0 : 1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: FolderChipFramePreferenceKey.self,
                                               value: [entry.id: geo.frame(in: .named("strip"))])
                    }
                )
                // **按下即预备**（`DragController.prepareCandidate`）：mouse-down 那一刻就把这张卡的位图
                // 挂上载体图层预热纹理，起拖当轮才能「点亮 + 藏卡」同帧。松手没起拖就撤掉。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: path, slot: folderChipFrames[entry.id], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: path) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            if dragController.draggingPayload == nil {
                                let slot = folderChipFrames[entry.id]
                                let grab: CGSize = slot.map {
                                    CGSize(width: $0.midX - value.startLocation.x,
                                           height: $0.midY - value.startLocation.y)
                                } ?? .zero
                                let payload = DragPayload(source: .folder, id: path,
                                                          bundleID: "", item: nil,
                                                          visualKind: .folderChip,
                                                          canExternalDrop: false)
                                dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                         startScreenLocation: NSEvent.mouseLocation,
                                                         grabOffset: grab,
                                                         sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                         pose: pickUpPose(for: entry, slot: slot),
                                                         snapshot: carrierSnapshot(for: entry, projection: projection))
                            }
                            // 区内重排 + 落点分类都由指针驱动（`updateFolderReorder` / `updateFolderDragZone`
                            // 在 `.onReceive(pointerMoves)` 里）——重抓出来的拖动没有这个手势。
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case .shelf:
            // 中转格固定头位,不可拖拽。帧走独立的 ShelfFramePreferenceKey（评审：不混 sentinel）。
            stripEntryView(entry, projection: projection)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ShelfFramePreferenceKey.self,
                                               value: geo.frame(in: .named("strip")))
                    }
                )
        case .divider:
            stripEntryView(entry, projection: projection)
        }
    }

    /// 悬停命中帧在这里**一处**上报（`StripHoverFramePreferenceKey`），所以四个区不可能漏
    /// ——`ChipView.onWindowTitleTooltipEvent` 当年那种"某个调用点漏传、编译还过"的坑
    /// 在这条路径上不会重演。分隔线也报：它占住那 5pt，指针压上去就没人拥有气泡，
    /// 于是宽缝天然是"什么都不弹"，两边的卡也不会隔着它抢。
    @ViewBuilder
    private func stripEntryView(_ entry: StripEntry, projection: StripProjection) -> some View {
        stripEntryContent(entry, projection: projection,
                          hovered: hoveredEntryID == entry.id, entrance: true)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: StripHoverFramePreferenceKey.self,
                                           value: [entry.id: geo.frame(in: .named("strip"))])
                }
            )
    }

    /// 四个区唯一的渲染漏斗。**载体位图也从这里出**（`carrierSnapshot(for:projection:)`），
    /// 所以「载体画的必须是卡槽同款视图」是构造上成立的，不需要另维护一张对照表。
    ///
    /// - Parameters:
    ///   - hovered: 指针在不在这张卡上。以前是在这里读 `hoveredEntryID`，改成显式传入，
    ///     快照路径才传得进 `false`（载体不可命中，画的必须是非悬停态）。
    ///   - entrance: 要不要走入场动画（`stripEntrance`）。**快照必须传 `false`**：
    ///     那个修饰器的 `@State` 从 `opacity 0 / offset 8` 起步，靠 `onAppear` 才翻正，
    ///     而快照是同步拍的——拍出来会是一张半透明、偏上 8pt 的图。
    @ViewBuilder
    private func stripEntryContent(_ entry: StripEntry, projection: StripProjection,
                                   hovered: Bool, entrance: Bool) -> some View {
        switch entry {
        case let .window(item):
            // 角标跟着应用走（2026-08-23）：`badgesByBundleID` 已按消息应用身份圈过范围，
            // 这里只再挑「该 app 最左那张卡」。
            let windowBadge: String? = item.bundleIdentifier.flatMap { bid in
                projection.badgeEntryIDByBundle[bid] == item.id ? badgeStore.badgesByBundleID[bid] : nil
            }
            ChipView(item: item,
                     labelTitle: projection.labelTitleByChipID[item.id] ?? item.title,
                     scale: dockScale,
                     hoverStyle: hoverStyle,
                     isHovered: hovered,
                     // 只有 app-* 兜底卡（访达常驻 / 保留兜底）代表整个应用；普通窗口卡不列。
                     showsWindowListInMenu: item.isAppLevelFallback,
                     showRunningDot: true,
                     pulseNonce: chipPulseNonces[item.id] ?? 0,
                     badgeText: windowBadge,
                     slotHidden: projection.draggingID == item.id)
        case .divider:
            Rectangle()
                .fill(theme.zoneDivider.color)
                // 宽度是发丝线，恒 1pt 不缩；只有高度跟着档位走。
                .frame(width: 1, height: Style.dividerHeight * dockScale)
                .padding(.horizontal, 2 * dockScale)
        case let .pinnedFolder(path):
            let index = 1 + (pinnedFolderStore.folderPaths.firstIndex(of: path) ?? 0)
            let delay = Double(min(index, 6)) * 0.018
            PinnedFolderChip(
                path: path,
                cover: folderCoverStore.covers[path],
                sortOrder: pinnedFolderStore.sortOrder(for: path),
                onTap: { folderPrimaryTap(path) },
                onPreview: { folderShowPreview(path) },
                onOpenInFinder: { openFolderInFinder(path) },
                onAddFolder: onAddFolder,
                onRemove: { pinnedFolderStore.remove(path) },
                onSetSortOrder: { pinnedFolderStore.setSortOrder($0, for: path) },
                isDropTarget: externalDropTarget == .moveInto(path: path),
                scale: dockScale,
                hoverStyle: hoverStyle,
                isHovered: hovered
            )
            .stripEntrance(id: entrance ? entry.id : nil, delay: delay,
                           animatedEntryIDs: $animatedEntryIDs)
        case .shelf:
            ShelfChip(
                itemCount: shelfStore.itemPaths.count,
                isDropTargeted: externalDropTarget == .stash,
                scale: dockScale,
                hoverStyle: hoverStyle,
                isHovered: hovered,
                onTap: { shelfChipTapped() },
                onClear: { shelfStore.clear() },
                onAddFolder: onAddFolder
            )
            .stripEntrance(id: entrance ? entry.id : nil, delay: 0,
                           animatedEntryIDs: $animatedEntryIDs)
        case let .messagingApp(bid, main):
            // 未读角标交给 chip 自己画（`badgeText:`），不再由这里套一层 ZStack 叠上去。
            // 叠在外面时它落在 chip 的缩放**之外**：悬停放大 / 按下回缩，红点纹丝不动
            // （owner 2026-08-17 实测两帧都是 16×15pt）。见 `ChipBadgeView`。
            let badge = badgeStore.badgesByBundleID[bid]
            Group {
                if let main {
                    // 运行中有主窗 → app chip 即主窗卡：标准 toggle + 完整窗口菜单。iconOnly 保持消息区
                    // 定宽图标行，运行点标记它是 app 入口。
                    // 消息区这张永远 `iconOnly`、不显示文字，标签给原始标题即可（`.help` 仍走 `fullTitle`）。
                    ChipView(item: main, labelTitle: main.title,
                             scale: dockScale, hoverStyle: hoverStyle,
                             isHovered: hovered,
                             // 消息区图标恒代表整个应用（主窗开着也一样），列出全部窗口。
                             showsWindowListInMenu: true,
                             iconOnly: true, showRunningDot: true,
                             badgeText: badge,
                             slotHidden: draggingMessagingBundleID == bid)
                } else {
                    // 无主窗两态：运行中（关窗/常驻）→ 点击 reopen 主窗；未运行（图标下方无运行点）→ 点击启动。
                    // 统一模型下消息应用也有「在程序坞中保留」勾选（与「取消标记」并存），由纯投影决定。
                    let running = runningApplicationStore.isRunning(bid)
                    LauncherChip(bundleID: bid,
                                 isRunning: running,
                                 isHidden: running && projection.hiddenBundleIDs.contains(bid),
                                 finderHasRealWindow: false,   // 访达进不了消息区

                                 isLaunching: runtime.launchingBundleIDs.contains(bid),
                                 scale: dockScale,
                                 hoverStyle: hoverStyle,
                                 hoverInput: .resolved(hovered),
                                 windowEntriesProvider: {
                                     WindowListMenuPlan.entries(
                                         snapshot: runtime.snapshot,
                                         bundleID: bid,
                                         fallbackTitle: AppDisplayNameResolver.displayName(for: bid)
                                     )
                                 },
                                 onActivateWindow: { runtime.activate(windowID: $0) },
                                 membershipItems: LauncherMembershipItem.items(
                                    surface: .strip,
                                    bundleID: bid,
                                    isKept: keptAppStore.contains(bid),
                                    isMessaging: true,
                                    controller: appMembershipController
                                 ),
                                 badgeText: badge,
                                 slotHidden: draggingMessagingBundleID == bid,
                                 onTap: running
                                    ? { Self.messagingFallbackTap(bundleID: bid,
                                                                  hasRealWindow: projection.hasRealWindow(bundleID: bid)) }
                                    : nil,
                                 onLaunch: { runtime.beginLaunch(bid) })
                }
            }
        case let .keptApp(bid):
            let isRunning = runningApplicationStore.isRunning(bid)
            let hasRealWindow = projection.hasRealWindow(bundleID: bid)
            let reopen: (() -> Void)? = isRunning && !hasRealWindow
                ? { Self.reopenMainWindow(bundleID: bid) }
                : nil
            LauncherChip(
                bundleID: bid,
                isRunning: isRunning,
                isHidden: runningApplicationStore.isHidden(bid),
                finderHasRealWindow: false,   // 访达有意不走 .keptApp 投影

                isLaunching: runtime.launchingBundleIDs.contains(bid),
                scale: dockScale,
                hoverStyle: hoverStyle,
                hoverInput: .resolved(hovered),
                windowEntriesProvider: {
                    WindowListMenuPlan.entries(
                        snapshot: runtime.snapshot,
                        bundleID: bid,
                        fallbackTitle: AppDisplayNameResolver.displayName(for: bid)
                    )
                },
                onActivateWindow: { runtime.activate(windowID: $0) },
                membershipItems: keptAppMembershipItems(bundleID: bid),
                badgeText: projection.badgeEntryIDByBundle[bid] == entry.id
                    ? badgeStore.badgesByBundleID[bid] : nil,
                slotHidden: projection.draggingID == "app-\(bid)",
                onTap: reopen,
                onLaunch: { runtime.beginLaunch(bid) }
            )
        }
    }

}

// MARK: - Visual Constants (hand-tune these)

private enum Style {
    // Shape —— 圆角与其余 4 个面板共用一处定义（本 enum 是 private，别的文件读不到）。
    static let cornerRadius: CGFloat   = DockShape.panelCornerRadius

    // Content layout
    static let chipContentInset: CGFloat = 20  // horizontal padding inside blur; > cornerRadius avoids corner-clip
    static let edgeFadeWidth: CGFloat    = 16  // scroll edge fade-out width (pt)
    // 真身在 `ChipPillMetrics.chipSpacing`（气泡的邻域判定也要用中心间距，而本 enum 是
    // private，别的文件读不到）。改它必须同步改 `StripContextMenuZone.defaultMinimumGapWidth`，
    // 理由见那边的注释。
    static let chipSpacing: CGFloat      = ChipPillMetrics.chipSpacing
    static let dividerHeight: CGFloat    = 20  // zone divider height (pt)

    // 描边的「顶强底弱」高光已由 DockThemeTokens.panelRimTop / panelRimBottom 正式接管
    //（原先这里的两个常量是零引用的死代码，实际画的是均匀一圈白 0.15）。
}
