import Foundation

/// 定时检查发现了新版之后，这一次要用多大动静告诉用户。
///
/// 纯决策，不碰 Sparkle 也不碰 AppKit，可单测。调用方（`SparkleUpdateService`）负责把
/// 结论翻译成「让不让 Sparkle 开窗」「要不要把 App 抢到前台」「状态栏留不留提示」。
///
/// ## 为什么需要它
///
/// 钨极是 `.accessory` 应用，定时检查发现的更新窗口默认出现在**所有窗口背后**，用户看不见，
/// 所以我们一直无条件把 App 带到前台。这在「一天查一次」时还好，改成 6 小时之后就变成骚扰：
/// 用户关掉窗口，几小时后又被抢一次前台，而他早就知道有新版了。
///
/// 于是分工变成：
///
/// - **同一个版本的第一次**：照旧开窗 + 抢前台，保证用户一定看得见；
/// - **第二次及以后**：不开窗、不抢前台，改由菜单栏图标上的小圆点持续提醒。
///
/// How `.remindQuietly` is carried out matters: the caller aborts that check in
/// `updater(_:shouldProceedWithUpdate:updateCheck:)` so Sparkle's session ends and the next
/// scheduled check still happens. Sparkle's own hook for this
/// (`standardUserDriverShouldHandleShowingScheduledUpdate` returning `NO`) keeps the session
/// open and thereby stops every later check — a newer release would never be noticed.
///
/// 提示本身不归这里管：状态栏那个点从「发现新版」一直留到用户装了、跳过了，或后续检查
/// 发现已经没有更新为止。
enum ScheduledUpdatePresentation {
    enum Outcome: Equatable {
        /// 让 Sparkle 开更新窗口，并且我们把 App 带到前台。**同一版本只会得到一次。**
        case announce
        /// 不开窗、不抢前台，只留状态栏提示 — the check is aborted before any UI so the session ends.
        case remindQuietly
        /// 用户自己点的「检查更新」。Sparkle 保证这条路一定置前，我们不插手。
        case deferToSparkle
    }

    /// - Parameters:
    ///   - version: 这次 appcast item 的版本串（`SUAppcastItem.displayVersionString`）
    ///   - userInitiated: `SPUUserUpdateState.userInitiated`
    ///   - announcedVersion: 已经抢过一次前台的那个版本；`nil` = 本次运行还没抢过
    static func decide(
        version: String,
        userInitiated: Bool,
        announcedVersion: String?
    ) -> Outcome {
        // 用户自己点出来的检查不受影响：重复 activate 没意义，Sparkle 已经置前了。
        guard !userInitiated else { return .deferToSparkle }

        // 这个版本已经当面告诉过他了。再抢一次前台属于骚扰，交给状态栏的小圆点。
        if announcedVersion == version { return .remindQuietly }

        return .announce
    }

    /// Whether Sparkle may run this check at all, asked before it starts (`mayPerform`).
    ///
    /// With automatic downloads on, a downloaded update leaves Sparkle's installer waiting for the
    /// app to quit, and every later *background* check skips the feed and re-opens that same update
    /// window. Once the user has seen it for `readyVersion`, those checks are refused so the window
    /// comes back only from the menu row; refusing ends the session, so nothing is held open, and a
    /// newer release could not be found anyway until the waiting one is installed.
    ///
    /// - Parameters:
    ///   - userInitiated: the menu row and the settings button must always get through
    ///   - readyVersion: the downloaded update waiting for install; `nil` = none
    ///   - announcedVersion: same as in `decide`
    static func allowsCheck(
        userInitiated: Bool,
        readyVersion: String?,
        announcedVersion: String?
    ) -> Bool {
        guard !userInitiated, let readyVersion else { return true }
        return readyVersion != announcedVersion
    }
}
