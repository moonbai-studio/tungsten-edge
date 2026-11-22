import CoreGraphics

struct WindowLabelWidth: Equatable {
    static let minimum: CGFloat = 40
    static let maximum: CGFloat = 240
    static let `default` = WindowLabelWidth(points: 140)
    let points: CGFloat

    init(clamping raw: CGFloat) {
        points = raw.isFinite ? min(max(raw.rounded(), Self.minimum), Self.maximum) : Self.default.points
    }

    private init(points: CGFloat) { self.points = points }

    func scaled(by scale: CGFloat) -> CGFloat { points * scale }
}

struct ChipLabelSizing: Equatable {
    let width: WindowLabelWidth
    let isFixed: Bool
    static let `default` = ChipLabelSizing(width: .default, isFixed: false)
}

enum TaskbarLayoutKind: Equatable {
    case height, labelWidth
}

/// Taskbar height as the user dragged it: whole points, clamped to `minimum...maximum`.
///
/// Every scaled size multiplies `scale`, which is normalised to `native` (the real Dock's
/// bar height) so that a bar at 54pt renders byte-for-byte the signed-off native pixels.
/// Heights are rounded to whole points before anything derives from them; a fractional
/// height would put corner radius, icons and the hairline divider on half pixels.
struct DockPanelHeight: Equatable {
    /// 32…120 mirrors the reach of the Dock's own Size slider (tile 16…128 around a default of
    /// 48) rather than a comfort band around `native`. Both ends are reached only through the
    /// status-menu slider or the grip; nothing seeds them. Below ~38pt the unscaled 9pt ▲▼ grip
    /// glyph reaches past the chip *frame* by under 1pt but stays short of the icon artwork
    /// (`ChipPillMetrics.bareIconVisibleSlot` keeps 3.75pt × scale of transparent margin).
    static let minimum: CGFloat = 32
    static let maximum: CGFloat = 120

    /// 54 = the native macOS Dock bar height (@2x screenshot: 108px). Icons (40pt,
    /// `ChipHoverVisual.bareIconSize`) and `ChipPillMetrics.chipHeight` are tuned to it;
    /// changing one without the others breaks the 0.741 icon/bar ratio.
    static let native = DockPanelHeight(validated: 54)
    static let `default` = native

    let points: CGFloat

    /// Non-finite → default; otherwise rounded to whole points and clamped.
    init(clamping raw: CGFloat) {
        guard raw.isFinite else {
            self = .default
            return
        }
        self.init(validated: min(max(raw.rounded(), Self.minimum), Self.maximum))
    }

    private init(validated points: CGFloat) {
        self.points = points
    }

    /// Multiplier for every tier-scaled size. Exactly `1.0` at `native`.
    var scale: CGFloat { points / Self.native.points }

    /// Legacy four-tier raw values (`com.tungsten.edge.dockSize`), read once for migration.
    static func migratingLegacyTier(rawValue: String) -> DockPanelHeight? {
        switch rawValue {
        case "small": return DockPanelHeight(clamping: 46)
        case "medium": return DockPanelHeight(clamping: 54)
        case "large": return DockPanelHeight(clamping: 62)
        case "extraLarge": return DockPanelHeight(clamping: 70)
        default: return nil
        }
    }

    /// The single source of panel geometry: AppKit (`PanelCoordinator`) and SwiftUI both
    /// read it, never their own copy.
    var metrics: PanelLayoutMetrics {
        PanelLayoutMetrics(
            panelHeight: points,
            // Shadow padding never scales: the shadow tokens are frozen.
            shadowPadding: PanelLayoutMetrics.shadowPadding,
            // Written as an expression, not a literal: the relation used to live only in a
            // comment and is exactly what a height change forgets.
            windowHeight: points + 2 * PanelLayoutMetrics.shadowPadding,
            bottomGap: 8,
            outerMargin: 12,
            capsuleWidth: points,
            capsuleGap: 8,
            minimumDockWidth: 120 * scale,
            minimumDrawerExtent: 120
        )
    }
}

