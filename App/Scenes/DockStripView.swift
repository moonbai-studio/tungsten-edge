import AppKit
import SwiftUI

/// One slot in the strip: either a concrete window chip, or a pinned messaging
/// app-level entry (Dock-icon-like, 方案 B 2026-06-12).
enum StripEntry: Identifiable, Hashable {
    case window(StripItem)
    /// Constant app-icon chip for a pinned messaging app. Carries the main window's
    /// StripItem when it exists (the chip then *is* that window: toggle + full window
    /// menu); when the main window is gone, tap sends a reopen (Dock-icon-click
    /// equivalent) so the app recreates it — verified to work for WeChat even with
    /// other chat windows visible.
    case messagingApp(bundleID: String, mainWindow: StripItem?)

    var id: String {
        switch self {
        case let .window(item): return item.id
        // Stable id regardless of main-window presence, so the chip doesn't churn
        // when the main window opens/closes.
        case let .messagingApp(bid, _): return "msg-app-\(bid)"
        }
    }
}

struct DockStripView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var badgeStore: BadgeStore
    @EnvironmentObject var stripOrderStore: StripOrderStore
    /// 跨面板拖动权威（拖卡进抽屉 路线 C）：起拖 → beginDrag；读 draggingItem 隐藏原位卡片、
    /// 读 isOverDropZone 在进投放区时停掉条内重排。载体面板/监视器/收尾都在它里面，本视图不碰。
    @EnvironmentObject var dragController: DragController

    /// id of the live chip currently being dragged (nil = not dragging) —读自 dragController。
    /// 只认 strip 来源的拖动（抽屉来源的载荷在任务条里不该隐藏任何卡片），且限定 live 区 chip。
    private var draggingID: String? {
        guard let p = dragController.draggingPayload, p.source == .strip else { return nil }
        return liveOrderIDs.contains(p.id) ? p.id : nil
    }

    /// Live chip frames by id in the `"strip"` space (含滚动偏移后的屏上位置), collected via
    /// preference — feeds the grab offset at drag start and the full-frame landing hit-test.
    /// `.background` GeometryReader (not overlay) so it never steals chip clicks.
    @State private var chipFrames: [String: CGRect] = [:]

    private var allNonDrawerItems: [StripItem] {
        StripItem.items(from: runtime.snapshot)
            .filter { !drawerStore.contains($0.bundleIdentifier ?? "") }
    }

    private var snapshotBundleIDs: Set<String> {
        Set(StripItem.items(from: runtime.snapshot).compactMap(\.bundleIdentifier))
    }

    private func isHiddenInSnapshot(bundleID: String) -> Bool {
        StripItem.items(from: runtime.snapshot)
            .first { $0.bundleIdentifier == bundleID }?
            .status == "hidden"
    }

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
    private func partitioned() -> (pinned: [StripEntry], liveNatural: [StripItem]) {
        let msg = messagingStore.bundleIDs            // ordered → drag-reorder friendly
            .filter { !drawerStore.contains($0) && snapshotBundleIDs.contains($0) }
        let msgSet = Set(msg)
        let items = allNonDrawerItems

        var pinned: [StripEntry] = []
        var absorbedWindowIDs = Set<String>()
        for bid in msg {
            let appWindows = items.filter { $0.bundleIdentifier == bid && !$0.isAppLevelFallback }
            let main = appWindows.first { AppDisplayNameResolver.titleMatchesAppName($0.title, bundleID: bid) }
            if let main { absorbedWindowIDs.insert(main.id) }
            pinned.append(.messagingApp(bundleID: bid, mainWindow: main))
        }

        let liveNatural = items.filter { item in
            guard msgSet.contains(item.bundleIdentifier ?? "") else { return true }
            if item.isAppLevelFallback { return false }     // app chip replaces the app-* fallback
            return !absorbedWindowIDs.contains(item.id)     // pop-outs stay as normal chips
        }
        return (pinned, liveNatural)
    }

    /// Live-zone chip ids in natural snapshot order — input to the order layer and the
    /// value the sync side-effect watches (changes only when windows open/close).
    private var liveOrderIDs: [String] {
        partitioned().liveNatural.map(\.id)
    }

    /// chip id → 所属 app 键（bundleId 优先，缺则 appID）。喂给顺序层，让新窗口插到同 app 同伴旁
    /// 而非任务条最右（拖标签出来成独立窗口 / Cmd+N）。
    private var liveAppKeys: [String: String] {
        Dictionary(partitioned().liveNatural.map { ($0.id, $0.bundleIdentifier ?? $0.appID) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// 单一显示顺序漏斗：pinned 区按 `MessagingAppStore` 序，live 区由 `stripOrderStore`
    /// 重排（已有保序 / 新窗口进末尾 / 真关闭丢弃，见 `StripOrdering`）。渲染**绝不**直接读
    /// `snapshot.orderedWindowIDs` 出 live 序。slice 2 用当前序播种 → 视觉上无变化。
    private var stripEntries: [StripEntry] {
        let (pinned, liveNatural) = partitioned()
        let appKeyOf = Dictionary(liveNatural.map { ($0.id, $0.bundleIdentifier ?? $0.appID) },
                                  uniquingKeysWith: { first, _ in first })
        let order = stripOrderStore.reconciled(current: liveNatural.map(\.id), appKeyOf: appKeyOf)
        let byID = Dictionary(liveNatural.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedLive = order.compactMap { byID[$0] }.map(StripEntry.window)
        return pinned + orderedLive
    }

    private var stripLayoutKeys: [StripLayoutKey] {
        stripEntries.map(StripLayoutKey.init)
    }

    var body: some View {
        ZStack {
            DockVisualEffectView()
                .padding(-2)
                .clipShape(RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous))
                .ignoresSafeArea()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(stripEntries) { entry in
                        chipWithReorder(entry)
                            .transition(.scale(scale: 0.88).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Style.chipContentInset)
                .frame(height: PanelCoordinator.panelHeight)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: stripLayoutKeys)
            }
            .clipShape(RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous))
            .defaultScrollAnchor(.leading)
            .mask(alignment: .center) {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Style.edgeFadeWidth)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Style.edgeFadeWidth)
                }
            }
        }
        // 抽屉图标拖到任务条上方 = 移回任务栏的投放反馈：整条任务条高亮描边（对称于胶囊的收纳高亮）。
        .overlay {
            RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                .strokeBorder(dragController.isOverUnstashZone ? .white.opacity(0.45) : .white.opacity(0.15),
                              lineWidth: dragController.isOverUnstashZone ? 1 : 0.5)
        }
        .animation(.easeOut(duration: 0.15), value: dragController.isOverUnstashZone)
        // 跨面板后，被拖的卡片改由 DragController 的全屏载体面板绘制（不再画在任务条 overlay 上 —
        // 任务条窗口只有 92pt 高，自绘 overlay 会被裁掉，飘不出去）。这里只保留"让出空位"的原位隐藏。
        .coordinateSpace(name: "strip")
        .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 8)
        .padding(PanelCoordinator.shadowPadding)
        // Converge the remembered live order with the current snapshot (drop closed, append
        // new) as a side-effect — never during body eval. `initial: true` seeds on first
        // appearance so the very first render's reconcile (empty → current) is a visual no-op.
        .onChange(of: liveOrderIDs, initial: true) { _, current in
            stripOrderStore.sync(current: current, appKeyOf: liveAppKeys)
            // 拖动中被拖窗口消失 → 取消拖动，免得空位卡死。(松手无回调那条由 DragController 的轮询兜底。)
            if let p = dragController.draggingPayload, p.source == .strip, !current.contains(p.id) {
                dragController.cancelDrag()
            }
        }
        .onPreferenceChange(ChipFramePreferenceKey.self) { chipFrames = $0 }
        // No .frame(maxWidth: .infinity) here — lets NSHostingView.fittingSize reflect
        // the natural content width so AppDelegate can read it for panel sizing.
    }

    /// Live-zone reorder during a drag: find the chip whose **full frame** the finger is over
    /// (excluding the dragged chip itself), and place the dragged chip on the half the finger is
    /// in. Drives the existing `stripLayoutKeys` spring so the others slide aside as the gap moves.
    /// 全帧命中（不只看 x）：手指抬向胶囊/抽屉时 y 已离开条内行，contains 不命中 → 不误改顺序（Codex 二审）。
    private func reorderTarget(at point: CGPoint, dragging id: String) {
        guard let hit = chipFrames.first(where: { kv in
            kv.key != id && kv.value.contains(point)
        }) else { return }
        stripOrderStore.reorder(draggedID: id, relativeTo: hit.key,
                                after: point.x > hit.value.midX, current: liveOrderIDs)
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
    private func chipWithReorder(_ entry: StripEntry) -> some View {
        switch entry {
        case let .window(item):
            stripEntryView(entry)
                .opacity(draggingID == item.id ? 0 : 1)
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
                // 起拖交给 DragController（载体面板 + 监视器全程接管跟手/落点/收尾）；本手势只负责：
                // ① 起拖一次（算 grabOffset，取屏幕坐标起点）；② 条内重排（进投放区即停，Codex 二审第 4 条 —
                // 实测手势离开面板后不会自停，必须显式 gate）。onEnded 是监视器 mouseUp 之外的幂等兜底。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            if dragController.draggingPayload == nil {
                                let grab: CGSize = chipFrames[item.id].map {
                                    CGSize(width: $0.midX - value.startLocation.x,
                                           height: $0.midY - value.startLocation.y)
                                } ?? .zero
                                let payload = DragPayload(source: .strip, id: item.id,
                                                          bundleID: item.bundleIdentifier ?? "",
                                                          item: item, visualKind: .stripChip,
                                                          canExternalDrop: DragController.canStash(item))
                                dragController.beginDrag(payload: payload,
                                                         startScreenLocation: NSEvent.mouseLocation,
                                                         grabOffset: grab)
                            }
                            if !dragController.isOverDropZone {
                                reorderTarget(at: value.location, dragging: item.id)
                            }
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case .messagingApp:
            stripEntryView(entry)
        }
    }

    /// `dragging: true` forces the chip's hovered visual — the floating drag copy renders this
    /// so it matches the chip you grabbed (cursor is on it → it was hovered), no size pop.
    @ViewBuilder
    private func stripEntryView(_ entry: StripEntry, dragging: Bool = false) -> some View {
        switch entry {
        case let .window(item):
            ChipView(item: item, forceHover: dragging)
        case let .messagingApp(bid, main):
            // Explicit ZStack: the badge is the LAST child + zIndex, guaranteed to
            // draw on top of the icon (classic Dock badge sits over the icon corner).
            ZStack(alignment: .topTrailing) {
                if let main {
                    // Main window exists → the app chip IS the main window's chip:
                    // standard toggle on tap, full window context menu. Icon-only so the
                    // pinned zone stays a constant-width row of app icons; running dot
                    // marks it as an app entry.
                    ChipView(item: main, iconOnly: true, showRunningDot: true)
                } else {
                    // Main window closed (app still running) → full-opacity app icon;
                    // tap sends reopen so the app recreates its main window.
                    LauncherChip(bundleID: bid,
                                 isRunning: true,
                                 isHidden: isHiddenInSnapshot(bundleID: bid),
                                 scale: 1.0,
                                 dimsWhenInactive: false,
                                 removeMenuLabel: "取消标记消息应用",
                                 onRemove: { messagingStore.unmark(bid) },
                                 onTap: { Self.reopenMainWindow(bundleID: bid) })
                }
                if let badge = badgeStore.badgesByBundleID[bid] {
                    ChipBadgeView(text: badge)
                        .zIndex(1)
                }
            }
        }
    }

    /// Dock-icon-click equivalent: unhide + reopen. The app recreates its main window
    /// even when other windows are visible (verified with WeChat, 2026-06-12).
    private static func reopenMainWindow(bundleID: String) {
        _ = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.unhide()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }

}

