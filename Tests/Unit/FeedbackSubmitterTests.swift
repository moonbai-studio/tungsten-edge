import XCTest

final class FeedbackSubmitterTests: XCTestCase {
    private func okResponse(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: WebsiteFeedbackSubmitter.endpointURL,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func fullDraft() -> FeedbackDraft {
        FeedbackDraft(
            message: "任务条很好用",
            contact: "me@example.com",
            appVersion: "版本 0.9.5 (117)",
            macosVersion: "macOS 15.5",
            lang: "zh"
        )
    }

    // MARK: 请求形状

    func testRequestCarriesHeaderTimeoutAndExactlyTheDisclosedFields() async throws {
        var captured: URLRequest?
        let submitter = WebsiteFeedbackSubmitter { request in
            captured = request
            return (Data("{}".utf8), self.okResponse())
        }

        try await submitter.submit(fullDraft())

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url, WebsiteFeedbackSubmitter.endpointURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, WebsiteFeedbackSubmitter.requestTimeout)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tungsten-Client"), "app")

        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(body, Data(#"{"appVersion":"版本 0.9.5 (117)","contact":"me@example.com","lang":"zh","macosVersion":"macOS 15.5","message":"任务条很好用"}"#.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["appVersion", "contact", "lang", "macosVersion", "message"],
            "body 恰好是界面披露的五个字段"
        )
        XCTAssertEqual(object["message"] as? String, "任务条很好用")
    }

    func testNilOptionalFieldsAreOmittedNeverPadded() async throws {
        var captured: URLRequest?
        let submitter = WebsiteFeedbackSubmitter { request in
            captured = request
            return (Data(), self.okResponse(201))
        }

        try await submitter.submit(FeedbackDraft(
            message: "hi", contact: nil, appVersion: nil, macosVersion: nil, lang: "en"
        ))

        let body = try XCTUnwrap(captured?.httpBody)
        XCTAssertEqual(body, Data(#"{"lang":"en","message":"hi"}"#.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["lang", "message"], "没填的字段整个省略，不发空值")
    }

    // MARK: 只有 2xx 算成功

    func testDiagnosticsTravelInJSONAndMultipartPayloadWithoutChangingText() async throws {
        let report = "## F. Window inventory\n应用: 文件 \\\"\n\twindow state=true"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([0x89, 0x50]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var payloads: [Data] = []
        for withAttachment in [false, true] {
            var captured: URLRequest?
            let submitter = WebsiteFeedbackSubmitter { request in
                captured = request
                return (Data(), self.okResponse())
            }
            try await submitter.submit(FeedbackDraft(
                message: "hi", contact: nil, appVersion: nil, macosVersion: nil, lang: "en",
                diagnostics: report,
                attachments: withAttachment
                    ? [.init(url: file, name: "shot.png", byteCount: 2, mimeType: "image/png")] : []
            ))
            let request = try XCTUnwrap(captured)
            var payload = try XCTUnwrap(request.httpBody)
            if withAttachment {
                XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
                let text = String(decoding: payload, as: UTF8.self)
                let start = try XCTUnwrap(text.range(of: "name=\"payload\"\r\n\r\n")).upperBound
                let end = try XCTUnwrap(text.range(of: "\r\n--", range: start..<text.endIndex)).lowerBound
                payload = Data(text[start..<end].utf8)
                XCTAssertTrue(text.contains("name=\"file0\"; filename=\"shot.png\""))
                XCTAssertFalse(text.contains("name=\"file1\""))
                XCTAssertFalse(text.contains("name=\"diagnostics\""))
            } else {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["diagnostics", "lang", "message"])
            XCTAssertEqual(object["diagnostics"] as? String, report)
            payloads.append(payload)
        }
        XCTAssertEqual(payloads[0], payloads[1])
    }

    func testDiagnosticsTooLongResponseIsRejected() async {
        let submitter = WebsiteFeedbackSubmitter { _ in
            (Data(#"{"code":"diagnostics_too_long"}"#.utf8), self.okResponse(400))
        }
        do {
            try await submitter.submit(fullDraft())
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? FeedbackError, .httpStatus(400, code: "diagnostics_too_long"))
            XCTAssertEqual(FeedbackFailure(error: error), .rejected)
        }
    }

    @MainActor
    func testFeedbackOptInSurvivesWindowSessionButPrivateReportDoesNot() throws {
        let draft = FeedbackDraftState()
        XCTAssertFalse(draft.includesDiagnostics)
        draft.includesDiagnostics = true
        let firstWindow = DiagnosticsSession()
        firstWindow.setIncludesTitles(true)
        let request = try XCTUnwrap(firstWindow.begin())
        firstWindow.complete(request, text: "private window title")
        XCTAssertTrue(firstWindow.canSendFeedback(includingDiagnostics: draft.includesDiagnostics))
        firstWindow.close()
        XCTAssertNil(firstWindow.report)
        XCTAssertFalse(firstWindow.canSendFeedback(includingDiagnostics: draft.includesDiagnostics))

        let reopened = DiagnosticsSession()
        XCTAssertTrue(draft.includesDiagnostics)
        XCTAssertFalse(reopened.includesTitles)
        XCTAssertNil(reopened.report)
        XCTAssertFalse(reopened.canSendFeedback(includingDiagnostics: draft.includesDiagnostics))
        var reads = 0
        reopened.collect { includesTitles, completion in
            XCTAssertFalse(includesTitles)
            reads += 1
            completion("report without titles")
        }
        XCTAssertTrue(reopened.canSendFeedback(includingDiagnostics: draft.includesDiagnostics))
        XCTAssertEqual(reopened.report, "report without titles")
        XCTAssertEqual(reads, 1)
        draft.clear()
        XCTAssertFalse(draft.includesDiagnostics)
    }

    @MainActor
    func testFeedbackBlocksCollectionFailureAndStaleGenerationsAndAllowsRetry() throws {
        let session = DiagnosticsSession()
        XCTAssertTrue(session.canSendFeedback(includingDiagnostics: false))
        var completions: [(String) -> Void] = []
        let collect: (Bool, @escaping (String) -> Void) -> Void = { _, completion in
            completions.append(completion)
        }
        session.collect(using: collect)
        XCTAssertFalse(session.canSendFeedback(includingDiagnostics: true))
        session.setIncludesTitles(true)
        session.collect(using: collect)
        completions[0]("stale title-free report")
        XCTAssertNil(session.report)
        XCTAssertTrue(session.isCollecting)
        completions[1]("")
        XCTAssertTrue(session.collectionFailed)
        XCTAssertFalse(session.canSendFeedback(includingDiagnostics: true))
        session.collect(using: collect)
        completions[2]("latest visible report")
        XCTAssertTrue(session.canSendFeedback(includingDiagnostics: true))
        XCTAssertEqual(session.report, "latest visible report")
        session.discardReport()
        XCTAssertNil(session.report)
        session.collect(using: collect)
        completions[2]("duplicate old result")
        XCTAssertNil(session.report)
        session.close()
        completions[3]("late result after close")
        XCTAssertNil(session.report)
        XCTAssertFalse(session.canSendFeedback(includingDiagnostics: true))
    }

    func testNon2xxThrowsHTTPStatus() async {
        let submitter = WebsiteFeedbackSubmitter { _ in (Data(), self.okResponse(429)) }
        do {
            try await submitter.submit(fullDraft())
            XCTFail("429 必须抛错")
        } catch let error as FeedbackError {
            XCTAssertEqual(error, .httpStatus(429, code: nil))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testNonHTTPResponseThrowsInvalidResponse() async {
        let submitter = WebsiteFeedbackSubmitter { _ in
            (Data(), URLResponse(url: WebsiteFeedbackSubmitter.endpointURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
        do {
            try await submitter.submit(fullDraft())
            XCTFail("非 HTTP 响应必须抛错")
        } catch let error as FeedbackError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    // MARK: 纯校验

    func testDraftCheckBoundaries() {
        XCTAssertEqual(FeedbackDraftCheck.validate(message: "  \n ", contact: ""), .emptyMessage)
        XCTAssertNil(FeedbackDraftCheck.validate(message: String(repeating: "字", count: 2000), contact: ""))
        XCTAssertEqual(
            FeedbackDraftCheck.validate(message: String(repeating: "字", count: 2001), contact: ""),
            .messageTooLong
        )
        XCTAssertNil(FeedbackDraftCheck.validate(message: "ok", contact: String(repeating: "c", count: 120)))
        XCTAssertEqual(
            FeedbackDraftCheck.validate(message: "ok", contact: String(repeating: "c", count: 121)),
            .contactTooLong
        )
    }

    // MARK: 在飞守卫与文案

    func testSubmitStateGuardsReentry() {
        var state = FeedbackSubmitState()
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.begin(), "在飞时不允许再次提交")
        XCTAssertFalse(state.presentation.isEnabled)
        state.finish()
        XCTAssertTrue(state.begin())
    }

    func testAlertContentSemantics() {
        XCTAssertTrue(FeedbackAlertContent.sent.didSend)
        XCTAssertFalse(FeedbackAlertContent.failure.didSend)
        XCTAssertTrue(FeedbackAlertContent.failure.isWarning)
        XCTAssertTrue(FeedbackAlertContent(rejection: .emptyMessage).isWarning)
        XCTAssertFalse(FeedbackAlertContent(rejection: .messageTooLong).didSend)
    }

    // MARK: 失败分类（2026-08-24）
    //
    // 起因：上线当天 owner 第一次真发就撞上每小时限流，界面却说「检查网络」。

    func testServerErrorCodeIsParsedFromTheFailureBody() async {
        let submitter = WebsiteFeedbackSubmitter { _ in
            (Data(#"{"code":"feedback_attachment_quota","message":"附件通道今日已满"}"#.utf8), self.okResponse(429))
        }
        do {
            try await submitter.submit(fullDraft())
            XCTFail("429 必须抛错")
        } catch let error as FeedbackError {
            XCTAssertEqual(error, .httpStatus(429, code: "feedback_attachment_quota"))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testUnparsableFailureBodyDegradesToNoCodeInsteadOfThrowing() async {
        for body in ["", "not json at all", "{}", #"{"code":""}"#] {
            let submitter = WebsiteFeedbackSubmitter { _ in (Data(body.utf8), self.okResponse(503)) }
            do {
                try await submitter.submit(fullDraft())
                XCTFail("503 必须抛错")
            } catch let error as FeedbackError {
                XCTAssertEqual(error, .httpStatus(503, code: nil), "body 是「\(body)」时应退化成没有 code")
            } catch {
                XCTFail("错误类型不对：\(error)")
            }
        }
    }

    func testFailureMappingCoversEveryCause() {
        XCTAssertEqual(FeedbackFailure(error: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(FeedbackFailure(error: URLError(.timedOut)), .offline)
        XCTAssertEqual(FeedbackFailure(error: FeedbackError.attachmentUnreadable), .attachmentUnreadable)
        XCTAssertEqual(FeedbackFailure(error: FeedbackError.invalidResponse), .serverUnavailable)
        XCTAssertEqual(FeedbackFailure(error: FeedbackError.httpStatus(429, code: nil)), .rateLimited)
        XCTAssertEqual(FeedbackFailure(error: FeedbackError.httpStatus(400, code: "invalid_request")), .rejected)
        XCTAssertEqual(FeedbackFailure(error: FeedbackError.httpStatus(413, code: "invalid_request")), .rejected)
        XCTAssertEqual(FeedbackFailure(error: FeedbackError.httpStatus(503, code: "unavailable")), .serverUnavailable)
        XCTAssertEqual(FeedbackFailure(error: FeedbackError.httpStatus(403, code: "invalid_source")), .serverUnavailable)
    }

    func testAttachmentQuotaCodeWinsOverTheGeneric429() {
        // 两种 429 状态码一样、说法完全不同：认 code 必须排在认状态码之前。
        XCTAssertEqual(
            FeedbackFailure(error: FeedbackError.httpStatus(429, code: "feedback_attachment_quota")),
            .attachmentQuota,
            "附件额度满不能被说成「发送太频繁」"
        )
        XCTAssertEqual(
            FeedbackFailure(error: FeedbackError.httpStatus(429, code: "too_many_requests")),
            .rateLimited
        )
    }

    func testEveryFailureHasItsOwnCopyAndNoneClaimsSuccess() {
        let failures: [FeedbackFailure] = [
            .offline, .rateLimited, .attachmentQuota, .rejected, .serverUnavailable, .attachmentUnreadable
        ]
        let contents = failures.map { FeedbackAlertContent(failure: $0) }
        XCTAssertEqual(Set(contents.map(\.title)).count, failures.count, "标题不能重复")
        XCTAssertEqual(Set(contents.map(\.message)).count, failures.count, "正文不能重复")
        for content in contents {
            XCTAssertTrue(content.isWarning)
            XCTAssertFalse(content.didSend, "失败绝不能清空草稿")
        }
        XCTAssertEqual(FeedbackAlertContent(failure: .offline), .failure, "网络故障沿用原有那条文案")
    }

    // MARK: 类型引导（2026-08-24）

    func testComposeReturnsNilForEmptyOrWhitespaceMessage() {
        XCTAssertNil(FeedbackComposition.compose(category: .bug, message: ""))
        XCTAssertNil(FeedbackComposition.compose(category: .suggestion, message: "  \n\t "))
    }

    func testComposePrefixesCategoryAndTrimsBody() {
        let composed = FeedbackComposition.compose(category: .bug, message: "  点击无反应 \n")
        XCTAssertEqual(composed, "【\(FeedbackCategory.bug.displayName)】\n点击无反应")
    }

    func testEveryCategoryHasDistinctDisplayNameAndPlaceholder() {
        let all = FeedbackCategory.allCases
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.displayName)).count, all.count, "类型名不能重复")
        XCTAssertEqual(Set(all.map(\.placeholder)).count, all.count, "引导文字必须随类型变")
    }
}
