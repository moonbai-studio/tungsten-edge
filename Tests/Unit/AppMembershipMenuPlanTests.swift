import XCTest
@testable import macos_dock_cc_v2

final class AppMembershipMenuPlanTests: XCTestCase {

    func testStripPlainAppShowsKeepAndUncheckedMessaging() {
        let items = AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: false, isMessaging: false)
        XCTAssertEqual(items, [.keep(isChecked: false), .messaging(isChecked: false), .unreadBadge(isChecked: false)])
    }

    func testStripMessagingAppShowsKeepAndCheckedMessaging() {
        let items = AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: true,
                                                isMessaging: true, showsUnreadBadge: true)
        XCTAssertEqual(items, [.keep(isChecked: true), .messaging(isChecked: true), .unreadBadge(isChecked: true)])
    }

    func testDrawerPlainAppShowsOnlyKeep() {
        let items = AppMembershipMenuPlan.items(surface: .drawer, isFinder: false, isKept: false, isMessaging: false)
        XCTAssertEqual(items, [.keep(isChecked: false)])
    }

    func testDrawerMessagingAppShowsKeepAndCheckedMessaging() {
        let items = AppMembershipMenuPlan.items(surface: .drawer, isFinder: false, isKept: true, isMessaging: true)
        XCTAssertEqual(items, [.keep(isChecked: true), .messaging(isChecked: true)])
    }

    /// 2026-08-20：访达纳入统一保留勾选，但消息项仍然不给（两个面都是）。
    func testFinderShowsOnlyKeep() {
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .strip, isFinder: true, isKept: true, isMessaging: false),
            [.keep(isChecked: true)]
        )
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .drawer, isFinder: true, isKept: false, isMessaging: false),
            [.keep(isChecked: false)]
        )
    }

    func testKeepCheckStateReflectsKept() {
        let unchecked = AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: false, isMessaging: false)
        XCTAssertEqual(unchecked.first, .keep(isChecked: false))
        let checked = AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: true, isMessaging: false)
        XCTAssertEqual(checked.first, .keep(isChecked: true))
    }

    func testKeepAlwaysPrecedesMessagingCommand() {
        let items = AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: false, isMessaging: true)
        XCTAssertEqual(items.first, .keep(isChecked: false))
        XCTAssertEqual(items[1], .messaging(isChecked: true))
    }

    func testMessagingCheckStateReflectsMembership() {
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: false, isMessaging: false)[1],
            .messaging(isChecked: false)
        )
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: false, isMessaging: true)[1],
            .messaging(isChecked: true)
        )
    }

    func testUnreadBadgeCheckStateIsIndependentOfPinning() {
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: false,
                                         isMessaging: false, showsUnreadBadge: true).last,
            .unreadBadge(isChecked: true)
        )
        XCTAssertEqual(
            AppMembershipMenuPlan.items(surface: .strip, isFinder: false, isKept: true,
                                         isMessaging: true, showsUnreadBadge: false).last,
            .unreadBadge(isChecked: false)
        )
    }

    func testDrawerDoesNotOfferBadgeToggleItCannotDisplay() {
        for isMessaging in [false, true] {
            let items = AppMembershipMenuPlan.items(surface: .drawer, isFinder: false, isKept: false,
                                                     isMessaging: isMessaging, showsUnreadBadge: true)
            XCTAssertFalse(items.contains(.unreadBadge(isChecked: true)))
        }
    }
}
