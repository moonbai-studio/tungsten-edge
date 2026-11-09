import Foundation

/// 反馈草稿的纯校验。上限与服务端 `functions/_lib/feedback-policy.js` 保持同一个数——
/// 客户端先挡明显超限的，省一次没意义的往返；真校验永远在服务端。
enum FeedbackDraftCheck {
    static let messageMaximum = 2000
    static let contactMaximum = 120

    enum Rejection: Equatable {
        case emptyMessage
        case messageTooLong
        case contactTooLong
    }

    static func validate(message: String, contact: String) -> Rejection? {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMessage.isEmpty { return .emptyMessage }
        if trimmedMessage.count > messageMaximum { return .messageTooLong }
        if contact.trimmingCharacters(in: .whitespacesAndNewlines).count > contactMaximum {
            return .contactTooLong
        }
        return nil
    }
}

/// 反馈类型（2026-08-24「模板引导」）：radio 三选一 + 随类型变的引导文字。
/// 类型**并入 message 开头**（见 `FeedbackComposition`），不作为独立字段——
/// JSON body 因此仍是那五个字段，服务端/控制台/邮件全不用动。
enum FeedbackCategory: String, CaseIterable {
    case bug
    case suggestion
    case other

    var displayName: String {
        switch self {
        case .bug: return String(localized: "Bug Report")
        case .suggestion: return String(localized: "Feature Suggestion")
        case .other: return String(localized: "Other")
        }
    }

    /// 输入框为空时叠显的引导文字（随类型变，overlay 不占布局）。
    var placeholder: String {
        switch self {
        case .bug:
            return String(localized: "What went wrong? What did you do when it happened? Paste any details that might help.")
        case .suggestion:
            return String(localized: "What should Tungsten Edge add or improve? Tell us how you'd use it.")
        case .other:
            return String(localized: "Anything you want to say — write it here.")
        }
    }
}

/// 正文组装的唯一入口：trim 后为空返回 nil，否则「【类型】\n正文」。
/// 长度校验必须跑在组装结果上（`performFeedback` 收到的就是它）——前缀也占
/// 2000 字限额，客户端不挡的话服务端会 400，弹「无法发送」误导用户。
enum FeedbackComposition {
    static func compose(category: FeedbackCategory, message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "【\(category.displayName)】\n\(trimmed)"
    }
}

/// Exactly what the Feedback pane's disclosure line promises — a new field here means updating that line,
/// the README privacy sections and the website privacy page. Diagnostics stay in the JSON payload; sent as
/// a file they would count against the attachment quota.
struct FeedbackDraft: Equatable {
    let message: String
    let contact: String?
    let appVersion: String?
    let macosVersion: String?
    let lang: String
    let diagnostics: String?
    let attachments: [FeedbackAttachment]

    init(
        message: String,
        contact: String?,
        appVersion: String?,
        macosVersion: String?,
        lang: String,
        diagnostics: String? = nil,
        attachments: [FeedbackAttachment] = []
    ) {
        self.message = message
        self.contact = contact
        self.appVersion = appVersion
        self.macosVersion = macosVersion
        self.lang = lang
        self.diagnostics = diagnostics
        self.attachments = attachments
    }
}

protocol FeedbackSubmitting {
    func submit(_ draft: FeedbackDraft) async throws
}

typealias FeedbackRequestLoader = (URLRequest) async throws -> (Data, URLResponse)

/// Only 2xx is success; `X-Tungsten-Client: app` is a source marker, not an authentication boundary.
/// No attachments → the JSON body; with attachments → multipart whose `payload` part is the same JSON.
/// A draft without diagnostics must encode byte-for-byte as before: released servers and the
/// backend's validator only know one payload shape.
final class WebsiteFeedbackSubmitter: FeedbackSubmitting {
    static let endpointURL = URL(string: "https://tungstenedge.app/api/feedback")!
    static let requestTimeout: TimeInterval = 15
    /// 带附件时的超时。40MB 走一条慢上行链路可以要好几分钟，15 秒会把本来能成功的
    /// 提交切断，用户看到「无法发送」却查不出任何毛病。
    static let attachmentRequestTimeout: TimeInterval = 300

    private let loader: FeedbackRequestLoader

    init(session: URLSession = .shared) {
        loader = { request in
            try await session.data(for: request)
        }
    }

    /// 测试注入点：假 loader 验请求内容与各种响应，不碰真网络。
    init(loader: @escaping FeedbackRequestLoader) {
        self.loader = loader
    }

