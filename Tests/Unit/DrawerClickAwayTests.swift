import XCTest
@testable import macos_dock_cc_v2

final class DrawerClickAwayTests: XCTestCase {
    typealias ClickAway = DrawerClickAway

    // Bar window 0…1000 × 0…110 with 20pt shadow padding; capsule window to its right; plate above.
    private let bar = CGRect(x: 0, y: 0, width: 1000, height: 110).insetBy(dx: 20, dy: 20)
    private let capsule = CGRect(x: 1000, y: 0, width: 110, height: 110)
    private let plate = CGRect(x: 800, y: 120, width: 400, height: 300)

    private func verdict(_ x: CGFloat, _ y: CGFloat, secondary: Bool = false) -> ClickAway.Verdict {
        ClickAway.verdict(at: CGPoint(x: x, y: y), isSecondary: secondary,
                          plate: plate, barVisible: bar, capsule: capsule)
    }

    func testThePlateKeepsTheDrawerForEitherButton() {
        XCTAssertEqual(verdict(900, 200), .ignore)
        XCTAssertEqual(verdict(900, 200, secondary: true), .ignore)
    }

    func testAPlainClickOnTheCapsuleLeavesItToTheCapsulesToggle() {
        XCTAssertEqual(verdict(1050, 50), .ignore)
    }

    func testASecondaryClickOnTheCapsuleClosesAtOnce() {
        XCTAssertEqual(verdict(1050, 50, secondary: true), .closeNow)
    }

    func testAPlainPressOnTheBarWaitsForTheRelease() {
        XCTAssertEqual(verdict(300, 50), .armBarPress)
    }

    func testASecondaryClickOnTheBarClosesAtOnce() {
        XCTAssertEqual(verdict(300, 50, secondary: true), .closeNow)
    }

    func testTheBarsClearShadowBorderIsOutside() {
        XCTAssertEqual(verdict(300, 10), .closeNow)
        XCTAssertEqual(verdict(10, 50), .closeNow)
    }

    func testTheDesktopClosesAtOnce() {
        XCTAssertEqual(verdict(300, 600), .closeNow)
        XCTAssertEqual(verdict(300, 600, secondary: true), .closeNow)
    }

    func testTheTapSlopMatchesTheChipDragThreshold() {
        XCTAssertEqual(ClickAway.tapSlop, 8)
        let origin = CGPoint(x: 100, y: 50)
        XCTAssertTrue(ClickAway.stillTap(pressOrigin: origin, point: CGPoint(x: 107.9, y: 50)))
        XCTAssertFalse(ClickAway.stillTap(pressOrigin: origin, point: CGPoint(x: 108, y: 50)))
    }

    func testATapOnTheBarClosesOnRelease() {
        var press = ClickAway.Press()
        press.begin(at: CGPoint(x: 100, y: 50))
        press.moved(to: CGPoint(x: 103, y: 52))
        XCTAssertTrue(press.released(at: CGPoint(x: 104, y: 52)))
        XCTAssertNil(press.origin)
    }

    func testADragThatComesBackToItsStartStaysVoid() {
        var press = ClickAway.Press()
        press.begin(at: CGPoint(x: 100, y: 50))
        press.moved(to: CGPoint(x: 110, y: 50))
        press.moved(to: CGPoint(x: 100, y: 50))
        XCTAssertFalse(press.released(at: CGPoint(x: 100, y: 50)))
    }

    func testAReleaseWithoutAPressOnTheBarDoesNothing() {
        var press = ClickAway.Press()
        XCTAssertFalse(press.released(at: .zero))
    }

    func testAReleaseFarFromThePressIsNotATap() {
        var press = ClickAway.Press()
        press.begin(at: CGPoint(x: 100, y: 50))
        XCTAssertFalse(press.released(at: CGPoint(x: 100, y: 70)))
    }
}
