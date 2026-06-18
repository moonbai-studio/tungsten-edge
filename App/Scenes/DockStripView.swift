import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    /// id of the live chip currently being dragged (nil = not dragging). Drives the
    /// in-flight hide so its slot becomes the landing gap.
    @State private var draggingID: String?

    /// Live chip widths by id, collected via preference — feeds the drop delegate's
    /// left/right-half split without an overlay (which would steal clicks).
    @State private var chipWidths: [String: CGFloat] = [:]

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
        .overlay {
            RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(Style.borderTopOpacity), .white.opacity(Style.borderBottomOpacity)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        // Converge the remembered live order with the current snapshot (drop closed, append
        // new) as a side-effect — never during body eval. `initial: true` seeds on first
        // appearance so the very first render's reconcile (empty → current) is a visual no-op.
        .onChange(of: liveOrderIDs, initial: true) { _, current in
            stripOrderStore.sync(current: current, appKeyOf: liveAppKeys)
        }
        // Catch releases that land in the gaps / background (not onto a chip) so the
        // in-flight chip's hidden state always clears. (Per-chip delegates clear on
        // drop-onto-chip; this is the fallback for everything else inside the strip.)
        .onDrop(of: [.text], delegate: ClearDragDropDelegate(draggingID: $draggingID))
        .onPreferenceChange(ChipWidthPreferenceKey.self) { chipWidths = $0 }
        // No .frame(maxWidth: .infinity) here — lets NSHostingView.fittingSize reflect
        // the natural content width so AppDelegate can read it for panel sizing.
    }

    /// Wraps a chip with drag-reorder for the **live zone only** (任务条拖动重排 slice 3).
    /// Pinned messaging chips don't participate — no drop delegate means a window chip can't
    /// land in that zone (拖动分区内进行).
    ///
    /// Live-reorder feel (native-Dock style): while dragging, the in-flight chip is hidden so
    /// its slot becomes the landing **gap**, and the others slide aside as the gap moves
    /// through them — driven by the existing `stripLayoutKeys` spring. The drop side returns
    /// `.move`, so the cursor shows a move (no copy「+」). Pointer over a target's left half →
    /// land left, right half → land right. macOS click-drag is free here (scrolling uses
    /// wheel/trackpad), so a plain tap still activates and right-click still opens the menu.
    /// `.onDrag` has no "drag ended" callback, and a release that lands off every drop target
    /// (dead space, or over the drawer before it has one) never fires `performDrop` — which
    /// would otherwise leave the hidden chip stuck invisible. So poll the hardware button state
    /// and clear `draggingID` the moment the mouse is released, wherever that happens. Runs only
    /// during a drag (stops as soon as the button is up or the id is already cleared).
    private func watchDragEnd() {
        guard draggingID != nil else { return }
        if NSEvent.pressedMouseButtons == 0 {
            draggingID = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { watchDragEnd() }
    }

    @ViewBuilder
    private func chipWithReorder(_ entry: StripEntry) -> some View {
        switch entry {
        case let .window(item):
            stripEntryView(entry)
                // Hide the in-flight chip so its slot is the landing **gap** that follows the
                // cursor (native-Dock feel); the floating **system** drag image is what you
                // carry (and can cross panels, for the future drag-into-drawer). `draggingID`
                // is cleared the instant the mouse is released (watchDragEnd), wherever the
                // release lands — so the chip can never stay hidden after a drop in dead space
                // / over the drawer, and the reappear coincides with the system image vanishing
                // (which also cuts the release ghost).
                .opacity(draggingID == item.id ? 0 : 1)
                .onDrag {
                    // Defer one tick so the drag image snapshots at full opacity, then start
                    // watching for the mouse release that ends the drag.
                    DispatchQueue.main.async {
                        draggingID = item.id
                        watchDragEnd()
                    }
                    return NSItemProvider(object: item.id as NSString)
                }
                // Width via a **background** GeometryReader — doesn't affect layout and,
                // crucially, doesn't steal clicks. (An overlay with a hittable Color.clear
                // sits on top and intercepts taps, breaking chip clicks — the slice-3 bug.)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChipWidthPreferenceKey.self, value: [item.id: geo.size.width])
                    }
                )
                // onDrop directly on the chip: catches drops while leaving onTapGesture /
                // contextMenu intact (a drop session doesn't block plain clicks).
                .onDrop(of: [.text], delegate: ChipReorderDropDelegate(
                    targetID: item.id,
                    targetWidth: chipWidths[item.id] ?? 44,
                    draggingID: $draggingID,
                    reorder: { dragged, after in
                        stripOrderStore.reorder(draggedID: dragged, relativeTo: item.id, after: after, current: liveOrderIDs)
                    }
                ))
        case .messagingApp:
            stripEntryView(entry)
        }
    }

    @ViewBuilder
    private func stripEntryView(_ entry: StripEntry) -> some View {
        switch entry {
        case let .window(item):
            ChipView(item: item)
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

    var body: some View {
        Group {
            if !iconOnly && item.showsTitle {
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
        return appIcon(size: 36 * scale, opacity: iconOpacity)
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
            .onTapGesture {
                if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.actionWindowID) }
            }
            .contextMenu { chipContextMenu }
            .help(displayTitle)
    }

    // MARK: - Labeled chip

    private var multiWindowChip: some View {
        let iconOpacity: Double = effectiveIsOnDesktop ? 1.0 : 0.45
        let textOpacity: Double = effectiveIsOnDesktop ? 0.9 : 0.42
        return HStack(spacing: 6 * scale) {
            appIcon(size: 22 * scale, opacity: iconOpacity)

            Text(displayTitle)
                .font(.system(size: max(10, 12 * scale), weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(textOpacity))
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(.horizontal, 10 * scale)
        .frame(height: 40 * scale)
        .background(
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(Color.white.opacity(0.09))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous))
        .onTapGesture {
            if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.actionWindowID) }
        }
        .contextMenu { chipContextMenu }
        .help(displayTitle)
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
                Button("收进抽屉") { drawerStore.add(bid); launchFavoriteStore.remove(bid) }
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
}

// MARK: - Drawer Capsule Button

struct DrawerCapsuleButton: View {
    @EnvironmentObject var drawerStore: DrawerStore
    let action: () -> Void

    private static let iconSize: CGFloat = 10
    private static let gridSpacing: CGFloat = 5

    private var folderIDs: [String] { Array(drawerStore.bundleIDs.prefix(9)) }

    var body: some View {
        ZStack {
            DockVisualEffectView()
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
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(Style.borderTopOpacity), .white.opacity(Style.borderBottomOpacity)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
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
    static let borderTopOpacity: Double    = 0.12  // top-edge highlight (simulates light from above)
    static let borderBottomOpacity: Double = 0.06  // side/bottom edges (nearly invisible)
}

// MARK: - Visual Effect Background

private struct DockVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.layer?.cornerRadius = Style.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Drag-reorder drop delegates (任务条拖动重排 slice 3)

/// Collects live chip widths by id (for the drop delegate's left/right-half split).
private struct ChipWidthPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Per-chip drop target: while a live chip is dragged over this one, place it left/right of
/// this chip by which half the pointer is in, live (so the others slide aside). Returns
/// `.move` so the cursor shows a move, not a copy「+」.
private struct ChipReorderDropDelegate: DropDelegate {
    let targetID: String
    let targetWidth: CGFloat
    @Binding var draggingID: String?
    let reorder: (_ draggedID: String, _ after: Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let dragging = draggingID, dragging != targetID {
            reorder(dragging, info.location.x > targetWidth / 2)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

/// Strip-background fallback: clears the drag state when a release lands off any chip, so the
/// in-flight chip never stays hidden. Doesn't reorder — the last `dropUpdated` already did.
private struct ClearDragDropDelegate: DropDelegate {
    @Binding var draggingID: String?

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
