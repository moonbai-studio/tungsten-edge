import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// One slot in the strip: a concrete window chip, an app-level leading entry,
/// a pinned folder/shelf entry, or a zone divider.
enum StripEntry: Identifiable, Hashable {
    case window(StripItem)
    /// Constant app-icon chip for a pinned messaging app. Carries the main window's
    /// StripItem when it exists (the chip then *is* that window: toggle + full window
    /// menu); when the main window is gone, tap sends a reopen (Dock-icon-click
    /// equivalent) so the app recreates it — verified to work for WeChat even with
    /// other chat windows visible.
    case messagingApp(bundleID: String, mainWindow: StripItem?)
    /// 「在程序坞中保留」的应用：运行时照常窗口卡片；退出后收敛成一个 app 图标留在原位。
    /// id 恒为 "app-\(bid)"——与 AppTracker rebuildSnapshot() 的无窗口 fallback token 同串，
    /// 是退出↔占位切换时 live 序连续的命门。
    case keptApp(bundleID: String)
    /// 固定文件夹区的一格（消息区右侧、窗口区左侧）。path 即身份。
    case pinnedFolder(path: String)
    /// 中转格：文件夹区固定头位的暂存格（不可拖拽,常驻——它也是文件夹区永不为空的保证,
    /// 让「拖目录进来固定」在还没固定过任何文件夹时就有落区）。
    case shelf
    /// Visual separator between zones. 现在最多两条（消息|文件夹、文件夹|窗口），id 必须唯一。
    case divider(id: String)

    var id: String {
        switch self {
        case let .window(item): return item.id
        // Stable id regardless of main-window presence, so the chip doesn't churn
        // when the main window opens/closes.
        case let .messagingApp(bid, _): return "msg-app-\(bid)"
        case let .keptApp(bid): return "app-\(bid)"
        case let .pinnedFolder(path): return "folder-\(path)"
        case .shelf: return "shelf"
        case let .divider(id): return id
        }
    }
}

struct StripProjection {
    let snapshotItems: [StripItem]
    let snapshotBundleIDs: Set<String>
    let hiddenBundleIDs: Set<String>
    let messaging: [StripEntry]
    let liveNatural: [StripEntry]
    let liveOrderIDs: [String]
    let appKeyByChipID: [String: String]
    let entries: [StripEntry]
    let layoutKeys: [StripLayoutKey]
    let messagingIDs: [String]
    let draggingID: String?

    func hasRealWindow(bundleID: String) -> Bool {
        snapshotItems.contains {
            $0.bundleIdentifier == bundleID && !$0.isAppLevelFallback
        }
    }

    func item(forID id: String) -> StripItem? {
        guard let entry = liveNatural.first(where: { $0.id == id }),
              case let .window(item) = entry else { return nil }
        return item
    }

    func liveChipIDs(bundleID: String) -> [String] {
        entries.compactMap { entry -> String? in
            guard case let .window(item) = entry,
                  item.bundleIdentifier == bundleID,
                  !item.isAppLevelFallback else { return nil }
            return item.id
        }
    }

