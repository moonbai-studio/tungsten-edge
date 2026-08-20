import CoreGraphics
import XCTest

final class PanelGeometryTests: XCTestCase {
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

        let drawer = layout(on: screen, drawerSize: CGSize(width: 210, height: 900)).drawer

        XCTAssertEqual(drawer.maxY, 920)
    }

    func testDrawerTopCapUsesSafeAreaWhenNotchIsLowerThanVisibleFrame() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32
        )
        XCTAssertEqual(screen.topUsableY, 950)

        let drawer = layout(on: screen, drawerSize: CGSize(width: 210, height: 900)).drawer

        XCTAssertEqual(drawer.maxY, 950)
    }

    func testMaxDrawerContentHeightUsesSameTopCapAsDrawerFrame() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32
        )
        let frames = layout(on: screen)

        let maxHeight = PanelGeometry.maxDrawerContentHeight(forCapsule: frames.capsule, on: screen, metrics: metrics)

        XCTAssertEqual(maxHeight, (screen.topUsableY - frames.drawer.minY) - 2 * metrics.shadowPadding)
    }

    // MARK: - 文件夹弹窗

    func testFolderPopupAnchorsAboveAnchorRectAndCenters() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let anchor = CGRect(x: 700, y: 8, width: 44, height: 52)

        let popup = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: anchor, size: CGSize(width: 400, height: 300), on: screen, metrics: metrics
        )

        XCTAssertEqual(popup.minY, anchor.maxY + 8)
        XCTAssertEqual(popup.midX, anchor.midX)
        XCTAssertEqual(popup.height, 300)
    }

    func testFolderPopupClampsHorizontallyIntoScreen() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let leftAnchor = CGRect(x: 4, y: 8, width: 44, height: 52)
        let rightAnchor = CGRect(x: 1500, y: 8, width: 44, height: 52)
        let size = CGSize(width: 400, height: 300)

        let left = PanelGeometry.folderPopupTargetFrame(anchorVisibleRect: leftAnchor, size: size, on: screen, metrics: metrics)
        let right = PanelGeometry.folderPopupTargetFrame(anchorVisibleRect: rightAnchor, size: size, on: screen, metrics: metrics)

        XCTAssertEqual(left.minX, screen.frame.minX)
        XCTAssertEqual(right.maxX, screen.frame.maxX)
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
        let maxContent = PanelGeometry.maxFolderPopupContentHeight(anchorVisibleRect: anchor, on: screen, metrics: metrics)

        XCTAssertEqual(popup.maxY, screen.topUsableY)
        XCTAssertEqual(maxContent, (screen.topUsableY - (anchor.maxY + 8)) - 2 * metrics.shadowPadding)
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

    // MARK: - 尺寸档位

    func testDockSizeTiersKeepIntegerHeightsAndDerivedWindowHeight() {
        let expected: [DockSize: CGFloat] = [.small: 46, .medium: 54, .large: 62, .extraLarge: 70]
        for size in DockSize.allCases {
            let m = size.metrics
            XCTAssertEqual(m.panelHeight, expected[size], "\(size) 面板高度")
            XCTAssertEqual(m.panelHeight.rounded(), m.panelHeight, "档位高度必须是整数，否则圆角和图标落在半像素上")
            // 这层关系以前只写在注释里，改高度时最容易漏掉窗口高度。
            XCTAssertEqual(m.windowHeight, m.panelHeight + 2 * m.shadowPadding)
            XCTAssertEqual(m.shadowPadding, 20, "阴影边距不随档位缩放——阴影 token 是冻结的")
            XCTAssertEqual(m.capsuleWidth, m.panelHeight, "胶囊是正方形，边长跟面板高度")
        }
    }

    /// 中档是四档的基准（`scale == 1`），逐字段锁死。
    ///
    /// **2026-08-16 由 52 改成 54，对齐原生 macOS 26 Dock**（owner 拍板；@2x 截图实测
    /// 原生条高 108px = 54pt）。此前这里锁的是「逐字节等于 2026-07-30 之前的历史字面值」，
    /// 那条冻结契约已被这次改判推翻 —— 不要按旧值把它改回去。
    /// 与之配套的是图标 36→40（`ChipHoverVisual.bareIconSize`）与卡高 52→54
    /// （`ChipPillMetrics.chipHeight`），三者必须同进同退。
    func testMediumTierMatchesTheNativeDockBaseline() {
        XCTAssertEqual(DockSize.medium.scale, 1.0)
        XCTAssertEqual(DockSize.medium.metrics, PanelLayoutMetrics(
            panelHeight: 54, shadowPadding: 20, windowHeight: 94,
            bottomGap: 8, outerMargin: 12, capsuleWidth: 54, capsuleGap: 8,
            minimumDockWidth: 120, minimumDrawerExtent: 120
        ))
    }

    /// 卡片必须撑满条高、上下不留空隙——任务条空白区右键的判定就建立在「没有垂直空隙」上。
    func testChipHeightFillsTheMediumPanelExactly() {
        XCTAssertEqual(ChipPillMetrics.chipHeight, DockSize.medium.panelHeight)
    }

    func testCapsuleGridContentFitsEveryTier() {
        // 九宫格 3 列：3×icon + 2×spacing + 2×padding 必须塞进胶囊宽度。
        // 中档 3×9 + 2×4 + 2×6 = 47pt，小档胶囊只有 44pt——不跟着缩就会被裁。
        for size in DockSize.allCases {
            let s = size.scale
            let content = (3 * 9 + 2 * 4 + 2 * 6) * s
            XCTAssertLessThanOrEqual(content, size.metrics.capsuleWidth, "\(size) 胶囊内容超宽")
        }
    }

    func testEveryTierLaysOutBottomAnchoredAndCentered() {
        let screen = screen(frame: CGRect(x: -1512, y: -400, width: 1512, height: 982))
        for size in DockSize.allCases {
            let m = size.metrics
            let dock = PanelGeometry.dockTargetFrame(contentWidth: 620, on: screen, metrics: m)
            let capsule = PanelGeometry.capsuleTargetFrame(forDock: dock, on: screen, metrics: m)
            // 非零原点屏幕也必须贴物理底边，且面板高度跟着档位走。
            XCTAssertEqual(dock.minY, screen.frame.minY + m.bottomGap - m.shadowPadding, "\(size) 底边")
            XCTAssertEqual(dock.height, m.windowHeight, "\(size) 面板高度")
            XCTAssertEqual(dock.midX, screen.frame.midX, accuracy: 0.5, "\(size) 居中")
            // 胶囊与任务条垂直居中对齐（两者等高时中心重合）。
            XCTAssertEqual(capsule.midY, dock.midY, accuracy: 0.5, "\(size) 胶囊垂直对齐")
        }
    }

    func testLiftTargetTracksTierHeight() {
        // 最大化避让的 taskbarTop = 屏幕底 + bottomGap + panelHeight，换档必须跟着变，
        // 否则被抬起的窗口底边和新任务条对不上。
        let screenMinY: CGFloat = -400
        var tops: [CGFloat] = []
        for size in DockSize.allCases {
            let m = size.metrics
            tops.append(screenMinY + m.bottomGap + m.panelHeight)
        }
        XCTAssertEqual(tops, [-346, -338, -330, -322], "中档 54 起、四档相差 8pt")
        XCTAssertEqual(Set(tops).count, DockSize.allCases.count, "四档的抬升目标必须两两不同")
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
