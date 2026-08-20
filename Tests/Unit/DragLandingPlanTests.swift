import XCTest
@testable import macos_dock_cc_v2

/// 松手归位飞行的纯判定。这里钉的核心是**坐标换算**：屏幕是左下原点、载体面板是左上原点，
/// 两者搞混的话图标会朝屏幕另一头飞——而那种错误在肉眼验收里只会被说成「动画怪怪的」。
final class DragLandingPlanTests: XCTestCase {
    /// 主屏 1512×982，载体面板永远铺满整屏。
    private let carrier = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testAnchorCentreConvertsToCarrierPanelCoordinates() {
        // 任务条上一张 40×54 的卡，可视区底边在 y=8（屏幕左下原点）。
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let flight = DragLandingPlan.flight(from: CGPoint(x: 900, y: 400),
                                            fromScale: DragLandingPlan.carriedScale,
                                            anchorScreenRect: slot,
                                            carrierScreenFrame: carrier)
        // 中心 x = 720；y 要翻过来：982 − 35 = 947（面板内左上原点）。
        XCTAssertEqual(flight?.to.x, 720)
        XCTAssertEqual(flight?.to.y, 947)
    }

    /// 载体面板不在主屏原点时（外接屏），换算要减去面板自己的原点。
    func testCarrierOriginIsSubtracted() {
        let external = CGRect(x: -504, y: 982, width: 2560, height: 1440)
        let slot = CGRect(x: 0, y: 1000, width: 40, height: 54)
        let flight = DragLandingPlan.flight(from: .zero,
                                            fromScale: 1,
                                            anchorScreenRect: slot,
                                            carrierScreenFrame: external)
        XCTAssertEqual(flight?.to.x, 20 - (-504))
        XCTAssertEqual(flight?.to.y, (982 + 1440) - 1027)
    }

    /// 起点与起始缩放原样带出去：载体在投放区里是缩着的（0.82），飞行必须从那个尺寸开始，
    /// 否则松手一瞬间会先跳大再飞。
    func testStartStateIsCarriedThrough() {
        let flight = DragLandingPlan.flight(from: CGPoint(x: 123, y: 456),
                                            fromScale: DragLandingPlan.dropZoneScale,
                                            anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                            carrierScreenFrame: carrier)
        XCTAssertEqual(flight?.from, CGPoint(x: 123, y: 456))
        XCTAssertEqual(flight?.fromScale, DragLandingPlan.dropZoneScale)
    }

    /// 终点缩放恒为 1：落地那一刻必须和条上那张卡逐像素同尺寸，不然收载体时会闪一下。
    func testAlwaysLandsAtNativeScale() {
        for start in [DragLandingPlan.carriedScale, DragLandingPlan.dropZoneScale] {
            let flight = DragLandingPlan.flight(from: .zero, fromScale: start,
                                                anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                                carrierScreenFrame: carrier)
            XCTAssertEqual(flight?.toScale, 1.0)
        }
    }

    // MARK: - 不飞的情形（一律退回改造前的瞬时收尾，零风险）

