import XCTest

final class SubscriptionSubmitterTests: XCTestCase {

    // MARK: 请求形状

    /// 回归锁：**没有 Origin 时，服务端只认 `X-Tungsten-Client: app` 这个头**。
    /// 漏掉它，App 里的每一次订阅都会被接口 403 掉，而界面上只会显示一句通用失败。
    func testRequestCarriesAppClientHeaderAndFifteenSecondTimeout() async throws {
        var captured: URLRequest?
        let submitter = WebsiteSubscriptionSubmitter { request in
            captured = request
            return Self.response(statusCode: 200, json: #"{"status":"created"}"#)
        }

        _ = try await submitter.submit(email: "someone@example.com", firstLaunchDate: nil)

        XCTAssertEqual(captured?.url, WebsiteSubscriptionSubmitter.endpointURL)
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.timeoutInterval, WebsiteSubscriptionSubmitter.requestTimeout)
        XCTAssertEqual(
            captured?.value(forHTTPHeaderField: WebsiteSubscriptionSubmitter.clientHeaderField),
            WebsiteSubscriptionSubmitter.clientHeaderValue
        )
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    /// 请求体只带三样东西：邮箱、来源、首装日期。
    /// 多一样都要重新过一遍隐私交代——界面上那句话是逐字承诺「只发送邮箱地址与首次安装日期」。
    func testRequestBodyCarriesOnlyEmailSourceAndFirstLaunchDay() async throws {
        var captured: URLRequest?
        let submitter = WebsiteSubscriptionSubmitter { request in
            captured = request
            return Self.response(statusCode: 200, json: #"{"status":"created"}"#)
        }
        // 2026-08-13 12:34:56 本地时间
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 13
        components.hour = 12
        components.minute = 34
        let date = try XCTUnwrap(Calendar.current.date(from: components))

        _ = try await submitter.submit(email: "  someone@example.com  ", firstLaunchDate: date)

        let body = try XCTUnwrap(captured?.httpBody)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(decoded.keys), ["email", "source", "firstLaunch"])
        // 首尾空白要去掉：用户从别处粘贴邮箱时经常带着空格。
        XCTAssertEqual(decoded["email"] as? String, "someone@example.com")
        XCTAssertEqual(decoded["source"] as? String, "app")
        // 只到「日」，不带时分秒。
        XCTAssertEqual(decoded["firstLaunch"] as? String, "2026-08-13")
    }

    func testRequestOmitsFirstLaunchWhenUnknown() async throws {
        var captured: URLRequest?
        let submitter = WebsiteSubscriptionSubmitter { request in
            captured = request
            return Self.response(statusCode: 200, json: #"{"status":"created"}"#)
        }

        _ = try await submitter.submit(email: "someone@example.com", firstLaunchDate: nil)

        let body = try XCTUnwrap(captured?.httpBody)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(decoded.keys), ["email", "source"])
    }

    // MARK: 响应映射

    func testCreatedStatusMapsToCreatedOutcome() async throws {
        let submitter = WebsiteSubscriptionSubmitter { _ in
            Self.response(statusCode: 200, json: #"{"status":"created","message":"…"}"#)
        }
        let outcome = try await submitter.submit(email: "a@b.com", firstLaunchDate: nil)
        XCTAssertEqual(outcome, .created)
    }

    func testExistingStatusMapsToAlreadySubscribed() async throws {
        let submitter = WebsiteSubscriptionSubmitter { _ in
            Self.response(statusCode: 200, json: #"{"status":"existing","message":"…"}"#)
        }
        let outcome = try await submitter.submit(email: "a@b.com", firstLaunchDate: nil)
        XCTAssertEqual(outcome, .alreadySubscribed)
    }

    /// 回归锁：**2xx 但响应体读不懂时，按成功处理，不能报错。**
    /// 请求已经 2xx 了说明名单那边确实收下了；这时候因为解析失败而告诉用户「订阅失败」，
    /// 会让他重复提交，而且他的邮箱其实早就进去了。
    func testUnparseableSuccessBodyStillCountsAsCreated() async throws {
        let submitter = WebsiteSubscriptionSubmitter { _ in
            Self.response(statusCode: 200, json: "not json at all")
        }
        let outcome = try await submitter.submit(email: "a@b.com", firstLaunchDate: nil)
        XCTAssertEqual(outcome, .created)
    }

    /// 回归锁：**只有 2xx 算成功。** 官网那个接口就是因为把某段 4xx 映射成"成功"，
    /// 把 firewall 拦截这类真实失败谎报成了成功（2026-08-13）。这一侧不能重蹈覆辙。
    func testNon2xxThrows() async {
        for status in [400, 403, 429, 500, 502] {
            let submitter = WebsiteSubscriptionSubmitter { _ in
                Self.response(statusCode: status, json: #"{"message":"…"}"#)
            }
            await XCTAssertThrowsErrorAsync(
                try await submitter.submit(email: "a@b.com", firstLaunchDate: nil)
            ) { error in
                XCTAssertEqual(error as? SubscriptionError, .httpStatus(status))
            }
        }
    }

    func testInvalidEmailNeverReachesTheNetwork() async {
        var didCallLoader = false
        let submitter = WebsiteSubscriptionSubmitter { _ in
            didCallLoader = true
            return Self.response(statusCode: 200, json: #"{"status":"created"}"#)
        }

        await XCTAssertThrowsErrorAsync(
            try await submitter.submit(email: "not-an-email", firstLaunchDate: nil)
        ) { error in
            XCTAssertEqual(error as? SubscriptionError, .invalidEmail)
        }
        XCTAssertFalse(didCallLoader, "格式明显不对时不该白跑一次网络")
    }

    // MARK: 邮箱格式检查

    func testEmailCheckAcceptsOrdinaryAddresses() {
        for address in [
            "a@b.co",
            "someone@example.com",
            "first.last+tag@sub.domain.co.uk",
            "用户@例子.中国"
        ] {
            XCTAssertTrue(EmailAddressCheck.looksValid(address), address)
        }
    }

    func testEmailCheckRejectsObviouslyBrokenInput() {
        for address in [
            "",
            "   ",
            "no-at-sign.com",
            "@example.com",
            "someone@",
            "someone@nodot",
            "someone@.com",
            "someone@example.",
            "two@at@example.com",
            "has space@example.com"
        ] {
            XCTAssertFalse(EmailAddressCheck.looksValid(address), address)
        }
    }

    func testEmailCheckRejectsOverlongAddress() {
        let long = String(repeating: "a", count: 250) + "@example.com"
        XCTAssertGreaterThan(long.count, EmailAddressCheck.maximumLength)
        XCTAssertFalse(EmailAddressCheck.looksValid(long))
    }

    // MARK: 在飞守卫

    /// 回归锁：连点两下订阅按钮不能发两次请求。
    func testSubmitStateRejectsSecondConcurrentSubmission() {
        var state = SubscriptionSubmitState()
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.begin(), "已经有一次在飞时必须拒绝")
        XCTAssertEqual(state.presentation, SubscriptionSubmitPresentation(title: String(localized: "Submitting…"), isEnabled: false))

        state.finish()
        XCTAssertEqual(state.presentation, SubscriptionSubmitPresentation(title: String(localized: "Subscribe"), isEnabled: true))
        XCTAssertTrue(state.begin())
    }

    // MARK: 文案映射

    /// 回归锁：**新订阅一定要提确认邮件。** Buttondown 走双重确认，不点确认信是不会真正
    /// 进名单的。少了这句，用户会以为已经完事，名单里却永远停在 unactivated。
    func testCreatedAlertTellsUserToConfirmByEmail() {
        let content = SubscriptionAlertContent(outcome: .created)
        // 语言无关地锁住「必须提确认邮件」：中文说「确认」，英文说 confirmation。
        let lowered = content.message.lowercased()
        XCTAssertTrue(lowered.contains("确认") || lowered.contains("confirm"), content.message)
        XCTAssertFalse(content.isWarning)
        XCTAssertTrue(content.didSubscribe)
    }

    func testAlreadySubscribedIsNotPresentedAsAFailure() {
        let content = SubscriptionAlertContent(outcome: .alreadySubscribed)
        XCTAssertFalse(content.isWarning)
        // 已经在名单里的人也该把本机标记为已订阅，否则每次开设置都再看见一遍推销。
        XCTAssertTrue(content.didSubscribe)
    }

    /// 失败绝不能把本机标记成「已订阅」——那会让用户以为留成功了，
    /// 而且订阅区块从此消失，他再也没有入口重试。
    func testFailureContentsNeverMarkAsSubscribed() {
        XCTAssertFalse(SubscriptionAlertContent.failure.didSubscribe)
        XCTAssertTrue(SubscriptionAlertContent.failure.isWarning)
        XCTAssertFalse(SubscriptionAlertContent.invalidEmail.didSubscribe)
        XCTAssertTrue(SubscriptionAlertContent.invalidEmail.isWarning)
    }

    // MARK: helpers

    private static func response(statusCode: Int, json: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: WebsiteSubscriptionSubmitter.endpointURL,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
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
