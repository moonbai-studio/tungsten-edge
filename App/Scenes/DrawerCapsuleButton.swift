import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drawer Capsule Button

struct DrawerCapsuleButton: View {
    @Environment(\.isPanelHeightResizing) private var isPanelHeightResizing
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var runningApplicationStore: RunningApplicationStore
    @EnvironmentObject var drawerOrderStore: DrawerOrderStore
    @EnvironmentObject var settingsStore: AppSettingsStore
    /// 拖卡进抽屉的投放反馈：手指压在投放区时胶囊放大 + 高亮描边。
    @EnvironmentObject var dragController: DragController
    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }
    /// 右键胶囊 → 弹钨极菜单。胶囊是设置的**主要后路入口**：它恒在、位置固定、尺寸等于面板高度，
    /// 而且是钨极自己的部件（不属于任何 app），不像任务条底板那样只剩几条缝可点。
    var onRequestTaskbarMenu: (NSEvent, NSView) -> Void = { _, _ in }
    /// 底板走不走原生 Liquid Glass。**显式传入、无默认值**（同 `scale` / `hoverStyle`）——
    /// 胶囊是另一棵长期存活的 hosting 根视图，漏传就会出现「条是玻璃、紧挨着的胶囊还是
    /// 毛玻璃」这种一眼可见的不一致。
    let usesLiquidGlass: Bool
    /// Toggles the full drawer: the bottom-trailing cell, and any cell that holds no app.
    let action: () -> Void
    /// An app cell dispatched an "open" (launch / unhide): an open drawer closes, exactly as
    /// after a tap inside it. No default — an omission would leave the drawer open.
    let onPrimaryAction: () -> Void
    /// App bundles dropped from outside onto the capsule (`DrawerAppDropReceiver`).
    /// No default — an omission would compile into a capsule that silently refuses them.
    let onDropApplications: ([URL]) -> Void
    /// An app dragged from outside entered / left the capsule: the coordinator's spring-load
    /// (`ExternalDragSpringLoad`). No default — an omission would compile into a capsule that
    /// lights up but never opens the drawer.
    let onExternalDragHover: (Bool) -> Void

    /// Cells are numbered row-major, 0...3; the last one is the expand cell.
    @State private var hoveredCell: Int?
    /// Press feedback per cell: a pure view-level signal, never fed to planner / frontmost.
    @State private var pressedCell: Int?
    /// An app dragged from outside hovers over the capsule: same feedback as a stash drag.
    @State private var isAppDropTargeted = false
    /// Which page of the drawer the capsule shows; per capsule, so per screen.
    @StateObject private var pager = DrawerCapsulePager()

    private var iconSize: CGFloat { DrawerCapsulePreviewMetrics.iconSize * dockScale }

    /// The carrier bitmap for an app dropped on the capsule: its icon, as the drag image showed it.
    private func externalCarrierSnapshot(application url: URL?, side: CGFloat, at frame: CGRect) -> CarrierSnapshot? {
        guard let url else { return nil }
        let scale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }?
            .backingScaleFactor ?? 2
        return ChipSnapshotter.iconSnapshot(of: NSWorkspace.shared.icon(forFile: url.path), side: side, scale: scale)
    }

    /// Every visible drawer app in the order the open drawer reads (`DrawerView.visibleMembers`):
    /// drawer order alone, never regrouped by running state, or the capsule pages disagree with
    /// the drawer.
    private var memberIDs: [String] {
        let placements = AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
        return AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: drawerOrderStore.reconciled(members: placements),
            keptIDs: keptAppStore.bundleIDs,
            runningIDs: runningApplicationStore.runningBundleIDs
        )
    }

    private var capsuleSide: CGFloat { settingsStore.dockPanelHeight.metrics.capsuleWidth }

    /// 胶囊是**另一棵**长期存活的 NSHostingView 根视图，必须自己观察同一个 store，
    /// 否则换档时任务条变了、胶囊里的四宫格还停在旧尺寸。
    private var dockScale: CGFloat { settingsStore.dockPanelHeight.scale }

    private var showsDropFeedback: Bool { dragController.isOverStashZone || isAppDropTargeted }

    /// While a card is dragged, hover gives way to the drop feedback (the drag wins).
    private var hoverEnabled: Bool { !isPanelHeightResizing && dragController.draggingPayload == nil }

    var body: some View {
        let ids = memberIDs
        let pageCount = DrawerCapsulePaging.pageCount(memberCount: ids.count)
        let page = DrawerCapsulePaging.clampedPage(pager.page, pageCount: pageCount)
        // Clicks, hover and press follow the page nearest to what is on screen, which differs from
        // the resting page while a trackpad gesture holds the capsule on its neighbour.
        let hitPage = DrawerCapsulePaging.hitPage(page: pager.page, drag: pager.drag, pageCount: pageCount)
        let apps = DrawerCapsulePaging.apps(page: hitPage, members: ids)
        return ZStack {
            DockPanelBackdrop(theme: theme,
                              cornerRadius: DockShape.panelCornerRadius * dockScale,
                              usesLiquidGlass: usesLiquidGlass,
                              matchesDockRefraction: true)

            // Hover and press feedback move only the cell under the pointer; the outer frame
            // (backdrop + rim) stays still.
            if ids.isEmpty {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 20 * dockScale, weight: .medium))
                    .foregroundStyle(theme.capsuleGlyph.color)
                    .cellFeedback(hovered: hoverEnabled && hoveredCell != nil, pressed: pressedCell != nil)
            } else {
                pagedPreview(ids: ids, pageCount: pageCount, page: page, hitPage: hitPage)
            }
        }
        .dockPanelRim(cornerRadius: DockShape.panelCornerRadius * dockScale,
                      style: theme.panelRimStyle,
                      lineWidth: theme.panelRimLineWidth,
                      usesLiquidGlass: usesLiquidGlass)
        // 拖卡悬到胶囊上：**微微发光 + 极轻微放大**（去掉原来生硬的白圈描边,owner 2026-06-21）。
        // The glow is a sibling beside the glass, never a `.shadow` around it: even a clear,
        // zero-radius shadow lands as a CALayer shadow on the glass's host layer, the suspected
        // cause of the milky capsule on macOS 26. Inside the scale, so the halo grows with the plate.
        .overlay(dropGlow(cornerRadius: DockShape.panelCornerRadius * dockScale))
        .scaleEffect(showsDropFeedback ? 1.04 : 1.0)
        .animation(.easeInOut(duration: DrawerAnimation.duration), value: showsDropFeedback)
        .dockShadow(theme.stripShadow,
                    visible: DockLiquidGlassConfiguration.stripShadowVisible(
                        usesLiquidGlass: usesLiquidGlass,
                        usesSystemVariant: DockGlassPresentation.usesSystemVariant))
        // After the scale, so the hover zoom never moves the zone; inside the shadow padding, so
        // the zone is the visible capsule + tolerance — the strip→capsule stash zone.
        .overlay(DrawerAppDropReceiver(
            screenZone: nil,
            onHoverChange: { over in
                isAppDropTargeted = over
                onExternalDragHover(over)
            },
            // The capsule only takes and lands first; nothing makes way on it.
            onHoverLocation: { _ in },
            // The drag image stays the source's over the capsule.
            dragImage: nil,
            onDropApplications: { urls, _, landing in
                // Sucked into the capsule like a bar card released on it, from the icon let go — up
                // before anything re-renders, as in the drawer.
                if let landing {
                    let square = min(landing.screenFrame.width, landing.screenFrame.height)
                    let frame = CGRect(x: landing.screenFrame.midX - square / 2, y: landing.screenFrame.midY - square / 2,
                                       width: square, height: square)
                    dragController.beginExternalLanding(
                        payload: DragPayload(source: .drawer, id: landing.bundleID, bundleID: landing.bundleID,
                                             item: nil, visualKind: .drawerIcon, canExternalDrop: true),
                        snapshot: externalCarrierSnapshot(
                            application: urls.first { Bundle(url: $0)?.bundleIdentifier == landing.bundleID },
                            side: square, at: frame),
                        fromScreenRect: frame, kind: .stash)
                }
                // On the next turn, as in the drawer: the carrier shows only once this turn ends.
                // The landed app takes the first cell; a capsule left on a later page would hide it
                // for the 3s its return waits.
                DispatchQueue.main.async {
                    pager.showFirstPage(pageCount: pageCount)
                    onDropApplications(urls)
                }
            }
        ).padding(-DrawerAppDrop.capsuleTolerance))
        .padding(PanelCoordinator.shadowPadding)
        // The hit cells split the whole padded frame into quadrants, so each target is as large
        // as the capsule allows and reaches the screen edge.
        .overlay(hitGrid(apps: apps))
        // Takes scroll events only (see `DrawerCapsuleScrollView.hitTest`); clicks fall through.
        .overlay(DrawerCapsuleScrollReceiver(enabled: hoverEnabled && pageCount > 1) { event in
            switch event {
            case .step(let direction): pager.step(direction, pageCount: pageCount)
            case .drag(let points): pager.drag(points: points, side: capsuleSide)
            case .dragEnded: pager.endDrag(pageCount: pageCount)
            }
        })
        // The three slots are worth their fixed places: once the pointer has left, the capsule
        // goes back to the first page.
        .onChange(of: hoveredCell == nil) { away in
            pager.pointerAway = away
        }
        .onReceive(dragController.capsuleStashes) { _ in
            pager.showFirstPage(pageCount: pageCount)
        }
        // MenuHostNSView takes only right / Control-clicks and lets left clicks through to the
        // cells above, so a right click anywhere on the capsule is the Tungsten menu — the
        // settings fallback entry keeps the whole capsule.
        .overlay(NativeMenuHost(popUpHandler: onRequestTaskbarMenu))
    }

    /// The stash drop glow: a blurred plate-shaped fill masked to the outside of the plate, so
    /// nothing is drawn over the glass. Always in the tree and faded by opacity — toggling it in
    /// and out would rebuild the glass beside it.
    private func dropGlow(cornerRadius: CGFloat) -> some View {
        let blurRadius: CGFloat = 5
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.capsuleStashGlow.color)
            .blur(radius: blurRadius)
            .mask {
                DrawerCapsuleGlowMask(cornerRadius: cornerRadius, outset: blurRadius * 3)
                    .fill(style: FillStyle(eoFill: true))
            }
            .opacity(showsDropFeedback ? 1 : 0)
            .allowsHitTesting(false)
    }

    // MARK: Preview

    /// Every app is one icon that lives through the whole scroll and is posed by the position
    /// (`DrawerCapsulePaging.pose`): turning forward, the mini icons grow and travel onto the three
    /// app cells, replacing the apps there, and the next ones grow into the mini grid. Nothing is
    /// clipped and nothing fades.
    private func pagedPreview(ids: [String], pageCount: Int, page: Int, hitPage: Int) -> some View {
        let side = capsuleSide
        let position = DrawerCapsulePaging.displayedPosition(page: page, drag: pager.drag, pageCount: pageCount)
        let hitApps = DrawerCapsulePaging.apps(page: hitPage, members: ids).count
        let expandActive = { (cell: Int?) in cell.map { $0 >= hitApps } == true }
        let appSlots = DrawerCapsulePreviewMetrics.appSlots
        // Past the last app the expand cell stays empty (no glyph) and still opens the drawer.
        return ZStack {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                // Press goes to the icons the click page holds: an app cell dips its own app, the
                // expand cell (or an app-less cell) the whole mini grid. Hover follows the same
                // split but is resolved by `DrawerCapsuleFlow`, against what is on screen.
                let slot = index - hitPage * appSlots
                let isApp = (0..<appSlots).contains(slot)
                let isMini = (appSlots..<DrawerCapsulePreviewMetrics.limit).contains(slot)
                DrawerCapsuleAppIcon(bundleID: id,
                                     size: iconSize,
                                     bounceHeight: DrawerCapsulePreviewMetrics.bounceHeight * dockScale,
                                     isLaunching: isApp && runtime.launchingBundleIDs.contains(id))
                    .chipPressScale(isApp ? pressedCell == slot : isMini && expandActive(pressedCell))
                    .modifier(DrawerCapsuleFlow(index: index, position: position, side: side, unit: dockScale,
                                                hoveredCell: hoverEnabled ? hoveredCell : nil,
                                                memberCount: ids.count))
            }
        }
        .frame(width: side, height: side)
    }

    // MARK: Hit cells

    private func hitGrid(apps: [String]) -> some View {
        let columns = DrawerCapsulePreviewMetrics.columns
        return VStack(spacing: 0) {
            ForEach(0..<columns, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        hitCell(index, bundleID: index < apps.count ? apps[index] : nil)
                    }
                }
            }
        }
    }

    private func hitCell(_ index: Int, bundleID: String?) -> some View {
        let isLaunching = bundleID.map { runtime.launchingBundleIDs.contains($0) } ?? false
        // Mid-turn an app slot shows the leaving and the arriving page at once, whatever the
        // arriving page holds there (an app or nothing): a click then would be a guess. Gated by
        // slot, not by content; the expand cell never changes meaning and stays live.
        let isMidTurn = index < DrawerCapsulePreviewMetrics.appSlots && pager.isTurning
        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hoveredCell = index } else if hoveredCell == index { hoveredCell = nil }
            }
            .onTapGesture {
                guard !isMidTurn else { return }
                if let bundleID { activate(bundleID) } else { action() }
            }
            // A tap during a launch session or a turn is a no-op, so it gets no press feedback either.
            .chipPressGesture(
                isPressed: Binding(
                    get: { pressedCell == index },
                    set: { pressed in
                        if pressed { pressedCell = index } else if pressedCell == index { pressedCell = nil }
                    }),
                isEnabled: !isLaunching && !isMidTurn
            )
            .help(bundleID.map { AppDisplayNameResolver.displayName(for: $0) } ?? "")
    }

    /// Same default tap as a drawer icon: launch / bring forward / hide when frontmost.
    private func activate(_ bundleID: String) {
        guard !runtime.launchingBundleIDs.contains(bundleID) else { return }
        let finderHasRealWindow = FinderTaskbarPolicy.isFinder(bundleID)
            && StripItem.items(from: runtime.snapshot).contains {
                $0.bundleIdentifier == bundleID && !$0.isAppLevelFallback
            }
        LauncherChip.performDefaultTap(
            bundleID: bundleID,
            isRunning: runningApplicationStore.isRunning(bundleID),
            finderHasRealWindow: finderHasRealWindow,
            launch: { if runtime.beginLaunch(bundleID) { onPrimaryAction() } },
            onOpen: onPrimaryAction
        )
    }
}

