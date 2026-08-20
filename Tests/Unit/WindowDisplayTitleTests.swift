import XCTest

final class WindowDisplayTitleTests: XCTestCase {
    func testNonemptyTitleIsReturnedUnchanged() {
        XCTAssertEqual(
            WindowDisplayTitle.resolve(rawTitle: "  System Settings  ", fallbackName: "Fallback"),
            "  System Settings  "
        )
    }

    func testMissingOrBlankTitleUsesFallbackName() {
        for title in [nil, "", " \n\t"] as [String?] {
            XCTAssertEqual(
                WindowDisplayTitle.resolve(rawTitle: title, fallbackName: "System Settings"),
                "System Settings"
            )
        }
    }

    func testMissingBundleIdentifierCanUseAppIDAsFallbackName() {
        let appID = "pid-456"

        XCTAssertEqual(
            WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: appID),
            appID
        )
    }

    func testTaskbarNameUsesLocalizedDisplayName() {
        XCTAssertEqual(
            WindowDisplayTitle.resolve(rawTitle: "macos-dock-cc-v2", fallbackName: "Fallback"),
            String(localized: "Taskbar")
        )
        XCTAssertEqual(
            WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: "macos-dock-cc-v2"),
            String(localized: "Taskbar")
        )
    }
}
