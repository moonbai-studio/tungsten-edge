import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · 投影构建：一次 body 求值只建一份 StripProjection（性能规则），标签去重、appKey。
// 2026-09-05 从 DockStripView.swift 按 extension 拆出，只搬不改。
extension DockStripView {
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
    func makeProjection() -> StripProjection {
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
        // 访达的应用级入口（无窗口时那张卡）只在勾了「在程序坞中保留」时显示（owner 2026-08-20）。
        // 跟踪层照旧永远跟着访达，所以取消勾选后一开窗口，窗口卡瞬时回来。
        let showsFinderEntry = FinderTaskbarPolicy.showsAppLevelEntry(
            isKept: keptAppStore.contains(FinderTaskbarPolicy.bundleID)
        )
        let items = snapshotItems.filter { item in
            let bid = item.bundleIdentifier ?? ""
            if drawerStore.contains(bid) { return false }
            if item.isAppLevelFallback, FinderTaskbarPolicy.isFinder(bid), !showsFinderEntry { return false }
            return true
        }

        var messaging: [StripEntry] = []
        var absorbedWindowIDs = Set<String>()
        for bid in msg {
            let appWindows = items.filter { $0.bundleIdentifier == bid && !$0.isAppLevelFallback }
            // 认主窗口的三条规则在纯 `MessagingMainWindowDecision` 里（标题匹配 → 排除后唯一 → 认不出）；
            // 这里只把窗口事实喂进去。
            let mainID = MessagingMainWindowDecision.mainWindowID(
                bundleID: bid,
                windows: appWindows.map {
                    .init(id: $0.id, title: $0.title,
                          isMinimized: $0.status == WindowStatus.minimized.rawValue,
                          area: ($0.bounds?.width ?? 0) * ($0.bounds?.height ?? 0))
                },
                titleMatchesAppName: { AppDisplayNameResolver.titleMatchesAppName($0, bundleID: bid) }
            )
            let main = appWindows.first { $0.id == mainID }
            if let main { absorbedWindowIDs.insert(main.id) }
            if main == nil || appWindows.count > 1 {
                MessagingZoneDiagnostics.record(bundleID: bid, windows: appWindows, mainID: main?.id)
            }
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
            // 访达有意留在 `.window` 兜底卡这条路径上：它带着专属菜单（最近使用的文件夹 /
            // 新建窗口）和「点击开主目录」，换成 .keptApp 的 LauncherChip 会把这些全丢掉。
            // kept 对访达只是上面那道可见性闸门。
            if FinderTaskbarPolicy.isFinder(bid) { continue }
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
        // 多屏 ④：按屏过滤**只在这里、只在顺序层之后**。上面喂给 `reconciled` 的 `liveOrderIDs` 和
        // `reconcileLiveOrder` 喂给 `sync` 的都是全集——各屏一致，共享顺序层才不会把别的屏的卡
        // 打成缺席（5s 后踢出记忆）、拖动重排也不会当帧截断。启动器类（保留占位、`app-*` 兜底卡、
        // 消息区、文件夹、中转站）每屏都在；归属未知 / 所在屏已拔 → 只落主屏。
        let displayFilter: StripDisplayFilter = {
            guard settingsStore.taskbarScreenPlacement == .allScreensPerDisplay, let displayUUID else {
                return .unfiltered
            }
            let table = displayTopologyStore.table
            return StripDisplayFilter(scope: displayUUID, connectedUUIDs: table.connectedUUIDs,
                                      primaryUUID: table.primaryUUID)
        }()
        // ④ 下正在拖动 / 归位飞行的那张窗口卡画在**认领**的那条上（指针悬上 B 条时 B 接管，B 开空槽、
        // A 合拢），不看归属键——归属键在松手搬完窗口之后才换。
        let carriedStripID = dragController.carriedPayload.flatMap { $0.source == .strip ? $0.id : nil }
        let claimedStrip = dragController.activeStripSurfaceID
        // 有运行圆点但没窗口的（应用级兜底卡、在运行却只剩占位的保留应用）只落主屏；
        // 没运行的占位是纯启动器，每屏都在（owner 2026-09-02：有圆点 = 只在一条上）。
        let renderedLive = orderedLive.filter { entry in
            let subject: StripDisplayFilter.Subject
            switch entry {
            case let .window(item):
                subject = item.isAppLevelFallback
                    ? .runningWithoutWindow(displayUUID: runtime.noWindowHomeByBundle[item.bundleIdentifier ?? ""]
                                                         ?? item.displayUUID)
                    : .window(displayUUID: item.displayUUID)
            case let .keptApp(bid):
                subject = runningIDs.contains(bid)
                    ? .runningWithoutWindow(displayUUID: runtime.noWindowHomeByBundle[bid]
                                                         ?? snapshotByBundle[bid]?.first?.displayUUID)
                    : .launcher
            default:
                return true
            }
            // 拖动中 / 归位飞行的那张卡按认领画（启动器类每屏都在，不用改）。
            if displayFilter.scope != nil, subject != .launcher, entry.id == carriedStripID, let claimedStrip {
                return claimedStrip == stripSurfaceID
            }
            return displayFilter.shows(subject)
        }
        // 卡片标签：同一应用的几张卡共享的那一段不承担区分作用，去掉（issue #41）。
        //
        // **按「这条 bar 上实际显示的卡」分组**，所以算在 `renderedLive` 定案之后：④ 下每块屏
        // 只显示本屏的窗口，公共段各屏不同，按全集算会把某块屏上仅剩的一张卡剥掉唯一的区分信息。
        // 也**必须在「拖出即合拢」的剔除之前**——拖走一张卡会让剩下的卡重算公共段，标签当场变长，
        // 拖到一半文字跳动。
        let labelTitleByChipID = Self.labelTitles(for: renderedLive)
        let folderEntries = (settingsStore.showShelf ? [StripEntry.shelf] : [])
            + pinnedFolderStore.folderPaths.map { StripEntry.pinnedFolder(path: $0) }
        // 拖出即合拢（owner 2026-09-03）：条上起拖的那张卡离开了条 → 从渲染里去掉（不是透明），
        // HStack 弹簧合拢、面板缩短（`PanelCoordinator` 订阅 `stripSlotCollapsed`）。**只在渲染数组里剔**：
        // `liveOrderIDs` / `messagingIDs` 喂顺序层与区内判定的仍是全集——顺序层子集不同会把它打成缺席
        // （5s 宽限后丢排名），消息区的「成员消失即取消拖动」监听也不能被它误触。只有认领的那条剔。
        let collapsedEntryID: String? = {
            guard ownsActiveDrag, dragController.stripSlotCollapsed,
                  let p = dragController.hiddenSlotPayload else { return nil }
            if p.source == .folder { return StripEntry.pinnedFolder(path: p.id).id }
            return Self.stripEntryID(for: p)
        }()
        var zones = [messaging, folderEntries, renderedLive]
            .map { zone in zone.filter { $0.id != collapsedEntryID } }
            .filter { !$0.isEmpty }
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
        // 角标落点：常规区里每个 app 显示序最左的那张窗口卡 / 占位卡。消息区成员跳过——
        // 它的红点在区里那枚图标上，独立聊天窗的卡不能再画一个。
        var badgeEntryIDByBundle: [String: String] = [:]
        for entry in entries {
            switch entry {
            case let .window(item):
                guard let bid = item.bundleIdentifier, !msgSet.contains(bid) else { continue }
                if badgeEntryIDByBundle[bid] == nil { badgeEntryIDByBundle[bid] = item.id }
            case let .keptApp(bid):
                guard !msgSet.contains(bid) else { continue }
                if badgeEntryIDByBundle[bid] == nil { badgeEntryIDByBundle[bid] = entry.id }
            default:
                continue
            }
        }
        let draggingID: String?
        // `carriedPayload` 而不是 `draggingPayload`：松手后还有 0.26 秒的归位飞行，
        // 那段时间原位必须继续空着，否则卡先显形、载体还在飞。
        // **只有拖动的那条 strip 空槽**（多屏 ③④ 下别的屏上同一张卡照常显示、跟着共享顺序层挪位，
        // owner 2026-09-02 报「另一块屏对应图标消失」）。
        if !ownsActiveDrag {
            draggingID = nil
        } else if let payload = dragController.hiddenSlotPayload,
           payload.source == .strip,
           liveOrderIDs.contains(payload.id) {
            draggingID = payload.id
        } else if let converted = dragController.convertedChipID,
                  liveOrderIDs.contains(converted) {
            // **认 chip id，不认代表卡**：`keepPlacement` 路径物化出来的是 `.keptApp` 占位或
            // app 级兜底卡，两者都当不了 `StripItem` 代表卡，跟着代表卡走就永远不让位（双影）。
            draggingID = converted
        } else if let bid = dragController.convertedDrawerBundleID,
                  let materialized = entries.lazy.compactMap({ entry -> String? in
                      switch entry {
                      case let .window(item): return item.bundleIdentifier == bid ? item.id : nil
                      case let .keptApp(id): return id == bid ? entry.id : nil
                      default: return nil
                      }
                  }).first(where: { liveOrderIDs.contains($0) }) {
            // 转正那一刻 `convertedChipID` 还是 nil——它在 `syncConvertedCarrier` 里、这一轮渲染**之后**才写。
            // 只认它，刚物化出来的卡就先以 1.0 不透明度插进条里、下一轮才被藏掉；SwiftUI 给插入配淡入、
            // 给藏掉配淡出，看到的就是「一个很淡的图标从末尾滑到落点」（owner 2026-09-04；图标缓存修好、
            // 显形变快之后才露出来）。从转正状态直接推出要藏的那张（与 `liveEntryIDs(bundleID:).first`
            // 同一条规则，保证和随后写入的 `convertedChipID` 是同一张），和插入同一轮生效。
            draggingID = materialized
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
            labelTitleByChipID: labelTitleByChipID,
            entries: entries,
            layoutKeys: entries.map(StripLayoutKey.init),
            messagingIDs: messagingIDs,
            draggingID: draggingID,
            badgeEntryIDByBundle: badgeEntryIDByBundle
        )
    }

    /// 每张窗口卡最终显示的标签：先去掉尾部的应用名，再去掉同一应用几张卡共享的公共段。
    ///
    /// 两步都要留着：④ 下一条 bar 上可能只剩某应用的一张卡（`showsTitle` 仍为 true、照样显示
    /// 标题），没有同伴可比对公共段，这时只有应用名那一步能生效。
    private static func labelTitles(for entries: [StripEntry]) -> [String: String] {
        var itemsByApp: [String: [(id: String, title: String)]] = [:]
        for case let .window(item) in entries {
            let appName = item.bundleIdentifier.map(AppDisplayNameResolver.displayName(for:)) ?? item.appID
            let resolved = WindowDisplayTitle.resolve(rawTitle: item.title, fallbackName: appName)
            let withoutApp = WindowDisplayTitle.trimmingAppNameSuffix(resolved, appName: appName)
            itemsByApp[item.bundleIdentifier ?? item.appID, default: []].append((item.id, withoutApp))
        }

        var labels: [String: String] = [:]
        for (_, group) in itemsByApp {
            let trimmed = StripSharedAffixTrim.trimmingSharedAffixes(group.map(\.title))
            for (entry, label) in zip(group, trimmed) { labels[entry.id] = label }
        }
        return labels
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
    func freshProjection() -> StripProjection { makeProjection() }

    /// 渲染路径（`reconciled`）与副作用路径（`sync`）**必须喂同一份 appKeyOf**，否则落盘的记忆序
    /// 与显示序不一致。抽成一个函数，让两条路径无从写岔。
    static func appKeys(of liveNatural: [StripEntry]) -> [String: String] {
        Dictionary(liveNatural.map { entry -> (String, String) in
            switch entry {
            case let .window(item): return (entry.id, item.bundleIdentifier ?? item.appID)
            case let .keptApp(bid): return (entry.id, bid)
            default: return (entry.id, entry.id)
            }
        }, uniquingKeysWith: { first, _ in first })
    }
}
