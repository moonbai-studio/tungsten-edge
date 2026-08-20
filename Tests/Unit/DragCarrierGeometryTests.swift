import XCTest
@testable import macos_dock_cc_v2

/// 载体图层的坐标换算。
///
/// 这里同时有三套坐标系（屏幕左下原点 / 载体面板内左下原点 / `"strip"` 空间左上原点 y 向下），
/// 混起来的后果是图标朝屏幕另一头飞——而那种错误在肉眼验收里只会被说成「动画怪怪的」，
/// 没人能一眼说出是 y 翻反了还是原点没减。所以钉死它。
final class DragCarrierGeometryTests: XCTestCase {
    /// 主屏 1512×982，原点在 (0,0)。
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // MARK: - 载体面板一次只铺一块屏

    /// 双屏：副屏在主屏正上方。指针在哪块屏，面板就铺哪块——**不能铺并集**：
    /// 「显示器具有单独的空间」下一个窗口只属于一块屏，越界部分不绘制（2026-08-19 内置屏「消失」的成因）。
    func testPanelFollowsTheScreenContainingThePoint() {
        let external = CGRect(x: -504, y: 982, width: 2560, height: 1440)
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: CGPoint(x: 100, y: 100),
                                                       in: [main, external]), main)
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: CGPoint(x: 100, y: 1500),
                                                       in: [main, external]), external)
    }

    /// 点不在任何屏上（切屏瞬间的边缘）→ 退回第一块，不给 `.zero`。
    func testPointOutsideEveryScreenFallsBackToTheFirst() {
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: CGPoint(x: -9999, y: -9999),
                                                       in: [main]), main)
    }

    /// 没有屏幕（面板还没建起来）→ `.zero`，调用方一律按「不摆位、不飞」处理。
    func testNoScreensIsZero() {
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: .zero, in: []), .zero)
    }

    // MARK: - 像素对齐（落地一帧不能糊）

    /// 2x 屏：52pt 宽的图层，中心 100.3 → 左边 74.3pt = 148.6px → 取整 149px = 74.5pt → 中心 100.5。
    func testPixelAlignedSnapsTheOriginToDevicePixels() {
        let center = DragCarrierGeometry.pixelAligned(center: CGPoint(x: 100.3, y: 40.2),
                                                      size: CGSize(width: 52, height: 66),
                                                      scale: 2)
        XCTAssertEqual(center.x, 100.5, accuracy: 0.0001)
        XCTAssertEqual(center.y, 40, accuracy: 0.0001)     // 7.2pt = 14.4px → 14px = 7pt → 中心 40
    }

    /// 已经对齐的点原样返回；scale ≤ 0 不动。
    func testPixelAlignedIsIdempotent() {
        let aligned = DragCarrierGeometry.pixelAligned(center: CGPoint(x: 100.5, y: 40),
                                                       size: CGSize(width: 52, height: 66), scale: 2)
        XCTAssertEqual(aligned, CGPoint(x: 100.5, y: 40))
        XCTAssertEqual(DragCarrierGeometry.pixelAligned(center: CGPoint(x: 1.234, y: 5.678),
                                                        size: CGSize(width: 10, height: 10), scale: 0),
                       CGPoint(x: 1.234, y: 5.678))
    }

    // MARK: - 屏幕 → 面板内（两者都是左下原点，只差一个平移）

    func testScreenPointSubtractsThePanelOrigin() {
        let panel = CGRect(x: -504, y: 0, width: 2016, height: 982)
        let point = DragCarrierGeometry.panelPoint(screen: CGPoint(x: 100, y: 200), panelFrame: panel)
        XCTAssertEqual(point, CGPoint(x: 604, y: 200))
    }

    /// 起拖时载体就摆在卡槽中心。任务条上一张 40×54 的卡，可视底边在 y=8。
    func testSlotCentreIsWhereTheCarrierStarts() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let centre = DragCarrierGeometry.panelCenter(ofScreenRect: slot, panelFrame: main)
        XCTAssertEqual(centre, CGPoint(x: 720, y: 35))
    }

    // MARK: - 抓取偏移的纵向反号（最容易写岔的一处）

    /// `grabOffset` 是在 `"strip"` / `"drawer"` 那种 **y 向下**的空间里量的
    /// （`frame.midY − startLocation.y`），而图层坐标 y 向上，所以纵向必须反号。
    /// 反错的话，从卡的上半部按下去，副本会跳到光标下方而不是上方。
    func testGrabOffsetVerticalIsInverted() {
        // 从卡中心偏上 10pt 处按下 → y 向下的空间里 grab.height = +10。
        let grab = CGSize(width: 6, height: 10)
        let centre = DragCarrierGeometry.carriedCenter(pointer: CGPoint(x: 400, y: 300),
                                                       grabOffset: grab, panelFrame: main)
        XCTAssertEqual(centre.x, 406)
        XCTAssertEqual(centre.y, 290)   // 不是 310
    }

    func testCarriedCentreAlsoSubtractsThePanelOrigin() {
        let panel = CGRect(x: -504, y: 982, width: 2560, height: 1440)
        let centre = DragCarrierGeometry.carriedCenter(pointer: CGPoint(x: 0, y: 1000),
                                                       grabOffset: .zero, panelFrame: panel)
        XCTAssertEqual(centre, CGPoint(x: 504, y: 18))
    }

    /// 重抓：从载体此刻的中心反推抓取偏移，再喂回 `carriedCenter` 必须回到同一个点
    ///（飞行途中按住图标接着拖，图标不能跳）。外接屏负原点也要闭合。
    func testGrabOffsetIsTheInverseOfCarriedCenter() {
        for panel in [main, CGRect(x: -504, y: 982, width: 2560, height: 1440)] {
            let pointer = CGPoint(x: 123.4, y: 1000.6)
            let centre = CGPoint(x: 700.25, y: 40.5)   // 面板内
            let grab = DragCarrierGeometry.grabOffset(pointer: pointer, carriedCenter: centre, panelFrame: panel)
            let back = DragCarrierGeometry.carriedCenter(pointer: pointer, grabOffset: grab, panelFrame: panel)
            XCTAssertEqual(back.x, centre.x, accuracy: 0.0001)
            XCTAssertEqual(back.y, centre.y, accuracy: 0.0001)
        }
        // 方向：指针在图标中心右下方 6/10pt → 和 `testGrabOffsetVerticalIsInverted` 同一组数。
        let grab = DragCarrierGeometry.grabOffset(pointer: CGPoint(x: 400, y: 300),
                                                  carriedCenter: CGPoint(x: 406, y: 290), panelFrame: main)
        XCTAssertEqual(grab, CGSize(width: 6, height: 10))
    }

    // MARK: - 与 DragLandingPlan 的接缝（左上原点 y 向下 ↔ 左下原点 y 向上）

    /// `DragLandingPlan.flight` 的终点是「面板内左上原点、y 向下」，摆位要翻过来。
    func testTopLeftPointFlipsIntoLayerCoordinates() {
        let flipped = DragCarrierGeometry.panelPoint(fromTopLeft: CGPoint(x: 720, y: 947),
                                                     panelFrame: main)
        XCTAssertEqual(flipped, CGPoint(x: 720, y: 35))
    }

    /// **往返必须闭合**：卡槽中心 → 左上原点系（喂 `DragLandingPlan`）→ 翻回图层坐标，
    /// 要回到同一个点。这两步分别写在两处，接缝对不上就是落地差几个 pt 的那种抖。
    func testRoundTripThroughTheLandingPlanCoordinateSystemIsClosed() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let layerCentre = DragCarrierGeometry.panelCenter(ofScreenRect: slot, panelFrame: main)
        // DragLandingPlan 用的就是这个换算算终点。
        let topLeft = CGPoint(x: slot.midX - main.minX, y: main.maxY - slot.midY)
        XCTAssertEqual(DragCarrierGeometry.panelPoint(fromTopLeft: topLeft, panelFrame: main),
                       layerCentre)
    }

    /// 飞行**起点**同样走左上原点系，且必须和跟手时的位置是同一个物理点。
    func testFlightStartMatchesTheLiveCarriedPosition() {
        let pointer = CGPoint(x: 400, y: 300)
        let grab = CGSize(width: 6, height: 10)
        let live = DragCarrierGeometry.carriedCenter(pointer: pointer, grabOffset: grab, panelFrame: main)
        let start = DragCarrierGeometry.topLeftCarriedCenter(pointer: pointer, grabOffset: grab,
                                                             panelFrame: main)
        XCTAssertEqual(DragCarrierGeometry.panelPoint(fromTopLeft: start, panelFrame: main), live)
    }

    /// 外接屏（面板原点为负）下上面那条也要成立——原点没减是这类 bug 的另一半。
    func testFlightStartMatchesTheLiveCarriedPositionOnAnExternalScreen() {
        let panel = CGRect(x: -504, y: 0, width: 2560, height: 1440)
        let pointer = CGPoint(x: -100, y: 900)
        let grab = CGSize(width: -4, height: 7)
        let live = DragCarrierGeometry.carriedCenter(pointer: pointer, grabOffset: grab, panelFrame: panel)
        let start = DragCarrierGeometry.topLeftCarriedCenter(pointer: pointer, grabOffset: grab,
                                                             panelFrame: panel)
        XCTAssertEqual(DragCarrierGeometry.panelPoint(fromTopLeft: start, panelFrame: panel), live)
    }

    // MARK: - 起拖姿态（悬停 × 按压的合成）

    /// 中档 54pt 高的卡、安静档悬停 1.10（底锚）+ 按压 0.93（中心）：整体 1.023、重心上移 2.51pt。
    /// 这组数就是 owner 2026-08-19 报「上下残影」时卡槽的真实形态——载体不按它摆就对不齐。
    func testPickUpPoseCombinesBottomAnchoredHoverWithCentredPress() {
        let pose = DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: 0.93, hoverScale: 1.10)
        XCTAssertEqual(pose.scale, 1.023, accuracy: 0.0005)
        XCTAssertEqual(pose.dy, 2.511, accuracy: 0.001)
    }

    /// 只按压、没悬停（标准档）：纯中心缩放，不上移。
    func testPickUpPosePressOnlyDoesNotShift() {
        let pose = DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: 0.93, hoverScale: nil)
        XCTAssertEqual(pose.scale, 0.93, accuracy: 0.0005)
        XCTAssertEqual(pose.dy, 0)
    }

    /// 只悬停、没按压（文件夹 chip：1.12 底锚放大、无按压反馈）。
    func testPickUpPoseHoverOnlyLiftsHalfTheGrowth() {
        let pose = DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: nil, hoverScale: 1.12)
        XCTAssertEqual(pose.scale, 1.12, accuracy: 0.0005)
        XCTAssertEqual(pose.dy, 0.12 * 54 / 2, accuracy: 0.001)
    }

    /// 什么都没有 = 静息。
    func testPickUpPoseRestingIsIdentity() {
        XCTAssertEqual(DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: nil, hoverScale: nil),
                       .resting)
    }
}
