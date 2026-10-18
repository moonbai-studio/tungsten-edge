import AppKit
import Foundation

/// Ordered list of apps pinned to the leftmost strip zone (the messaging zone) — they
/// persist even after app exit. Drawer placement may hide the chip without clearing
/// this zone membership.
///
/// **Two concepts, split on 2026-08-23 (owner): "is a messaging app" vs "is in the zone".**
/// - *Identity* (`isMessagingApp`): whitelist ∪ social-networking category ∪ manual pin,
///   supplies the default for **unread badges**, wherever the app's card happens to be.
/// - *Badge preference* (`badgeOverrides`): explicit on/off overrides that default,
///   without changing identity or placement.
/// - *Zone membership* (`bundleIDs`): decides the pinned-zone chip. Auto-entry still
///   requires an identifiable main window (`autoRegister`); everything else is manual
///   (right-click「固定在 Dock 栏左侧」, the fallback for apps the whitelist misses).
/// Overseas messengers (信息 / Slack / Discord …) are single-window apps that never pass
/// the zone gate — the badge is what they actually need, so it must not depend on the zone.
///
/// The messaging flag is permanent until explicitly unmarked — moving an app to the
/// drawer hides it from the strip but does NOT clear the flag (drawer is the
/// "I don't want it pinned" escape hatch). Unmarking an auto-detected app records an
/// opt-out so it isn't silently re-registered next round.
///
/// `bundleIDs` stays an ordered array: pinned-zone order is muscle memory, and the
/// future strip drag-reorder will reorder this array (same shape as `DrawerStore`).
@MainActor
final class MessagingAppStore: ObservableObject {
    @Published private(set) var bundleIDs: [String] = []
    /// 显式角标选择独立于左侧固定；未设置的应用沿用原来的消息应用默认值。
    @Published private(set) var badgeOverrides: [String: Bool] = [:]
    private var optOutIDs: Set<String> = []
    private let key = "messagingBundleIDsV2"
    private let optOutKey = "messagingOptOutBundleIDsV2"
    private let legacyKey = "messagingBundleIDs"
    private let legacyOptOutKey = "messagingOptOutBundleIDs"
    private let defaults: UserDefaults
    private let badgeOverridesKey = "unreadBadgeOverridesV1"

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        badgeOverrides = defaults.dictionary(forKey: badgeOverridesKey) as? [String: Bool] ?? [:]
        // Name list V2: migrate from the frozen legacy key once, then own V2.
        // Empty is also persisted — key existence is the migration marker.
        if defaults.object(forKey: key) != nil {
            bundleIDs = defaults.stringArray(forKey: key) ?? []
        } else {
            bundleIDs = defaults.stringArray(forKey: legacyKey) ?? []
            defaults.set(bundleIDs, forKey: key)
        }
        // Opt-out V2 migrates independently (supports a one-migrated-one-not state).
        if defaults.object(forKey: optOutKey) != nil {
            optOutIDs = Set(defaults.stringArray(forKey: optOutKey) ?? [])
        } else {
            optOutIDs = Set(defaults.stringArray(forKey: legacyOptOutKey) ?? [])
            defaults.set(Array(optOutIDs), forKey: optOutKey)
        }
    }

    func contains(_ id: String) -> Bool { bundleIDs.contains(id) }

    /// 消息应用**身份**（决定角标），与「在不在消息区」无关：名单里的 / 内置白名单 /
    /// App Store 社交类目。类目误判（Ghostty 之类）没有副作用——它在系统 Dock 上没有
    /// 角标，读出来是空。
    ///
    /// **不看 opt-out**（2026-08-23 验收回炉：owner 早先把信息从区里取消过，红点就没了）：
    /// 菜单项叫「固定在 Dock 栏左侧」，取消它只能表达「别钉在区里」，表达不了「这不是消息应用」；
    /// opt-out 的职责只剩「别自动再钉回去」（`autoRegister`）。
    ///
    /// 读的是 store 当前状态：调用方必须在发布完成后再读（`@Published` 在赋值前发布，
    /// `AppDelegate` 的订阅走 `receive(on: .main)` 异步派发，所以安全）。
    func isMessagingApp(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return bundleIDs.contains(id)
            || Self.builtinMessagingIDs.contains(id)
            || Self.isSocialCategory(id)
    }

    func showsUnreadBadge(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return badgeOverrides[id] ?? isMessagingApp(id)
    }

    /// 即使选择与当前默认值一致也保留，后续固定/取消固定不能覆盖用户的显式选择。
    func setShowsUnreadBadge(_ id: String, enabled: Bool) {
        guard !id.isEmpty, badgeOverrides[id] != enabled else { return }
        badgeOverrides[id] = enabled
        defaults.set(badgeOverrides, forKey: badgeOverridesKey)
    }

    /// Manual mark: pins the app and clears any earlier opt-out. Returns whether
    /// this was the first join, so the caller seeds kept on first join only.
    @discardableResult
    func mark(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        if optOutIDs.remove(id) != nil { persistOptOut() }
        guard !bundleIDs.contains(id) else { return false }
        bundleIDs.append(id)
        persist()
        return true
    }

    /// Unmark: unpins and opts the app out of auto re-registration.
    func unmark(_ id: String) {
        bundleIDs.removeAll { $0 == id }
        optOutIDs.insert(id)
        persist()
        persistOptOut()
    }

    /// Strip messaging-zone drag reorder: move `draggedID` to the left/right of `targetID`
    /// (same shape as `DrawerOrderStore.reorder`). Operates on the full persisted array —
    /// hidden members (stashed in drawer / not running) keep their relative positions.
    /// Callers guarantee both ids are currently visible zone chips.
    func reorder(draggedID: String, relativeTo targetID: String, after: Bool) {
        guard draggedID != targetID,
              let from = bundleIDs.firstIndex(of: draggedID) else { return }
        var next = bundleIDs
        next.remove(at: from)
        guard let t = next.firstIndex(of: targetID) else { return }
        next.insert(draggedID, at: after ? t + 1 : t)
        if next != bundleIDs {
            bundleIDs = next
            persist()
        }
    }

    /// Auto tier: register a running app that both **looks like** a messenger (whitelist or
    /// App Store category) and **can be represented** in the zone — i.e. we can currently
    /// identify its main window. Called on every snapshot update; first sight appends to the
    /// end of the ordered list. Returns the ids newly added this round so the caller seeds
    /// kept on first registration only.
    ///
    /// The capability gate is what keeps Apple 信息 out: it is a Mac Catalyst app whose window
    /// title is a UIScene session id, so it can **never** title-match and the zone chip would
    /// be a launcher that only wakes and never collapses. Same for terminals like Ghostty that
    /// trip the social-networking category.
    ///
    /// Registration is **once-and-for-all**: the persisted list itself is the "has qualified"
    /// record, so a member is never re-tested after joining. Re-testing every round would drop
    /// 微信 out of the zone whenever its main window is closed (only 「笔记」 left → no title
    /// match) and put it back on reopen — zone flapping that would also break the owner's daily
    /// "main window closed → click the zone icon to wake it" flow.
    @discardableResult
    func autoRegister(runningBundleIDs: Set<String>,
                      mainWindowIdentifiableBundleIDs: Set<String>) -> [String] {
        var added: [String] = []
        for id in runningBundleIDs {
            guard !id.isEmpty, !bundleIDs.contains(id), !optOutIDs.contains(id) else { continue }
            guard Self.builtinMessagingIDs.contains(id) || Self.isSocialCategory(id) else { continue }
            guard mainWindowIdentifiableBundleIDs.contains(id) else { continue }
            bundleIDs.append(id)
            added.append(id)
        }
        if !added.isEmpty { persist() }
        return added
    }

    private func persist() {
        defaults.set(bundleIDs, forKey: key)
    }

    private func persistOptOut() {
        defaults.set(Array(optOutIDs), forKey: optOutKey)
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