private extension View {
    /// Hover grows the cell in place, press dips it; both settle back exactly.
    func cellFeedback(hovered: Bool, pressed: Bool) -> some View {
        scaleEffect(hovered ? DrawerCapsulePreviewMetrics.hoverScale : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .chipPressScale(pressed)
    }
}

/// The band around the capsule plate: an outset rectangle with the plate cut out (even-odd fill).
private struct DrawerCapsuleGlowMask: Shape {
    let cornerRadius: CGFloat
    let outset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -outset, dy: -outset))
        path.addRoundedRect(in: rect,
                            cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
                            style: .continuous)
        return path
    }
}

/// Places one app's icon by the capsule's position. The position is the animatable value, so a
/// spring between two pages moves the icon along its blend frame by frame.
private struct DrawerCapsuleFlow: ViewModifier, Animatable {
    let index: Int
    var position: CGFloat
    let side: CGFloat
    let unit: CGFloat
    /// Nil while hover is disabled.
    let hoveredCell: Int?
    let memberCount: Int

    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    func body(content: Content) -> some View {
        let pose = DrawerCapsulePaging.endPullPose(index: index, position: position, memberCount: memberCount)
            ?? DrawerCapsulePaging.pose(index: index, position: position)
        // Hover is judged and scaled by the position on screen, so a turn hands it from one icon
        // to the next while neither is lifted. The timed animation only runs when the pointer
        // moves between cells; mid-turn the flag flips where the lift is already zero.
        let hovered = DrawerCapsulePaging.isHovered(index: index, position: position,
                                                    hoveredCell: hoveredCell, memberCount: memberCount)
        let lift = hovered
            ? 1 + (DrawerCapsulePreviewMetrics.hoverScale - 1) * DrawerCapsulePaging.hoverCalm(position: position)
            : 1
        content
            .scaleEffect(lift)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .scaleEffect(pose.size / DrawerCapsulePreviewMetrics.iconSize)
            .position(x: side / 2 + pose.x * unit, y: side / 2 + pose.y * unit)
            // The later app is always on top: turning forward the arriving icon covers the app it
            // replaces; turning back the leaving one shrinks away over the app coming back.
            .zIndex(Double(index))
            .opacity(pose.size > 0 ? 1 : 0)
    }
}