struct PanelLayoutMetrics: Equatable {
    var panelHeight: CGFloat
    var shadowPadding: CGFloat
    var windowHeight: CGFloat
    var bottomGap: CGFloat
    var outerMargin: CGFloat
    var capsuleWidth: CGFloat
    var capsuleGap: CGFloat
    var minimumDockWidth: CGFloat
    var minimumDrawerExtent: CGFloat

    /// Fixed; never scales with the bar height (see `DockPanelHeight.metrics`).
    static let shadowPadding: CGFloat = 20

    /// Native-height baseline for default parameters and tests; real values come from
    /// `DockPanelHeight.metrics`.
    static let tungstenEdge = DockPanelHeight.native.metrics
}

/// The drawer capsule's preview (2 × 2): three directly clickable apps plus a bottom-trailing
/// "expand" cell that shows the next four as a mini grid. Values are at the native height and
/// scale with the bar: `columns × icon + spacing + 2 × padding` must fit `capsuleWidth` at every
/// height (`PanelGeometryTests.testCapsuleGridContentFitsEveryHeight`).
enum DrawerCapsulePreviewMetrics {
    static let columns = 2
    /// Every cell but the bottom-trailing one launches an app.
    static let appSlots = columns * columns - 1
    static let miniColumns = 2
    static let miniLimit = miniColumns * miniColumns
    static let limit = appSlots + miniLimit
    // Proportions follow the system's app-library tile, on the visible artwork: a gap of about a
    // fifth of an icon, mini icons 0.4 of an icon. App icon assets carry ~9% transparent margin
    // per side, which already is that gap, so the frames touch. The 42pt the two columns span
    // keeps the icons clear of the capsule rim; growing it puts their corners against it.
    static let iconSize: CGFloat = 21
    static let gridSpacing: CGFloat = 0
    static let gridPadding: CGFloat = 4
    static let miniIconSize: CGFloat = 8.5
    static let miniSpacing: CGFloat = 0
    static let hoverScale: CGFloat = 1.1
    static let bounceHeight: CGFloat = 3

    /// The mini grid sits centred in one app cell and must not outgrow it.
    static var miniGridWidth: CGFloat {
        CGFloat(miniColumns) * miniIconSize + CGFloat(miniColumns - 1) * miniSpacing
    }

    static var contentWidth: CGFloat {
        CGFloat(columns) * iconSize + CGFloat(columns - 1) * gridSpacing + 2 * gridPadding
    }
}

/// Paging of the capsule preview: a page is three apps plus a mini grid of the next four.
/// `page` is where the capsule rests; `drag` is the live trackpad travel in pages.
enum DrawerCapsulePaging {
    /// Travel past which a released trackpad gesture turns the page instead of springing back.
    static let turnThreshold: CGFloat = 0.15
    /// How much of the overscroll past the first / last page is shown.
    static let rubberBand: CGFloat = 0.15
    /// Where one app's icon is drawn: its centre relative to the capsule's centre and its side
    /// length, both at the native height.
    struct IconPose: Equatable {
        var x: CGFloat
        var y: CGFloat
        var size: CGFloat
    }

