import AppKit
import Foundation

/// Ordered list of "messaging" apps whose chips pin to the leftmost strip zone and
/// persist while the app is running, even with all windows closed. Chips disappear
/// on app quit (the future drawer "待启动区" will take over the not-running role).
///
/// Membership has two tiers with identical behavior:
/// - Auto: built-in whitelist + `LSApplicationCategoryType == social-networking`,
///   registered the first time the app is seen running (`autoRegister`).
/// - Manual: right-click「标记为消息应用」, the fallback for apps the whitelist misses.
///
/// The messaging flag is permanent until explicitly unmarked — moving an app to the
/// drawer hides it from the strip but does NOT clear the flag (drawer is the
/// "I don't want it pinned" escape hatch). Unmarking an auto-detected app records an
/// opt-out so it isn't silently re-registered next round.
///
/// `bundleIDs` stays an ordered array: pinned-zone order is muscle memory, and the
/// future strip drag-reorder will reorder this array (same shape as `DrawerStore`).
final class MessagingAppStore: ObservableObject {
    @Published private(set) var bundleIDs: [String] = []
    private var optOutIDs: Set<String> = []
    private let key = "messagingBundleIDs"
    private let optOutKey = "messagingOptOutBundleIDs"

    /// Built-in messaging app whitelist. Wrong/stale IDs are harmless (they never
    /// match a running app); the social-networking category check below catches
    /// messengers this list misses.
    static let builtinMessagingIDs: Set<String> = [
        "com.tencent.xinWeChat",              // 微信
        "com.tencent.qq",                     // QQ
        "com.tencent.WeWorkMac",              // 企业微信
        "com.alibaba.DingTalkMac",            // 钉钉
        "com.electron.lark",                  // 飞书 / Lark
        "com.apple.MobileSMS",                // 信息（iMessage）
        "ru.keepcoder.Telegram",              // Telegram（Mac App Store 原生版）
        "org.telegram.desktop",               // Telegram Desktop
        "net.whatsapp.WhatsApp",              // WhatsApp
        "com.tinyspeck.slackmacgap",          // Slack
        "com.hnc.Discord",                    // Discord
        "org.whispersystems.signal-desktop",  // Signal
        "jp.naver.line.mac",                  // LINE
        "com.skype.skype",                    // Skype
        "com.microsoft.teams2",               // Microsoft Teams（新版）
        "com.microsoft.teams",                // Microsoft Teams（旧版）
        "com.kakao.KakaoTalkMac",             // KakaoTalk
        "com.facebook.archon",                // Facebook Messenger
        "Mattermost.Desktop",                 // Mattermost
        "chat.rocket",                        // Rocket.Chat
        "im.riot.app",                        // Element
        "com.viber.osx",                      // Viber
    ]

    init() {
        bundleIDs = UserDefaults.standard.stringArray(forKey: key) ?? []
        optOutIDs = Set(UserDefaults.standard.stringArray(forKey: optOutKey) ?? [])
    }

    func contains(_ id: String) -> Bool { bundleIDs.contains(id) }

    /// Manual mark: pins the app and clears any earlier opt-out.
    func mark(_ id: String) {
        guard !id.isEmpty else { return }
        if optOutIDs.remove(id) != nil { persistOptOut() }
        guard !bundleIDs.contains(id) else { return }
        bundleIDs.append(id)
        persist()
    }

    /// Unmark: unpins and opts the app out of auto re-registration.
    func unmark(_ id: String) {
        bundleIDs.removeAll { $0 == id }
        optOutIDs.insert(id)
        persist()
        persistOptOut()
    }

    /// Auto tier: register any running app that looks like a messenger (whitelist or
    /// App Store category) unless the user has opted it out. Called on every snapshot
    /// update; first sight appends to the end of the ordered list.
    func autoRegister(runningBundleIDs: Set<String>) {
        var changed = false
        for id in runningBundleIDs {
            guard !id.isEmpty, !bundleIDs.contains(id), !optOutIDs.contains(id) else { continue }
            guard Self.builtinMessagingIDs.contains(id) || Self.isSocialCategory(id) else { continue }
            bundleIDs.append(id)
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        UserDefaults.standard.set(bundleIDs, forKey: key)
    }

    private func persistOptOut() {
        UserDefaults.standard.set(Array(optOutIDs), forKey: optOutKey)
    }

    // MARK: - Category signal

    private static var socialCategoryCache: [String: Bool] = [:]

    private static func isSocialCategory(_ id: String) -> Bool {
        if let cached = socialCategoryCache[id] { return cached }
        var result = false
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
           let category = Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String {
            result = category == "public.app-category.social-networking"
        }
        socialCategoryCache[id] = result
        return result
    }
}
