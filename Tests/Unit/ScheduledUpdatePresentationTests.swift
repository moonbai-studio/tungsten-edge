import XCTest

final class ScheduledUpdatePresentationTests: XCTestCase {

    /// 第一次遇见某个版本：一定要当面告诉用户——`.accessory` 应用不抢前台就等于没提示。
    func testFirstSightingOfAVersionAnnounces() {
        XCTAssertEqual(
            ScheduledUpdatePresentation.decide(version: "0.9.2", userInitiated: false, announcedVersion: nil),
            .announce
        )
    }

    /// 同一个版本的第二轮定时检查不再抢前台，改由状态栏的小圆点提醒。
    /// 这是把间隔从一天缩到 6 小时之后唯一挡住骚扰的东西。
    func testSameVersionRemindsQuietly() {
        XCTAssertEqual(
            ScheduledUpdatePresentation.decide(version: "0.9.2", userInitiated: false, announcedVersion: "0.9.2"),
            .remindQuietly
        )
    }

    /// 又出了一版：这是新消息，值得再抢一次前台。
    func testNewerVersionAnnouncesAgain() {
        XCTAssertEqual(
            ScheduledUpdatePresentation.decide(version: "0.9.3", userInitiated: false, announcedVersion: "0.9.2"),
            .announce
        )
    }

    /// 用户自己点的检查，Sparkle 保证置前，我们不插手——也不能因此把「已提示过」记掉，
    /// 否则一次手动检查会吃掉后面那次真正需要抢前台的提示。
    func testUserInitiatedDefersToSparkle() {
        XCTAssertEqual(
            ScheduledUpdatePresentation.decide(version: "0.9.2", userInitiated: true, announcedVersion: nil),
            .deferToSparkle
        )
        XCTAssertEqual(
            ScheduledUpdatePresentation.decide(version: "0.9.2", userInitiated: true, announcedVersion: "0.9.2"),
            .deferToSparkle
        )
    }

    /// Downloaded and already shown: a background check would only re-open the same window.
    func testBackgroundCheckRefusedOnceReadyUpdateWasShown() {
        XCTAssertFalse(
            ScheduledUpdatePresentation.allowsCheck(userInitiated: false, readyVersion: "0.9.2", announcedVersion: "0.9.2")
        )
    }

    /// Downloaded but not shown yet (the check right after the download): this is the one announcement.
    func testBackgroundCheckAllowedBeforeReadyUpdateIsShown() {
        XCTAssertTrue(
            ScheduledUpdatePresentation.allowsCheck(userInitiated: false, readyVersion: "0.9.2", announcedVersion: nil)
        )
        XCTAssertTrue(
            ScheduledUpdatePresentation.allowsCheck(userInitiated: false, readyVersion: "0.9.3", announcedVersion: "0.9.2")
        )
    }

    /// Nothing waiting → normal check; user-initiated checks (menu row, settings button) always run.
    func testOtherChecksAlwaysAllowed() {
        XCTAssertTrue(
            ScheduledUpdatePresentation.allowsCheck(userInitiated: false, readyVersion: nil, announcedVersion: "0.9.2")
        )
        XCTAssertTrue(
            ScheduledUpdatePresentation.allowsCheck(userInitiated: true, readyVersion: "0.9.2", announcedVersion: "0.9.2")
        )
    }
}