    /// The pose of the icon resting in `slot`, counted from the first app of the shown page:
    /// 0...2 are the three app cells, 3...6 the mini grid. The page before (-3...-1) has shrunk
    /// to nothing in its app cell; the three after the mini grid (7...9) wait at zero size on the
    /// mini spots they are about to take. Everything further away is at zero size.
    static func restPose(slot: Int) -> IconPose {
        typealias M = DrawerCapsulePreviewMetrics
        let pitch = M.iconSize + M.gridSpacing
        func cell(_ index: Int) -> (x: CGFloat, y: CGFloat) {
            let wrapped = ((index % M.appSlots) + M.appSlots) % M.appSlots
            return (x: (CGFloat(wrapped % M.columns) - 0.5) * pitch, y: (CGFloat(wrapped / M.columns) - 0.5) * pitch)
        }
        func mini(_ index: Int) -> (x: CGFloat, y: CGFloat) {
            let miniPitch = M.miniIconSize + M.miniSpacing
            return (x: pitch / 2 + (CGFloat(index % M.miniColumns) - 0.5) * miniPitch,
                    y: pitch / 2 + (CGFloat(index / M.miniColumns) - 0.5) * miniPitch)
        }
        switch slot {
        case 0..<M.appSlots:
            let c = cell(slot)
            return IconPose(x: c.x, y: c.y, size: M.iconSize)
        case M.appSlots..<M.limit:
            let c = mini(slot - M.appSlots)
            return IconPose(x: c.x, y: c.y, size: M.miniIconSize)
        case M.limit..<(M.limit + M.appSlots):
            let c = mini(slot - 2 * M.appSlots)
            return IconPose(x: c.x, y: c.y, size: 0)
        default:
            let c = cell(slot)
            return IconPose(x: c.x, y: c.y, size: 0)
        }
    }

    /// Share of a turn during which a replaced app keeps its full size before it starts to shrink,
    /// so mid-turn the cell still holds two near-even icons instead of two small ones.
    static let leaveHold: CGFloat = 0.2
    /// Share of a turn before a new mini icon starts to grow: its spot is still held by the icon
    /// leaving it. The last spot waits longer — the fourth mini icon crosses the grid to vacate it.
    static let fillDelay: CGFloat = 0.3
    static let lastFillDelay: CGFloat = 0.45

    /// The pose of app `index` while the capsule is at `position` pages: a path between its
    /// resting poses on the two neighbouring pages (bowed slightly for two of the app cells, see
    /// `cellBend`). Turning forward, the first three mini icons grow and travel onto the three app
    /// cells while the apps there shrink away beneath.
    static func pose(index: Int, position: CGFloat) -> IconPose {
        let lower = position.rounded(.down)
        let t = position - lower
        let slot = index - Int(lower) * DrawerCapsulePreviewMetrics.appSlots
        let from = restPose(slot: slot)
        guard t > 0 else { return from }
        let to = restPose(slot: slot - DrawerCapsulePreviewMetrics.appSlots)
        let grown = sizeProgress(slot: slot, t: t)
        let bend = travelBend(slot: slot)
        let arc = 4 * t * (1 - t)
        return IconPose(x: from.x + (to.x - from.x) * t + arc * bend.x,
                        y: from.y + (to.y - from.y) * t + arc * bend.y,
                        size: from.size + (to.size - from.size) * grown)
    }

    /// Mid-turn offset from a straight path for the icon travelling onto each app cell
    /// (top-leading, top-trailing, bottom-leading). The two side paths bow a point and a half
    /// towards the capsule's inside, which also keeps the growing icons within the resting icons'
    /// outer edge; the diagonal stays straight. No rotation and no overshoot: in a cell this
    /// small either competes with the icons themselves.
    static let cellBend: [(x: CGFloat, y: CGFloat)] = [(0, 0), (-1.5, 0), (0, -1.5)]

    private static func travelBend(slot: Int) -> (x: CGFloat, y: CGFloat) {
        let appSlots = DrawerCapsulePreviewMetrics.appSlots
        guard (appSlots..<(2 * appSlots)).contains(slot) else { return (0, 0) }
        return cellBend[slot - appSlots]
    }

    /// How far the size has moved towards the next page's, for the icon resting in `slot` on the
    /// lower page. Only a function of the position, so a turn played backwards retraces it.
    private static func sizeProgress(slot: Int, t: CGFloat) -> CGFloat {
        let appSlots = DrawerCapsulePreviewMetrics.appSlots
        switch slot {
        case 0..<appSlots:
            // A replaced app holds, then shrinks; it reaches zero (and is hidden) only at the end.
            return smoothstep((t - leaveHold) / (1 - leaveHold))
        case appSlots..<(2 * appSlots):
            // A mini icon growing onto an app cell settles into its full size.
            return smoothstep(t)
        case DrawerCapsulePreviewMetrics.limit..<(DrawerCapsulePreviewMetrics.limit + appSlots):
            // A new mini icon grows only once its spot has emptied, so it never crowds the leaver.
            let isLastSpot = slot == DrawerCapsulePreviewMetrics.limit + appSlots - 1
            let delay = isLastSpot ? lastFillDelay : fillDelay
            return smoothstep((t - delay) / (1 - delay))
        default:
            return t
        }
    }

