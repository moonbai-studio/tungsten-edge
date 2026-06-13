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

    /// Pinned messaging zone (leftmost, in store order) + live window zone.
    /// Messaging apps show only while running (quit → chip gone; the future drawer
    /// 待启动区 takes over the not-running role). Drawer membership hides a messaging
    /// app from the strip without clearing its messaging flag.
    ///
    /// 方案 B: each messaging app pins exactly ONE app-level chip. Its main window
    /// (title matches the app name) is absorbed into that chip; pop-out windows
    /// (chat windows etc.) flow through the live zone as normal window chips so the
    /// pinned zone keeps a stable width (muscle memory).
    private var stripEntries: [StripEntry] {
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

        let live = items
            .filter { item in
                guard msgSet.contains(item.bundleIdentifier ?? "") else { return true }
                if item.isAppLevelFallback { return false }     // app chip replaces the app-* fallback
                return !absorbedWindowIDs.contains(item.id)     // pop-outs stay as normal chips
            }
            .map { StripEntry.window($0) }

        return pinned + live
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
                        stripEntryView(entry)
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
        // No .frame(maxWidth: .infinity) here — lets NSHostingView.fittingSize reflect
        // the natural content width so AppDelegate can read it for panel sizing.
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
        runtime.optimisticStatesByWindowID[item.id]?.status.rawValue ?? item.status
    }

    private var effectiveIsOnDesktop: Bool {
        guard let optimistic = runtime.optimisticStatesByWindowID[item.id] else {
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
                if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.id) }
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
            if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.id) }
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
                Button("显示") { runtime.activate(windowID: item.id) }
            } else {
                Button("隐藏") { runtime.hide(windowID: item.id) }
            }
            Divider()
            Button("退出 App") { runtime.quit(windowID: item.id) }
            membershipMenuItems
        } else {
            Button("新建窗口") { runtime.newWindow(windowID: item.id) }
            if effectiveStatus == "minimized" {
                Button("还原") { runtime.activate(windowID: item.id) }
            } else {
                Button("最小化") { runtime.minimize(windowID: item.id) }
            }
            Button("隐藏 App") { runtime.hide(windowID: item.id) }
            membershipMenuItems
            Divider()
            Button("关闭窗口") { runtime.close(windowID: item.id) }
            Button("退出 App") { runtime.quit(windowID: item.id) }
        }
    }

    /// Drawer + launch-favorite + messaging membership toggles, mutually exclusive
    /// (2026-06-12 拍板「四者互斥」): choosing one membership clears the others.
    /// Exception kept from the earlier bug fix: the messaging flag is permanent across
    /// drawer moves — moving to the drawer only changes where the app shows (drawer
    /// wins display) and must NOT clear the flag.
    @ViewBuilder
    private var membershipMenuItems: some View {
        if let bid = item.bundleIdentifier {
            Divider()
            if drawerStore.contains(bid) {
                Button("移回任务栏") { drawerStore.remove(bid) }
            } else {
                Button("收进抽屉") { drawerStore.add(bid); launchFavoriteStore.remove(bid) }
            }
            if launchFavoriteStore.contains(bid) {
                Button("取消固定") { launchFavoriteStore.remove(bid) }
            } else {
                Button("固定到启动台") {
                    launchFavoriteStore.add(bid)
                    drawerStore.remove(bid)
                    // unmark also records the auto-registration opt-out, so the
                    // whitelist won't silently pull the app back to the pinned zone.
                    if messagingStore.contains(bid) { messagingStore.unmark(bid) }
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
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = Style.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
