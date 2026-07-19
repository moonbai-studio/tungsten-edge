import Foundation

struct AppVersion: Comparable, Equatable {
    private let components: [Int]
    private let preRelease: [PreReleaseIdentifier]?

    private enum PreReleaseIdentifier: Equatable {
        case numeric(Int)
        case text(String)

        init?(_ rawValue: Substring) {
            guard !rawValue.isEmpty,
                  rawValue.utf8.allSatisfy({ byte in
                      (48...57).contains(byte)
                          || (65...90).contains(byte)
                          || (97...122).contains(byte)
                          || byte == 45
                  }) else { return nil }

            if rawValue.utf8.allSatisfy({ (48...57).contains($0) }) {
                guard rawValue.count == 1 || rawValue.first != "0" else { return nil }
                guard let value = Int(rawValue) else { return nil }
                self = .numeric(value)
            } else {
                self = .text(String(rawValue))
            }
        }
    }

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }

        let versionParts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !versionParts.isEmpty, !versionParts[0].isEmpty else { return nil }

        let parts = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else { return nil }
            parsed.append(number)
        }

        while parsed.count > 1, parsed.last == 0 {
            parsed.removeLast()
        }
        components = parsed

        if versionParts.count == 2 {
            let identifiers = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty else { return nil }
            var parsedIdentifiers: [PreReleaseIdentifier] = []
            parsedIdentifiers.reserveCapacity(identifiers.count)
            for identifier in identifiers {
                guard let parsedIdentifier = PreReleaseIdentifier(identifier) else { return nil }
                parsedIdentifiers.append(parsedIdentifier)
            }
            preRelease = parsedIdentifiers
        } else {
            preRelease = nil
        }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }

        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (.some(left), .some(right)):
            for index in 0..<min(left.count, right.count) {
                if left[index] == right[index] { continue }
                switch (left[index], right[index]) {
                case let (.numeric(lhs), .numeric(rhs)):
                    return lhs < rhs
                case (.numeric, .text):
                    return true
                case (.text, .numeric):
                    return false
                case let (.text(lhs), .text(rhs)):
                    return lhs < rhs
                }
            }
            return left.count < right.count
        }
    }
}

enum UpdateCheckOutcome: Equatable {
    case updateAvailable(currentVersion: String, latestVersion: String, releaseURL: URL)
    case upToDate(currentVersion: String, latestVersion: String)
}

protocol UpdateChecking {
    func check(currentVersion: String) async throws -> UpdateCheckOutcome
}

typealias UpdateRequestLoader = (URLRequest) async throws -> (Data, URLResponse)

final class GitHubUpdateChecker: UpdateChecking {
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/moonbai-studio/tungsten-edge/releases/latest")!
    static let releasesURL = URL(string: "https://github.com/moonbai-studio/tungsten-edge/releases")!
    static let requestTimeout: TimeInterval = 10

    private let loader: UpdateRequestLoader

    init(session: URLSession = .shared) {
        loader = { request in
            try await session.data(for: request)
        }
    }

    init(loader: @escaping UpdateRequestLoader) {
        self.loader = loader
    }

    func check(currentVersion: String) async throws -> UpdateCheckOutcome {
        guard let installedVersion = AppVersion(currentVersion) else {
            throw UpdateCheckError.invalidCurrentVersion
        }

        var request = URLRequest(url: Self.latestReleaseAPIURL, timeoutInterval: Self.requestTimeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tungsten-Edge/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await loader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }

        let release = try JSONDecoder().decode(LatestRelease.self, from: data)
        guard let latestVersion = AppVersion(release.tagName) else {
            throw UpdateCheckError.invalidLatestVersion
        }

        if installedVersion < latestVersion {
            return .updateAvailable(
                currentVersion: currentVersion,
                latestVersion: release.tagName,
                releaseURL: release.htmlURL
            )
        }
        return .upToDate(currentVersion: currentVersion, latestVersion: release.tagName)
    }
}

private struct LatestRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

enum UpdateCheckError: LocalizedError, Equatable {
    case invalidCurrentVersion
    case invalidLatestVersion
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion:
            return "无法读取当前版本号。"
        case .invalidLatestVersion:
            return "最新版本号格式无效。"
        case .invalidResponse:
            return "更新服务器返回了无效响应。"
        case .httpStatus(let status):
            return "更新服务器返回状态码 \(status)。"
        }
    }
}

struct UpdateCheckMenuPresentation: Equatable {
    let title: String
    let isEnabled: Bool
}

struct UpdateCheckMenuState {
    private(set) var isCheckingUpdates = false

    var presentation: UpdateCheckMenuPresentation {
        if isCheckingUpdates {
            return UpdateCheckMenuPresentation(title: "正在检查更新…", isEnabled: false)
        }
        return UpdateCheckMenuPresentation(title: "检查更新…", isEnabled: true)
    }

    mutating func begin() -> Bool {
        guard !isCheckingUpdates else { return false }
        isCheckingUpdates = true
        return true
    }

    mutating func finish() {
        isCheckingUpdates = false
    }
}