    /// Share of a turn over which the hover lift folds away after leaving a page, and comes back
    /// before reaching the next one.
    static let hoverSettle: CGFloat = 0.08

    /// How much of the hover lift may show at `position`: all of it at rest, none mid-turn. A
    /// function of the position, not of time, so hover never resizes an icon while it travels.
    static func hoverCalm(position: CGFloat) -> CGFloat {
        let t = position - position.rounded(.down)
        return 1 - smoothstep(min(t, 1 - t) / hoverSettle)
    }

    /// Whether app `index` answers to `hoveredCell`, judged on the page nearest to what is on
    /// screen at `position` (not the resting page, which jumps ahead when a wheel turn starts). An
    /// app cell lights its own app; the expand cell — or a cell with no app — lights the mini grid.
    static func isHovered(index: Int, position: CGFloat, hoveredCell: Int?, memberCount: Int) -> Bool {
        guard let hoveredCell else { return false }
        typealias M = DrawerCapsulePreviewMetrics
        let page = clampedPage(Int(position.rounded()), pageCount: pageCount(memberCount: memberCount))
        let slot = index - page * M.appSlots
        let appsOnPage = min(M.appSlots, max(0, memberCount - page * M.appSlots))
        if (0..<M.appSlots).contains(slot) { return hoveredCell == slot }
        return (M.appSlots..<M.limit).contains(slot) && hoveredCell >= appsOnPage
    }

    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    static func pageCount(memberCount: Int) -> Int {
        let slots = DrawerCapsulePreviewMetrics.appSlots
        return max(1, (memberCount + slots - 1) / slots)
    }

    static func apps(page: Int, members: [String]) -> [String] {
        let start = page * DrawerCapsulePreviewMetrics.appSlots
        guard page >= 0, start < members.count else { return [] }
        return Array(members[start...].prefix(DrawerCapsulePreviewMetrics.appSlots))
    }

    static func more(page: Int, members: [String]) -> [String] {
        let start = (page + 1) * DrawerCapsulePreviewMetrics.appSlots
        guard page >= 0, start < members.count else { return [] }
        return Array(members[start...].prefix(DrawerCapsulePreviewMetrics.miniLimit))
    }

    static func clampedPage(_ page: Int, pageCount: Int) -> Int {
        min(max(0, page), max(0, pageCount - 1))
    }

    /// One gesture turns at most one page. The resting page is clamped first: the member list
    /// may have shrunk under it, and the turn starts from the page actually shown.
    static func settledPage(page: Int, drag: CGFloat, pageCount: Int) -> Int {
        let shown = clampedPage(page, pageCount: pageCount)
        guard abs(drag) > turnThreshold else { return shown }
        return clampedPage(shown + (drag > 0 ? 1 : -1), pageCount: pageCount)
    }

    /// The page a click lands on: the one nearest to what is on screen. While a trackpad gesture
    /// holds the capsule on the next page, that page — not the resting one — takes the click.
    static func hitPage(page: Int, drag: CGFloat, pageCount: Int) -> Int {
        let shown = clampedPage(page, pageCount: pageCount)
        return clampedPage(shown + Int(drag.rounded()), pageCount: pageCount)
    }

    /// Position in pages, with the travel beyond either end damped.
    static func displayedPosition(page: Int, drag: CGFloat, pageCount: Int) -> CGFloat {
        let last = CGFloat(max(0, pageCount - 1))
        let raw = CGFloat(page) + drag
        if raw < 0 { return raw * rubberBand }
        if raw > last { return last + (raw - last) * rubberBand }
        return raw
    }

