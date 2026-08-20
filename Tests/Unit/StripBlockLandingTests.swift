import XCTest
@testable import macos_dock_cc_v2

/// 抽屉整块拖进任务条的落点判定。改造前用的是整帧 `contains`，实测（2026-08-18 拖拽日志）
/// 首次落点 100% 退化成「落到末尾」——因为转正判定框故意伸到条上沿之外 16pt，
/// 而在条外整帧命中永远失败。这里钉的就是「**只看 x、永远给得出答案**」。
final class StripBlockLandingTests: XCTestCase {
    /// live 区三张原生间距的卡：宽 40、间距 2，中心在 20 / 62 / 104。
    private let live: [String: CGRect] = [
        "a": CGRect(x: 0,   y: 0, width: 40, height: 54),
        "b": CGRect(x: 42,  y: 0, width: 40, height: 54),
        "c": CGRect(x: 84,  y: 0, width: 40, height: 54)
    ]

    private func hit(_ x: CGFloat, _ frames: [String: CGRect]? = nil) -> String {
        guard let t = StripBlockLanding.target(pointerX: x, frames: frames ?? live) else { return "nil" }
        return "\(t.id)\(t.after ? ">" : "<")"
    }

    func testLandsOnTheHalfThePointerIsIn() {
        XCTAssertEqual(hit(10), "a<")
        XCTAssertEqual(hit(30), "a>")
        XCTAssertEqual(hit(55), "b<")
        XCTAssertEqual(hit(70), "b>")
    }

    /// **本轮的核心**：条上沿之外、卡与卡之间的 2pt 缝、消息区/文件夹区上方——
    /// 这些位置以前一律"没有目标"，整块就原地不动或落到末尾。现在都要给出最近的插入位。
    func testEveryPointerPositionResolvesToASlot() {
        for x in stride(from: CGFloat(-200), through: 400, by: 1) {
            XCTAssertNotEqual(hit(x), "nil", "x=\(x) 必须能落位")
        }
    }

    /// 缝里按到卡中心的距离取近：缝正中偏左归左卡的右边、偏右归右卡的左边——
    /// 两者其实是**同一个插入位**，所以缝里怎么判都不会跳格。
    func testTheGapResolvesToTheSameInsertionSlotFromEitherSide() {
        XCTAssertEqual(hit(40.9), "a>")
        XCTAssertEqual(hit(43.1), "b<")
    }

    /// 光标远在 live 区左边（压在消息区/文件夹区上）→ 插到最左那张卡**之前**，
    /// 不是末尾。缝要开在看得见、且贴近手指那一侧。
    func testFarLeftInsertsBeforeTheFirstCard() {
        XCTAssertEqual(hit(-500), "a<")
    }

    /// 远在右边 → 最右那张卡之后。
    func testFarRightInsertsAfterTheLastCard() {
        XCTAssertEqual(hit(9999), "c>")
    }

    /// y 完全不参与：判定发生在条上沿之上 16pt 的容差带里也必须有答案。
    /// （用一组 y 落在条外的帧来表达——只要 x 对得上就该命中。）
    func testVerticalPositionIsIrrelevantByConstruction() {
        // target 的签名里根本没有 y，这条用「同样的 x 得到同样的结果」把它固化下来。
        let shifted = live.mapValues { $0.offsetBy(dx: 0, dy: 500) }
        for x in stride(from: CGFloat(-50), through: 200, by: 7) {
            XCTAssertEqual(hit(x, shifted), hit(x), "x=\(x) 的落位不该受纵向位置影响")
        }
    }

    /// 还没量到的帧不参与，否则原点附近会凭空多一个落位。
    func testUnmeasuredFramesAreIgnored() {
        XCTAssertEqual(hit(500, ["ghost": .zero]), "nil")
        XCTAssertEqual(hit(50, ["a": live["a"]!, "ghost": .zero]), "a>")
    }

    /// live 区真的空了才返回 nil（那时调用方本来也无处可插）。
    func testEmptyLiveZone() {
        XCTAssertEqual(hit(50, [:]), "nil")
    }

    /// 距离相同时结果必须确定——字典遍历顺序不定，不定序就会两帧之间来回跳。
    func testTiesAreResolvedDeterministically() {
        let symmetric: [String: CGRect] = [
            "z": CGRect(x: 0,  y: 0, width: 40, height: 54),
            "a": CGRect(x: 60, y: 0, width: 40, height: 54)
        ]
        // x = 40 到两心距离都是 20。
        let first = hit(40, symmetric)
        for _ in 0..<50 { XCTAssertEqual(hit(40, symmetric), first) }
    }
}