// MARK: - Capsule Paging

/// Where the capsule rests (`page`) and how far a live trackpad gesture has pulled it (`drag`).
/// The page is not clamped here — the member list changes underneath it — the view clamps on read.
@MainActor
final class DrawerCapsulePager: ObservableObject {
    @Published private(set) var page = 0
    @Published private(set) var drag: CGFloat = 0
    /// True from the moment a turn is committed until its spring has visibly settled. App cells
    /// ignore clicks meanwhile: the click page has already moved on while the old icons are
    /// still the larger ones on screen.
    @Published private(set) var isTurning = false
    private var turnTimer: Timer?
    private var returnTimer: Timer?
    /// Whether the pointer is off the capsule. Kept here, not only reacted to, because a turn can
    /// settle after the pointer has already left — the return must be armed at that point too.
    var pointerAway = true {
        didSet {
            guard pointerAway != oldValue else { return }
            if pointerAway { scheduleReturn() } else { cancelReturn() }
        }
    }

    /// Turn springs are critically damped: any overshoot past a page plays the start of the next
    /// turn, which reads as the capsule moving again just after it landed. A wheel notch plays the
    /// whole handover on its own; a trackpad release has the fingers' travel behind it.
    private static let wheelTurn = Animation.spring(response: 0.38, dampingFraction: 1)
    private static let releaseTurn = Animation.spring(response: 0.32, dampingFraction: 1)
    private static let returnHome = Animation.spring(response: 0.5, dampingFraction: 0.9)
    private static let returnDelay: TimeInterval = 3
    /// By now the arriving icons are within about a point of rest for the turn springs, and the
    /// apps they replace have shrunk to nothing.
    private static let turnSettle: TimeInterval = 0.3