    /// The pose of app `index` while the capsule is pulled past its last page, nil otherwise.
    /// Nothing arrives there and the apps hold their size for `leaveHold`, longer than the rubber
    /// band reaches, so the plain pose would not move at all. Instead each of the last page's apps
    /// takes exactly the pose the same cell shows when pulled as far before the first page: at
    /// both ends the apps gather together towards the mini grid. Not a mirror — mirrored, the apps
    /// spread apart towards the rim, which reads as a different gesture.
    static func endPullPose(index: Int, position: CGFloat, memberCount: Int) -> IconPose? {
        let last = pageCount(memberCount: memberCount) - 1
        let over = position - CGFloat(last)
        let slot = index - last * DrawerCapsulePreviewMetrics.appSlots
        guard over > 0, (0..<DrawerCapsulePreviewMetrics.appSlots).contains(slot) else { return nil }
        return pose(index: slot, position: -over)
    }
}

struct PanelScreenGeometry: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat

    /// The drawer's top cap still follows top system UI. On displays without a notch,
    /// this usually tracks visibleFrame.maxY and may change when the menu bar auto-hides.
    /// On notched displays, the safe-area cap can take over once the menu bar is hidden,
    /// so the same known edge can be smaller there than on external displays.
    var topUsableY: CGFloat {
        min(visibleFrame.maxY, frame.maxY - safeAreaTop)
    }
}

enum PanelGeometry {
    static let windowTitleTooltipScreenMargin: CGFloat = 8
    /// 阴影留白**不随档位缩放**：气泡的阴影 token 本身是固定的，跟着缩会动到定稿的观感。
    /// 视图侧和这里必须用同一个值（视图 `.padding(它)`，这里再减回去）。
    static let windowTitleTooltipShadowPadding: CGFloat = 8