    /// 拿不到落点 → 不飞。转正进任务条那一支就是这种：松手会解冻条宽、整条重新居中，
    /// 落点在飞行途中还会漂，与其飞歪不如不飞。
    func testNoAnchorMeansNoFlight() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: nil, carrierScreenFrame: carrier))
    }

    /// 还没量到的帧（`.zero` / 零宽高）不能当落点——那会让图标飞到屏幕左下角。
    func testUnmeasuredAnchorIsRejected() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: .zero, carrierScreenFrame: carrier))
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: CGRect(x: 10, y: 10, width: 0, height: 54),
                                            carrierScreenFrame: carrier))
    }

    /// 载体面板还没建起来（frame 为空）同理。
    func testEmptyCarrierFrameIsRejected() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                            carrierScreenFrame: .zero))
    }

    // MARK: - 时长按距离取（owner 2026-08-18：「没有原生的动画从容优雅」）

    /// 定长会让短距离显得急、长距离显得赶。距离越远飞得越久，但两端都有闸。
    func testDurationGrowsWithDistanceAndIsClampedAtBothEnds() {
        XCTAssertEqual(DragLandingPlan.duration(travel: 0), DragLandingPlan.minimumDuration)
        XCTAssertEqual(DragLandingPlan.duration(travel: DragLandingPlan.referenceTravel),
                       DragLandingPlan.maximumFlightDuration, accuracy: 0.0001)
        // 再远也不加了，否则跨屏那种超长距离会拖沓。
        XCTAssertEqual(DragLandingPlan.duration(travel: 5000),
                       DragLandingPlan.maximumFlightDuration, accuracy: 0.0001)
        // 负数（不该出现）也不能穿到下界以下。
        XCTAssertEqual(DragLandingPlan.duration(travel: -10), DragLandingPlan.minimumDuration)
    }

    /// 开根号而不是线性：**近距离要比线性更慷慨**，不然小归位一闪而过看不见。
    func testShortTravelIsMoreGenerousThanLinear() {
        let quarter = DragLandingPlan.referenceTravel / 4
        let linear = DragLandingPlan.minimumDuration
            + (DragLandingPlan.maximumFlightDuration - DragLandingPlan.minimumDuration) * 0.25
        XCTAssertGreaterThan(DragLandingPlan.duration(travel: quarter), linear)
    }

    /// 每一次飞行都自带时长，视图和计时器读的是同一个值——分开算过就会漂。
    func testFlightCarriesItsOwnDuration() {
        let near = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                          anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                          carrierScreenFrame: carrier)
        let far = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                         anchorScreenRect: CGRect(x: 1200, y: 8, width: 40, height: 54),
                                         carrierScreenFrame: carrier)
        XCTAssertNotNil(near?.duration)
        XCTAssertLessThan(near!.duration, far!.duration)
    }

    /// **只有亚像素的落点才不飞。** 位图载体之后，5pt 的「点击手抖」也照飞——副本不透明、
    /// 逐像素等于卡槽，飞回去只会比跳过去更好；原来 12pt 的闸把一半以上的条内落点变成了
    /// 瞬间跳到位（owner 2026-08-19：「短距离的飞行动画偏快」）。
    func testOnlySubPixelTravelSkipsTheFlight() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let centre = CGPoint(x: 720, y: 982 - 35)
        let subPixel = CGPoint(x: centre.x + 0.3, y: centre.y + 0.2)
        XCTAssertNil(DragLandingPlan.flight(from: subPixel, fromScale: 1,
                                            anchorScreenRect: slot, carrierScreenFrame: carrier))
        let jitter = CGPoint(x: centre.x + 4, y: centre.y + 3)
        XCTAssertNotNil(DragLandingPlan.flight(from: jitter, fromScale: 1,
                                               anchorScreenRect: slot, carrierScreenFrame: carrier))
    }

    /// 真的拖开了就照飞不误。
    func testTravelBeyondTheThresholdStillFlies() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let away = CGPoint(x: 720 + DragLandingPlan.minimumTravel + 6, y: 982 - 35)
        XCTAssertNotNil(DragLandingPlan.flight(from: away, fromScale: 1,
                                               anchorScreenRect: slot, carrierScreenFrame: carrier))
    }

    /// 阈值必须**小于**起拖门槛 8pt：每一次真起拖（≥ 8pt）松手都要有归位飞行，不许再为
    /// 「点击手抖」把它抬回两位数——那正是短距离落点瞬跳的来源。也不能是 0（亚像素别白飞）。
    func testThresholdOnlyBlocksSubPixelTravel() {
        XCTAssertGreaterThan(DragLandingPlan.minimumTravel, 0)
        XCTAssertLessThan(DragLandingPlan.minimumTravel, 8)
    }

    // MARK: - 曲线按距离取（owner 2026-08-19：「短距离的飞行动画偏快」）

    /// 两端锁死：短途 = `shortCurve`，长途 = 原来那条 (0.2, 0.9, 0.3, 1.0)——字面量写死，
    /// owner 认可过的长途手感谁也别顺手改。
    func testCurveEndsAreFrozen() {
        XCTAssertEqual(DragLandingPlan.curve(travel: 0), DragLandingPlan.shortCurve)
        let long = DragLandingCurve(c0x: 0.2, c0y: 0.9, c1x: 0.3, c1y: 1.0)
        XCTAssertEqual(DragLandingPlan.curve(travel: DragLandingPlan.referenceTravel), long)
        XCTAssertEqual(DragLandingPlan.curve(travel: 5000), long)
        XCTAssertEqual(DragLandingPlan.curve, long)
    }

    /// 近的更缓：短途曲线的 y 控制点都低于长途的（长途 17% 时间就走完 61%，短途不能那么抢）。
    func testShortCurveIsGentlerThanTheLongOne() {
        XCTAssertLessThan(DragLandingPlan.shortCurve.c0y, DragLandingPlan.curve.c0y)
        XCTAssertLessThanOrEqual(DragLandingPlan.shortCurve.c1y, DragLandingPlan.curve.c1y)
    }

    /// 中间连续过渡：每个控制点都落在两端之间，且和时长用同一个进度数。
    func testCurveInterpolatesBetweenTheEnds() {
        let mid = DragLandingPlan.curve(travel: DragLandingPlan.referenceTravel / 4)
        let f = DragLandingPlan.travelFactor(DragLandingPlan.referenceTravel / 4)
        XCTAssertEqual(f, 0.5, accuracy: 0.0001)
        func between(_ v: Double, _ a: Double, _ b: Double) -> Bool { v >= min(a, b) && v <= max(a, b) }
        XCTAssertTrue(between(mid.c0x, DragLandingPlan.shortCurve.c0x, DragLandingPlan.curve.c0x))
        XCTAssertTrue(between(mid.c0y, DragLandingPlan.shortCurve.c0y, DragLandingPlan.curve.c0y))
        XCTAssertTrue(between(mid.c1x, DragLandingPlan.shortCurve.c1x, DragLandingPlan.curve.c1x))
        XCTAssertTrue(between(mid.c1y, DragLandingPlan.shortCurve.c1y, DragLandingPlan.curve.c1y))
        XCTAssertEqual(mid.c0y, DragLandingPlan.shortCurve.c0y
                       + (DragLandingPlan.curve.c0y - DragLandingPlan.shortCurve.c0y) * f, accuracy: 0.0001)
    }

    /// 曲线求值（重抓时算图标此刻在哪）：两端为 0 / 1、单调、和手算的形状对得上
    ///（长途 17% 时间走完约 61%；短途 50% 时间走完约 77%）。
    func testCurveProgressMatchesTheBezier() {
        let long = DragLandingPlan.curve, short = DragLandingPlan.shortCurve
        XCTAssertEqual(long.progress(at: 0), 0)
        XCTAssertEqual(long.progress(at: 1), 1)
        XCTAssertEqual(long.progress(at: -1), 0)
        XCTAssertEqual(long.progress(at: 2), 1)
        XCTAssertEqual(long.progress(at: 0.17), 0.61, accuracy: 0.03)
        XCTAssertEqual(short.progress(at: 0.5), 0.77, accuracy: 0.02)
        var previous = 0.0
        for i in 1...100 {
            let v = long.progress(at: Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, previous - 1e-9)
            previous = v
        }
        XCTAssertGreaterThan(long.progress(at: 0.3), short.progress(at: 0.3), "长途更抢")
    }

    /// 每次飞行自带曲线，和 `duration` 一样——控制器读的必须是同一个值。
    func testFlightCarriesItsOwnCurve() {
        let near = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                          anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                          carrierScreenFrame: carrier)!
        let travel = hypot(near.to.x - near.from.x, near.to.y - near.from.y)
        XCTAssertEqual(near.curve, DragLandingPlan.curve(travel: travel))
        XCTAssertNotEqual(near.curve, DragLandingPlan.curve)   // 短途不是长途那条
    }

    // MARK: - 吸进胶囊（owner 2026-08-19：收纳后图标往任务条那头飘一段再消失）

    /// 松在胶囊上收纳：终点 = 胶囊中心、缩到 0.3、淡到 0、定时长——不是飞回卡槽。
    func testStashFlightShrinksAndFadesIntoTheTarget() {
        let capsule = CGRect(x: 1400, y: 8, width: 44, height: 54)
        let flight = DragLandingPlan.stashFlight(from: CGPoint(x: 1300, y: 900), fromScale: 0.82,
                                                 targetScreenRect: capsule, carrierScreenFrame: carrier)!
        XCTAssertEqual(flight.to, CGPoint(x: 1422, y: 982 - 35))
        XCTAssertEqual(flight.fromScale, 0.82)
        XCTAssertEqual(flight.toScale, DragLandingPlan.stashScale)
        XCTAssertEqual(flight.toOpacity, 0)
        XCTAssertEqual(flight.duration, DragLandingPlan.stashDuration)
        XCTAssertLessThan(DragLandingPlan.stashScale, 0.5, "得看出来是被吸进去")
        // 不知道胶囊在哪 → 不飞（瞬时收尾），绝不能退回「飞回卡槽」。
        XCTAssertNil(DragLandingPlan.stashFlight(from: .zero, fromScale: 1, targetScreenRect: nil,
                                                 carrierScreenFrame: carrier))
    }

    /// 常规归位飞行落地是不透明的。
    func testReturnFlightLandsOpaque() {
        let flight = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                            anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                            carrierScreenFrame: carrier)!
        XCTAssertEqual(flight.toOpacity, 1)
    }

    // MARK: - 中途纠偏的时间闸（owner 2026-08-18：落地有几率抖）

    /// 快到上限时**不许**再纠偏：那时候重新起飞一段必然被上限截断，
    /// 反而制造出要治的那一下跳。
    func testRetargetIsRefusedNearTheDeadline() {
        XCTAssertFalse(DragLandingPlan.allowsRetarget(remainingBeforeDeadline: 0))
        XCTAssertFalse(DragLandingPlan.allowsRetarget(
            remainingBeforeDeadline: DragLandingPlan.duration))
        XCTAssertFalse(DragLandingPlan.allowsRetarget(remainingBeforeDeadline: -1))
    }

    /// 时间还够就允许——纠偏本身是治「卡槽还在动、终点会漂」的手段，不能一刀切掉。
    func testRetargetIsAllowedWhileThereIsRoomForAWholeFlight() {
        XCTAssertTrue(DragLandingPlan.allowsRetarget(
            remainingBeforeDeadline: DragLandingPlan.maximumDuration))
    }

    /// 上限必须容得下至少一次完整的纠偏重飞，否则那个闸永远是关的、纠偏形同虚设。
    func testDeadlineLeavesRoomForAtLeastOneRetarget() {
        XCTAssertGreaterThan(DragLandingPlan.maximumDuration,
                             2 * (DragLandingPlan.duration + DragLandingPlan.settleMargin))
    }


    /// 抬起（从卡槽滑到指针下）要明显比归位飞行短：它是起拖的**接手**动作，
    /// 长了就变成「起拖要等一下」，反而是要治的那种迟滞。
    ///
    /// 闸原来写 `/ 3`，2026-08-19 归位从 0.60 收到 0.32 后放宽到 `/ 2`——**意图没变**
    /// （抬起明显短于归位），变的是归位本身。真要再收就得连抬起一起重新定，别只改这个数。
    func testLiftIsMuchShorterThanTheReturnFlight() {
        XCTAssertLessThan(DragLandingPlan.liftDuration, DragLandingPlan.minimumDuration / 2)
        XCTAssertGreaterThan(DragLandingPlan.liftDuration, 0)
    }

    // MARK: - 调速旋钮（owner 2026-08-19：「归位飞行能不能调快一些」）

    /// 时长表本身要在「原生量级」上：最短一段不该长到读起来是拖沓，也不能短到看不见动画。
    func testDurationTableStaysInTheNativeBallpark() {
        XCTAssertGreaterThan(DragLandingPlan.minimumDuration, 0.15)
        XCTAssertLessThan(DragLandingPlan.minimumDuration, 0.45)
        XCTAssertGreaterThan(DragLandingPlan.maximumFlightDuration, DragLandingPlan.minimumDuration)
        XCTAssertLessThan(DragLandingPlan.maximumFlightDuration, 0.70)
    }

    /// `DOCK_DRAG_FLIGHT_MS` 只接受「两个正数且最短 ≤ 最长」，其余一律当没设——
    /// **半套生效比不生效更糟**（只改了下界的话曲线两端会反过来）。
    func testFlightDurationOverrideRejectsAnythingMalformed() {
        for bad in ["", "320", "320,", ",500", "abc,500", "320,abc", "0,500", "-320,500", "500,320", "320,500,700"] {
            XCTAssertNil(DragLandingPlan.parseFlightDurations(bad), "「\(bad)」不该被接受")
        }
        let good = DragLandingPlan.parseFlightDurations("320,500")
        XCTAssertEqual(good?.minimum ?? 0, 0.32, accuracy: 0.0001)
        XCTAssertEqual(good?.maximum ?? 0, 0.50, accuracy: 0.0001)
        // 两端相等是合法的（定长飞行），空格也要容忍
        XCTAssertNotNil(DragLandingPlan.parseFlightDurations(" 400 , 400 "))
    }
}