    func submit(_ draft: FeedbackDraft) async throws {
        let payload = try Self.encodedPayload(for: draft)
        let request = draft.attachments.isEmpty
            ? Self.jsonRequest(payload: payload)
            : try Self.multipartRequest(payload: payload, attachments: draft.attachments)

        let (data, response) = try await loader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            // 失败才读 body：服务端给一个机器可读的 code（就是它那边的 i18n key），
            // App 靠它把两种 429 分开。读不出来就当没有，绝不因为解析失败改变判定。
            throw FeedbackError.httpStatus(httpResponse.statusCode, code: Self.errorCode(in: data))
        }
        // 2xx 即成功：D1-first，服务端已经收下了。**这条路不碰响应体**——
        // body 解析失败也仍是成功（同订阅那条承重规则）。
    }

    /// 宽松解析失败响应里的 `code`。任何异常都退化成 nil，让调用方回落到状态码判断。
    private static func errorCode(in data: Data) -> String? {
        guard !data.isEmpty,
              let body = try? JSONDecoder().decode(ErrorBody.self, from: data),
              let code = body.code,
              !code.isEmpty
        else { return nil }
        return code
    }

    /// Nil diagnostics must be omitted so existing requests remain byte-identical.
    private static func encodedPayload(for draft: FeedbackDraft) throws -> Data {
        let body = RequestBody(
            appVersion: draft.appVersion,
            contact: draft.contact,
            diagnostics: draft.diagnostics,
            lang: draft.lang,
            macosVersion: draft.macosVersion,
            message: draft.message
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    /// ⚠️ 无附件的这条路**逐字节不许变**：已经发出去的版本一直在用它，服务端的
    /// JSON 分支也照着它写；`FeedbackSubmitterTests` 锁着它的形状。
    private static func jsonRequest(payload: Data) -> URLRequest {
        var request = URLRequest(url: endpointURL, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            WebsiteSubscriptionSubmitter.clientHeaderValue,
            forHTTPHeaderField: WebsiteSubscriptionSubmitter.clientHeaderField
        )
        request.httpBody = payload
        return request
    }

    /// `payload` + `file0..file2`。文件内容在**发送这一刻**才读——选完到点发送之间
    /// 用户可能把文件删了或移走了，那种情况整单失败（草稿含附件列表不清空，可以重试）。
    private static func multipartRequest(payload: Data, attachments: [FeedbackAttachment]) throws -> URLRequest {
        var form = MultipartFormBody()
        form.append(field: "payload", value: String(decoding: payload, as: UTF8.self))
        for (index, attachment) in attachments.enumerated() {
            guard let data = try? Data(contentsOf: attachment.url), !data.isEmpty else {
                throw FeedbackError.attachmentUnreadable
            }
            form.append(
                file: "file\(index)",
                filename: attachment.name,
                mimeType: attachment.mimeType,
                data: data
            )
        }

        var request = URLRequest(url: endpointURL, timeoutInterval: attachmentRequestTimeout)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            WebsiteSubscriptionSubmitter.clientHeaderValue,
            forHTTPHeaderField: WebsiteSubscriptionSubmitter.clientHeaderField
        )
        request.httpBody = form.encoded()
        return request
    }

    private struct ErrorBody: Decodable {
        let code: String?
    }

    private struct RequestBody: Encodable {
        let appVersion: String?
        let contact: String?
        let diagnostics: String?
        let lang: String
        let macosVersion: String?
        let message: String
    }
}

enum FeedbackError: LocalizedError, Equatable {
    case invalidResponse
    /// `code` 是服务端 `/api/feedback` 在错误响应里给的 i18n key，取不到就是 nil。
    case httpStatus(Int, code: String?)
    case attachmentUnreadable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "The feedback server returned an invalid response.")
        case .httpStatus(let status, _):
            return String(format: String(localized: "The feedback server returned status code %d."), status)
        case .attachmentUnreadable:
            return String(localized: "One of the attachments could not be read.")
        }
    }
}

/// 发送失败的六种成因。**每种的下一步动作都不一样**，所以才分开——
/// 2026-08-24 之前全压成一句「检查网络」，而 owner 第一次真发就撞上限流，
/// 被那句话指向了完全错误的方向。
///
/// 服务端的 code 优先于状态码：两种 429（每小时限流 / 附件通道今日已满）
/// 状态码相同但说法完全不同，`feedback_attachment_quota` 必须先认出来。
enum FeedbackFailure: Equatable {
    case offline
    case rateLimited
    case attachmentQuota
    case rejected
    case serverUnavailable
    case attachmentUnreadable

    init(error: Error) {
        switch error {
        case let feedbackError as FeedbackError:
            self = Self.from(feedbackError)
        case is URLError:
            // 连不上、超时、断线全归这一类：用户能做的事都是一样的。
            self = .offline
        default:
            self = .serverUnavailable
        }
    }

    private static func from(_ error: FeedbackError) -> FeedbackFailure {
        switch error {
        case .attachmentUnreadable:
            return .attachmentUnreadable
        case .invalidResponse:
            return .serverUnavailable
        case .httpStatus(let status, let code):
            if code == "feedback_attachment_quota" { return .attachmentQuota }
            switch status {
            case 429: return .rateLimited
            case 400, 413: return .rejected
            default: return .serverUnavailable
            }
        }
    }
}

/// 在飞守卫（同订阅的 `SubscriptionSubmitState`）：连点两下不能发两次。
struct FeedbackSubmitState {
    private(set) var isSubmitting = false

    var presentation: FeedbackSubmitPresentation {
        if isSubmitting {
            return FeedbackSubmitPresentation(title: String(localized: "Sending…"), isEnabled: false)
        }
        return FeedbackSubmitPresentation(title: String(localized: "Send"), isEnabled: true)
    }