// MARK: - Chip View

struct ChipView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var launchFavoriteStore: LaunchFavoriteStore
    let item: StripItem
    var scale: CGFloat = 1.0
    var iconOnly: Bool = false
    var showRunningDot: Bool = false
    var drawerTap: (() -> Void)? = nil
    /// Force the hovered visual regardless of pointer (used by the floating drag copy, which
    /// isn't hit-testable so its own `isHovering` would never light up).
    var forceHover: Bool = false

    @State private var isHovering = false

    /// Visual hover state: the real pointer hover OR forced (drag copy).
    private var showsHover: Bool { forceHover || isHovering }

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
    }

    // MARK: - Icon-only chip

    private var bareIconChip: some View {
        let iconOpacity: Double = effectiveIsOnDesktop ? 1.0 : 0.45
        let iconSize: CGFloat = showsHover ? 24 * scale : 36 * scale
        return VStack(spacing: 2) {
            Spacer(minLength: 0)
            appIcon(size: iconSize, opacity: iconOpacity)
            if showsHover {
                Text(displayTitle)
                    .font(.system(size: max(8, 10 * scale), weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: 64 * scale)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 44 * scale, height: 52 * scale)
        .overlay(alignment: .bottom) {
            if showRunningDot {
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 4, height: 4)
                    .padding(.bottom, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.actionWindowID) }
        }
        .contextMenu { chipContextMenu }
        .help(displayTitle)
        .animation(.easeInOut(duration: 0.18), value: isHovering)
    }

    // MARK: - Labeled chip

    private var multiWindowChip: some View {
        let iconOpacity: Double = effectiveIsOnDesktop ? 1.0 : 0.45
        let textOpacity: Double = effectiveIsOnDesktop ? 0.9 : 0.60
        let bgOpacity: Double = showsHover ? 0.14 : 0.08

        let pillHeight: CGFloat = showsHover ? 28 * scale : 34 * scale
        let pillIconSize: CGFloat = showsHover ? 18 * scale : 22 * scale
        let pill = HStack(spacing: 6 * scale) {
            // Fixed layout frame (22pt) so HStack width never changes on hover;
            // only the visual icon content shrinks.
            appIcon(size: pillIconSize, opacity: iconOpacity)
                .frame(width: 22 * scale, height: 22 * scale)
            Text(displayTitle)
                .font(.system(size: max(10, 12 * scale), weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(textOpacity))
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(.horizontal, 10 * scale)
        .frame(height: pillHeight)
        .background(
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(Color.white.opacity(bgOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(showsHover ? 0.25 : 0.15), .white.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
        )

        return VStack(spacing: 2) {
            Spacer(minLength: 0)
            pill
            if showsHover {
                Text(appName)
                    .font(.system(size: max(8, 9 * scale), weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .frame(maxWidth: 160 * scale)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 52 * scale)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.actionWindowID) }
        }
        .contextMenu { chipContextMenu }
        .help(displayTitle)
        .animation(.easeInOut(duration: 0.18), value: isHovering)
    }

    // MARK: - Shared Icon

    private func appIcon(size: CGFloat, opacity: Double) -> some View {
        Image(nsImage: AppIconResolver.icon(for: item.bundleIdentifier ?? item.appID))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .opacity(opacity)
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
    }

    // MARK: - Context Menu

    // 可打断（2026-06-13）：菜单项不再按 pending 置灰；显隐类动作随时可点
    //（乐观 overlay 保证一致性），close / quit 的防重入由 runtime.trigger 兜底。
    // 状态分支读 effectiveStatus，刚点过最小化立刻右键也能看到「还原」。
    @ViewBuilder
    private var chipContextMenu: some View {
        if item.isAppLevelFallback {
            if effectiveStatus == "hidden" {
                Button("显示") { runtime.activate(windowID: item.actionWindowID) }
            } else {
                Button("隐藏") { runtime.hide(windowID: item.actionWindowID) }
            }
            Divider()
            Button("退出 App") { runtime.quit(windowID: item.actionWindowID) }
            membershipMenuItems
        } else {
            Button("新建窗口") { runtime.newWindow(windowID: item.actionWindowID) }
            if effectiveStatus == "minimized" {
                Button("还原") { runtime.activate(windowID: item.actionWindowID) }
            } else {
                Button("最小化") { runtime.minimize(windowID: item.actionWindowID) }
            }
            Button("隐藏 App") { runtime.hide(windowID: item.actionWindowID) }
            membershipMenuItems
            Divider()
            // 整组关闭（2026-06-14）：标签组的「关闭窗口」关掉组内每个标签；
            // 普通窗口 memberWindowIDs == [id]，行为不变。
            Button("关闭窗口") {
                for wid in item.memberWindowIDs { runtime.close(windowID: wid) }
            }
            Button("退出 App") { runtime.quit(windowID: item.actionWindowID) }
        }
    }

    /// Drawer + launch-favorite toggles are independent since 2026-06-16 (reversed
    /// from the original 「四者互斥」), except 收进抽屉 below still clears the favorite
    /// flag — coexistence only survives pin-then-stash order, not stash-then-pin.
    /// Messaging stays mutually exclusive with both. The messaging flag itself is
    /// permanent across drawer moves — moving to the drawer only changes where the
    /// app shows (drawer wins display) and must NOT clear the flag.
    @ViewBuilder
    private var membershipMenuItems: some View {
        if let bid = item.bundleIdentifier {
            Divider()
            if drawerStore.contains(bid) {
                Button("移回任务栏") { drawerStore.remove(bid) }
            } else {
                // 不清固定标志：收纳与固定可共存（2026-06-16）。旧代码在此 remove 固定，
                // 导致「固定→收进抽屉→移回任务栏」后固定丢失（2026-06-18 owner 报告）。
                Button("收进抽屉") { drawerStore.add(bid) }
            }
            // 「固定到启动台」只对**不在抽屉**的 app 有意义（给它在任务条留常驻启动位）。
            // 已收进抽屉的 app 本就常驻抽屉，这个开关对它没有可见效果、只会造成「我已经
            // 固定了为啥还让我固定」的困惑（2026-06-18 owner 拍板：抽屉里不再显示）。
            if !drawerStore.contains(bid) {
                if launchFavoriteStore.contains(bid) {
                    Button("取消固定") { launchFavoriteStore.remove(bid) }
                } else {
                    Button("固定到启动台") {
                        launchFavoriteStore.add(bid)
                        if messagingStore.contains(bid) { messagingStore.unmark(bid) }
                    }
                }
            }
            if messagingStore.contains(bid) {
                Button("取消标记消息应用") { messagingStore.unmark(bid) }
            } else {
                Button("标记为消息应用") { messagingStore.mark(bid); drawerStore.remove(bid); launchFavoriteStore.remove(bid) }
            }
        }
    }

    // MARK: - Helpers

    private var displayTitle: String {
        item.title == "macos-dock-cc-v2" ? "任务条" : item.title
    }

    private var appName: String {
        guard let bid = item.bundleIdentifier else { return displayTitle }
        let name = AppDisplayNameResolver.displayName(for: bid)
        return name == "macos-dock-cc-v2" ? "任务条" : name
    }
}

// MARK: - Drawer Capsule Button

struct DrawerCapsuleButton: View {
    @EnvironmentObject var drawerStore: DrawerStore
    /// 拖卡进抽屉的投放反馈：手指压在投放区时胶囊放大 + 高亮描边。
    @EnvironmentObject var dragController: DragController
    let action: () -> Void

    private static let iconSize: CGFloat = 10
    private static let gridSpacing: CGFloat = 5

    private var folderIDs: [String] { Array(drawerStore.bundleIDs.prefix(9)) }

    var body: some View {
        ZStack {
            DockVisualEffectView()
                .padding(-2)
                .clipShape(RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous))
                .ignoresSafeArea()

            if folderIDs.isEmpty {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(Self.iconSize), spacing: Self.gridSpacing), count: 3),
                    spacing: Self.gridSpacing
                ) {
                    ForEach(folderIDs, id: \.self) { id in
                        Image(nsImage: AppIconResolver.icon(for: id))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: Self.iconSize, height: Self.iconSize)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }
                .padding(6)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        }
        // 拖卡悬到胶囊上：**微微发光 + 极轻微放大**（去掉原来生硬的白圈描边,owner 2026-06-21）。
        .scaleEffect(dragController.isOverStashZone ? 1.04 : 1.0)
        .shadow(color: .white.opacity(dragController.isOverStashZone ? 0.18 : 0),
                radius: dragController.isOverStashZone ? 5 : 0)
        .animation(.easeInOut(duration: DrawerAnimation.duration), value: dragController.isOverStashZone)
        .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 8)
        .padding(PanelCoordinator.shadowPadding)
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }
}

