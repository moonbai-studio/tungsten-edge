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

    // MARK: - trimmingAppNameSuffix（issue #41）

    func testTrailingAppNameSuffixIsRemoved() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("local-dc02 - Google Chrome", appName: "Google Chrome"),
            "local-dc02"
        )
    }

    func testDashVariantsAreRecognized() {
        for separator in [" - ", " — ", " – ", " | ", " · ", "-"] {
            XCTAssertEqual(
                WindowDisplayTitle.trimmingAppNameSuffix("Cursor\(separator)Google Chrome", appName: "Google Chrome"),
                "Cursor",
                "分隔符「\(separator)」没被认出来"
            )
        }
    }

    func testOnlyTheLastSeparatorIsConsumed() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("README - macos-dock - Visual Studio Code",
                                                     appName: "Visual Studio Code"),
            "README - macos-dock"
        )
    }

    func testTitleWithoutTheAppNameIsUnchanged() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("local-dc02", appName: "Google Chrome"),
            "local-dc02"
        )
    }

    func testTitleEqualToTheAppNameIsKept() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("Google Chrome", appName: "Google Chrome"),
            "Google Chrome"
        )
    }

    /// 去掉后只剩分隔符 / 空白时必须原样留着——否则卡上会出现一张没有标签的窗口卡。
    func testTitleThatWouldBecomeEmptyIsKept() {
        for title in ["- Google Chrome", " - Google Chrome", "— Google Chrome"] {
            XCTAssertEqual(
                WindowDisplayTitle.trimmingAppNameSuffix(title, appName: "Google Chrome"),
                title
            )
        }
    }

    func testAppNameInTheMiddleIsNotTouched() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("Google Chrome 更新说明", appName: "Google Chrome"),
            "Google Chrome 更新说明"
        )
    }

    /// v1 只处理后缀式重复；应用名在开头的应用原样返回（有需要再扩）。
    func testLeadingAppNameIsOutOfScopeForNow() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("Safari — 起始页", appName: "Safari"),
            "Safari — 起始页"
        )
    }

    func testBlankAppNameIsIgnored() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("local-dc02 - Google Chrome", appName: "   "),
            "local-dc02 - Google Chrome"
        )
    }
}