    deinit {
        returnTimer?.invalidate()
        turnTimer?.invalidate()
    }

    /// Commits a turn to `target`; gates app clicks only when the page really changes.
    private func turn(to target: Int, from shown: Int, animation: Animation) {
        if target != shown {
            isTurning = true
            turnTimer?.invalidate()
            let timer = Timer(timeInterval: Self.turnSettle, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.turnTimer = nil
                    self?.isTurning = false
                }
            }
            turnTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        withAnimation(animation) {
            page = target
            drag = 0
        }
    }

    /// A wheel notch: one page, animated.
    func step(_ direction: Int, pageCount: Int) {
        let shown = DrawerCapsulePaging.clampedPage(page, pageCount: pageCount)
        turn(to: DrawerCapsulePaging.clampedPage(shown + direction, pageCount: pageCount),
             from: shown, animation: Self.wheelTurn)
        if pointerAway { scheduleReturn() }
    }

    /// Trackpad travel follows the fingers frame by frame, so it is never animated.
    func drag(points: CGFloat, side: CGFloat) {
        guard side > 0, points.isFinite else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drag = min(max(drag - points / side, -1), 1)
        }
    }

    func endDrag(pageCount: Int) {
        // The click page before release is the one nearest to what is shown; only a release that
        // lands elsewhere changes what a click would hit.
        let shown = DrawerCapsulePaging.hitPage(page: page, drag: drag, pageCount: pageCount)
        turn(to: DrawerCapsulePaging.settledPage(page: page, drag: drag, pageCount: pageCount),
             from: shown, animation: Self.releaseTurn)
        if pointerAway { scheduleReturn() }
    }

    /// Back to the first page at once (an app was just dropped into its first cell).
    func showFirstPage(pageCount: Int) {
        cancelReturn()
        turn(to: 0, from: DrawerCapsulePaging.hitPage(page: page, drag: drag, pageCount: pageCount),
             animation: Self.returnHome)
    }

    private func scheduleReturn() {
        returnTimer?.invalidate()
        guard page != 0 else { return }
        let timer = Timer(timeInterval: Self.returnDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.returnTimer = nil
                self.turn(to: 0, from: self.page, animation: Self.returnHome)
            }
        }
        returnTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelReturn() {
        returnTimer?.invalidate()
        returnTimer = nil
    }
}