    /// The bar and the drawer capsule to its right are centered as one group, the way the native
    /// Dock centers its whole row. Centering the bar alone leaves the set (gap + capsule) / 2 right
    /// of center; at the width cap the group keeps `outerMargin` on both sides.
    static func dockTargetFrame(
        contentWidth: CGFloat,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGRect {
        let trailing = metrics.capsuleGap + metrics.capsuleWidth
        let maxWidth = screen.frame.width - 2 * metrics.outerMargin - trailing
        let panelWidth = max(min(contentWidth, maxWidth), metrics.minimumDockWidth)
        let x = screen.frame.minX + (screen.frame.width - (panelWidth + trailing)) / 2
        return CGRect(
            x: x - metrics.shadowPadding,
            y: screen.frame.minY + metrics.bottomGap - metrics.shadowPadding,
            width: panelWidth + metrics.shadowPadding * 2,
            height: metrics.windowHeight
        )
    }

    static func capsuleTargetFrame(
        forDock dockFrame: CGRect,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGRect {
        let rawX = dockFrame.maxX - metrics.shadowPadding + metrics.capsuleGap
        let rawY = dockFrame.minY + metrics.shadowPadding + (metrics.panelHeight - metrics.capsuleWidth) / 2
        let clampedX = min(max(rawX, screen.frame.minX), screen.frame.maxX - metrics.capsuleWidth)
        let clampedY = min(max(rawY, screen.frame.minY), screen.frame.maxY - metrics.capsuleWidth)
        return CGRect(
            x: clampedX - metrics.shadowPadding,
            y: clampedY - metrics.shadowPadding,
            width: metrics.capsuleWidth + metrics.shadowPadding * 2,
            height: metrics.capsuleWidth + metrics.shadowPadding * 2
        )
    }

    // MARK: Folder / shelf / Trash popup
    //
    // The popup window is the plate plus a transparent `StackPopupMetrics.panelMargin` border on
    // every side (the glass's own shadow lives there) and the arrow strip under the plate. These
    // functions speak in window frames; `folderPopupPlateFrame` converts back to what is visible.

    /// Bottom edge of the popup window for an anchor: the arrow's tip floats `tipGap` above the
    /// chip, the transparent border hangs below the tip.
    static func folderPopupDesiredBottomY(anchorVisibleRect: CGRect) -> CGFloat {
        anchorVisibleRect.maxY + StackPopupMetrics.tipGap - StackPopupMetrics.panelMargin
    }

    /// How close the popup's **plate** may come to the screen's left and right edges.
    struct StackPopupScreenMargins: Equatable {
        var left: CGFloat
        var right: CGFloat

        func interpolated(to other: StackPopupScreenMargins, progress: CGFloat) -> StackPopupScreenMargins {
            .init(left: left + (other.left - left) * progress, right: right + (other.right - right) * progress)
        }
    }

    /// Margins for an anchor: `screenMargin` (native), giving way down to `minimumScreenMargin`
    /// on the side the anchor hugs, so the arrow — never closer than `arrowInset` to the plate's
    /// side — still lands on that chip. They belong to the **anchor**, never to an interpolated
    /// centre: the switch tween interpolates them (`folderPopupScreenMargins(holding:)` → these).
    static func folderPopupScreenMargins(anchorCenterX: CGFloat, on screen: PanelScreenGeometry) -> StackPopupScreenMargins {
        let m = StackPopupMetrics.self
        func margin(_ distanceToEdge: CGFloat) -> CGFloat {
            min(m.screenMargin, max(m.minimumScreenMargin, distanceToEdge - m.arrowInset))
        }
        return .init(left: margin(anchorCenterX - screen.frame.minX), right: margin(screen.frame.maxX - anchorCenterX))
    }

    /// The margins a popup window already on screen satisfies — a tween's starting point, so its
    /// first tick reproduces the current frame instead of re-clamping it.
    static func folderPopupScreenMargins(holding panelFrame: CGRect, on screen: PanelScreenGeometry) -> StackPopupScreenMargins {
        let m = StackPopupMetrics.self
        let plate = folderPopupPlateFrame(panelFrame: panelFrame)
        func margin(_ distanceToEdge: CGFloat) -> CGFloat { min(m.screenMargin, max(0, distanceToEdge)) }
        return .init(left: margin(plate.minX - screen.frame.minX), right: margin(screen.frame.maxX - plate.maxX))
    }

    /// The single truth for anchoring and clamping: first frame, re-anchoring and every tick of
    /// the switch tween go through it. The plate stays `margins` inside the screen; the window
    /// itself may overhang the screen by its transparent border.
    static func folderPopupClampedOrigin(
        desiredCenterX: CGFloat,
        desiredBottomY: CGFloat,
        size: CGSize,
        margins: StackPopupScreenMargins,
        on screen: PanelScreenGeometry
    ) -> CGPoint {
        let m = StackPopupMetrics.self
        let minX = screen.frame.minX + margins.left - m.panelMargin
        let maxX = screen.frame.maxX - margins.right + m.panelMargin - size.width
        // Wider than the screen allows: centre it rather than favour one edge.
        let x = maxX >= minX ? min(max(desiredCenterX - size.width / 2, minX), maxX) : screen.frame.midX - size.width / 2
        return CGPoint(x: x, y: desiredBottomY)
    }

    /// The popup window's frame: centred on the anchor chip, clamped into the screen, growing
    /// upward only and capped where the plate would cross `topUsableY`. `size` is the whole window.
    static func folderPopupTargetFrame(
        anchorVisibleRect: CGRect,
        size: CGSize,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGRect {
        let origin = folderPopupClampedOrigin(
            desiredCenterX: anchorVisibleRect.midX,
            desiredBottomY: folderPopupDesiredBottomY(anchorVisibleRect: anchorVisibleRect),
            size: size,
            margins: folderPopupScreenMargins(anchorCenterX: anchorVisibleRect.midX, on: screen),
            on: screen)
        let top = screen.topUsableY + StackPopupMetrics.panelMargin
        let height = min(size.height, max(metrics.minimumDrawerExtent, top - origin.y))
        return CGRect(x: origin.x, y: origin.y, width: size.width, height: height)
    }

    /// Height the plate may take above the anchor, leaving `stackPopupTopGap` under the menu bar;
    /// feeds `StackGridLayout.limits`, which takes a status line's height off it when there is one.
    static func stackPopupAvailablePlateHeight(anchorVisibleRect: CGRect, on screen: PanelScreenGeometry) -> CGFloat {
        let plateBottom = anchorVisibleRect.maxY + StackPopupMetrics.tipGap + StackPopupMetrics.arrowHeight
        return screen.topUsableY - stackPopupTopGap - plateBottom
    }

    static let stackPopupTopGap: CGFloat = 8

    /// The visible part of the popup window — plate plus arrow strip. Hit tests use this, never
    /// the window frame: the border is 40pt of nothing.
    static func folderPopupPlateFrame(panelFrame: CGRect) -> CGRect {
        panelFrame.insetBy(dx: StackPopupMetrics.panelMargin, dy: StackPopupMetrics.panelMargin)
    }

    /// Window-title tooltip panel frame. The panel includes transparent padding for its SwiftUI
    /// shadow, while the visible bubble stays 8pt above the pill and 8pt inside the screen edges.
    /// `tipGap` = 气泡**尖端**到锚点顶边的距离，随档位缩放，由调用方从
    /// `WindowTitleTooltipStyle.tipGap` 传进来——系数只在样式那一处算，这里不再算第二遍。
    static func windowTitleTooltipTargetFrame(
        anchorVisibleRect: CGRect,
        size: CGSize,
        tipGap: CGFloat,
        on screen: PanelScreenGeometry
    ) -> CGRect {
        let inset = windowTitleTooltipShadowPadding
        let visibleWidth = max(0, size.width - 2 * inset)
        let visibleHeight = max(0, size.height - 2 * inset)
        let minVisibleX = screen.frame.minX + windowTitleTooltipScreenMargin
        let maxVisibleX = screen.frame.maxX - windowTitleTooltipScreenMargin - visibleWidth
        let desiredVisibleX = anchorVisibleRect.midX - visibleWidth / 2
        let visibleX = min(max(desiredVisibleX, minVisibleX), maxVisibleX)
        let desiredVisibleY = anchorVisibleRect.maxY + tipGap
        let maxVisibleY = screen.topUsableY - visibleHeight
        let visibleY = min(desiredVisibleY, maxVisibleY)

        return CGRect(
            x: visibleX - inset,
            y: visibleY - inset,
            width: size.width,
            height: size.height
        )
    }

    /// The drawer is a stack popup anchored on its capsule: this is the capsule's visible rect,
    /// the anchor every `folderPopup…` function takes.
    static func drawerAnchorVisibleRect(
        forCapsule capsuleFrame: CGRect,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGRect {
        capsuleFrame.insetBy(dx: metrics.shadowPadding, dy: metrics.shadowPadding)
    }

    static func drawerTargetFrame(
        forCapsule capsuleFrame: CGRect,
        size: CGSize,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> CGRect {
        folderPopupTargetFrame(
            anchorVisibleRect: drawerAnchorVisibleRect(forCapsule: capsuleFrame, metrics: metrics),
            size: size, on: screen, metrics: metrics)
    }

    /// Rows and columns the drawer's grid may take above its capsule on this screen.
    static func drawerGridLimits(
        forCapsule capsuleFrame: CGRect,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .tungstenEdge
    ) -> StackGridLayout.Limits {
        StackGridLayout.drawerLimits(
            screenSize: screen.frame.size,
            availablePlateHeight: stackPopupAvailablePlateHeight(
                anchorVisibleRect: drawerAnchorVisibleRect(forCapsule: capsuleFrame, metrics: metrics), on: screen))
    }

    /// The pointer's lower bound for "inside the drawer body" while dragging a strip chip: the
    /// capsule's top, i.e. the bar's top edge. `plate` is `folderPopupPlateFrame` of the drawer.
    static func drawerBodyFloorY(plate: CGRect) -> CGFloat {
        plate.minY - StackPopupMetrics.tipGap
    }
}
