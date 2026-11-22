import CoreGraphics
import XCTest

final class PanelGeometryTests: XCTestCase {
    func testWindowLabelWidthClampsRoundsAndRejectsNonFiniteValues() {
        for (raw, expected): (CGFloat, CGFloat) in [(-1, 40), (39.9, 40), (40, 40),
            (139.49, 139), (139.5, 140), (240, 240), (240.8, 240), (999, 240),
            (.nan, 140), (.infinity, 140), (-.infinity, 140)] {
            XCTAssertEqual(WindowLabelWidth(clamping: raw).points, expected)
        }
        XCTAssertEqual(ChipLabelSizing.default.width.points, 140)
        XCTAssertFalse(ChipLabelSizing.default.isFixed)
    }

    func testWindowLabelWidthScalesWithoutPrematureRounding() {
        for height in stride(from: 32, through: 120, by: 1) {
            let scale = DockPanelHeight(clamping: CGFloat(height)).scale
            for width: CGFloat in [40, 140, 240] {
                XCTAssertEqual(WindowLabelWidth(clamping: width).scaled(by: scale), width * scale)
            }
        }
    }

    private let metrics = PanelLayoutMetrics.tungstenEdge

    func testBottomDockVisibleFrameChangeDoesNotMoveBottomPanelsVertically() {
        let hidden = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let shown = screen(
            frame: hidden.frame,
            visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 869)
        )

        let hiddenLayout = layout(on: hidden)
        let shownLayout = layout(on: shown)

