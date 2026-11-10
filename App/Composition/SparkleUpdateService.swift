import AppKit
import Combine
import OSLog
import Sparkle

/// Sparkle 的薄封装。**两个界面入口（状态栏菜单 / 设置窗口）只认这一个对象**，
/// 别让 `SPUStandardUpdaterController` 散到三处去——这是原来 `UpdateCheckMenuState`
/// 把"在飞守卫"放在共享层的同一条纪律，理由也一样：各写一份迟早会漂。
///
/// ## 为什么必须实现 gentle reminders
///
/// 钨极是 `.accessory` 应用（没有程序坞图标）。Sparkle 自己的头文件
///（`SPUStandardUserDriverDelegate.h`）写死了这种应用的默认行为：
///
/// > For background running applications, when `immediateFocus` is `NO` the standard user
/// > driver will always want to show the update alert immediately, **but behind other
/// > running applications**.
///
/// 也就是说**定时检查**发现新版时，更新窗口会安安静静地出现在所有窗口背后，用户根本看不见。
/// 这和 2026-07-29 那位真实用户报的「检查更新失效」是同一个坑——那次是 `NSAlert` 没先
/// `activate`，修法是 `runModalInForeground`；这次换了个框架，病因一模一样。
///
/// 所以这里声明支持 gentle reminders，并在真正要展示更新时把 App 带到前台。
/// 用户主动点「检查更新」的那条路不受影响（Sparkle 保证用户发起的检查一定置前）。
///
/// ## Why the quiet re-sighting aborts the session instead of hiding the window
///
/// Sparkle's own gentle-reminder hook (`standardUserDriverShouldHandleShowingScheduledUpdate`
/// returning `NO`) keeps the update session *open* — the alert exists but is not shown, so the
/// delegate's reminder can bring it back with `checkForUpdates`. An open session also blocks
/// every later scheduled check (`SPUUpdater` only schedules the next one when a session ends),
/// so a user who dismissed the alert once never heard about a newer release until relaunch.
/// The 「same version, one interruption」 rule therefore lives in
/// `updater(_:shouldProceedWithUpdate:updateCheck:)`: throwing there aborts the session before
/// any UI, Sparkle schedules the next check as usual, and the menu-bar badge keeps reminding.
///
/// ## Automatic downloads: one window, then the menu row
///
/// With `automaticallyDownloadsUpdates` on, a background check downloads silently and leaves
/// Sparkle's installer waiting; Sparkle **always** installs it when the app quits (by design, not
/// switchable). We decline `willInstallUpdateOnQuit`'s immediate-install block — taking it holds
/// the session open and Sparkle can no longer show its update window, so release notes would never
/// be seen. Instead, when that cycle ends we start one more background check, which resumes the
/// waiting installer and shows the window once with 「安装并重启应用 / 退出应用时安装」. Later background
/// checks skip the feed and re-open that same window (weekly while an installer waits, every check
/// for a download still awaiting an administrator password), so `mayPerform` refuses them once it
/// was shown; the menu row (a user-initiated check) brings it back.
@MainActor
final class SparkleUpdateService: NSObject, ObservableObject, UpdateControlling {
    /// Sparkle 是否处于可以发起检查的状态（正在检查、正在下载时为 false）。
    /// 两个界面的「检查更新」按钮都读它，取代原来手写的在飞守卫。
    @Published private(set) var canCheckForUpdates = false

    /// 定时检查发现的、还没被处理掉的新版版本号（`nil` = 没有）。状态栏靠它决定
    /// 图标上要不要点那个小圆点、菜单里那条写「检查更新…」还是「安装 0.9.2…」。
    ///
    /// ⚠️ **不要在「用户瞄了一眼更新窗口」时清掉它**。原来的写法是收到
    /// `standardUserDriverDidReceiveUserAttention` 就清，于是用户关掉窗口之后界面上
    /// 一点痕迹都不留——owner 2026-08-20 报的「没有主动推送」有一半是这么来的。
    /// 它只在**用户真的做了选择**（装了 / 跳过了）或**后续检查发现已经没有更新**时才撤。
    @Published private(set) var pendingUpdateVersion: String?

    /// `pendingUpdateVersion`'s installer is prepared and waits for a relaunch (the menu row then says
    /// 「重启以更新到 …」). Only Sparkle's `.installing` stage counts: a `.downloaded` update that still
    /// needs an administrator password is not ready. Cleared together with `pendingUpdateVersion`.
    @Published private(set) var isPendingUpdateReadyToInstall = false