enum DrawerCapsuleScrollEvent {
    /// A wheel notch: -1 = previous page, 1 = next.
    case step(Int)
    /// Trackpad travel in points, in the system's content direction.
    case drag(CGFloat)
    case dragEnded
}

struct DrawerCapsuleScrollReceiver: NSViewRepresentable {
    let enabled: Bool
    let onEvent: (DrawerCapsuleScrollEvent) -> Void

    func makeNSView(context: Context) -> DrawerCapsuleScrollView { DrawerCapsuleScrollView() }

    func updateNSView(_ view: DrawerCapsuleScrollView, context: Context) {
        view.onEvent = onEvent
        view.enabled = enabled
    }

    static func dismantleNSView(_ view: DrawerCapsuleScrollView, coordinator: ()) { view.finishTracking() }
}

final class DrawerCapsuleScrollView: NSView {
    var onEvent: (DrawerCapsuleScrollEvent) -> Void = { _ in }
    var enabled = true {
        didSet { if oldValue && !enabled { finishTracking() } }
    }
    private var isTracking = false
    private var lastStepTime: TimeInterval = 0
    private var watchdog: Timer?

    /// Fast wheel spins turn several pages, but never faster than one page per interval.
    private static let stepInterval: TimeInterval = 0.12
    /// A gesture whose end never arrives (the pointer left the capsule mid-swipe) still settles.
    /// Resting fingers send no events either, so the watchdog only ends a gesture once the
    /// pointer is off the capsule.
    private static let trackingTimeout: TimeInterval = 0.3

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled, super.hitTest(point) != nil,
              let event = NSApp.currentEvent, event.type == .scrollWheel else { return nil }
        // End events carry zero deltas and still belong to this gesture.
        return abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard enabled else { return }
        // Paging settles on its own spring; the system's momentum tail would turn a second page.
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.isEmpty {
            let delta = event.scrollingDeltaY
            guard delta != 0, event.timestamp - lastStepTime >= Self.stepInterval else { return }
            lastStepTime = event.timestamp
            onEvent(.step(delta > 0 ? -1 : 1))
            return
        }
        if event.phase.contains(.began) { isTracking = true }
        guard isTracking else { return }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finishTracking()
            return
        }
        if event.scrollingDeltaY != 0 { onEvent(.drag(event.scrollingDeltaY)) }
        armWatchdog()
    }

    private func armWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: Self.trackingTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.isPointerInside { self.armWatchdog() } else { self.finishTracking() }
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private var isPointerInside: Bool {
        guard let window else { return false }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return bounds.contains(convert(inWindow, from: nil))
    }

    func finishTracking() {
        watchdog?.invalidate()
        watchdog = nil
        guard isTracking else { return }
        isTracking = false
        onEvent(.dragEnded)
    }

    deinit { watchdog?.invalidate() }
}

