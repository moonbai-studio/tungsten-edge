import XCTest

final class AppInstallLocationTests: XCTestCase {
    func testClassifiesStableAndTransientLocations() {
        XCTAssertEqual(
            AppInstallLocation(bundleURL: URL(fileURLWithPath: "/Applications/Tungsten Edge.app")),
            .applications
        )
        XCTAssertEqual(
            AppInstallLocation(bundleURL: URL(fileURLWithPath: "/Volumes/Tungsten Edge/Tungsten Edge.app")),
            .diskImage
        )
        XCTAssertEqual(
            AppInstallLocation(bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Tungsten Edge.app")),
            .appTranslocation
        )
        XCTAssertEqual(
            AppInstallLocation(bundleURL: URL(fileURLWithPath: "/Users/test/Build/Tungsten Edge.app")),
            .other
        )
    }

    func testTransientLocationsRejectAccessibilityPrompt() {
        XCTAssertTrue(AppInstallLocation.applications.allowsAccessibilityPrompt)
        XCTAssertTrue(AppInstallLocation.other.allowsAccessibilityPrompt)
        XCTAssertFalse(AppInstallLocation.diskImage.allowsAccessibilityPrompt)
        XCTAssertFalse(AppInstallLocation.appTranslocation.allowsAccessibilityPrompt)
    }
}

final class PermissionOnboardingStateTests: XCTestCase {
    func testRelocationWinsEvenWhenTransientCopyIsAlreadyTrusted() {
        XCTAssertEqual(
            PermissionOnboardingState.initial(installLocation: .diskImage, isTrusted: true),
            .moveToApplications(.diskImage)
        )
    }

    func testWaitingBecomesStalledAtEightSecondsAndGrantedWhenTrusted() {
        let waiting = PermissionOnboardingState.waiting
        XCTAssertEqual(
            waiting.updated(isTrusted: false, elapsed: 7.99, stallAfter: 8),
            .waiting
        )
        XCTAssertEqual(
            waiting.updated(isTrusted: false, elapsed: 8, stallAfter: 8),
            .stalled
        )
        XCTAssertEqual(
            PermissionOnboardingState.stalled.updated(isTrusted: true, elapsed: 9, stallAfter: 8),
            .granted
        )
    }
}

@MainActor
final class AccessibilityPermissionModelTests: XCTestCase {
    func testTransientCopyNeverChecksOrRequestsPermission() {
        for location in [AppInstallLocation.diskImage, .appTranslocation] {
            var checkCount = 0
            var promptCount = 0
            let service = PermissionService(
                trustCheck: {
                    checkCount += 1
                    return true
                },
                promptRequest: {
                    promptCount += 1
                    return false
                }
            )
            let model = AccessibilityPermissionModel(
                permissionService: service,
                installLocation: location,
                initialTrusted: false
            )

            model.startPolling()
            model.requestSystemPromptIfNeeded()
            model.applicationDidBecomeActive()

            XCTAssertEqual(model.state, .moveToApplications(location))
            XCTAssertEqual(checkCount, 0)
            XCTAssertEqual(promptCount, 0)
            model.stop()
        }
    }

    func testPollingTransitionsToStalledAfterEightSeconds() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var now = startedAt
        let model = AccessibilityPermissionModel(
            permissionService: PermissionService(
                trustCheck: { false },
                promptRequest: { false }
            ),
            installLocation: .applications,
            initialTrusted: false,
            now: { now }
        )
        defer { model.stop() }

        model.startPolling()
        XCTAssertEqual(model.state, .waiting)

        now = startedAt.addingTimeInterval(7.99)
        model.checkNow()
        XCTAssertEqual(model.state, .waiting)

        now = startedAt.addingTimeInterval(8)
        model.checkNow()
        XCTAssertEqual(model.state, .stalled)
    }

    func testApplicationActivationRechecksAndGrantCallbackIsOneShot() {
        var trusted = false
        var checkCount = 0
        var grantedCount = 0
        let model = AccessibilityPermissionModel(
            permissionService: PermissionService(
                trustCheck: {
                    checkCount += 1
                    return trusted
                },
                promptRequest: { false }
            ),
            installLocation: .applications,
            initialTrusted: false
        )
        model.onGranted = { grantedCount += 1 }
        defer { model.stop() }

        model.startPolling()
        XCTAssertEqual(checkCount, 1)

        trusted = true
        model.applicationDidBecomeActive()
        XCTAssertEqual(checkCount, 2)
        XCTAssertEqual(model.state, .granted)
        XCTAssertEqual(grantedCount, 1)

        model.applicationDidBecomeActive()
        model.checkNow()
        model.startPolling()
        XCTAssertEqual(checkCount, 2)
        XCTAssertEqual(grantedCount, 1)
    }

    func testStableCopyRequestsNativePromptAtMostOnce() {
        var promptCount = 0
        let model = AccessibilityPermissionModel(
            permissionService: PermissionService(
                trustCheck: { false },
                promptRequest: {
                    promptCount += 1
                    return false
                }
            ),
            installLocation: .applications,
            initialTrusted: false
        )

        model.requestSystemPromptIfNeeded()
        model.requestSystemPromptIfNeeded()

        XCTAssertEqual(promptCount, 1)
    }
}