    /// `pendingUpdateVersion` is downloaded (`.downloaded` or `.installing`). Sparkle resumes such an
    /// update on every background check without reading the feed, so this drives the `mayPerform`
    /// refusal. Cleared together with `pendingUpdateVersion`.
    private var isPendingUpdateDownloaded = false

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    /// 已经为哪个版本抢过一次前台。**只在内存里**——不落盘就没有新的数据边界，
    /// 代价只是重启钨极后同一个版本会再当面提醒一次，这可以接受。
    private var announcedVersion: String?

    /// Set when an automatic download finished preparing the installer; the end of that cycle
    /// starts the background check that shows the update window (see the type comment).
    private var showsPreparedUpdateAfterCycle = false

    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "update")

    /// Domain of the error thrown to abort a quiet re-sighting; Sparkle logs it once per aborted check.
    private static let quietAbortErrorDomain = "com.caye.macosdockcc.v2.update"

    /// 自动检查更新。设置窗口那个勾选项直接读写它。
    ///
    /// 真值存在 Sparkle 自己那边（`SUEnableAutomaticChecks` / 用户偏好），**不要**在
    /// `AppSettingsStore` 里另存一份镜像：两份状态一定会漂，而这个偏好 Sparkle 自己也会写。
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Download (and, on quit, install) updates in the background. Initial value is
    /// `SUAutomaticallyUpdate` in Info.plist; Sparkle persists the user's choice itself, so it is not
    /// mirrored into `AppSettingsStore` either.
    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// `UpdateControlling`：把 SwiftUI 的变更通道摊平成一个普通 publisher，
    /// 好让 `SettingsCoordinator` 不必知道这里是不是 `ObservableObject`。
    var changes: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    /// 启动更新器。
    ///
    /// ⚠️ **只在非临时副本的正常运行分支调用**。挂载在 DMG 里的那份临时副本去更新自己毫无意义
    /// （它卸载就没了），而且会在系统里留下痕迹——和 `AppDelegate` 不给临时副本注册全局热键、
    /// 不向系统申请权限是同一条理由。
    func start() {
        guard controller == nil else { return }
        // updaterDelegate 也是自己：状态栏那个提示要在**用户做出选择之后**才撤，
        // 而「装了 / 跳过了」「这一轮没找到更新」只有 updater 侧的回调会说。
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller

        // canCheckForUpdates 是 Sparkle 用 KVO 发布的，不是 Combine。桥过来给两个界面用。
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            // 只用 KVO 送来的 Bool（`.new` + `.initial` 保证有值），不在这个 Sendable 回调里回读
            // `updater`——它是主 actor 隔离的对象，严格并发下不允许从这里碰。
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.canCheckForUpdates = value
            }
        }
    }

    /// 用户主动检查。Sparkle 自带全套界面（有新版 / 已是最新 / 查不到），
    /// 所以这里不再需要 `UpdateCheckAlertContent` 那套自绘文案。
    ///
    /// **提示不在这里撤**：点进来只是把更新窗口叫出来，用户可能又把它关掉；
    /// 撤的时机统一在「做了选择」或「已经没有更新」那两条回调里。
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

extension SparkleUpdateService: SPUStandardUserDriverDelegate {
    /// 声明我们会自己管"温和提醒"。不声明的话下面几个回调 Sparkle 根本不会调。
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle 即将展示一个更新。
    ///
    /// `state.userInitiated == false` 表示这是**定时检查**的结果——`.accessory` 应用的这种
    /// 更新窗会被压在所有窗口后面，不 activate 就等于没提示（2026-07-29 那次「检查更新失效」
    /// 是同一个病）。所以第一次遇见某个版本时把 App 带到前台。A scheduled re-sighting of the
    /// same version never reaches this point: `updater(_:shouldProceedWithUpdate:updateCheck:)`
    /// aborts it before Sparkle builds the alert, so only the menu-bar badge remains.
    ///
    /// 用户自己点出来的检查不碰 activate：那条路 Sparkle 已经保证置前。
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let userInitiated = state.userInitiated
        let version = update.displayVersionString
        let isDownloaded = state.stage != .notDownloaded
        let isReady = state.stage == .installing
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 不管这一轮开不开窗，状态栏都要知道「有一版在等着」。
            self.pendingUpdateVersion = version
            if isDownloaded { self.isPendingUpdateDownloaded = true }
            if isReady { self.isPendingUpdateReadyToInstall = true }
            // The window is on its way already (e.g. Sparkle re-checks immediately for a critical
            // update), so the follow-up check after the download cycle must not run later on its own.
            self.showsPreparedUpdateAfterCycle = false
            switch ScheduledUpdatePresentation.decide(
                version: version,
                userInitiated: userInitiated,
                announcedVersion: self.announcedVersion
            ) {
            case .announce:
                self.announcedVersion = version
                NSApp.activate(ignoringOtherApps: true)
            case .remindQuietly, .deferToSparkle:
                // `.remindQuietly` is unreachable here (aborted in `shouldProceedWithUpdate`);
                // Sparkle brings user-initiated alerts forward itself.
                break
            }
        }
    }
}

