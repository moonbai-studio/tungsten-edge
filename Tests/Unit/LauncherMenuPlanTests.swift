import XCTest
@testable import macos_dock_cc_v2

final class LauncherMenuPlanTests: XCTestCase {

    func testRunningNotHiddenShowsHideAndQuit() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: true, isHidden: false, hasMembership: false)
        XCTAssertEqual(kinds, [.recentDocuments, .hide, .quit])
    }

    func testRunningHiddenShowsShowAndQuit() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: true, isHidden: true, hasMembership: false)
        XCTAssertEqual(kinds, [.recentDocuments, .show, .quit])
    }

    func testNotRunningNoMembershipShowsOpenOnly() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: false, isHidden: false, hasMembership: false)
        XCTAssertEqual(kinds, [.open])
    }

    func testNotRunningWithMembershipShowsOpenRecentAndMembership() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: false, isHidden: false, hasMembership: true)
        XCTAssertEqual(kinds, [.open, .recentDocuments, .membership])
    }

    func testRunningWithMembershipShowsAll() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: true, isHidden: false, hasMembership: true)
        XCTAssertEqual(kinds, [.recentDocuments, .hide, .quit, .membership])
    }

}
