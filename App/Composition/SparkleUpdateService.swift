import AppKit
import Combine
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

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    /// 已经为哪个版本抢过一次前台。**只在内存里**——不落盘就没有新的数据边界，
    /// 代价只是重启钨极后同一个版本会再当面提醒一次，这可以接受。
    private var announcedVersion: String?

    /// 自动检查更新。设置窗口那个勾选项直接读写它。
    ///
    /// 真值存在 Sparkle 自己那边（`SUEnableAutomaticChecks` / 用户偏好），**不要**在
    /// `AppSettingsStore` 里另存一份镜像：两份状态一定会漂，而这个偏好 Sparkle 自己也会写。
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
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

    /// 这一轮定时检查，要不要让 Sparkle 自己开更新窗口。
    ///
    /// 返回 `false` = 「我自己用界面提示，你别开窗」，正是 Sparkle 给 gentle reminders
    /// 留的口子。判定归纯函数 `ScheduledUpdatePresentation`：同一个版本只在第一次开窗，
    /// 之后交给菜单栏图标上的小圆点。
    ///
    /// ⚠️ **这个回调里不许有副作用**（Sparkle 头文件明写），所以只读 `announcedVersion`，
    /// 记录留给下面的 `willHandleShowingUpdate`。用户主动发起的检查不会走到这里。
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Sparkle 在主线程调这个同步回调；`assumeIsolated` 只是把这一事实告诉编译器，
        // 不能改成 Task——那样这里就没有返回值可给了。
        MainActor.assumeIsolated {
            ScheduledUpdatePresentation.decide(
                version: update.displayVersionString,
                userInitiated: false,
                announcedVersion: announcedVersion
            ) == .announce
        }
    }

    /// Sparkle 即将展示一个更新。
    ///
    /// `state.userInitiated == false` 表示这是**定时检查**的结果——`.accessory` 应用的这种
    /// 更新窗会被压在所有窗口后面，不 activate 就等于没提示（2026-07-29 那次「检查更新失效」
    /// 是同一个病）。所以第一次遇见某个版本时把 App 带到前台；同一个版本的后续几轮由
    /// 上面那个回调挡在开窗之前，只留状态栏的小圆点。
    ///
    /// 用户自己点出来的检查不碰 activate：那条路 Sparkle 已经保证置前。
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let userInitiated = state.userInitiated
        let version = update.displayVersionString
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 不管这一轮开不开窗，状态栏都要知道「有一版在等着」。
            self.pendingUpdateVersion = version
            switch ScheduledUpdatePresentation.decide(
                version: version,
                userInitiated: userInitiated,
                announcedVersion: self.announcedVersion
            ) {
            case .announce:
                self.announcedVersion = version
                NSApp.activate(ignoringOtherApps: true)
            case .remindQuietly, .deferToSparkle:
                break
            }
        }
    }
}

extension SparkleUpdateService: SPUUpdaterDelegate {
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
    }
}