extension SparkleUpdateService: SPUUpdaterDelegate {
    /// Sparkle picked `updateItem` from the appcast and asks whether to go on with it.
    ///
    /// A **background** check that finds the version already announced in this run is aborted
    /// here by throwing. Nothing reaches the screen (`SPUScheduledUpdateDriver` surfaces errors
    /// only after an alert was shown), `updaterDidNotFindUpdate` is not on this path so
    /// `pendingUpdateVersion` and the badge survive, and — the point of it — the session ends,
    /// so Sparkle schedules the next check and a *newer* version can announce itself at the next
    /// tick. Doing this through `standardUserDriverShouldHandleShowingScheduledUpdate` instead
    /// would hold the session open and silently stop all later checks (see the type comment).
    ///
    /// User-initiated checks always proceed: the badge row's `checkForUpdates()` relies on that
    /// to bring the alert back.
    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        let version = updateItem.displayVersionString
        let outcome = ScheduledUpdatePresentation.decide(
            version: version,
            userInitiated: updateCheck == .updates,
            announcedVersion: announcedVersion
        )
        guard outcome == .remindQuietly else { return }
        // The badge normally already shows this version; re-asserting it costs nothing and
        // covers a reminder lost to a transient state change.
        pendingUpdateVersion = version
        throw NSError(
            domain: Self.quietAbortErrorDomain,
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Update \(version) was already announced in this run; the menu-bar badge carries the reminder."
            ]
        )
    }

    /// Refuses background checks that would only re-open an already-shown downloaded update
    /// (`ScheduledUpdatePresentation.allowsCheck`). Throwing ends the session and Sparkle schedules
    /// the next check; no UI is shown for a background check.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let readyVersion = isPendingUpdateDownloaded ? pendingUpdateVersion : nil
        guard !ScheduledUpdatePresentation.allowsCheck(
            userInitiated: updateCheck == .updates,
            readyVersion: readyVersion,
            announcedVersion: announcedVersion
        ) else { return }
        throw NSError(
            domain: Self.quietAbortErrorDomain,
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Update \(readyVersion ?? "") is downloaded and was already shown; the menu row brings it back."
            ]
        )
    }

    /// An automatic download finished and the installer waits for quit. Returning `false` declines
    /// the immediate-install block on purpose (see the type comment); the update is shown once
    /// when this cycle ends.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        logger.info("update \(version, privacy: .public) downloaded; installs on quit")
        pendingUpdateVersion = version
        isPendingUpdateDownloaded = true
        isPendingUpdateReadyToInstall = true
        showsPreparedUpdateAfterCycle = announcedVersion != version
        return false
    }

    /// Called after the session has ended; starting a check here also makes Sparkle skip
    /// scheduling, which the new check's own completion then does.
    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard showsPreparedUpdateAfterCycle else { return }
        showsPreparedUpdateAfterCycle = false
        // `checkForUpdatesInBackground` ignores the automatic-checks switch; honour it here.
        guard updater.automaticallyChecksForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }

    /// One line per scheduled check so「为什么没查更新」has evidence in Console
    /// (`log show --predicate 'subsystem == "com.caye.macosdockcc.v2" AND category == "update"'`).
    /// Silence here after an update was found is exactly the bug this file guards against.
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        logger.info("next scheduled update check in \(Int(delay), privacy: .public)s")
    }

    /// `DOCK_UPDATE_FEED_URL` points Sparkle at a test appcast (e.g. one served from localhost)
    /// so an unpublished feed can be checked end to end; unset → `SUFeedURL` from Info.plist.
    func feedURLString(for updater: SPUUpdater) -> String? {
        DebugSwitch.updateFeedURL.value()
    }

    /// 用户对这次更新做了选择。装了 / 跳过了 / 稍后再说——前两种要把状态栏的提示撤掉。
    ///
    /// 「稍后再说」(`.dismiss`) **不撤**：那正是「我知道了，但先不弄」，小圆点留着才对，
    /// 否则又回到「关掉窗口就什么都不剩」的老样子。
    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        switch choice {
        case .install, .skip:
            pendingUpdateVersion = nil
            isPendingUpdateDownloaded = false
            isPendingUpdateReadyToInstall = false
        case .dismiss:
            break
        @unknown default:
            break
        }
    }

    /// 这一轮检查没找到更新——说明用户已经在最新版上了（可能是他自己手动装的），
    /// 状态栏那个提示该撤了。
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        pendingUpdateVersion = nil
        isPendingUpdateDownloaded = false
        isPendingUpdateReadyToInstall = false
    }
}