// MARK: - Capsule App Icon

/// One directly clickable app in the capsule. Owns only the launch bounce; hover and press
/// are applied by the capsule, which owns the hit cells.
private struct DrawerCapsuleAppIcon: View {
    @ObservedObject private var iconRevision = AppIconRevision.shared
    let bundleID: String
    let size: CGFloat
    let bounceHeight: CGFloat
    /// Runtime-owned launch session state, rendered only (same contract as `LauncherChip`).
    let isLaunching: Bool

    @State private var bounceUp = false
    @State private var bounceTimer: Timer?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isPanelHeightResizing) private var isPanelHeightResizing

    var body: some View {
        Image(nsImage: AppIconResolver.icon(for: bundleID, points: size, displayScale: displayScale,
                                             colorScheme: colorScheme, allowsRendering: !isPanelHeightResizing))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .offset(y: bounceUp ? -bounceHeight : 0)
            .animation(.easeInOut(duration: 0.25), value: bounceUp)
            .onAppear { if isLaunching { startBounce() } }
            .onDisappear { stopBounce() }
            .onChange(of: isLaunching) { launching in
                if launching { startBounce() } else { stopBounce() }
            }
    }

    /// Finite legs scheduled by a common-mode timer, as in `LauncherChip`: a hover or layout
    /// transaction cannot turn the bounce into one that outlives the launch.
    private func startBounce() {
        guard bounceTimer == nil else { return }
        bounceUp = true
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in bounceUp.toggle() }
        timer.tolerance = 0.02
        bounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopBounce() {
        bounceTimer?.invalidate()
        bounceTimer = nil
        bounceUp = false
    }
}
