import Foundation

struct IdentityRuleResult {
    let accepted: Bool
    let normalizedTitle: String?
    let fallbackIdentity: IdentityFallback?
}

protocol IdentityRule {
    func apply(to observation: SystemObservation) -> IdentityRuleResult
}

struct IdentityFallback {
    let windowID: WindowID
    let confidence: Confidence
    let reason: String
}

struct IdentityRuleEngine {
    private let rules: [IdentityRule] = [
        FinderIdentityRule(),
        ChromiumIdentityRule(),
        WeChatIdentityRule(),
        FeishuIdentityRule()
    ]

    func evaluate(_ observation: SystemObservation) -> IdentityRuleResult {
        for rule in rules {
            let result = rule.apply(to: observation)
            if result.accepted == false || result.normalizedTitle != nil {
                return result
            }
        }

        return IdentityRuleResult(
            accepted: true,
            normalizedTitle: normalizedTitle(observation.title),
            fallbackIdentity: nil
        )
    }

    private func normalizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

private struct FinderIdentityRule: IdentityRule {
    func apply(to observation: SystemObservation) -> IdentityRuleResult {
        guard observation.bundleIdentifier == "com.apple.finder" else {
            return IdentityRuleResult(accepted: true, normalizedTitle: nil, fallbackIdentity: nil)
        }
        return IdentityRuleResult(
            accepted: true,
            normalizedTitle: normalizedTitle(observation.title) ?? "finder-window",
            fallbackIdentity: nil
        )
    }

    private func normalizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

private struct ChromiumIdentityRule: IdentityRule {
    private let bundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev"
    ]

    func apply(to observation: SystemObservation) -> IdentityRuleResult {
        guard let bundleIdentifier = observation.bundleIdentifier,
              bundleIDs.contains(bundleIdentifier) else {
            return IdentityRuleResult(accepted: true, normalizedTitle: nil, fallbackIdentity: nil)
        }

        return IdentityRuleResult(
            accepted: true,
            normalizedTitle: normalizedChromiumTitle(observation.title) ?? "chromium-window",
            fallbackIdentity: nil
        )
    }

    private func normalizedChromiumTitle(_ title: String?) -> String? {
        guard var normalized = normalizedTitle(title) else { return nil }

        normalized = normalized.replacingOccurrences(
            of: #" - 属于“[^”]+”群组"#,
            with: "",
            options: .regularExpression
        )

        let browserSuffixes = [
            " - google chrome canary",
            " - google chrome beta",
            " - google chrome dev",
            " - google chrome"
        ]

        for suffix in browserSuffixes where normalized.hasSuffix(suffix) {
            normalized.removeLast(suffix.count)
            break
        }

        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

private struct WeChatIdentityRule: IdentityRule {
    private let bundleID = "com.tencent.xinWeChat"
    private let contentTitles: Set<String> = [
        "收藏",
        "favorites",
        "朋友圈",
        "moments",
        "图片和视频",
        "images and videos"
    ]

    func apply(to observation: SystemObservation) -> IdentityRuleResult {
        guard observation.bundleIdentifier == bundleID else {
            return IdentityRuleResult(accepted: true, normalizedTitle: nil, fallbackIdentity: nil)
        }

        let normalized = normalizedTitle(observation.title)
        if let normalized, contentTitles.contains(normalized) {
            return IdentityRuleResult(accepted: false, normalizedTitle: normalized, fallbackIdentity: nil)
        }

        return IdentityRuleResult(
            accepted: true,
            normalizedTitle: normalized ?? "wechat-window",
            fallbackIdentity: nil
        )
    }

    private func normalizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

private struct FeishuIdentityRule: IdentityRule {
    private let bundleIDs: Set<String> = ["com.electron.lark", "com.feishu.app"]

    func apply(to observation: SystemObservation) -> IdentityRuleResult {
        guard let bundleIdentifier = observation.bundleIdentifier,
              bundleIDs.contains(bundleIdentifier) else {
            return IdentityRuleResult(accepted: true, normalizedTitle: nil, fallbackIdentity: nil)
        }

        if shouldFallbackToAppLevel(observation) {
            return IdentityRuleResult(
                accepted: true,
                normalizedTitle: normalizedTitle(observation.title) ?? "feishu-app",
                fallbackIdentity: IdentityFallback(
                    windowID: WindowID(rawValue: "app-\(bundleIdentifier)"),
                    confidence: .medium,
                    reason: "feishu-app-fallback"
                )
            )
        }

        return IdentityRuleResult(
            accepted: true,
            normalizedTitle: normalizedTitle(observation.title) ?? "feishu-window",
            fallbackIdentity: nil
        )
    }

    private func shouldFallbackToAppLevel(_ observation: SystemObservation) -> Bool {
        let normalized = normalizedTitle(observation.title)

        if normalized == nil {
            return true
        }

        if normalized == "飞书" {
            return true
        }

        if observation.source == .accessibility && observation.bounds == nil {
            return true
        }

        return false
    }

    private func normalizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}
