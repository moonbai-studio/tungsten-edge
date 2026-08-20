import XCTest
@testable import macos_dock_cc_v2

/// 「指针压在哪张卡上」的纯判定。取代了每张卡各自的 `.onHover`——成因、实测数据和
/// 它同时治掉的两个毛病（快速横扫漏格 / 切换边界带方向）见 `StripHoverResolution` 的注释。
final class StripHoverResolutionTests: XCTestCase {
    /// 原生间距的一排图标卡：宽 40、间距 2，中心间距 42。
    private let bar: [String: CGRect] = [
        "a": CGRect(x: 0,  y: 0, width: 40, height: 54),
        "b": CGRect(x: 42, y: 0, width: 40, height: 54),
        "c": CGRect(x: 84, y: 0, width: 40, height: 54)
    ]
    private let midY: CGFloat = 27

    private func hit(_ x: CGFloat, _ frames: [String: CGRect]? = nil) -> String? {
        StripHoverResolution.chip(at: CGPoint(x: x, y: midY), frames: frames ?? bar)
    }

    func testPointerInsideACardHitsThatCard() {
        XCTAssertEqual(hit(20), "a")
        XCTAssertEqual(hit(62), "b")
        XCTAssertEqual(hit(104), "c")
    }

    // MARK: - 边界：一条硬线，与来向无关

    /// **这条是本轮的目标。** 改造前两张卡的命中矩形之间隔着 2pt 死区，必须完全走进
    /// 下一张卡才换手，于是切换点带方向——实测向右落在右卡左边缘、向左落在中点偏左，
    /// 迟滞 3.5pt（owner 2026-08-17 报「边界不固定、不利落」）。
    /// 现在缝被桥接，切换点就是缝的正中 41，两个方向同一个数。
    func testTheSwitchPointIsExactlyTheMiddleOfTheGap() {
        XCTAssertEqual(hit(40.4), "a", "缝的左半边仍归左卡")
        XCTAssertEqual(hit(41.6), "b", "缝的右半边归右卡")
    }

    /// 缝里**没有一处是无主的**——那 2pt 曾经是「谁都不是」的中间态，
    /// 慢慢滑过去看到的就是「A → 空 → B」。
    func testNoDeadZoneAnywhereInsideTheGap() {
        for step in stride(from: CGFloat(40), through: 42, by: 0.1) {
            XCTAssertNotNil(hit(step), "缝内 x=\(step) 不该无人认领")
        }
    }

    /// 宽窄不一的卡并排时，缝的裁决按**到卡边**的距离取近，不是按到卡心：
    /// 按卡心的话窄卡会多吃一块，边界就不在缝正中了。
    func testGapIsSplitByEdgeDistanceNotByCardCentre() {
        let mixed: [String: CGRect] = [
            "wide": CGRect(x: 0, y: 0, width: 160, height: 54),
            "icon": CGRect(x: 162, y: 0, width: 40, height: 54)
        ]
        XCTAssertEqual(hit(160.4, mixed), "wide")
        XCTAssertEqual(hit(161.6, mixed), "icon")
    }

    // MARK: - 宽缝仍然什么都不弹

    /// 分区分隔线那道 9pt 宽的缝、任务条两端的留白：两侧各桥接 2pt 之后中间仍空着，
    /// 所以悬停在上面没有任何卡被拥有（原生也是这样）。
    func testWideGapsStayUnowned() {
        let zones: [String: CGRect] = [
            "left":  CGRect(x: 0,  y: 0, width: 40, height: 54),
            "right": CGRect(x: 49, y: 0, width: 40, height: 54)   // 9pt 分区缝
        ]
        XCTAssertNil(hit(44.5, zones), "分区缝正中不该有人拥有")
        XCTAssertNil(hit(-5, zones), "条左端留白之外")
        XCTAssertNil(hit(200, zones), "条右端留白之外")
    }

    /// 纵向不桥接：竖着离开条就该没人拥有，否则贴边唤醒/胶囊那一带会误判。
    func testVerticalIsNotBridged() {
        XCTAssertNil(StripHoverResolution.chip(at: CGPoint(x: 20, y: -3), frames: bar))
        XCTAssertNil(StripHoverResolution.chip(at: CGPoint(x: 20, y: 80), frames: bar))
    }

    /// 桥接量随档位缩放（小档卡窄、缝也窄）。传 0 就退化成「必须完全走进卡里」——
    /// 也就是改造前那个带方向的行为，这条顺带把参数确实被用上了钉住。
    func testGapBridgeIsAParameter() {
        XCTAssertNil(StripHoverResolution.chip(at: CGPoint(x: 41, y: midY),
                                               frames: bar, gapBridge: 0))
        XCTAssertNotNil(StripHoverResolution.chip(at: CGPoint(x: 41, y: midY),
                                                  frames: bar, gapBridge: 2))
    }

    /// 桥接量正好等于卡间距，两者是同一件事：缝两侧各扩一半宽就在正中相接。
    func testBridgeMatchesTheChipSpacing() {
        XCTAssertEqual(StripHoverResolution.defaultGapBridge, ChipPillMetrics.chipSpacing)
    }

    /// 还没量到的帧（`.zero`）不参与判定，否则原点附近会凭空多一个拥有者。
    func testUnmeasuredFramesAreIgnored() {
        XCTAssertNil(StripHoverResolution.chip(at: .zero, frames: ["x": .zero]))
    }

    /// 空表不崩、不认领。
    func testEmptyFrames() {
        XCTAssertNil(hit(20, [:]))
    }
}
