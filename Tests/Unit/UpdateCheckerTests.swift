import XCTest

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparisonAcceptsLeadingVAndPadsMissingSegments() {
        XCTAssertEqual(AppVersion("v0.5"), AppVersion("0.5.0"))
        XCTAssertEqual(AppVersion("V1.2.0.0"), AppVersion("1.2"))
        XCTAssertLessThan(AppVersion("0.5.9")!, AppVersion("0.6")!)
        XCTAssertGreaterThan(AppVersion("1.10")!, AppVersion("1.2.9")!)
    }

    func testVersionComparisonRejectsNonNumericVersions() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion("1.2+3"))
        XCTAssertNil(AppVersion("1.2-"))
        XCTAssertNil(AppVersion("1.2-beta..1"))
        XCTAssertNil(AppVersion("1.2-beta.01"))
    }

    func testVersionComparisonOrdersPrereleasesBeforeStableVersion() {
        XCTAssertLessThan(AppVersion("0.6.6-beta.1")!, AppVersion("0.6.6-beta.2")!)
        XCTAssertLessThan(AppVersion("0.6.6-beta.2")!, AppVersion("0.6.6-beta.10")!)
        XCTAssertLessThan(AppVersion("0.6.6-beta.2")!, AppVersion("0.6.6-rc.1")!)
        XCTAssertLessThan(AppVersion("0.6.6-1")!, AppVersion("0.6.6-alpha")!)
        XCTAssertLessThan(AppVersion("0.6.6-alpha")!, AppVersion("0.6.6-alpha.1")!)
        XCTAssertLessThan(AppVersion("v0.6.6-rc.1")!, AppVersion("0.6.6")!)
        XCTAssertGreaterThan(AppVersion("0.6.6")!, AppVersion("0.6.6-beta.99")!)
    }

    func testStableReleaseIsOfferedToMatchingPrerelease() async throws {
        let expectedURL = URL(string: "https://github.com/moonbai-studio/tungsten-edge/releases/tag/v0.6.6")!
        let checker = makeChecker(
            statusCode: 200,
            json: #"{"tag_name":"v0.6.6","html_url":"https://github.com/moonbai-studio/tungsten-edge/releases/tag/v0.6.6"}"#
        )

        let outcome = try await checker.check(currentVersion: "0.6.6-beta.1")

        XCTAssertEqual(
            outcome,
            .updateAvailable(
                currentVersion: "0.6.6-beta.1",
                latestVersion: "v0.6.6",
                releaseURL: expectedURL
            )
        )
    }

    func testNewerReleaseUsesGitHubReleaseURL() async throws {
        let expectedURL = URL(string: "https://github.com/moonbai-studio/tungsten-edge/releases/tag/v0.6.0")!
        let checker = makeChecker(
            statusCode: 200,
            json: #"{"tag_name":"v0.6.0","html_url":"https://github.com/moonbai-studio/tungsten-edge/releases/tag/v0.6.0"}"#
        )

        let outcome = try await checker.check(currentVersion: "0.5.0")

        XCTAssertEqual(
            outcome,
            .updateAvailable(currentVersion: "0.5.0", latestVersion: "v0.6.0", releaseURL: expectedURL)
        )
    }

    func testEqualOrOlderReleaseIsUpToDate() async throws {
        let equalChecker = makeChecker(
            statusCode: 200,
            json: #"{"tag_name":"v0.5","html_url":"https://github.com/moonbai-studio/tungsten-edge/releases/tag/v0.5.0"}"#
        )
        let olderChecker = makeChecker(
            statusCode: 200,
            json: #"{"tag_name":"v0.4.5","html_url":"https://github.com/moonbai-studio/tungsten-edge/releases/tag/v0.4.5"}"#
        )
        let equalOutcome = try await equalChecker.check(currentVersion: "0.5.0")
        let olderOutcome = try await olderChecker.check(currentVersion: "0.5.0")

        XCTAssertEqual(
            equalOutcome,
            .upToDate(currentVersion: "0.5.0", latestVersion: "v0.5")
        )
        XCTAssertEqual(
            olderOutcome,
            .upToDate(currentVersion: "0.5.0", latestVersion: "v0.4.5")
        )
    }

    func testRequestUsesGitHubHeadersAndTenSecondTimeout() async throws {
        var capturedRequest: URLRequest?
        let checker = GitHubUpdateChecker { request in
            capturedRequest = request
            return self.response(
                statusCode: 200,
                json: #"{"tag_name":"v0.5.0","html_url":"https://github.com/moonbai-studio/tungsten-edge/releases/tag/v0.5.0"}"#
            )
        }

        _ = try await checker.check(currentVersion: "0.5.0")

        XCTAssertEqual(capturedRequest?.url, GitHubUpdateChecker.latestReleaseAPIURL)
        XCTAssertEqual(capturedRequest?.timeoutInterval, GitHubUpdateChecker.requestTimeout)
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "User-Agent"), "Tungsten-Edge/0.5.0")
    }

    func testHTTPFailureIsReported() async {
        let checker = makeChecker(statusCode: 503, json: "{}")

        await XCTAssertThrowsErrorAsync(try await checker.check(currentVersion: "0.5.0")) { error in
            XCTAssertEqual(error as? UpdateCheckError, .httpStatus(503))
        }
    }

    func testInvalidJSONAndInvalidTagAreReported() async {
        let invalidJSON = makeChecker(statusCode: 200, json: "not-json")
        let invalidTag = makeChecker(
            statusCode: 200,
            json: #"{"tag_name":"v0.6.0-beta..1","html_url":"https://github.com/moonbai-studio/tungsten-edge/releases/tag/v0.6.0-beta..1"}"#
        )

        await XCTAssertThrowsErrorAsync(try await invalidJSON.check(currentVersion: "0.5.0")) { error in
            XCTAssertTrue(error is DecodingError)
        }
        await XCTAssertThrowsErrorAsync(try await invalidTag.check(currentVersion: "0.5.0")) { error in
            XCTAssertEqual(error as? UpdateCheckError, .invalidLatestVersion)
        }
    }

    func testTimeoutPassesThroughAndFallbackURLIsStable() async {
        let checker = GitHubUpdateChecker { _ in throw URLError(.timedOut) }

        await XCTAssertThrowsErrorAsync(try await checker.check(currentVersion: "0.5.0")) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(
            GitHubUpdateChecker.releasesURL,
            URL(string: "https://github.com/moonbai-studio/tungsten-edge/releases")
        )
    }

    func testMenuStateRejectsDuplicateChecksAndRestoresAfterFinish() {
        var state = UpdateCheckMenuState()

        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.begin())
        XCTAssertEqual(state.presentation, UpdateCheckMenuPresentation(title: "正在检查更新…", isEnabled: false))

        state.finish()
        XCTAssertEqual(state.presentation, UpdateCheckMenuPresentation(title: "检查更新…", isEnabled: true))
        XCTAssertTrue(state.begin())
    }

    private func makeChecker(statusCode: Int, json: String) -> GitHubUpdateChecker {
        GitHubUpdateChecker { _ in
            self.response(statusCode: statusCode, json: json)
        }
    }

    private func response(statusCode: Int, json: String) -> (Data, URLResponse) {
        let url = GitHubUpdateChecker.latestReleaseAPIURL
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
