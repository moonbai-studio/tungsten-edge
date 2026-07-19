import XCTest
@testable import macos_dock_cc_v2

final class LauncherChipVisualPlanTests: XCTestCase {

    // 退出态：无论本区是否对隐藏态降级，都恒定灰显、无点。
    func testNotRunningIsGrayNoDot() {
        for dims in [true, false] {
            let v = LauncherChipVisualPlan.visual(isRunning: false, isHidden: false, dimsWhenHidden: dims)
            XCTAssertEqual(v.opacity, 0.35, accuracy: 0.0001)
            XCTAssertFalse(v.showsRunningDot)
        }
    }

    // 运行可见：全亮、有点。
    func testRunningVisibleIsBrightWithDot() {
        for dims in [true, false] {
            let v = LauncherChipVisualPlan.visual(isRunning: true, isHidden: false, dimsWhenHidden: dims)
            XCTAssertEqual(v.opacity, 1.0, accuracy: 0.0001)
            XCTAssertTrue(v.showsRunningDot)
        }
    }

    // 消息区运行隐藏（dimsWhenHidden=false）：保持全亮、有点（随时可点）。
    func testMessagingRunningHiddenStaysBright() {
        let v = LauncherChipVisualPlan.visual(isRunning: true, isHidden: true, dimsWhenHidden: false)
        XCTAssertEqual(v.opacity, 1.0, accuracy: 0.0001)
        XCTAssertTrue(v.showsRunningDot)
    }

    // 默认区（抽屉 / 普通 kept）运行隐藏（dimsWhenHidden=true）：降级 0.45、有点。
    func testDefaultRunningHiddenDims() {
        let v = LauncherChipVisualPlan.visual(isRunning: true, isHidden: true, dimsWhenHidden: true)
        XCTAssertEqual(v.opacity, 0.45, accuracy: 0.0001)
        XCTAssertTrue(v.showsRunningDot)
    }
}
