import Foundation

/// 邮箱地址的**宽松**格式检查。
///
/// 只用来挡住明显打错的输入、省掉一次没意义的往返，**不是校验**——真正的判定在服务端
/// 和 Buttondown 那边（它还有一次性邮箱与保留域名的永久黑名单）。写严了只会误伤合法地址：
/// 真实世界的邮箱地址比大多数人以为的宽松得多。
enum EmailAddressCheck {
    /// RFC 5321 的地址上限，和服务端那道校验保持同一个数字。
    static let maximumLength = 254

    static func looksValid(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        guard !value.contains(" ") else { return false }

        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty else { return false }
        // 域名至少要有一个点，且点不在两端。
        guard domain.contains("."), domain.first != ".", domain.last != "." else { return false }
        return true
    }
}

enum SubscriptionOutcome: Equatable {
    /// 新建成功。Buttondown 会先发一封确认邮件，用户点了才算数。
    case created
    /// 这个邮箱已经在名单里。对用户来说不是错误，照成功收场。
    case alreadySubscribed
}

protocol SubscriptionSubmitting {
    func submit(email: String, firstLaunchDate: Date?) async throws -> SubscriptionOutcome
}

typealias SubscriptionRequestLoader = (URLRequest) async throws -> (Data, URLResponse)

/// 把邮箱提交到官网的 `/api/subscribe`（Cloudflare Pages Function，再转给 Buttondown）。
///
/// **App 不直接调 Buttondown**：那需要把 API 密钥放进客户端，等于公开发布它。
/// 官网那个接口是唯一持有密钥的地方。
final class WebsiteSubscriptionSubmitter: SubscriptionSubmitting {
    static let endpointURL = URL(string: "https://tungstenedge.app/api/subscribe")!
    static let requestTimeout: TimeInterval = 15

    /// ⚠️ **这个头不是安全校验，别把它当成安全校验。**
    ///
    /// 服务端要求「有 Origin 就按白名单校验；没有 Origin 就必须带这个头」。`Origin` 有用是
    /// 因为浏览器强制附加、页面脚本改不掉，所以它挡得住「别的网站放个表单往我们接口提交」；
    /// 而自定义头谁都能伪造，所以这条通路**不提供任何安全性**，它只是让原生请求走得通、
    /// 顺便标出来源。真正的防护始终是服务端的 honeypot + Buttondown 双重确认 + 黑名单。
    ///
    /// 所以**不要**把它升级成一个"密钥"式的固定 token 来假装安全：那个 token 会随 App 发布
    /// 给每一个用户，一样是公开的，只是看起来更像回事。
    static let clientHeaderField = "X-Tungsten-Client"
    static let clientHeaderValue = "app"

    private let loader: SubscriptionRequestLoader

    init(session: URLSession = .shared) {
        loader = { request in
            try await session.data(for: request)
        }
    }

    /// 测试注入点：给一个假 loader 就能验请求内容与各种响应，不碰真网络。
    init(loader: @escaping SubscriptionRequestLoader) {
        self.loader = loader
    }

    func submit(email: String, firstLaunchDate: Date?) async throws -> SubscriptionOutcome {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard EmailAddressCheck.looksValid(trimmed) else {
            throw SubscriptionError.invalidEmail
        }

        var request = URLRequest(url: Self.endpointURL, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.clientHeaderValue, forHTTPHeaderField: Self.clientHeaderField)

        let body = RequestBody(
            email: trimmed,
            source: Self.clientHeaderValue,
            firstLaunch: firstLaunchDate.map(Self.dayString(from:))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await loader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SubscriptionError.httpStatus(httpResponse.statusCode)
        }

        // 服务端给的是 `status: "created" | "existing"`。**解不出来时按 created 处理**——
        // 请求已经 2xx 了，说明名单那边确实收下了，这时候报错等于把成功说成失败。
        let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data)
        return decoded?.status == "existing" ? .alreadySubscribed : .created
    }

    /// 首装日期只取到「日」。时分秒对"是不是原始用户"这个判断没有意义，
    /// 少传一点是一点。用固定 locale，免得跟着系统语言变出别的格式。
    static func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private struct RequestBody: Encodable {
        let email: String
        let source: String
        let firstLaunch: String?
    }

    private struct ResponseBody: Decodable {
        let status: String?
    }
}

enum SubscriptionError: LocalizedError, Equatable {
    case invalidEmail
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return String(localized: "The email address is not valid.")
        case .invalidResponse:
            return String(localized: "The subscription server returned an invalid response.")
        case .httpStatus(let status):
            return String(format: String(localized: "The subscription server returned status code %d."), status)
        }
    }
}

struct SubscriptionSubmitPresentation: Equatable {
    let title: String
    let isEnabled: Bool
}

/// 在飞守卫。和检查更新那个 `UpdateCheckMenuState` 是同一套路：
/// 连点两下不能发两次请求。
struct SubscriptionSubmitState {
    private(set) var isSubmitting = false

    var presentation: SubscriptionSubmitPresentation {
        if isSubmitting {
            return SubscriptionSubmitPresentation(title: String(localized: "Submitting…"), isEnabled: false)
        }
        return SubscriptionSubmitPresentation(title: String(localized: "Subscribe"), isEnabled: true)
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

/// 订阅结果的**文案单一来源**，纯值类型、可单测。
struct SubscriptionAlertContent: Equatable {
    let title: String
    let message: String
    let isWarning: Bool
    /// 只有真正写进名单了才算数：调用方据此决定要不要把「已订阅」记到本地。
    let didSubscribe: Bool

    init(title: String, message: String, isWarning: Bool = false, didSubscribe: Bool = false) {
        self.title = title
        self.message = message
        self.isWarning = isWarning
        self.didSubscribe = didSubscribe
    }

    init(outcome: SubscriptionOutcome) {
        switch outcome {
        case .created:
            self.init(
                title: String(localized: "Subscribed"),
                // 双重确认是 Buttondown 的默认流程，不点确认信是不会真正进名单的，
                // 所以这句必须说出来，否则用户会以为已经完事了。
                message: String(localized: "Check your inbox and click the confirmation link to finish subscribing."),
                didSubscribe: true
            )
        case .alreadySubscribed:
            self.init(
                title: String(localized: "You’re Already Subscribed"),
                message: String(localized: "This address is already on the list. Your license will be sent straight to it."),
                didSubscribe: true
            )
        }
    }

    static let invalidEmail = SubscriptionAlertContent(
        title: String(localized: "Invalid Email Address"),
        message: String(localized: "Check whether there is a typo."),
        isWarning: true
    )

    static let failure = SubscriptionAlertContent(
        title: String(localized: "Can’t Subscribe Right Now"),
        message: String(localized: "Check your network connection and try again, or leave your address on tungstenedge.app."),
        isWarning: true
    )
}