        XCTAssertEqual(hiddenLayout.dock.minY, shownLayout.dock.minY)
        XCTAssertEqual(hiddenLayout.capsule.minY, shownLayout.capsule.minY)
        XCTAssertEqual(hiddenLayout.drawer.minY, shownLayout.drawer.minY)
    }

    func testSideDockVisibleFrameChangeDoesNotMoveOrResizeBottomPanelsHorizontally() {
        let hidden = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let leftDockShown = screen(
            frame: hidden.frame,
            visibleFrame: CGRect(x: 90, y: 0, width: 1422, height: 949)
        )
        let rightDockShown = screen(
            frame: hidden.frame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1422, height: 949)
        )

        let hiddenLayout = layout(on: hidden)
        for candidate in [layout(on: leftDockShown), layout(on: rightDockShown)] {
            XCTAssertEqual(candidate.dock.minX, hiddenLayout.dock.minX)
            XCTAssertEqual(candidate.dock.width, hiddenLayout.dock.width)
            XCTAssertEqual(candidate.capsule.minX, hiddenLayout.capsule.minX)
            XCTAssertEqual(candidate.drawer.minX, hiddenLayout.drawer.minX)
        }
    }

    func testBottomAnchoringUsesNonZeroScreenMinY() {
        let upperScreen = screen(frame: CGRect(x: -488, y: 982, width: 2560, height: 1440))
        let lowerScreen = screen(frame: CGRect(x: -2408, y: -640, width: 1920, height: 1080))

        XCTAssertEqual(layout(on: upperScreen).dock.minY, upperScreen.frame.minY + metrics.bottomGap - metrics.shadowPadding)
        XCTAssertEqual(layout(on: lowerScreen).dock.minY, lowerScreen.frame.minY + metrics.bottomGap - metrics.shadowPadding)
    }

    func testDockFrameKeepsOriginalBottomCoordinate() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))

        let dock = PanelGeometry.dockTargetFrame(contentWidth: 620, on: screen, metrics: metrics)

        XCTAssertEqual(dock.minY, -12, "bottomGap 8 − shadowPadding 20，与档位高度无关")
        XCTAssertEqual(dock.height, 94, "中档 54 + 2×20")
    }

    func testDrawerTopCapUsesVisibleFrameWhenMenuBarIsLowerThanSafeAreaCap() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 920),
            safeAreaTop: 32
        )
        XCTAssertEqual(screen.topUsableY, 920)

        let drawer = layout(on: screen, drawerSize: CGSize(width: 210, height: 1100)).drawer

        XCTAssertEqual(PanelGeometry.folderPopupPlateFrame(panelFrame: drawer).maxY, 920)
    }

    func testDrawerTopCapUsesSafeAreaWhenNotchIsLowerThanVisibleFrame() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32
        )
        XCTAssertEqual(screen.topUsableY, 950)

        let drawer = layout(on: screen, drawerSize: CGSize(width: 210, height: 1100)).drawer

        XCTAssertEqual(PanelGeometry.folderPopupPlateFrame(panelFrame: drawer).maxY, 950)
    }

    func testDrawerIsAStackPopupAnchoredOnItsCapsule() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32
        )
        let size = StackPopupMetrics.panelSize(
            forPlate: StackPlateMetrics.drawer.plateSize(columns: 3, rows: 2, hasNote: false, scrolls: false))
        let frames = layout(on: screen, drawerSize: size)
        let anchor = PanelGeometry.drawerAnchorVisibleRect(forCapsule: frames.capsule, metrics: metrics)
        let plate = PanelGeometry.folderPopupPlateFrame(panelFrame: frames.drawer)

        // Arrow tip `tipGap` above the capsule; the pointer's floor for "inside the drawer body"
        // is the capsule's top, never inside the bar.
        XCTAssertEqual(plate.minY, anchor.maxY + StackPopupMetrics.tipGap)
        XCTAssertEqual(PanelGeometry.drawerBodyFloorY(plate: plate), anchor.maxY)
        // The capsule sits at the bar's right end: the plate stays on screen and its arrow can
        // still reach the capsule's centre.
        XCTAssertLessThanOrEqual(plate.maxX, screen.frame.maxX - StackPopupMetrics.minimumScreenMargin)
        XCTAssertGreaterThanOrEqual(anchor.midX, plate.minX + StackPopupMetrics.arrowInset)
        XCTAssertLessThanOrEqual(anchor.midX, plate.maxX - StackPopupMetrics.arrowInset)

        // The grid's row limit is what fits between the capsule and the top cap.
        let limits = PanelGeometry.drawerGridLimits(forCapsule: frames.capsule, on: screen, metrics: metrics)
        let tallest = StackPlateMetrics.drawer.plateSize(columns: 1, rows: limits.fitRows, hasNote: false,
                                                         scrolls: false).height
        XCTAssertLessThanOrEqual(plate.minY + StackPopupMetrics.arrowHeight + tallest, screen.topUsableY)
    }

    // MARK: - 文件夹弹窗

    func testFolderPopupAnchorsAboveAnchorRectAndCenters() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let anchor = CGRect(x: 700, y: 8, width: 44, height: 52)

        let popup = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: anchor, size: CGSize(width: 400, height: 300), on: screen, metrics: metrics
        )
        let plate = PanelGeometry.folderPopupPlateFrame(panelFrame: popup)

        // The arrow's tip (bottom of the visible part) floats 3pt above the chip.
        XCTAssertEqual(plate.minY, anchor.maxY + StackPopupMetrics.tipGap)
        XCTAssertEqual(popup.midX, anchor.midX)
        XCTAssertEqual(popup.height, 300)
    }

    func testFolderPopupKeepsThePlateInsideTheScreenMargin() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        // Near the edges, but far enough in that the margin does not have to give way.
        let leftAnchor = CGRect(x: 100, y: 8, width: 44, height: 52)
        let rightAnchor = CGRect(x: 1368, y: 8, width: 44, height: 52)
        let size = CGSize(width: 400, height: 300)

        let left = PanelGeometry.folderPopupTargetFrame(anchorVisibleRect: leftAnchor, size: size, on: screen, metrics: metrics)
        let right = PanelGeometry.folderPopupTargetFrame(anchorVisibleRect: rightAnchor, size: size, on: screen, metrics: metrics)

        // The window overhangs the screen by its transparent border; the plate never does.
        XCTAssertEqual(PanelGeometry.folderPopupPlateFrame(panelFrame: left).minX,
                       screen.frame.minX + StackPopupMetrics.screenMargin)
        XCTAssertEqual(PanelGeometry.folderPopupPlateFrame(panelFrame: right).maxX,
                       screen.frame.maxX - StackPopupMetrics.screenMargin)
    }

    /// Clamp and arrow together: wherever the chip is, the arrow's tip ends up on its centre —
    /// the plate gives up its screen margin before the arrow gives up the chip.
    func testFolderPopupArrowLandsOnTheAnchorCenter() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let size = StackPopupMetrics.panelSize(forPlate: StackPopupMetrics.plateSize(columns: 7, rows: 4, hasNote: false))
        // Mid-screen, the nearest centre the arrow can still reach (minimum margin + arrow inset),
        // and the same on the right. Nearer than `reach` the arrow is off by `reach − distance`:
        // 7pt for the first chip of a full-width bar at the default height, 18pt at the smallest.
        let reach = StackPopupMetrics.minimumScreenMargin + StackPopupMetrics.arrowInset
        for center in [756, 200, 81, reach, 1512 - reach, 1431, 1300] as [CGFloat] {
            let anchor = CGRect(x: center - 20, y: 8, width: 40, height: 47)
            let popup = PanelGeometry.folderPopupTargetFrame(anchorVisibleRect: anchor, size: size, on: screen, metrics: metrics)
            let plate = PanelGeometry.folderPopupPlateFrame(panelFrame: popup)
            let arrow = StackPopupOutline.clampedArrowCenterX(plate.width / 2 + (anchor.midX - popup.midX), plateWidth: plate.width)
            XCTAssertEqual(plate.minX + arrow, anchor.midX, accuracy: 0.001, "anchor centre \(center)")
            XCTAssertGreaterThanOrEqual(plate.minX, screen.frame.minX + StackPopupMetrics.minimumScreenMargin)
            XCTAssertLessThanOrEqual(plate.maxX, screen.frame.maxX - StackPopupMetrics.minimumScreenMargin)
        }
        // Closer than that — whatever put the chip there: a full-width bar (39), one just short of
        // the width cap at the smallest height (33), the smallest bar at full width (28) — the
        // plate stops at the minimum margin and the arrow is off by exactly `reach − distance`.
        for distance in [39, 33, 28] as [CGFloat] {
            for center in [distance, 1512 - distance] {
                let anchor = CGRect(x: center - 12, y: 8, width: 24, height: 28)
                let popup = PanelGeometry.folderPopupTargetFrame(anchorVisibleRect: anchor, size: size, on: screen, metrics: metrics)
                let plate = PanelGeometry.folderPopupPlateFrame(panelFrame: popup)
                let arrow = StackPopupOutline.clampedArrowCenterX(plate.width / 2 + (anchor.midX - popup.midX), plateWidth: plate.width)
                XCTAssertEqual(abs(plate.minX + arrow - anchor.midX), reach - distance, accuracy: 0.001, "distance \(distance)")
                XCTAssertEqual(min(plate.minX, 1512 - plate.maxX), StackPopupMetrics.minimumScreenMargin, accuracy: 0.001)
            }
        }
    }

    func testFolderPopupHeightCappedByTopUsableY() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 920),
            safeAreaTop: 0
        )
        let anchor = CGRect(x: 700, y: 8, width: 44, height: 52)

        let popup = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: anchor, size: CGSize(width: 400, height: 2000), on: screen, metrics: metrics
        )

        XCTAssertEqual(PanelGeometry.folderPopupPlateFrame(panelFrame: popup).maxY, screen.topUsableY)
    }

    func testStackPopupRowsFitUnderTheMenuBar() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1352, height: 878),
            visibleFrame: CGRect(x: 0, y: 0, width: 1352, height: 845),
            safeAreaTop: 0
        )
        let anchor = CGRect(x: 700, y: 8, width: 44, height: 47)

        let available = PanelGeometry.stackPopupAvailablePlateHeight(anchorVisibleRect: anchor, on: screen)
        let limits = StackGridLayout.limits(screenSize: screen.frame.size, availablePlateHeight: available)
        XCTAssertEqual(limits, .init(maxColumns: 7, nominalRows: 4, fitRows: 5, fitRowsWithNote: 5))
        // The tallest plate those limits allow — with and without a status line — clears the menu bar.
        for (rows, hasNote) in [(limits.fitRows, false), (limits.fitRowsWithNote, true)] {
            let plate = StackPopupMetrics.plateSize(columns: limits.maxColumns, rows: rows, hasNote: hasNote)
            let popup = PanelGeometry.folderPopupTargetFrame(
                anchorVisibleRect: anchor, size: StackPopupMetrics.panelSize(forPlate: plate), on: screen, metrics: metrics
            )
            XCTAssertEqual(popup.height, StackPopupMetrics.panelSize(forPlate: plate).height)
            XCTAssertLessThanOrEqual(PanelGeometry.folderPopupPlateFrame(panelFrame: popup).maxY,
                                     screen.topUsableY - PanelGeometry.stackPopupTopGap)
        }
    }

    /// The switch tween feeds the clamp an interpolated centre and interpolated margins. Its first
    /// tick must reproduce the frame on screen and its last the target — also when the popup it
    /// starts from hugs the screen edge with a margin that gave way.
    func testFolderPopupSwitchTweenStartsOnTheCurrentFrameAndEndsOnTheTarget() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let size = StackPopupMetrics.panelSize(forPlate: StackPopupMetrics.plateSize(columns: 3, rows: 1, hasNote: false))
        func tick(from start: CGRect, to anchor: CGRect, progress p: CGFloat) -> CGPoint {
            let startMargins = PanelGeometry.folderPopupScreenMargins(holding: start, on: screen)
            let endMargins = PanelGeometry.folderPopupScreenMargins(anchorCenterX: anchor.midX, on: screen)
            let endBottom = PanelGeometry.folderPopupDesiredBottomY(anchorVisibleRect: anchor)
            return PanelGeometry.folderPopupClampedOrigin(
                desiredCenterX: start.midX + (anchor.midX - start.midX) * p,
                desiredBottomY: start.minY + (endBottom - start.minY) * p,
                size: size, margins: startMargins.interpolated(to: endMargins, progress: p), on: screen)
        }
        // Edge chip → its neighbour, neighbour → mid-screen, mid-screen → the far edge, and a
        // re-switch from a frame caught mid-flight.
        let anchors = [39, 81, 700, 1484].map { CGRect(x: CGFloat($0) - 20, y: 8, width: 40, height: 47) }
        var starts = anchors.map { PanelGeometry.folderPopupTargetFrame(anchorVisibleRect: $0, size: size, on: screen, metrics: metrics) }
        starts.append(CGRect(origin: tick(from: starts[0], to: anchors[2], progress: 0.4), size: size))
        for start in starts {
            for anchor in anchors {
                let target = PanelGeometry.folderPopupTargetFrame(anchorVisibleRect: anchor, size: size, on: screen, metrics: metrics)
                let first = tick(from: start, to: anchor, progress: 0)
                let last = tick(from: start, to: anchor, progress: 1)
                XCTAssertEqual(first.x, start.minX, accuracy: 0.001)
                XCTAssertEqual(first.y, start.minY, accuracy: 0.001)
                XCTAssertEqual(last.x, target.minX, accuracy: 0.001)
                XCTAssertEqual(last.y, target.minY, accuracy: 0.001)
            }
        }
    }

    // MARK: - Window title tooltip

    func testWindowTitleTooltipAnchorsVisibleBubbleAbovePillAndCenters() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let anchor = CGRect(x: 700, y: 20, width: 160, height: 34)
        let frame = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: anchor, size: CGSize(width: 300, height: 60),
            tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        )
        let bubble = frame.insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                                   dy: PanelGeometry.windowTitleTooltipShadowPadding)

        XCTAssertEqual(bubble.minY, anchor.maxY + WindowTitleTooltipStyle.native.tipGap)
        XCTAssertEqual(bubble.midX, anchor.midX)
    }

    func testWindowTitleTooltipClampsVisibleBubbleInsideNonZeroScreenEdges() {
        let screen = screen(frame: CGRect(x: -1512, y: 982, width: 1512, height: 982))
        let size = CGSize(width: 300, height: 60)
        let left = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: CGRect(x: screen.frame.minX, y: 1000, width: 40, height: 30),
            size: size, tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        ).insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                  dy: PanelGeometry.windowTitleTooltipShadowPadding)
        let right = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: CGRect(x: screen.frame.maxX - 40, y: 1000, width: 40, height: 30),
            size: size, tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        ).insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                  dy: PanelGeometry.windowTitleTooltipShadowPadding)

        XCTAssertEqual(left.minX, screen.frame.minX + PanelGeometry.windowTitleTooltipScreenMargin)
        XCTAssertEqual(right.maxX, screen.frame.maxX - PanelGeometry.windowTitleTooltipScreenMargin)
    }

    func testWindowTitleTooltipRespectsTopUsableY() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 920),
            safeAreaTop: 0
        )
        let frame = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: CGRect(x: 700, y: 900, width: 100, height: 30),
            size: CGSize(width: 300, height: 60),
            tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        )
        let bubble = frame.insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                                   dy: PanelGeometry.windowTitleTooltipShadowPadding)

        XCTAssertEqual(bubble.maxY, screen.topUsableY)
    }

    // MARK: - 条高（连续）

    private let sampleHeights: [DockPanelHeight] = [32, 40, 47, 54, 63, 80, 120].map { DockPanelHeight(clamping: $0) }

    func testClampingRoundsAndClampsToTheRange() {
        XCTAssertEqual(DockPanelHeight(clamping: 31.4).points, 32)
        XCTAssertEqual(DockPanelHeight(clamping: 40.6).points, 41)
        XCTAssertEqual(DockPanelHeight(clamping: 120.4).points, 120)
        XCTAssertEqual(DockPanelHeight(clamping: 200).points, 120)
        XCTAssertEqual(DockPanelHeight(clamping: 0).points, 32)
        XCTAssertEqual(DockPanelHeight(clamping: .nan).points, 54)
        XCTAssertEqual(DockPanelHeight(clamping: .infinity).points, 54)
        // 32…120 mirrors the reach of the Dock's own Size slider; both ends stay reachable by
        // the settings slider and the grip, and every legacy tier value lands strictly inside.
        XCTAssertEqual(DockPanelHeight.minimum, 32)
        XCTAssertEqual(DockPanelHeight.maximum, 120)
    }

    func testLegacyTierMigrationTable() {
        // The four raw strings are the frozen contract of the tier releases' UserDefaults key.
        XCTAssertEqual(DockPanelHeight.migratingLegacyTier(rawValue: "small")?.points, 46)
        XCTAssertEqual(DockPanelHeight.migratingLegacyTier(rawValue: "medium")?.points, 54)
        XCTAssertEqual(DockPanelHeight.migratingLegacyTier(rawValue: "large")?.points, 62)
        XCTAssertEqual(DockPanelHeight.migratingLegacyTier(rawValue: "extraLarge")?.points, 70)
        XCTAssertNil(DockPanelHeight.migratingLegacyTier(rawValue: "gigantic"))
    }

    func testEveryHeightKeepsIntegerPointsAndDerivedWindowHeight() {
        for height in sampleHeights {
            let m = height.metrics
            XCTAssertEqual(m.panelHeight, height.points)
            XCTAssertEqual(m.panelHeight.rounded(), m.panelHeight, "条高必须是整数，否则圆角和图标落在半像素上")
            // 这层关系以前只写在注释里，改高度时最容易漏掉窗口高度。
            XCTAssertEqual(m.windowHeight, m.panelHeight + 2 * m.shadowPadding)
            XCTAssertEqual(m.shadowPadding, 20, "阴影边距不随条高缩放——阴影 token 是冻结的")
            XCTAssertEqual(m.capsuleWidth, m.panelHeight, "胶囊是正方形，边长跟面板高度")
        }
    }

    /// 54pt 是基准（`scale == 1`），逐字段锁死。
    ///
    /// **2026-08-16 由 52 改成 54，对齐原生 macOS 26 Dock**（owner 拍板；@2x 截图实测
    /// 原生条高 108px = 54pt）。与之配套的是图标 36→40（`ChipHoverVisual.bareIconSize`）
    /// 与卡高 52→54（`ChipPillMetrics.chipHeight`），三者必须同进同退。
    func testNativeHeightMatchesTheNativeDockBaseline() {
        XCTAssertEqual(DockPanelHeight.native.points, 54)
        XCTAssertEqual(DockPanelHeight.native.scale, 1.0)
        XCTAssertEqual(DockPanelHeight.default, DockPanelHeight.native)
        XCTAssertEqual(DockPanelHeight.native.metrics, PanelLayoutMetrics(
            panelHeight: 54, shadowPadding: 20, windowHeight: 94,
            bottomGap: 8, outerMargin: 12, capsuleWidth: 54, capsuleGap: 8,
            minimumDockWidth: 120, minimumDrawerExtent: 120
        ))
        XCTAssertEqual(PanelLayoutMetrics.tungstenEdge, DockPanelHeight.native.metrics)
    }

    /// 卡片必须撑满条高、上下不留空隙——任务条空白区右键的判定就建立在「没有垂直空隙」上。
    func testChipHeightFillsTheNativePanelExactly() {
        XCTAssertEqual(ChipPillMetrics.chipHeight, DockPanelHeight.native.points)
    }

    func testCapsuleGridContentFitsEveryHeight() {
        // 2 × 2 preview: columns × icon + spacing + 2 × padding must fit the capsule at every height.
        XCTAssertEqual(DrawerCapsulePreviewMetrics.appSlots, 3)
        XCTAssertEqual(DrawerCapsulePreviewMetrics.limit, 7)
        XCTAssertLessThan(DrawerCapsulePreviewMetrics.miniGridWidth, DrawerCapsulePreviewMetrics.iconSize)
        for height in sampleHeights {
            let content = DrawerCapsulePreviewMetrics.contentWidth * height.scale
            XCTAssertLessThanOrEqual(content, height.metrics.capsuleWidth, "\(height.points)pt 胶囊内容超宽")
        }
    }

    func testCapsulePagingSplitsMembersIntoThreesWithTheNextFourAsPreview() {
        let members = (0..<8).map { "app\($0)" }
        XCTAssertEqual(DrawerCapsulePaging.pageCount(memberCount: 0), 1)
        XCTAssertEqual(DrawerCapsulePaging.pageCount(memberCount: 3), 1)
        XCTAssertEqual(DrawerCapsulePaging.pageCount(memberCount: 4), 2)
        XCTAssertEqual(DrawerCapsulePaging.pageCount(memberCount: 8), 3)
        XCTAssertEqual(DrawerCapsulePaging.apps(page: 0, members: members), ["app0", "app1", "app2"])
        XCTAssertEqual(DrawerCapsulePaging.more(page: 0, members: members), ["app3", "app4", "app5", "app6"])
        XCTAssertEqual(DrawerCapsulePaging.apps(page: 2, members: members), ["app6", "app7"])
        XCTAssertEqual(DrawerCapsulePaging.more(page: 2, members: members), [])
        XCTAssertEqual(DrawerCapsulePaging.apps(page: 3, members: members), [])
    }

    func testCapsulePagingTurnsAtMostOnePageAndStaysInRange() {
        XCTAssertEqual(DrawerCapsulePaging.settledPage(page: 1, drag: 0.1, pageCount: 3), 1)
        XCTAssertEqual(DrawerCapsulePaging.settledPage(page: 1, drag: 0.9, pageCount: 3), 2)
        XCTAssertEqual(DrawerCapsulePaging.settledPage(page: 1, drag: -0.2, pageCount: 3), 0)
        XCTAssertEqual(DrawerCapsulePaging.settledPage(page: 2, drag: 0.9, pageCount: 3), 2)
        XCTAssertEqual(DrawerCapsulePaging.settledPage(page: 0, drag: -0.9, pageCount: 3), 0)
        // A member list that shrank under a resting page clamps back into range.
        XCTAssertEqual(DrawerCapsulePaging.settledPage(page: 5, drag: 0, pageCount: 2), 1)
        // ...and a turn from there starts at the page actually shown, not the stale one.
        XCTAssertEqual(DrawerCapsulePaging.settledPage(page: 5, drag: -0.5, pageCount: 2), 0)
    }

    func testCapsuleClickLandsOnThePageNearestToWhatIsShown() {
        XCTAssertEqual(DrawerCapsulePaging.hitPage(page: 1, drag: 0, pageCount: 3), 1)
        XCTAssertEqual(DrawerCapsulePaging.hitPage(page: 1, drag: 0.4, pageCount: 3), 1)
        XCTAssertEqual(DrawerCapsulePaging.hitPage(page: 1, drag: 0.9, pageCount: 3), 2)
        XCTAssertEqual(DrawerCapsulePaging.hitPage(page: 1, drag: -0.9, pageCount: 3), 0)
        XCTAssertEqual(DrawerCapsulePaging.hitPage(page: 2, drag: 0.9, pageCount: 3), 2)
        XCTAssertEqual(DrawerCapsulePaging.hitPage(page: 5, drag: -0.9, pageCount: 2), 0)
    }

    func testCapsulePagingDampsTravelPastEitherEnd() {
        XCTAssertEqual(DrawerCapsulePaging.displayedPosition(page: 1, drag: 0.5, pageCount: 3), 1.5)
        XCTAssertEqual(DrawerCapsulePaging.displayedPosition(page: 0, drag: -1, pageCount: 3),
                       -DrawerCapsulePaging.rubberBand)
        XCTAssertEqual(DrawerCapsulePaging.displayedPosition(page: 2, drag: 1, pageCount: 3),
                       2 + DrawerCapsulePaging.rubberBand)
    }

    func testCapsuleRestPosesFillTheGridAndStayInsideTheCapsule() {
        typealias M = DrawerCapsulePreviewMetrics
        let half = M.contentWidth / 2
        for slot in 0..<M.limit {
            let pose = DrawerCapsulePaging.restPose(slot: slot)
            XCTAssertEqual(pose.size, slot < M.appSlots ? M.iconSize : M.miniIconSize)
            XCTAssertLessThanOrEqual(abs(pose.x) + pose.size / 2, half - M.gridPadding + 1e-9, "slot \(slot)")
            XCTAssertLessThanOrEqual(abs(pose.y) + pose.size / 2, half - M.gridPadding + 1e-9, "slot \(slot)")
        }
        // Top-leading app cell and the first mini icon, relative to the capsule's centre.
        XCTAssertEqual(DrawerCapsulePaging.restPose(slot: 0), .init(x: -10.5, y: -10.5, size: 21))
        XCTAssertEqual(DrawerCapsulePaging.restPose(slot: 3), .init(x: 6.25, y: 6.25, size: 8.5))
        // Neighbouring pages rest at zero size.
        for slot in [-6, -3, -1, 7, 9, 12] {
            XCTAssertEqual(DrawerCapsulePaging.restPose(slot: slot).size, 0, "slot \(slot)")
        }
    }

    func testCapsuleTurnCarriesTheMiniIconsOntoTheAppCells() {
        // App 3 is the first mini icon on page 0 and the top-leading app on page 1.
        XCTAssertEqual(DrawerCapsulePaging.pose(index: 3, position: 0), DrawerCapsulePaging.restPose(slot: 3))
        XCTAssertEqual(DrawerCapsulePaging.pose(index: 3, position: 1), DrawerCapsulePaging.restPose(slot: 0))
        // App 4 heads for the top-trailing cell, which runs on the turn's own clock; mid-turn its
        // path bows towards the capsule's inside by the full bend.
        let mid = DrawerCapsulePaging.pose(index: 4, position: 0.5)
        XCTAssertEqual(mid.x, 12.625 + DrawerCapsulePaging.cellBend[1].x, accuracy: 1e-9)
        XCTAssertEqual(mid.y, -2.125, accuracy: 1e-9)
        XCTAssertEqual(mid.size, 14.75, accuracy: 1e-9)
        // The app it replaces holds its size for a moment, then shrinks in place: mid-turn it is
        // still about as large as the arriving icon. The last mini icon moves up to the first spot.
        XCTAssertEqual(DrawerCapsulePaging.pose(index: 1, position: DrawerCapsulePaging.leaveHold),
                       DrawerCapsulePaging.restPose(slot: 1))
        let leaving = DrawerCapsulePaging.pose(index: 1, position: 0.5)
        XCTAssertEqual(leaving.x, 10.5, accuracy: 1e-9)
        XCTAssertEqual(leaving.y, -10.5, accuracy: 1e-9)
        XCTAssertEqual(leaving.size, 14.35546875, accuracy: 1e-9)
        // The three cells hand over in lockstep, measured along the axis each path does not bow on.
        func travelled(_ index: Int, along axis: KeyPath<DrawerCapsulePaging.IconPose, CGFloat>) -> CGFloat {
            let from = DrawerCapsulePaging.restPose(slot: index)
            let to = DrawerCapsulePaging.restPose(slot: index - DrawerCapsulePreviewMetrics.appSlots)
            return (DrawerCapsulePaging.pose(index: index, position: 0.5)[keyPath: axis] - from[keyPath: axis])
                / (to[keyPath: axis] - from[keyPath: axis])
        }
        XCTAssertEqual(travelled(3, along: \.y), 0.5, accuracy: 1e-9)
        XCTAssertEqual(travelled(4, along: \.y), 0.5, accuracy: 1e-9)
        XCTAssertEqual(travelled(5, along: \.x), 0.5, accuracy: 1e-9)
        for cell in [0, 2] {
            XCTAssertEqual(DrawerCapsulePaging.pose(index: cell, position: 0.5).size, leaving.size, accuracy: 1e-9)
        }
        // The bottom-leading path bows up, towards the capsule's inside.
        let low = DrawerCapsulePaging.pose(index: 5, position: 0.5)
        XCTAssertEqual(low.y, 14.75 - 4.25 * 0.5 + DrawerCapsulePaging.cellBend[2].y, accuracy: 1e-9)
        for index in 0..<6 {
            XCTAssertEqual(DrawerCapsulePaging.pose(index: index, position: 1),
                           DrawerCapsulePaging.restPose(slot: index - DrawerCapsulePreviewMetrics.appSlots))
        }
        XCTAssertEqual(DrawerCapsulePaging.pose(index: 0, position: 0.999).size, 0, accuracy: 0.01)
        XCTAssertEqual(DrawerCapsulePaging.pose(index: 0, position: 1).size, 0)
        XCTAssertEqual(DrawerCapsulePaging.pose(index: 6, position: 1), DrawerCapsulePaging.restPose(slot: 3))
        XCTAssertEqual(DrawerCapsulePaging.pose(index: 6, position: 0.5).size, DrawerCapsulePreviewMetrics.miniIconSize)
        // New mini icons wait until their spot has emptied; the one taking the spot the fourth mini
        // icon leaves waits longest. All of them end at full mini size.
        XCTAssertEqual(DrawerCapsulePaging.pose(index: 7, position: DrawerCapsulePaging.fillDelay).size, 0)
        XCTAssertEqual(DrawerCapsulePaging.pose(index: 9, position: DrawerCapsulePaging.lastFillDelay).size, 0)
        XCTAssertGreaterThan(DrawerCapsulePaging.pose(index: 7, position: 0.5).size,
                             DrawerCapsulePaging.pose(index: 9, position: 0.5).size)
        XCTAssertGreaterThan(DrawerCapsulePaging.pose(index: 9, position: 0.5).size, 0)
        for index in 7...9 {
            XCTAssertEqual(DrawerCapsulePaging.pose(index: index, position: 1),
                           DrawerCapsulePaging.restPose(slot: index - DrawerCapsulePreviewMetrics.appSlots))
        }
        // Overscroll before the first page pulls the apps a little towards the mini grid.
        let pulled = DrawerCapsulePaging.pose(index: 0, position: -0.1)
        XCTAssertLessThan(pulled.size, DrawerCapsulePreviewMetrics.iconSize)
        XCTAssertGreaterThan(pulled.x, -10.5)
    }

    func testCapsulePulledPastTheLastPageAnswersLikeThePullBeforeTheFirst() {
        typealias P = DrawerCapsulePaging
        // Seven apps: pages 0, 1 and 2, the last holding app 6 alone.
        let fullPull = P.displayedPosition(page: 2, drag: 1, pageCount: 3)
        let over = fullPull - 2
        // The held apps alone would not move at all within the rubber band's reach.
        XCTAssertEqual(P.pose(index: 6, position: fullPull), P.restPose(slot: 0))
        // Pulled past the end, app 6 does exactly what app 0 does pulled as far before the first
        // page: it gathers towards the mini grid (down and to the trailing side) and shrinks.
        XCTAssertEqual(P.endPullPose(index: 6, position: fullPull, memberCount: 7), P.pose(index: 0, position: -over))
        let end = P.pose(index: 0, position: -over)
        let rest = P.restPose(slot: 0)
        XCTAssertLessThan(end.size, rest.size)
        XCTAssertGreaterThan(end.x, rest.x)
        XCTAssertGreaterThan(end.y, rest.y)
        // At rest, mid-list and at the first page there is no end pull.
        XCTAssertNil(P.endPullPose(index: 6, position: 2, memberCount: 7))
        XCTAssertNil(P.endPullPose(index: 3, position: 1.1, memberCount: 7))
        XCTAssertNil(P.endPullPose(index: 0, position: -0.1, memberCount: 7))
        XCTAssertNil(P.endPullPose(index: 3, position: fullPull, memberCount: 7))
    }

    func testCapsuleHoverLiftFoldsAwayMidTurnAndFollowsTheScreen() {
        typealias P = DrawerCapsulePaging
        // Full lift at rest, none once the turn is a little way off either page, in both directions.
        XCTAssertEqual(P.hoverCalm(position: 0), 1)
        XCTAssertEqual(P.hoverCalm(position: 2), 1)
        XCTAssertEqual(P.hoverCalm(position: 0.5), 0)
        XCTAssertEqual(P.hoverCalm(position: P.hoverSettle), 0, accuracy: 1e-9)
        XCTAssertEqual(P.hoverCalm(position: 1 - P.hoverSettle), 0, accuracy: 1e-9)
        XCTAssertEqual(P.hoverCalm(position: P.hoverSettle / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(P.hoverCalm(position: -P.hoverSettle / 2), 0.5, accuracy: 1e-9)

        // Pointer on the top-leading app cell: the app there owns hover until the turn passes halfway.
        XCTAssertTrue(P.isHovered(index: 0, position: 0.4, hoveredCell: 0, memberCount: 10))
        XCTAssertFalse(P.isHovered(index: 3, position: 0.4, hoveredCell: 0, memberCount: 10))
        XCTAssertTrue(P.isHovered(index: 3, position: 0.6, hoveredCell: 0, memberCount: 10))
        XCTAssertFalse(P.isHovered(index: 0, position: 0.6, hoveredCell: 0, memberCount: 10))
        // Pointer on the expand cell: the whole mini grid, and nothing else.
        XCTAssertEqual((0..<10).filter { P.isHovered(index: $0, position: 0, hoveredCell: 3, memberCount: 10) },
                       [3, 4, 5, 6])
        // On a last page with one app, an app-less cell is an expand cell; the app keeps its own.
        XCTAssertTrue(P.isHovered(index: 3, position: 1, hoveredCell: 0, memberCount: 4))
        XCTAssertFalse(P.isHovered(index: 3, position: 1, hoveredCell: 1, memberCount: 4))
        XCTAssertFalse(P.isHovered(index: 0, position: 0, hoveredCell: nil, memberCount: 4))
    }

    func testEveryHeightLaysOutBottomAnchoredAndCentered() {
        let screen = screen(frame: CGRect(x: -1512, y: -400, width: 1512, height: 982))
        for height in sampleHeights {
            let m = height.metrics
            let dock = PanelGeometry.dockTargetFrame(contentWidth: 620, on: screen, metrics: m)
            let capsule = PanelGeometry.capsuleTargetFrame(forDock: dock, on: screen, metrics: m)
            // 非零原点屏幕也必须贴物理底边，且面板高度跟着条高走。
            XCTAssertEqual(dock.minY, screen.frame.minY + m.bottomGap - m.shadowPadding, "\(height.points)pt 底边")
            XCTAssertEqual(dock.height, m.windowHeight, "\(height.points)pt 面板高度")
            // Bar + drawer capsule are centered as one group, not the bar alone.
            let groupMinX = dock.minX + m.shadowPadding
            let groupMaxX = capsule.maxX - m.shadowPadding
            XCTAssertEqual((groupMinX + groupMaxX) / 2, screen.frame.midX, accuracy: 0.5, "\(height.points)pt 整组居中")
            // 胶囊与任务条垂直居中对齐（两者等高时中心重合）。
            XCTAssertEqual(capsule.midY, dock.midY, accuracy: 0.5, "\(height.points)pt 胶囊垂直对齐")
        }
    }

    func testFullBarKeepsOuterMarginOnBothSidesOfTheGroup() {
        let screen = screen(frame: CGRect(x: -1512, y: -400, width: 1512, height: 982))
        for height in sampleHeights {
            let m = height.metrics
            let dock = PanelGeometry.dockTargetFrame(contentWidth: 10_000, on: screen, metrics: m)
            let capsule = PanelGeometry.capsuleTargetFrame(forDock: dock, on: screen, metrics: m)
            let barVisible = dock.insetBy(dx: m.shadowPadding, dy: m.shadowPadding)
            let capsuleVisible = capsule.insetBy(dx: m.shadowPadding, dy: m.shadowPadding)
            XCTAssertEqual(barVisible.minX - screen.frame.minX, m.outerMargin, accuracy: 0.5, "\(height.points)pt 左边距")
            XCTAssertEqual(screen.frame.maxX - capsuleVisible.maxX, m.outerMargin, accuracy: 0.5, "\(height.points)pt 右边距")
            XCTAssertEqual(capsuleVisible.minX - barVisible.maxX, m.capsuleGap, accuracy: 0.5, "\(height.points)pt 胶囊间距")
        }
    }

    func testLiftTargetTracksBarHeight() {
        // 最大化避让的 taskbarTop = 屏幕底 + bottomGap + panelHeight，条高一变必须跟着变，
        // 否则被抬起的窗口底边和新任务条对不上。
        let screenMinY: CGFloat = -400
        let tops = [40, 54, 80].map { DockPanelHeight(clamping: $0).metrics }.map { screenMinY + $0.bottomGap + $0.panelHeight }
        XCTAssertEqual(tops, [-352, -338, -312])
        XCTAssertEqual(tops, tops.sorted(), "抬升目标随条高单调上升")
    }

    private func layout(
        on screen: PanelScreenGeometry,
        contentWidth: CGFloat = 620,
        drawerSize: CGSize = CGSize(width: 210, height: 260)
    ) -> (dock: CGRect, capsule: CGRect, drawer: CGRect) {
        let dock = PanelGeometry.dockTargetFrame(contentWidth: contentWidth, on: screen, metrics: metrics)
        let capsule = PanelGeometry.capsuleTargetFrame(forDock: dock, on: screen, metrics: metrics)
        let drawer = PanelGeometry.drawerTargetFrame(forCapsule: capsule, size: drawerSize, on: screen, metrics: metrics)
        return (dock, capsule, drawer)
    }

    private func screen(frame: CGRect, visibleFrame: CGRect? = nil, safeAreaTop: CGFloat = 0) -> PanelScreenGeometry {
        PanelScreenGeometry(frame: frame, visibleFrame: visibleFrame ?? frame, safeAreaTop: safeAreaTop)
    }
}