    mutating func begin() -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        return true
    }

    mutating func finish() {
        isSubmitting = false
    }
}

struct FeedbackSubmitPresentation: Equatable {
    let title: String
    let isEnabled: Bool
}

/// 反馈结果的**文案单一来源**，纯值类型、可单测（同 `SubscriptionAlertContent` 的套路）。
struct FeedbackAlertContent: Equatable {
    let title: String
    let message: String
    let isWarning: Bool
    /// 真送达才 true：调用方据此决定要不要清空输入框。
    let didSend: Bool

    init(title: String, message: String, isWarning: Bool = false, didSend: Bool = false) {
        self.title = title
        self.message = message
        self.isWarning = isWarning
        self.didSend = didSend
    }

    init(rejection: FeedbackDraftCheck.Rejection) {
        switch rejection {
        case .emptyMessage:
            self.init(
                title: String(localized: "Message Is Empty"),
                message: String(localized: "Write something first."),
                isWarning: true
            )
        case .messageTooLong:
            self.init(
                title: String(localized: "Message Is Too Long"),
                message: String(localized: "Keep it under 2000 characters."),
                isWarning: true
            )
        case .contactTooLong:
            self.init(
                title: String(localized: "Contact Is Too Long"),
                message: String(localized: "Keep it under 120 characters."),
                isWarning: true
            )
        }
    }

    /// 选文件当场被拒的四种情况。**都在本地判掉，不发请求**——40MB 传上去再被 400
    /// 拒回来，用户等的那几分钟是白等的。
    init(attachmentRejection: FeedbackAttachmentCheck.Rejection) {
        switch attachmentRejection {
        case .tooMany:
            self.init(
                title: String(localized: "Too Many Attachments"),
                message: String(localized: "You can attach up to 3 files. Remove one first."),
                isWarning: true
            )
        case .unsupportedType:
            self.init(
                title: String(localized: "File Type Not Supported"),
                message: String(localized: "Attach a screenshot (PNG, JPEG, GIF, HEIC) or a screen recording (MOV, MP4)."),
                isWarning: true
            )
        case .tooLarge(.image):
            self.init(
                title: String(localized: "Image Is Too Large"),
                message: String(localized: "Each image must be 10 MB or smaller."),
                isWarning: true
            )
        case .tooLarge(.video):
            self.init(
                title: String(localized: "Video Is Too Large"),
                message: String(localized: "Each video must be 30 MB or smaller."),
                isWarning: true
            )
        case .totalTooLarge:
            self.init(
                title: String(localized: "Attachments Are Too Large"),
                message: String(localized: "All attachments together must be 40 MB or smaller."),
                isWarning: true
            )
        case .unreadable:
            self.init(
                title: String(localized: "Can’t Read That File"),
                message: String(localized: "The file could not be read. Try choosing it again."),
                isWarning: true
            )
        }
    }

    static let sent = FeedbackAlertContent(
        title: String(localized: "Feedback Sent"),
        message: String(localized: "Thanks — we read every message."),
        didSend: true
    )

    /// 六种失败各说各的下一步（owner 2026-08-24 定）。刻意**不写具体数字**
    /// （「每小时 5 条」「每天 3 单」）：那是服务端常量，写进 App 文案迟早漂。
    init(failure: FeedbackFailure) {
        switch failure {
        case .offline:
            // 沿用 2026-08-24 之前那条通用文案的两个 key——它本来就是照网络故障写的。
            self = .failure
        case .rateLimited:
            self.init(
                title: String(localized: "Sending Too Often"),
                message: String(localized: "You’ve sent too many messages in a short time. Try again in a little while — your message and attachments are still here."),
                isWarning: true
            )
        case .attachmentQuota:
            self.init(
                title: String(localized: "Attachment Limit Reached for Today"),
                message: String(localized: "Today’s attachment allowance is used up. Remove the attachments to send just the text, try again tomorrow, or email support@tungstenedge.app."),
                isWarning: true
            )
        case .rejected:
            self.init(
                title: String(localized: "The Server Didn’t Accept It"),
                message: String(localized: "Your message or attachments were not accepted. Try shortening the message or using a different file, or email support@tungstenedge.app."),
                isWarning: true
            )
        case .serverUnavailable:
            self.init(
                title: String(localized: "Feedback Is Unavailable"),
                message: String(localized: "The feedback service is temporarily unavailable. Try again later, or email support@tungstenedge.app."),
                isWarning: true
            )
        case .attachmentUnreadable:
            self.init(
                title: String(localized: "An Attachment Can’t Be Read"),
                message: String(localized: "It may have been moved or deleted. Remove it and add it again."),
                isWarning: true
            )
        }
    }

    /// 网络不通时的文案，也是 `FeedbackFailure.offline` 的落点。
    static let failure = FeedbackAlertContent(
        title: String(localized: "Can’t Send Right Now"),
        message: String(localized: "Check your network connection and try again, or email support@tungstenedge.app."),
        isWarning: true
    )
}
