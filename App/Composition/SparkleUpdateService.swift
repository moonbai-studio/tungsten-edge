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

    /// 定时检查发现了新版、而用户还没正眼看过它。留给状态栏那边做提示用。
    @Published private(set) var hasUnseenScheduledUpdate = false

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

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
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.controller = controller

        // canCheckForUpdates 是 Sparkle 用 KVO 发布的，不是 Combine。桥过来给两个界面用。
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// 用户主动检查。Sparkle 自带全套界面（有新版 / 已是最新 / 查不到），
    /// 所以这里不再需要 `UpdateCheckAlertContent` 那套自绘文案。
    func checkForUpdates() {
        hasUnseenScheduledUpdate = false
        controller?.checkForUpdates(nil)
    }
}

extension SparkleUpdateService: SPUStandardUserDriverDelegate {
    /// 声明我们会自己管"温和提醒"。不声明的话下面两个回调 Sparkle 根本不会调。
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle 即将展示一个更新。
    ///
    /// `state.userInitiated == false` 表示这是**定时检查**的结果——正是会被压在别的应用
    /// 后面的那种。把 App 带到前台，否则用户永远看不到这扇窗。
    ///
    /// 用户自己点出来的检查不碰 activate：那条路 Sparkle 已经保证置前，重复 activate 没意义。
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let userInitiated = state.userInitiated
        Task { @MainActor [weak self] in
            guard !userInitiated else { return }
            self?.hasUnseenScheduledUpdate = true
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 用户已经正眼看过这次更新了，提示可以撤了。
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor [weak self] in
            self?.hasUnseenScheduledUpdate = false
        }
    }
}