    /// 该 app 在 live 区占了位置的**所有卡**，显示序，**不排除 app 级兜底卡与 `.keptApp` 占位**。
    ///
    /// 和 `liveChipIDs` 是两个口径，不要合并：那个回答「载体该画哪张窗口卡」，
    /// 这个回答「条上哪张卡要让位」。兜底卡和占位卡画不成载体，但它们实实在在占着一格——
    /// 早先两个问题共用前一个口径，`keepPlacement` 路径就永远不让位（双影，owner 2026-08-18）。
    func liveEntryIDs(bundleID: String) -> [String] {
        entries.compactMap { entry -> String? in
            switch entry {
            case let .window(item):
                return item.bundleIdentifier == bundleID ? item.id : nil
            case let .keptApp(bid):
                return bid == bundleID ? entry.id : nil
            default:
                return nil
            }
        }
    }
}

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

    /// 这条任务条的底板是不是原生 Liquid Glass。由 `PanelCoordinator` 在建面板时一次定死
    /// （背景窗口建成功才为 true），**显式传入、没有默认值**：同 `scale` / `hoverStyle`，
    /// 漏传是编译错误。不要退回读全局静态量 —— SwiftUI 观察不到它，面板拆除后会读到旧值。
    let usesLiquidGlass: Bool

    /// 当前尺寸档位派生的面板几何与缩放系数。**条内不写裸尺寸数字**——凡是随任务条一起
    /// 放大缩小的值都乘 `dockScale`；发丝线（分隔线宽、描边）保持 1pt 不缩。
    private var metrics: PanelLayoutMetrics { settingsStore.dockSize.metrics }
    private var dockScale: CGFloat { settingsStore.dockSize.scale }
    /// 任务条圆角。**玻璃态与毛玻璃态同一个值** —— 几何只有 `DockSize.metrics` /
    /// `DockShape` 一个来源，换底板材质不改尺寸（否则四档缩放失效，`scale` 的定义
    /// 就是 `panelHeight / 52`）。
    private var taskbarCornerRadius: CGFloat { Style.cornerRadius * dockScale }
    /// 悬停效果档位。条内每个 chip 都显式接收它（同 `dockScale`，漏传是编译错误）；
    /// 抽屉面板与抽屉入口胶囊有意不受它影响（owner 2026-08-02）。
    private var hoverStyle: HoverStyle { settingsStore.hoverStyle }
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
    @State private var chipFrames: [String: CGRect] = [:]
    /// 手势预览触发的按 chip 脉冲计数（重击/中键活访达窗口时 +1，给 ~200ms 反查一个即时"点到了"）。
    @State private var chipPulseNonces: [String: Int] = [:]

    /// 文件夹 chip 帧（弹窗锚点 + 外部拖入的 pin 落点路由）。**独立字典,绝不混入 chipFrames**——
    /// 那是 live 窗口区拖拽重排与抽屉拖回落点的输入,混入会让窗口拖动命中文件夹区、落点 no-op（评审 P1）。
    @State private var folderChipFrames: [String: CGRect] = [:]

    /// 消息区 chip 帧（bundleID → "strip" 空间 frame）。**独立字典,同文件夹 chip 的理由绝不混入
    /// chipFrames**——喂消息区内重排 hit-test + 抽屉拖出的"消息区范围"释放判定。
    @State private var messagingChipFrames: [String: CGRect] = [:]

    /// 中转格 frame（"strip" 空间）。**独立上报,不塞进 folderChipFrames**（评审：那个字典专属
    /// 文件夹 chip,后续还喂文件夹重排 hit-test,不能混 sentinel）。喂中转弹窗锚点 + drop 路由。
    @State private var shelfFrame: CGRect = .zero

    /// 外部文件拖入的实时落点目标（悬停高亮用;nil = 没有外部拖拽悬停）。
    @State private var externalDropTarget: StripDropRouting.Target?

    /// 外部拖入高亮的「拖放结束看门狗」+「点亮门控」。SwiftUI 文件 drop 有两种收尾异常:
    /// ①拖放在最后一次 dropUpdated 后不给任何 performDrop/dropExited 收尾回调 → 高亮遗留在 .pin;
    /// ②成功 drop 后 ~330ms 会补发一次孤立的 dropUpdated 把高亮重新点亮。
    /// 门控:高亮只能由 dropEntered 点亮（hoverActive），落定/离开后孤立的 dropUpdated 一律忽略（治②回闪）。
    /// 看门狗:可取消的 .common Timer,拖放悬停停更超时即清遗留高亮（治①永久白边）;generation 防旧 timer 误清。
    /// 逻辑见 externalDropHoverBegan/Moved/Ended + setExternalDropTarget。
    @State private var externalDropWatchdog: Timer?
    @State private var externalDropGeneration = 0
    @State private var externalDropHoverActive = false

    /// 任务条内容区（"strip" 空间）在屏幕坐标系的 frame（bottom-left）。抽屉拖回任务条·精确落点用它把
    /// 全局鼠标位置映回 "strip" 空间命中卡片，并判进/出任务条区（迟滞）。与 "strip" 命名空间挂同一视图。
    @State private var stripRootScreenRect: CGRect = .zero

    /// 悬停命中帧（`StripEntry.id` → "strip" 空间帧）。**又一本独立字典**，理由同上面那三本：
    /// 它们各有各的用途（重排 / 弹窗锚点 / 释放判定），谁也不能替谁。这一本是「指针落在谁身上」
    /// 的唯一依据，所以**四个区的卡全收进来**，由 `stripEntryView` 一处统一上报。
    @State private var stripHoverFrames: [String: CGRect] = [:]

    /// 指针当前压在哪张卡上。**全条唯一的悬停真相**——悬停视觉和名字气泡都读它。
    /// 每张卡不再各自挂 `.onHover`，成因与实测见 `StripHoverResolution`。
    @State private var hoveredEntryID: String?

    /// 最后一次指针位置（屏幕坐标）。**刻意放在引用盒里而不是 `@State` 值**：
    /// 指针每动一次都写 `@State` 就会以指针的频率重算整条 body，而真正需要重算的
    /// 只有「拥有者变了」那一刻——那一刻写的是上面的 `hoveredEntryID`。
    @State private var pointerBox = PointerBox()

    /// 当前占着气泡面板的 chip。只用来在收气泡时报出正确的 id（`.exit` 要匹配才生效）。
    @State private var bubbleOwnerID: String?

    /// 记录已经播放过入场动画的固定区元素 ID（避免重复播，且支持新增元素播动画）。
    @State private var animatedEntryIDs: Set<String> = []

    /// Pinned messaging zone (leftmost, in store order) + live window zone, in **natural**
    /// snapshot order. Messaging apps show only while running (quit → chip gone; the future
    /// drawer 待启动区 takes over the not-running role). Drawer membership hides a messaging
    /// app from the strip without clearing its messaging flag.
    ///
    /// 方案 B: each messaging app pins exactly ONE app-level chip. Its main window
    /// (title matches the app name) is absorbed into that chip; pop-out windows
    /// (chat windows etc.) flow through the live zone as normal window chips so the
    /// pinned zone keeps a stable width (muscle memory).
    ///
    /// Split out so the live zone can be reordered by `stripOrderStore` (任务条拖动重排
    /// A 路线) while the pinned messaging zone keeps its own `MessagingAppStore` order —
    /// the two zones never cross (拖动分区内进行).
    private func makeProjection() -> StripProjection {
        // This is the only snapshot-to-strip conversion in one body evaluation. Everything below,
        // including drag callbacks captured by that body, consumes the same immutable projection.
        let snapshotItems = StripItem.items(from: runtime.snapshot)
        let snapshotBundleIDs = Set(snapshotItems.compactMap(\.bundleIdentifier))
        let hiddenBundleIDs = Set(snapshotItems.compactMap { item in
            item.status == "hidden" ? item.bundleIdentifier : nil
        })
        let keptIDs = keptAppStore.bundleIDs
        let runningIDs = runningApplicationStore.runningBundleIDs
        // 统一模型：消息区可见 = (messaging − drawer) ∩ (running ∪ kept)。消息身份不再独立保活，
        // 由 kept 决定退出后留不留（首次标记即补 kept，默认观感不变）；抽屉例外仍隐藏（抽屉优先级更高）。
        let msg = AppMembershipProjection.visibleMessagingIDs(
            messagingIDs: messagingStore.bundleIDs,
            drawerIDs: drawerStore.bundleIDs,
            keptIDs: keptIDs,
            runningIDs: runningIDs
        )
        let msgSet = Set(msg)
        let items = snapshotItems.filter { !drawerStore.contains($0.bundleIdentifier ?? "") }

        var messaging: [StripEntry] = []
        var absorbedWindowIDs = Set<String>()
        for bid in msg {
            let appWindows = items.filter { $0.bundleIdentifier == bid && !$0.isAppLevelFallback }
            let main = appWindows.first { AppDisplayNameResolver.titleMatchesAppName($0.title, bundleID: bid) }
            if let main { absorbedWindowIDs.insert(main.id) }
            messaging.append(.messagingApp(bundleID: bid, mainWindow: main))
        }

        // Live zone: real windows (including kept app windows) + kept app placeholders
        var liveNatural: [StripEntry] = []
        for item in items {
            guard !msgSet.contains(item.bundleIdentifier ?? "") else {
                if item.isAppLevelFallback { continue }     // app chip replaces the app-* fallback
                if absorbedWindowIDs.contains(item.id) { continue }
                liveNatural.append(.window(item))
                continue
            }
            liveNatural.append(.window(item))
        }

        // Kept app placeholders (D1 two sources):
        // a. Unrunning: not in snapshot → inject placeholder
        // b. Running but only isAppLevelFallback → replace the fallback .window with .keptApp
        // 占位插在 liveNatural **头部**（按 kept store 顺序）：正常运行时顺序由记忆层决定，
        // 数组位置只影响"无记忆的新 id"落点——即跨机器重启（boottime 丢档）后占位落 live 区头部。
        let snapshotByBundle = Dictionary(grouping: snapshotItems, by: { $0.bundleIdentifier ?? "" })
        var keptPlaceholders: [StripEntry] = []
        for bid in keptIDs {
            guard !drawerStore.contains(bid),
                  !msgSet.contains(bid) else { continue }
            let appItems = snapshotByBundle[bid] ?? []
            let hasRealWindow = appItems.contains { !$0.isAppLevelFallback }
            if hasRealWindow { continue }  // Real windows render normally, no placeholder
            if !appItems.isEmpty {
                // Source b: replace fallback .window with .keptApp (same id "app-\(bid)")
                liveNatural.removeAll { entry in
                    if case let .window(item) = entry, item.bundleIdentifier == bid, item.isAppLevelFallback {
                        return true
                    }
                    return false
                }
            }
            // Both sources inject .keptApp with id "app-\(bid)"
            keptPlaceholders.append(.keptApp(bundleID: bid))
        }
        let projectedLive = keptPlaceholders + liveNatural
        let liveOrderIDs = projectedLive.map(\.id)
        let appKeys = Self.appKeys(of: projectedLive)
        let order = stripOrderStore.reconciled(
            current: liveOrderIDs,
            appKeyOf: appKeys,
            headPreferred: Set(messagingStore.bundleIDs)
        )
        let byID = Dictionary(projectedLive.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedLive = order.compactMap { byID[$0] }
        if HoverTrace.isEnabled, dragController.carriedPayload != nil {
            HoverTrace.liveOrder(orderedLive.map(\.id))
        }
        let folderEntries = (settingsStore.showShelf ? [StripEntry.shelf] : [])
            + pinnedFolderStore.folderPaths.map { StripEntry.pinnedFolder(path: $0) }
        var zones = [messaging, folderEntries, orderedLive].filter { !$0.isEmpty }
        var entries: [StripEntry] = []
        if !zones.isEmpty {
            entries = zones.removeFirst()
            for (index, zone) in zones.enumerated() {
                entries.append(.divider(id: "zone-divider-\(index)"))
                entries += zone
            }
        }
        let messagingIDs = messaging.compactMap { entry -> String? in
            guard case let .messagingApp(bundleID, _) = entry else { return nil }
            return bundleID
        }
        let draggingID: String?
        // `carriedPayload` 而不是 `draggingPayload`：松手后还有 0.26 秒的归位飞行，
        // 那段时间原位必须继续空着，否则卡先显形、载体还在飞。
        if let payload = dragController.hiddenSlotPayload,
           payload.source == .strip,
           liveOrderIDs.contains(payload.id) {
            draggingID = payload.id
        } else if let converted = dragController.convertedChipID,
                  liveOrderIDs.contains(converted) {
            // **认 chip id，不认代表卡**：`keepPlacement` 路径物化出来的是 `.keptApp` 占位或
            // app 级兜底卡，两者都当不了 `StripItem` 代表卡，跟着代表卡走就永远不让位（双影）。
            draggingID = converted
        } else {
            draggingID = nil
        }
        return StripProjection(
            snapshotItems: snapshotItems,
            snapshotBundleIDs: snapshotBundleIDs,
            hiddenBundleIDs: hiddenBundleIDs,
            messaging: messaging,
            liveNatural: projectedLive,
            liveOrderIDs: liveOrderIDs,
            appKeyByChipID: appKeys,
            entries: entries,
            layoutKeys: entries.map(StripLayoutKey.init),
            messagingIDs: messagingIDs,
            draggingID: draggingID
        )
    }

    /// **`onChange` 闭包里必须用它，不能用闭包捕获的 `projection`。**
    ///
    /// 老式 `onChange(of:perform:)` 触发时跑的是**上一帧**装进去的闭包，里面那份 projection
    /// 因此永远落后一代。平时无所谓（下一次变化会追上），但抽屉转正那一刻是致命的
    /// （实测 2026-08-18：渲染已经是 12 张卡了，`sync` 收到的还是 11 张，不含刚冒出来的占位）：
    ///
    /// 1. `sync` 里 `next.contains("app-<bid>")` 为 false → **落点暂存一次都没被消费**；
    /// 2. 记忆序 `liveOrder` 因此始终没有这个 id → 后续 `reorderBlock` 的 `movingBlock`
    ///    找不到要移动的 id，**每一次都原样返回**（日志里五次 `ok` 全是空转）；
    /// 3. 渲染只能退回 `reconciled` 的 kept 稳定名次，把它钉在一个跟光标无关的固定位置。
    ///
    /// 也就是 owner 说的「不容易触发把其他图标挤走」。这里重建一次 projection 的代价可以接受：
    /// 它只在 live 区卡的集合真的变了时触发，不是每帧、更不是每次鼠标移动。
    /// （AGENTS 那条「一次 body 只建一个 projection」管的是**渲染路径**，这里是副作用路径。）
    private func freshProjection() -> StripProjection { makeProjection() }

    /// 渲染路径（`reconciled`）与副作用路径（`sync`）**必须喂同一份 appKeyOf**，否则落盘的记忆序
    /// 与显示序不一致。抽成一个函数，让两条路径无从写岔。
    private static func appKeys(of liveNatural: [StripEntry]) -> [String: String] {
        Dictionary(liveNatural.map { entry -> (String, String) in
            switch entry {
            case let .window(item): return (entry.id, item.bundleIdentifier ?? item.appID)
            case let .keptApp(bid): return (entry.id, bid)
            default: return (entry.id, entry.id)
            }
        }, uniquingKeysWith: { first, _ in first })
    }

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
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: projection.layoutKeys)
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
        // 抽屉图标拖到任务条上方 = 移出抽屉的投放反馈：整条任务条高亮描边（对称于胶囊的收纳高亮）。
        // 外部拖目录悬停文件夹区（pin 落点）复用同一条高亮。
        .dockPanelRim(
            cornerRadius: taskbarCornerRadius,
            style: theme.panelRimStyle(highlighted: stripHighlighted),
            lineWidth: theme.panelRimLineWidth(highlighted: stripHighlighted),
            usesLiquidGlass: usesLiquidGlass,
            keepsVisible: stripHighlighted
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
        .background(ScreenRectReader { rect in
            guard rect != stripRootScreenRect else { return }
            stripRootScreenRect = rect
            refreshHoveredEntry(frames: stripHoverFrames, origin: rect)
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
            updateDrawerToMessagingRelease(projection: projection)
            updateDrawerToStripConvert(projection: projection)
            updateStripBlockReorder(projection: projection)
            updateLiveReorder(projection: projection)
            updateMessagingReorder(messagingIDs: projection.messagingIDs)
            updateFolderReorder()
            syncConvertedCarrier(projection: projection)
            updateFolderDragZone()
            updateLandingAnchor()
        }
        // 归位飞行途中点了一下图标 = 点了这张卡（owner 2026-08-19：「落地前点它没反应」）。
        // 按 entry 分派、逐字镜像 `stripEntryContent` 各分支的 tap；用**此刻**的投影，不用载荷里起拖时那份。
        .onReceive(dragController.carrierClicks) { payload in
            performCarrierClick(payload, projection: freshProjection())
        }
        // 转正那一刻上面那个闭包手里的 projection 还是**旧的**（app 还在抽屉里），代表卡/让位卡都算不出来。
        // 光靠鼠标驱动就意味着「光标停在边界不动 = 一直双影」。store 一变就再算一次，把那一帧补上。
        .onChange(of: projection.liveOrderIDs) { _ in
            syncConvertedCarrier(projection: freshProjection())
        }
        // 悬停压制的开关翻转时重判一次：起拖藏卡那一刻清掉旧悬停；落地按住期结束（指针动了）
        // 那一刻按当前指针位置补上悬停。**不再在「手里空了」那一刻重判**——那正是落地一停稳
        // 就往上长一截的来源（见 `refreshHoveredEntry`）。
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
        .onPreferenceChange(FolderChipFramePreferenceKey.self) { folderChipFrames = $0 }
        .onPreferenceChange(MessagingChipFramePreferenceKey.self) { messagingChipFrames = $0 }
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

    /// 任务条整条高亮：抽屉图标拖回（unstash/keepPlacement）或外部拖目录悬停文件夹区（pin）。
    /// 消息成员的抽屉图标不点亮——它的落点只有消息区范围（释放时 chip 物化就是反馈），
    /// 整条高亮会暗示"哪里都能放"（Codex 评审 P1-3 的落点边界）。
    private var stripHighlighted: Bool {
        if dragController.isOverUnstashZone,
           let p = dragController.draggingPayload, !messagingStore.contains(p.bundleID) { return true }
        if case .pin = externalDropTarget { return true }
        return false
    }

    /// 外部拖入高亮的三个生命周期入口 + 看门狗。`externalDropTarget` 只在这一组里改。
    /// dropEntered：一次悬停会话开始 → 允许点亮。
    private func externalDropHoverBegan(_ target: StripDropRouting.Target) {
        externalDropHoverActive = true
        setExternalDropTarget(target)
    }

    /// dropUpdated：只在会话进行中才更新;落定/离开后系统补发的孤立 dropUpdated（hoverActive=false）忽略 → 无回闪。
    private func externalDropHoverMoved(_ target: StripDropRouting.Target) {
        guard externalDropHoverActive else { return }
        setExternalDropTarget(target)
    }

    /// performDrop/dropExited：会话结束 → 立即清高亮、作废看门狗、关门控（同步清,落定即灭,不留尾巴）。
    private func externalDropHoverEnded() {
        externalDropHoverActive = false
        externalDropGeneration &+= 1
        externalDropWatchdog?.invalidate()
        externalDropWatchdog = nil
        externalDropTarget = nil
    }

    /// 设落点目标 + 重置拖放结束看门狗。`dropUpdated` 悬停期每 ~50ms 来一次会不断把 0.35s Timer 推后
    /// → 移动/静止悬停都不会误清;一旦拖放结束却没给收尾回调（dropUpdated 停），Timer 到点即清遗留高亮。
    /// generation 仍匹配才清,避免已入队的旧 Timer 误清新拖放。只动 `externalDropTarget`,不碰抽屉 unstash 高亮。
    private func setExternalDropTarget(_ target: StripDropRouting.Target) {
        externalDropTarget = target
        externalDropGeneration &+= 1
        externalDropWatchdog?.invalidate()
        let gen = externalDropGeneration
        let timer = Timer(timeInterval: 0.35, repeats: false) { _ in
            guard externalDropGeneration == gen else { return }
            externalDropHoverActive = false
            externalDropTarget = nil
            externalDropWatchdog = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        externalDropWatchdog = timer
    }

    /// 外部拖放落定（DropDelegate 异步取齐 URL 后回到主线程调）。
    /// 中转收一切；命中 chip 移入；间隙/尾部固定只收目录。
    private func handleExternalDrop(_ target: StripDropRouting.Target, urls: [URL]) {
        switch target {
        case .stash:
            shelfStore.stash(paths: urls.map(\.path))
        case .moveInto(let path):
            onMoveExternalFiles(urls, path)
        case .pin(let insertIndex):
            var index = insertIndex
            for url in urls where isDirectoryURL(url) {
                pinnedFolderStore.insert(url.path, at: index)
                index += 1
            }
        case .none:
            break
        }
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }

    /// Converge the remembered live order with the current snapshot (drop closed, append new).
    /// Called on every `liveOrderIDs` change **and** once on appear (the latter mirrors the old
    /// `onChange(of:initial:)` seed that pre-macOS-14 `onChange` doesn't provide).
    private func reconcileLiveOrder(_ projection: StripProjection) {
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
    private func syncConvertedCarrier(projection: StripProjection) {
        let dc = dragController
        guard dc.isConvertedToStrip, let p = dc.draggingPayload, p.source == .drawer else { return }
        let rep = projection.liveChipIDs(bundleID: p.bundleID).first
            .flatMap { projection.liveOrderIDs.contains($0) ? projection.item(forID: $0) : nil }
        let changed = dc.convertedRepresentative != rep
        dc.setConvertedRepresentative(rep, chipID: projection.liveEntryIDs(bundleID: p.bundleID).first)
        // 载体改画代表卡（与条内拖动同款）。`rep` 变回 nil = 回滚，传 nil 让载体换回起拖时那张图。
        guard changed else { return }
        dc.setCarrierSnapshot(rep.flatMap { carrierSnapshot(for: .window($0), projection: projection) })
    }


    /// 飞行途中被点了一下的那张卡该干什么：和它在条上被点一下**完全一样**。
    /// 窗口卡 → 切换那个窗口；保留应用 / 无主窗的消息应用 → 运行中唤主窗、未运行启动、启动中不动。
    /// 文件夹 chip 不做（弹窗锚在还空着的格上，图标半秒后才到）；找不到 entry（已经不在条上）不做。
    private func performCarrierClick(_ payload: DragPayload, projection: StripProjection) {
        guard let entryID = Self.stripEntryID(for: payload),
              let entry = projection.entries.first(where: { $0.id == entryID }) else { return }
        switch entry {
        case let .window(item):
            runtime.toggle(windowID: item.actionWindowID)
        case let .messagingApp(bid, main):
            if let main { runtime.toggle(windowID: main.actionWindowID) } else { launcherTap(bid) }
        case let .keptApp(bid):
            launcherTap(bid)
        case .pinnedFolder, .shelf, .divider:
            return
        }
    }

    /// 载荷 → 条上那张卡的 entry id。`nil` = 这份载荷不属于任务条（抽屉图标 / 文件夹 chip）。
    /// **两处共用**：飞行中点一下要找到它做动作、飞行中悬停要豁免它——两边算法必须是同一份。
    static func stripEntryID(for payload: DragPayload) -> String? {
        switch payload.source {
        case .strip: return payload.id                       // 窗口卡 = chip token；保留占位 = "app-<bid>"
        case .messaging: return "msg-app-\(payload.bundleID)"
        case .drawer, .folder: return nil
        }
    }

    /// `LauncherChip` 在条上的两条 tap 路径（`onTap: reopen` / `onLaunch`），加上它自己的「启动中不动」闸。
    private func launcherTap(_ bid: String) {
        guard !runtime.launchingBundleIDs.contains(bid) else { return }
        if runningApplicationStore.isRunning(bid) {
            Self.reopenMainWindow(bundleID: bid)
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
        let anchor: CGRect? = {
            // `carriedPayload`：飞行途中也要继续报，卡槽落定后 `DragController` 才纠得了偏。
            guard let p = dragController.carriedPayload, !dragController.isConvertedToStrip,
                  stripRootScreenRect != .zero else { return nil }
            switch p.source {
            case .strip:  return chipFrames[p.id].map(stripFrameToScreen)
            case .folder: return folderChipFrames[p.id].map(stripFrameToScreen)
            case .messaging: return messagingChipFrames[p.bundleID].map(stripFrameToScreen)
            case .drawer: return nil   // 抽屉侧自己写
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
    private func stripPoint(from global: CGPoint) -> CGPoint? {
        guard stripRootScreenRect != .zero else { return nil }
        return CGPoint(x: global.x - stripRootScreenRect.minX,
                       y: stripRootScreenRect.maxY - global.y)
    }

    // MARK: - 悬停归属（整条一块跟踪区）

    /// 重新判一次「指针压在谁身上」，**只有结论变了才写 `@State`**。
    /// 判定是纯函数 `StripHoverResolution`：缝隙里按到卡边的距离取近，边界与来向无关。
    ///
    /// 帧和原点显式传进来而不是读 `self`：它俩自己也是 `@State`，在 `onChange` /
    /// `onPreferenceChange` 闭包里读到的是旧值。
    private func refreshHoveredEntry(frames: [String: CGRect], origin: CGRect) {
        // 起拖那一两帧**原地冻结**：载体正按卡槽此刻的「悬停 × 按压」姿态压在卡上，
        // 这时候把悬停清掉、卡开始回落，两者就对不上了（owner 2026-08-19「上下残影」）。
        guard !dragController.hoverFrozen else { return }
        let resolved: String? = {
            // 手里拎着东西时不判悬停，落地之后也**先按住、等指针真动了再判**。三个理由：
            // ① 拖动途中指针扫过谁就给谁点亮、还弹名字气泡，本来就不对；
            // ② 松手位置必然压在刚落定的那张卡上——载体画的是**非悬停**态，
            //    卡一显形却已经是悬停态（安静档还要放大 1.10），两者尺寸不一样，
            //    交接那一帧就"啵"地跳一下；
            // ③ 卡以 1.0 停稳后立刻重判悬停，安静档会当场往上长 1.10——图标刚停稳又动一下，
            //    就是 owner 2026-08-19 报的「落位抖动」。AppKit 自己对拖放结束后的悬停也是
            //    等鼠标动了才发 mouseEntered。按住期由 `DragController.hoverHoldPayload` 管。
            guard !dragController.hoverSuppressed else { return nil }
            guard let pointer = pointerBox.value, origin != .zero else { return nil }
            let point = CGPoint(x: pointer.x - origin.minX, y: origin.maxY - pointer.y)
            let hit = StripHoverResolution.chip(
                at: point,
                frames: frames,
                gapBridge: StripHoverResolution.defaultGapBridge * dockScale
            )
            // 正在飞回去的 / 刚落定还没等到指针移动的那**一张**不给悬停，别的卡照常
            //（owner 2026-08-19：「图标飞行时鼠标划到其他图标上没有悬停效果」）。理由见
            // `DragController.hoverExemptPayload`。
            if let exempt = dragController.hoverExemptPayload,
               Self.stripEntryID(for: exempt) == hit { return nil }
            return hit
        }()
        if resolved != hoveredEntryID { hoveredEntryID = resolved }
    }

    /// 该 entry 的气泡文案。`nil` = 这类 chip 不弹气泡。
    ///
    /// **弹的是应用名，不是窗口标题**（owner 2026-08-17，原生 Dock 的标签永远只写应用名）。
    /// 固定文件夹不弹——它的名字常驻在封面下方；分隔线不是 chip。
    private func bubbleTitle(for entry: StripEntry) -> String? {
        switch entry {
        case let .window(item):
            return appBubbleName(bundleID: item.bundleIdentifier, fallback: item.appID)
        case let .messagingApp(bid, _):
            return appBubbleName(bundleID: bid, fallback: bid)
        case let .keptApp(bid):
            return appBubbleName(bundleID: bid, fallback: bid)
        case .shelf:
            let count = shelfStore.itemPaths.count
            return count > 0
                ? String(format: String(localized: "Shelf · %d"), count)
                : String(localized: "Shelf")
        case .pinnedFolder, .divider:
            return nil
        }
    }

    private func appBubbleName(bundleID: String?, fallback: String) -> String {
        let name = bundleID.map(AppDisplayNameResolver.displayName(for:)) ?? fallback
        return WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: name)
    }

    /// 这一帧该给气泡面板什么。`nil` = 收气泡。
    ///
    /// 由「指针位置 + 卡片几何 + 档位」整体推出来，所以锚点漂移、应用名变化、档位切换
    /// 全都自动跟上，不需要每张卡各自补发 `.refresh`——那套「内容驱动的重发」连同它的
    /// 归属守卫一起没了，因为现在**只有一个人**能占用这块面板。
    ///
    /// 安静档不弹气泡（`hoverStyle.isExpressive`），与改造前的 `showsHover` 门槛一致。
    private func bubbleRequest(projection: StripProjection) -> WindowTitleTooltipRequest? {
        guard hoverStyle.isExpressive,
              let id = hoveredEntryID,
              let frame = stripHoverFrames[id],
              stripRootScreenRect != .zero,
              let entry = projection.entries.first(where: { $0.id == id }),
              let title = bubbleTitle(for: entry) else { return nil }
        return WindowTitleTooltipRequest(chipID: id,
                                         title: title,
                                         anchorVisibleRect: stripFrameToScreen(frame))
    }

    /// 右键任务条底板时该不该弹钨极菜单。判定本身在纯 `StripContextMenuZone` 里，
    /// 这里只负责换算坐标、把四个区的帧凑齐（消息区 / 固定文件夹 / 中转格的帧各有独立的
    /// PreferenceKey，从来不合并进 `chipFrames`）。
    private func taskbarMenuZoneClaims(atScreen global: CGPoint) -> Bool {
        guard let point = stripPoint(from: global) else { return false }
        var frames = Array(chipFrames.values)
        frames.append(contentsOf: folderChipFrames.values)
        frames.append(contentsOf: messagingChipFrames.values)
        if shelfFrame != .zero { frames.append(shelfFrame) }
        return StripContextMenuZone.claims(
            point: point,
            chipFrames: frames,
            bounds: CGRect(origin: .zero, size: stripRootScreenRect.size),
            minimumGapWidth: StripContextMenuZone.defaultMinimumGapWidth * dockScale
        )
    }

    /// 抽屉整块落点：**只看 x、永远给得出答案**。判据与理由（以及为什么不能用整帧 `contains`）
    /// 见纯类型 `StripBlockLanding`——简单说，转正判定框故意伸到条上沿之外 16pt，
    /// 而整帧命中在那里永远失败，首次落点因此 100% 退化成末尾。
    private func blockTarget(atX x: CGFloat, excluding block: Set<String>) -> (id: String, after: Bool)? {
        StripBlockLanding.target(pointerX: x,
                                 frames: chipFrames.filter { !block.contains($0.key) })
    }

    /// 进/出任务条区驱动转正/还原（迟滞防边界抖）。
    /// unstash 路径：进 → convertDrawerToStrip + 暂存落点；出 → cancelExternalBlock + revertDrawerToStrip。
    /// keepPlacement 路径：无真窗口时用现有 app fallback / kept placeholder 落位；全程不修改 kept。
    private func updateDrawerToStripConvert(projection: StripProjection) {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .drawer, p.canExternalDrop,
              stripRootScreenRect != .zero else { return }
        let bid = p.bundleID
        let g = dc.globalLocation
        let r = stripRootScreenRect
        // 右侧容差要一直伸到**抽屉入口胶囊**的外缘：抽屉的可视右缘是和胶囊右缘对齐的，
        // 比任务条本体还要靠右 `capsuleGap + capsuleWidth`（中档 62pt）。只放 8pt 的话，
        // 抽屉最右一列多多少少垂直往下拖，光标全程落在胶囊上、**永远进不了判定框**
        // （实测 2026-08-18：整趟 60 帧 enter 全 false）。对抽屉来源的载荷来说胶囊没有别的语义
        // ——它的投放区只有任务条面板——所以这里把它并进来不会和收纳打架。
        let rightReach = metrics.capsuleGap + metrics.capsuleWidth
        let enter      = g.x >= r.minX - 8  && g.x <= r.maxX + rightReach
                      && g.y >= r.minY - 8  && g.y <= r.maxY + 16
        let clearlyOut = g.x < r.minX - 24  || g.x > r.maxX + rightReach + 16
                      || g.y < r.minY - 24  || g.y > r.maxY + 40
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
        guard let p = dc.draggingPayload, p.source == .drawer, p.canExternalDrop,
              !dc.isConvertedToStrip,
              currentDrawerDragOutMode(p.bundleID, projection: projection) == .releaseToMessaging,
              let pt = stripPoint(from: dc.globalLocation),
              let zone = messagingReleaseZone(messagingIDs: projection.messagingIDs),
              zone.insetBy(dx: -8, dy: -8).contains(pt) else { return }
        dc.convertDrawerToMessaging()
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
                                dragController.beginDrag(payload: payload,
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
                            dragController.beginDrag(payload: payload,
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
                                dragController.beginDrag(payload: payload,
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
                                dragController.beginDrag(payload: payload,
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
            ChipView(item: item,
                     scale: dockScale,
                     hoverStyle: hoverStyle,
                     isHovered: hovered,
                     showRunningDot: true,
                     pulseNonce: chipPulseNonces[item.id] ?? 0,
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
                    ChipView(item: main, scale: dockScale, hoverStyle: hoverStyle,
                             isHovered: hovered, iconOnly: true, showRunningDot: true,
                             badgeText: badge,
                             slotHidden: draggingMessagingBundleID == bid)
                } else {
                    // 无主窗两态：运行中（关窗/常驻）→ 点击 reopen 主窗；未运行（图标下方无运行点）→ 点击启动。
                    // 统一模型下消息应用也有「在程序坞中保留」勾选（与「取消标记」并存），由纯投影决定。
                    let running = runningApplicationStore.isRunning(bid)
                    LauncherChip(bundleID: bid,
                                 isRunning: running,
                                 isHidden: running && projection.hiddenBundleIDs.contains(bid),
                                 isLaunching: runtime.launchingBundleIDs.contains(bid),
                                 scale: dockScale,
                                 hoverStyle: hoverStyle,
                                 hoverInput: .resolved(hovered),
                                 membershipItems: LauncherMembershipItem.items(
                                    surface: .strip,
                                    bundleID: bid,
                                    isKept: keptAppStore.contains(bid),
                                    isMessaging: true,
                                    controller: appMembershipController
                                 ),
                                 badgeText: badge,
                                 slotHidden: draggingMessagingBundleID == bid,
                                 onTap: running ? { Self.reopenMainWindow(bundleID: bid) } : nil,
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
                isLaunching: runtime.launchingBundleIDs.contains(bid),
                scale: dockScale,
                hoverStyle: hoverStyle,
                hoverInput: .resolved(hovered),
                membershipItems: keptAppMembershipItems(bundleID: bid),
                slotHidden: projection.draggingID == "app-\(bid)",
                onTap: reopen,
                onLaunch: { runtime.beginLaunch(bid) }
            )
        }
    }

    /// Kept launcher uses the same shared membership projection (strip surface).
    private func keptAppMembershipItems(bundleID: String) -> [LauncherMembershipItem] {
        LauncherMembershipItem.items(
            surface: .strip,
            bundleID: bundleID,
            isKept: keptAppStore.contains(bundleID),
            isMessaging: messagingStore.contains(bundleID),
            controller: appMembershipController
        )
    }

    /// 固定文件夹左键唯一入口：按 `FolderInteraction.primaryAction` 分派（现固定 = 内容预览）。
    /// A/B「左键预览 vs 左键开 Finder」只改策略枚举，不动这里的调用点。
    private func folderPrimaryTap(_ path: String) {
        switch FolderInteraction.primaryAction {
        case .openFinderWindow: openFolderInFinder(path)
        case .preview: folderShowPreview(path)
        }
    }

    /// 打开该路径的访达窗口（best-effort；左键与右键「在访达中打开」共用此入口）。
    private func openFolderInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 固定文件夹内容预览唯一入口（左键 A/B 的 preview 分支、右键「预览内容」、以后中键/重击都走它）。
    /// 把 "strip" 空间帧（top-left,y-down）换算成屏幕坐标（bottom-left）传给弹窗。
    /// 镜像 stripPoint(from:) 的逆映射。帧未就绪（首帧）就不弹,下次触发再说。
    private func folderShowPreview(_ path: String) {
        let entryID = StripEntry.pinnedFolder(path: path).id
        guard let frame = folderChipFrames[entryID], stripRootScreenRect != .zero else { return }
        let screenRect = CGRect(
            x: stripRootScreenRect.minX + frame.minX,
            y: stripRootScreenRect.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        onFolderPopupToggle(path, screenRect)
    }

    /// strip 空间帧 → 屏幕矩形（stripPoint(from:) 的逆；弹窗锚点用）。
    private func stripFrameToScreen(_ frame: CGRect) -> CGRect {
        CGRect(x: stripRootScreenRect.minX + frame.minX,
               y: stripRootScreenRect.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    /// 手势（重击/中键）命中回调：全局屏幕坐标 → strip 空间 → 命中固定文件夹 / 具体访达窗口 → 预览。
    /// 命中不到任何可预览 chip 就静默忽略。
    private func handleGesturePreview(atScreen global: CGPoint) {
        guard let p = stripPoint(from: global) else { return }
        for path in pinnedFolderStore.folderPaths {
            let entryID = StripEntry.pinnedFolder(path: path).id
            if let frame = folderChipFrames[entryID], frame.contains(p) {
                onFolderPopupToggle(path, stripFrameToScreen(frame))
                return
            }
        }
        for (cid, frame) in chipFrames where frame.contains(p) {
            guard let item = StripItem.items(from: runtime.snapshot).first(where: { $0.id == cid }),
                  item.bundleIdentifier == "com.apple.finder", item.isAppLevelFallback == false else { return }
            chipPulseNonces[cid, default: 0] += 1   // 立刻"点到了"反馈，兜住反查那 ~200ms
            previewFinderWindow(item, anchor: stripFrameToScreen(frame))
            return
        }
    }

    /// 具体访达窗口 → 反查路径 → 预览。AX 定位 + 权限流在主线程，AppleEvents 枚举放后台，
    /// 成功回主线程开预览；拒授权 / 无唯一匹配 / 超时 → beep + log，不弹空窗（spike#2 已验证）。
    private func previewFinderWindow(_ item: StripItem, anchor: CGRect) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.caye.macosdockcc.v2", category: "FinderWindowPreview")
        let ref = FinderWindowReference(pid: item.pid, cgWindowID: item.cgWindowID, title: item.title, bounds: item.bounds)
        let reader = FinderWindowContentsReader()
        let onToggle = onFolderPopupToggle

        func resolveViaAppleEvents(_ aeTarget: FinderWindowAppleEventsTarget) {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = try FinderWindowContentsReader.folderURLViaAppleEvents(for: aeTarget)
                    DispatchQueue.main.async { onToggle(url.path, anchor) }
                } catch {
                    logger.error("finder-window-preview AppleEvents failed: \(String(describing: error), privacy: .public)")
                    DispatchQueue.main.async { NSSound.beep() }
                }
            }
        }
        // 最小化窗口在 AX 里按 cgWindowID 定位不到（缺失/对不上）→ 用 StripItem 自带的 title+frame
        // 直接走 AppleEvents 唯一匹配（AppleScript 的 `Finder windows` 含最小化窗口，报还原态 bounds）。
        func resolveFromItem() {
            guard let bounds = item.bounds else { NSSound.beep(); return }
            resolveViaAppleEvents(FinderWindowAppleEventsTarget(title: item.title, cocoaFrame: bounds))
        }

        do {
            switch try reader.target(for: ref) {
            case .folderURL(let url):
                onToggle(url.path, anchor)
            case .appleEvents(let aeTarget):
                resolveViaAppleEvents(aeTarget)
            }
        } catch FinderWindowContentsError.windowNotFound {
            resolveFromItem()
        } catch FinderWindowContentsError.missingWindowID {
            resolveFromItem()
        } catch FinderWindowContentsError.automationPermissionRequired {
            if FinderWindowContentsReader.requestFinderAutomationPermission() { resolveFromItem() } else { NSSound.beep() }
        } catch {
            logger.error("finder-window-preview target failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    /// 中转格点击：同 folderShowPreview 的坐标换算,锚点用独立的 shelfFrame。
    private func shelfChipTapped() {
        guard shelfFrame != .zero, stripRootScreenRect != .zero else { return }
        let screenRect = CGRect(
            x: stripRootScreenRect.minX + shelfFrame.minX,
            y: stripRootScreenRect.maxY - shelfFrame.maxY,
            width: shelfFrame.width,
            height: shelfFrame.height
        )
        onShelfPopupToggle(screenRect)
    }

    /// Dock-icon-click equivalent: unhide + reopen. The app recreates its main window
    /// even when other windows are visible (verified with WeChat, 2026-06-12).
    private static func reopenMainWindow(bundleID: String) {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter {
                $0.activationPolicy == .regular
                    && ProcessLiveness.isAlive(pid: $0.processIdentifier)
            }
        for app in runningApps { _ = app.unhide() }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }

}

// MARK: - Chip View

struct ChipView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var appMembershipController: AppMembershipController
    private let theme = DockThemeTokens.standard
    let item: StripItem
    /// 档位系数（`DockSize.scale`）。**故意不给默认值**：消息区曾因为它有默认值 1.0 而静默漏传，
    /// 在非中档下渲染成中档尺寸（见 AGENTS《Taskbar Size Tiers》）。漏传必须是编译错误。
    let scale: CGFloat
    /// 悬停效果档位。**同样故意不给默认值**——漏传是编译错误，理由见上面 `scale` 那条。
    /// `.quiet` 下悬停不产生任何视觉变化；长标题的全文浮层不受影响（它跟的是裸 `isHovering`）。
    let hoverStyle: HoverStyle
    /// 指针在不在这张卡上。**由任务条整条那块跟踪区算好后传进来**，卡片自己不再挂 `.onHover`
    /// （漏格 + 边界带方向，成因与实测见 `StripHoverResolution`）。同样故意不给默认值。
    let isHovered: Bool
    var iconOnly: Bool = false
    var showRunningDot: Bool = false
    /// 见 `EnvironmentValues.isDragCarrierSnapshot`：拍副本时不画圆点、不烘投影。
    @Environment(\.isDragCarrierSnapshot) private var isDragCarrierSnapshot
    var drawerTap: (() -> Void)? = nil
    /// 外部手势（重击/中键预览）触发的脉冲信号：nonce 变化即触发一次 fireTapPulse，
    /// 给活访达窗口预览那 ~200ms 反查延迟一个"点到了"的即时确认。默认 0 = 不脉冲。
    var pulseNonce: Int = 0
    /// 未读角标文本（消息区专用），`nil` = 不画。默认 `nil` 是**正确**的省略语义
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
    private var showsHover: Bool { hoverStyle.isExpressive && isHovered }
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
        let capturedDisplayTitle = displayTitle
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
        .help(capturedDisplayTitle)
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
                .fill(theme.chipPillFill.color(emphasisProgress: Double(progress)))
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
        let titleColor: Color = effectiveIsOnDesktop ? theme.labelActive.color : theme.labelInactive.color
        let capturedDisplayTitle = displayTitle
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
    }

    // MARK: - Shared Icon

    private func appIcon(size: CGFloat) -> some View {
        Image(nsImage: AppIconResolver.icon(for: item.bundleIdentifier ?? item.appID))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            // 图标**不带外投影**（owner 2026-08-19，对齐原生 Dock）。别加回来：实测 macOS 的
            // 图标资源自己不投影（画在全透明画布上，主体下方 alpha 恰好 0），我们加的那层是
            // 净多出来的，条上量到图标正下方比两侧空隙暗 18–24。中转格方块、文件夹封面同此。
    }

    // MARK: - Context Menu

    // 可打断（2026-06-13）：菜单项不再按 pending 置灰；显隐类动作随时可点
    //（乐观 overlay 保证一致性），close / quit 的防重入由 runtime.trigger 兜底。
    // 状态分支读 effectiveStatus，刚点过最小化立刻右键也能看到「还原」。
    private var isFinderChip: Bool { item.bundleIdentifier == "com.apple.finder" }

    /// Native AppKit menu rebuilt fresh on each right-click (captures live runtime
    /// + store + optimistic state). See AppMenuFragments for why this isn't SwiftUI.
    private func buildChipMenu() -> NSMenu {
        let menu = NSMenu()
        let bid = item.bundleIdentifier
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

    private var displayTitle: String {
        WindowDisplayTitle.resolve(rawTitle: item.title, fallbackName: appName)
    }

    private var appName: String {
        let name = item.bundleIdentifier.map(AppDisplayNameResolver.displayName(for:)) ?? item.appID
        return WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: name)
    }
}

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
                              cornerRadius: Style.cornerRadius * dockScale,
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
        .dockPanelRim(cornerRadius: Style.cornerRadius * dockScale,
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

// MARK: - Layout Animation Key

struct StripLayoutKey: Equatable {
    let id: String
    let form: Form

    enum Form: Equatable { case zero, single, multi, launcher }

    init(_ entry: StripEntry) {
        id = entry.id
        switch entry {
        case let .window(item):
            if item.isAppLevelFallback { form = .zero }
            else if item.showsTitle    { form = .multi }
            else                        { form = .single }
        case .messagingApp:
            form = .launcher    // both states render as a fixed-size icon chip
        case .keptApp:
            form = .launcher    // fixed-size kept-app icon chip
        case .pinnedFolder:
            form = .launcher    // fixed-size folder chip
        case .shelf:
            form = .launcher    // fixed-size shelf chip
        case .divider:
            form = .launcher    // fixed-size separator, no animation form change
        }
    }
}

/// 悬停命中帧（`StripEntry.id` → "strip" 空间帧）。**四个区的卡全收进这一本**——它回答的是
/// 「指针压在谁身上」，那本来就不分区。同样独立于其余三本：那三本各自喂重排 / 弹窗锚点 /
/// 释放判定，语义不同，合并会互相污染（评审 P1 的老教训）。
struct StripHoverFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 文件夹 chip 帧（弹窗锚点 + 外部拖入 pin 路由）。独立于 ChipFramePreferenceKey——后者是
/// live 窗口区拖拽重排/落点命中的输入,文件夹 id 混进去会被当成落点目标（评审 P1）。
struct FolderChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 消息区 chip 帧（bundleID → frame）。独立于 ChipFramePreferenceKey——理由同文件夹 chip：
/// 混进 live 重排/落点命中的输入会让窗口拖动命中消息区、落点 no-op。
struct MessagingChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 中转格 frame（单值）。独立于 FolderChipFramePreferenceKey（评审：文件夹帧字典不混 sentinel）。
struct ShelfFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 外部文件拖入任务条的系统拖放收口。路由几何 = 纯函数 `StripDropRouting.route`;
/// 本 delegate 只负责:悬停期间把目标发布给视图做高亮、松手后异步取齐 URL 再回主线程提交。
/// 挂载点必须与 "strip" coordinateSpace 同层（坐标同源,评审拍板）。
struct StripFileDropDelegate: DropDelegate {
    /// nil = 中转格被用户关掉（不是「帧还没量到」，后者仍传 `.zero`）。
    let shelfFrame: CGRect?
    let folderFrames: [String: CGRect]
    let orderedPaths: [String]
    var headSlack: CGFloat = StripDropRouting.defaultHeadSlack
    /// dropEntered = 悬停会话开始;dropUpdated = 会话进行中移动;performDrop/dropExited = 会话结束。
    /// 视图侧据此做「高亮只能由 dropEntered 点亮 + 拖放结束看门狗」（见 externalDropHover*）。
    let onHoverBegan: (StripDropRouting.Target) -> Void
    let onHoverMoved: (StripDropRouting.Target) -> Void
    let onHoverEnded: () -> Void
    let onCommit: (StripDropRouting.Target, [URL]) -> Void

    private func route(_ info: DropInfo) -> StripDropRouting.Target {
        StripDropRouting.route(location: info.location,
                               shelfFrame: shelfFrame,
                               folderFrames: folderFrames,
                               orderedPaths: orderedPaths,
                               headSlack: headSlack)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        onHoverBegan(route(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = route(info)
        onHoverMoved(target)
        return DropProposal(operation: target == .none ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        onHoverEnded()
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = route(info)
        onHoverEnded()   // 落定即灭高亮,同步清（系统在这之后仍可能补发孤立 dropUpdated,已被门控忽略）。
        guard target != .none else { return false }
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }

        // 异步取齐全部 URL,保持 provider 顺序,回主线程一次性提交。
        let group = DispatchGroup()
        let box = ResultBox(count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                box.set(url, at: index)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = box.urls.compactMap { $0 }
            guard !urls.isEmpty else { return }
            onCommit(target, urls)
        }
        return true
    }

    /// loadObject 回调在后台线程,加锁按位写,保序。
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [URL?]
        init(count: Int) { urls = Array(repeating: nil, count: count) }
        func set(_ url: URL?, at index: Int) {
            lock.lock(); defer { lock.unlock() }
            urls[index] = url
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

// MARK: - Visual Effect Background

/// 全部悬浮面板（任务条 / 抽屉 / 胶囊 / 两个弹窗）唯一的毛玻璃底。
/// `.behindWindow` 的模糊与提饱和度由 WindowServer 在窗口后面算，材质本身跟随系统外观。
struct DockVisualEffectView: NSViewRepresentable {
    /// 由调用方按当前外观传入（`DockThemeTokens.panelMaterial`）。
    var material: DockPanelMaterial = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material.nsMaterial
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    /// 必须真的应用材质：外观切换时 SwiftUI 只会重跑 update，不会重建 NSView。
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        let resolved = material.nsMaterial
        if nsView.material != resolved { nsView.material = resolved }
    }
}

// MARK: - Mouse wheel horizontal strip scrolling

private struct WheelScrollInterceptorRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelScrollInterceptorView {
        WheelScrollInterceptorView()
    }

    func updateNSView(_ nsView: WheelScrollInterceptorView, context: Context) {
        nsView.resolveScrollViewIfNeeded()
    }
}

private final class WheelScrollInterceptorView: NSView {
    private static let wheelSpeed: CGFloat = 56
    private static let maxStep: CGFloat = 120

    private weak var scrollView: NSScrollView?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollViewIfNeeded()
    }

    override func layout() {
        super.layout()
        resolveScrollViewIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point),
              let event = NSApp.currentEvent,
              event.type == .scrollWheel,
              !event.hasPreciseScrollingDeltas,
              event.scrollingDeltaY != 0,
              resolveScrollViewIfNeeded() != nil else {
            return nil
        }
        return self
    }

    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas,
              event.scrollingDeltaY != 0,
              let scrollView = resolveScrollViewIfNeeded(),
              let documentView = scrollView.documentView else {
            super.scrollWheel(with: event)
            return
        }

        let clipView = scrollView.contentView
        let maxX = max(0, documentView.bounds.width - clipView.bounds.width)
        guard maxX > 0 else { return }

        let naturalScrolling = UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection")
        let sign: CGFloat = naturalScrolling ? -1 : 1
        let rawDelta = sign * event.scrollingDeltaY * Self.wheelSpeed
        let delta = min(max(rawDelta, -Self.maxStep), Self.maxStep)
        guard delta != 0 else { return }

        let currentX = clipView.bounds.origin.x
        let nextX = min(max(currentX + delta, 0), maxX)
        guard nextX != currentX else { return }

        clipView.scroll(to: NSPoint(x: nextX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    @discardableResult
    func resolveScrollViewIfNeeded() -> NSScrollView? {
        if let scrollView, scrollView.window != nil {
            return scrollView
        }

        var ancestor = superview
        while let candidate = ancestor {
            if let found = findScrollView(in: candidate) {
                scrollView = found
                return found
            }
            ancestor = candidate.superview
        }
        scrollView = nil
        return nil
    }

    private func findScrollView(in root: NSView) -> NSScrollView? {
        guard root !== self else { return nil }
        if let scrollView = root as? NSScrollView {
            return scrollView
        }
        for subview in root.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Drag-reorder preference (任务条拖动重排 路线 A 自绘拖动)

/// Collects live chip frames by id in the `"strip"` space — feeds the floating drag copy's
/// position and the left/right-half landing decision (replaces the old width-only key + the
/// SwiftUI DropDelegates, now that the drag is a self-rendered in-app gesture).
private struct ChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// macOS 14 的 `defaultScrollAnchor(.leading)` 在更老系统上不可用；横向 ScrollView 本来就从
    /// 前缘开始，所以旧系统走默认即可（仅 14+ 显式锚定，保持原行为）。
    @ViewBuilder
    func compatLeadingScrollAnchor() -> some View {
        if #available(macOS 14.0, *) {
            self.defaultScrollAnchor(.leading)
        } else {
            self
        }
    }
}

// MARK: - Strip Entrance Modifier

struct StripEntranceModifier: ViewModifier {
    /// `nil` = 这一次不播入场。**载体快照走的就是这条**：入场的 `@State` 从
    /// `opacity 0 / offset 8` 起步、靠 `onAppear` 才翻正，而快照是同步拍的——
    /// 不关掉的话拍出来会是一张半透明、往上偏 8pt 的图。
    let id: String?
    let delay: Double
    @Binding var animatedEntryIDs: Set<String>

    @State private var isAppeared = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if let id {
            animated(content, id: id)
        } else {
            content
        }
    }

    private func animated(_ content: Content, id: String) -> some View {
        content
            .offset(y: isAppeared ? 0 : 8)
            .opacity(isAppeared ? 1 : 0)
            .onAppear {
                if animatedEntryIDs.contains(id) {
                    isAppeared = true
                } else {
                    // 错开首帧布局，避免坐标原点飞入
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8).delay(delay)) {
                            isAppeared = true
                        }
                        animatedEntryIDs.insert(id)
                    }
                }
            }
    }
}

extension View {
    func stripEntrance(id: String?, delay: Double, animatedEntryIDs: Binding<Set<String>>) -> some View {
        self.modifier(StripEntranceModifier(id: id, delay: delay, animatedEntryIDs: animatedEntryIDs))
    }
}

// MARK: - 整条一块的指针跟踪区

/// 最后一次指针位置的引用盒。放进 `@State` 只为了跨 body 存活；**改它不触发重算**，
/// 这正是要的——指针每动一次都重算整条 body 太贵，重算只发生在拥有者真的变了的时候。
final class PointerBox {
    var value: CGPoint?
}

/// 盖住整条任务条的一块 `NSTrackingArea`，把指针位置报上去。谁被悬停由纯判定
/// `StripHoverResolution` 算——**这是全条唯一的悬停来源**，每张卡不再各自挂 `.onHover`
///（漏格 + 边界带方向，成因见那个类型）。
///
/// **进出用跟踪区，位置靠自己按帧轮询。** 第一版全指望跟踪区的 `.mouseMoved`，实测是死路：
/// 一趟 34 步的合成扫描只报上来 **6** 次，而且 5 次挤在最后 80ms 里一起到（2026-08-17）。
/// 原因是这几块面板都是 `.nonactivatingPanel`、永远不会成为 key 窗口，而 AppKit 只保证把
/// 鼠标移动事件送给 key 窗口——`acceptsMouseMovedEvents` 也救不回来（试过）。
/// 进入 / 离开倒是可靠的（SwiftUI 的 `.onHover(true)` 一直就是靠它）。
///
/// 所以：`mouseEntered` 起一个 60Hz 的定时器读 `NSEvent.mouseLocation`，指针走出本视图
/// 就报 `nil` 并停表。**只在指针压在任务条上时存在**，不是常驻轮询；位置没变的那一拍直接跳过，
/// 归属没变也不写 `@State`，所以停在条上不动是零开销。
///
/// 这不是 AGENTS 禁掉的常驻 `.mouseMoved` 全局监视器：那条禁的是 `addGlobalMonitorForEvents`
///（事件 tap，全系统鼠标事件先过我们进程，我们自己弹菜单时会被拖慢 100ms）。定时器不是 tap。
///
/// 另外两件承重的事：
/// - `.activeAlways`：面板永远不是 key 窗口，默认的 `.activeInKeyWindow` 连进出都收不到。
/// - `hitTest` 返回 `nil`：它是 `.background`，只观测、绝不吃点击。
private struct StripPointerTracker: NSViewRepresentable {
    /// 屏幕坐标（bottom-left）；`nil` = 指针离开了任务条。
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove   // 刷新闭包，捕获最新 @State 写入口
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
        nsView.stopPolling()
        nsView.onMove = nil
    }

    final class TrackingView: NSView {
        /// 关掉轮询、只留跟踪区自己的 `.mouseMoved`（`DOCK_STRIP_HOVER_POLL=0`）。
        /// 留着它才有办法回答「轮询到底是不是必需的」——2026-08-17 就是靠这个 A/B 定的。
        static let pollingEnabled =
            ProcessInfo.processInfo.environment["DOCK_STRIP_HOVER_POLL"] != "0"

        var onMove: ((CGPoint?) -> Void)?
        private var area: NSTrackingArea?
        private var poll: Timer?
        private var lastReported: CGPoint?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopPolling() }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(next)
            area = next
        }

        override func mouseEntered(with event: NSEvent) { pointerEvent() }
        override func mouseMoved(with event: NSEvent) { pointerEvent() }
        override func mouseDragged(with event: NSEvent) { pointerEvent() }

        /// 跟踪区确实送到了一个事件：位置照报（这条永远走），顺便起表。
        private func pointerEvent() {
            report(NSEvent.mouseLocation)
            guard Self.pollingEnabled else { return }
            startPolling()
        }

        /// 跟踪区的 exit 只是**其中一条**收尾路径：它在指针快速划出时会漏
        ///（AGENTS 里那条"气泡看门狗"的存在理由就是这个）。轮询自己判出界更可靠，
        /// 所以这里只是提前一步停表。
        override func mouseExited(with event: NSEvent) { leave() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func startPolling() {
            guard poll == nil else { return }
            tick()
            // 60Hz：屏幕就这个刷新率，再密也看不出来。2400pt/s 横扫时每 42pt 一格
            // 约 17.5ms，这个节奏刚好一格不漏。
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            poll = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func stopPolling() {
            poll?.invalidate()
            poll = nil
        }

        private func leave() {
            stopPolling()
            guard lastReported != nil else { return }
            lastReported = nil
            onMove?(nil)
        }

        private func tick() {
            guard let window, window.isVisible else {
                leave()
                return
            }
            let location = NSEvent.mouseLocation
            guard window.convertToScreen(convert(bounds, to: nil)).contains(location) else {
                leave()
                return
            }
            report(location)
        }

        /// 位置没变的那一拍直接跳过：停在条上不动 = 零开销。
        private func report(_ location: CGPoint) {
            guard location != lastReported else { return }
            lastReported = location
            onMove?(location)
        }
    }
}

// MARK: - 手势监视器（重击 / 中键 → 内容预览）
//
// 在任务条视图树里挂一个**本地** NSEvent 监视器：触控板重击（.pressure 压进 stage 2，去抖只在
// 进入 stage2 那一刻触发一次）+ 鼠标中键（.otherMouseDown button 2）→ 回调全局屏幕坐标，交给
// handleGesturePreview 做命中反查。监视器只观测不消费（return e），左键点击/文件夹拖拽零干扰；
// spike（2026-07-09）已验证重击不触发左键动作，无冲突。
private struct GestureMonitorInstaller: NSViewRepresentable {
    let onGesture: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onGesture = onGesture
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onGesture = onGesture   // 刷新闭包，捕获最新 chip 帧
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onGesture: ((CGPoint) -> Void)?
        private var pressureMonitor: Any?
        private var middleMonitor: Any?
        private var lastStage = 0

        func start() {
            pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { [weak self] e in
                guard let self else { return e }
                if e.stage == 2 && self.lastStage < 2 { self.onGesture?(NSEvent.mouseLocation) }
                self.lastStage = e.stage
                return e
            }
            middleMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] e in
                if e.buttonNumber == 2 { self?.onGesture?(NSEvent.mouseLocation) }
                return e
            }
        }

        func stop() {
            if let m = pressureMonitor { NSEvent.removeMonitor(m) }
            if let m = middleMonitor { NSEvent.removeMonitor(m) }
            pressureMonitor = nil
            middleMonitor = nil
        }
    }
}