// MARK: - Chip Badge

/// Classic Dock-style unread badge: red capsule, white text, top-right of the chip.
/// Renders whatever string the app put on its Dock tile ("3", "99+", "•") as-is.
/// Not a hit target — taps fall through to the chip underneath.
private struct ChipBadgeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(
                Capsule().fill(Color(red: 1.0, green: 0.23, blue: 0.19))   // Apple badge red
            )
            .overlay(
                Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
            )
            // Native Dock badges sit mostly ON the icon, protruding only slightly past
            // its rounded corner. Chip frame is 44×52, icon inset (4, 8) → this offset
            // puts the badge center just inside the icon's top-right corner.
            .offset(x: 2, y: 3)
            .allowsHitTesting(false)
    }
}

// MARK: - Layout Animation Key

private struct StripLayoutKey: Equatable {
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
        }
    }
}

// MARK: - Visual Constants (hand-tune these)

private enum Style {
    // Shape
    static let cornerRadius: CGFloat   = 16   // panel corner radius

    // Content layout
    static let chipContentInset: CGFloat = 20  // horizontal padding inside blur; > cornerRadius avoids corner-clip
    static let edgeFadeWidth: CGFloat    = 16  // scroll edge fade-out width (pt)

    // Border
    static let borderTopOpacity: Double    = 0.55  // top-edge highlight (simulates light from above)
    static let borderBottomOpacity: Double = 0.02  // side/bottom edges (nearly invisible)
}

// MARK: - Visual Effect Background

struct DockVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
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
