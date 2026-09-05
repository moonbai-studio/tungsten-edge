import AppKit
import Combine
import QuartzCore
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let inventoryLog = WindowInventoryAnomalyLog()
    /// 在场屏幕表的唯一来源：窗口清单（归属键）与任务条投影（多屏 ④ 按屏过滤）都读它。
    let displayTopologyStore = DisplayTopologyStore()
    private(set) lazy var runtime = AppRuntime(
        inventoryLog: inventoryLog,
        displayTableProvider: { [displayTopologyStore] in displayTopologyStore.table },
        isAccessibilityTrusted: { [weak self] in self?.cachedAccessibilityTrusted ?? false }
    )
    let drawerStore = DrawerStore()
    let messagingStore = MessagingAppStore()
    let badgeStore = BadgeStore()
    let keptAppStore = KeptAppStore()
    lazy var stripOrderStore = StripOrderStore(
        keptIDsProvider: { [keptAppStore] in Set(keptAppStore.bundleIDs) },
        stableKeptOrderProvider: { [keptAppStore, messagingStore] in
            keptAppStore.bundleIDs.filter { !messagingStore.contains($0) }
        },
        inventoryLog: inventoryLog
    )
    let drawerOrderStore = DrawerOrderStore()
    let settingsStore = AppSettingsStore()
    let pinnedFolderStore = PinnedFolderStore()
    let shelfStore = ShelfStore()
    let runningApplicationStore = RunningApplicationStore()
    private(set) lazy var appMembershipController = AppMembershipController(
        keptAppStore: keptAppStore,
        drawerStore: drawerStore,
        messagingStore: messagingStore
    )
    /// lazy：sortOrderProvider 要引用 pinnedFolderStore（封面跟随该文件夹当前排序的第一个文件）。
    private(set) lazy var folderCoverStore = PinnedFolderCoverStore(
        sortOrderProvider: { [pinnedFolderStore] path in pinnedFolderStore.sortOrder(for: path) }
    )
    private var panelCoordinator: TaskbarScreenOrchestrator?
    private var windowLiftAvoidanceController: WindowLiftAvoidanceController?
    private lazy var launchAtLoginService = LaunchAtLoginService()
    private lazy var nativeDockPreferencesService = NativeDockPreferencesService()
    private let updateService = SparkleUpdateService()
    private lazy var settingsCoordinator = SettingsCoordinator(
        store: settingsStore,
        launchAtLoginService: launchAtLoginService,
        nativeDockPreferencesService: nativeDockPreferencesService,
        updateService: updateService,
        subscriptionSubmitter: WebsiteSubscriptionSubmitter(),
        feedbackSubmitter: WebsiteFeedbackSubmitter(),
        // 改键的真实注册入口。临时副本没有 monitor（也进不了设置窗口），兜底报失败。
        hotKeyRegistrar: { [weak self] shortcut in
            self?.edgeToggleHotKey?.update(shortcut: shortcut) ?? .monitorUnavailable
        }
    )
    /// 本机授权凭据。设置窗口的「授权」区块读它；将来的试用期逻辑也会读它，
    /// 所以它是 AppDelegate 的一等成员，不藏在设置窗口里。
    let licenseStore = LicenseStore()
    private lazy var settingsWindowController = SettingsWindowController(
        store: settingsStore,
        coordinator: settingsCoordinator,
        licenseStore: licenseStore,
        // 直通 showWelcomeWindow()，不走 presentWelcomeGuideIfNeeded()——那条对
        // hasSeenWelcome 已置位的存量用户永远静默跳过，而存量用户正是这个入口的全部受众。
        // 入口 2026-09-01 从状态栏菜单搬进设置卡「通用」页（owner 拍板）；直通这一点不变。
        onShowWelcomeGuide: { [weak self] in self?.showWelcomeWindow() }
    )
    /// 常驻切换全局快捷键。回调只切设置（经 settingsStore），不经过 panelCoordinator——
    /// 后者在权限引导完成前是 nil，settingsStore 从 AppDelegate 构造起即存在。
    private var edgeToggleHotKey: GlobalHotKeyMonitor?
    private var terminationTask: Task<Void, Never>?
    private var debugWindow: NSWindow?
    /// 只在 `DOCK_HOVER_TRACE=1` 时存在，见 `startMainLoopStallProbeIfTracing`。
    private var mainLoopStallProbe: Timer?
    private var permissionWindow: NSWindow?
    private var permissionHostingView: NSHostingView<PermissionOnboardingWindowContent>?
    private var welcomeWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var messagingAutoRegisterSubscription: AnyCancellable?
    private var badgeContextSubscription: AnyCancellable?
    private var windowLiftSettingSubscription: AnyCancellable?
    /// 全局反转鼠标滚轮。active tap 需要辅助功能授权，所以挂在任务条运行期
    ///（startTaskbarRuntime 建、suspend/终止拆），与全屏 tap 同一生命周期语义。
    private var scrollReverserMonitor: ScrollReverserMonitor?
    private var scrollReverserSettingSubscription: AnyCancellable?
    private let permissionService = PermissionService()
    private var installLocation: AppInstallLocation = .other
    private var permissionCoordinator: PermissionRecoveryCoordinator?
    private var permissionWatchdogTimer: Timer?
    private var permissionWatchdogGate = PermissionWatchdogGate()
    private let permissionProbeQueue = DispatchQueue(label: "com.caye.macosdockcc.v2.permission-probe", qos: .utility)
    private var cachedAccessibilityTrusted = false
    private var hasStartedApp = false
    private let permissionLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "permissions")
    private lazy var statusMenuController = StatusMenuController(
        store: settingsStore,
        settingsCoordinator: settingsCoordinator,
        isAccessibilityTrusted: { [weak self] in self?.cachedAccessibilityTrusted ?? false },
        onShowDebugConsole: { [weak self] in self?.showDebugConsole() },
        onExportDebugSnapshot: { [weak self] in self?.exportDebugSnapshot() },
        onShowSettings: { [weak self] in self?.openSettings(nil) },
        onMenuVisibilityChanged: { [weak self] isOpen in
            self?.panelCoordinator?.setTaskbarMenuOpen(isOpen)
        },
        onQuit: { NSApp.terminate(nil) },
        hotKeyGlyphs: { [weak self] in
            self?.edgeToggleHotKey?.shortcut.displayGlyphs
                ?? GlobalHotKeyShortcut.edgeAutoHideMode.displayGlyphs
        },
        isToggleHotKeyRegistered: { [weak self] in self?.edgeToggleHotKey?.isRegistered ?? false },
        connectedScreens: { DisplayIdentity.connectedScreenOptions() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 行缓冲 stdout：从命令行/后台启动时，print() 输出到文件默认是块缓冲，
        // 日志要攒满缓冲区才落盘。改成行缓冲后每条 print 立即写出，便于实时读日志。
        setvbuf(stdout, nil, _IOLBF, 0)

        startMainLoopStallProbeIfTracing()

        // 首装时间戳：**故意放在所有分支判断之前**，搬家引导、权限引导、正常启动都要记。
        // 这三条分支的用户都是真的运行过钨极的人，将来转收费判定老用户时不该把谁漏掉。
        // 只写一次、之后永不覆盖，理由见 `InstallationRecord`。
        //
        // ⚠️ 顺序承重：**先取「是不是全新安装」，再写首装键**。写完再问永远得到「老用户」，
        // 下面那条播种就再也不会对任何人生效（静默失效，没有任何报错）。
        let isFreshInstall = InstallationRecord.firstLaunchDate() == nil
        InstallationRecord.recordFirstLaunchIfNeeded()
        // 全新安装把最大化避让播种为开；老用户维持关（它会改写别人应用的窗口尺寸，
        // 不能靠一次升级静默打开）。理由见 `AppSettingsStore.seedWindowLiftEnabledForFreshInstall`。
        if isFreshInstall {
            settingsStore.seedWindowLiftEnabledForFreshInstall()
        }

        // **无条件钉死浅色，这一句不能省。** 产品固定浅色（owner 2026-08-16 删掉深色模式），
        // 而 `NSVisualEffectView` 和 Liquid Glass 跟的是**窗口的 effectiveAppearance**、
        // 不看 SwiftUI 环境。系统处于深色时若不钉，材质会渲染成深色，而 `DockThemeTokens`
        // 只有一套浅色数值 —— 结果就是「文字是浅色的、底板是深色的」那种对不上
        //（实测同屏同壁纸，底板亮度 37.7 对 143.2）。
        //
        // 钉在 `NSApp` 这一处就够：所有面板与窗口都没覆写自己的 `appearance`，会一路回落到
        // 这里——**包括之后才按需新建的**抽屉、两个弹窗、tooltip、拖动载体，以及状态栏与
        // 右键菜单。状态栏图标是 template image，仍由菜单栏按系统外观自己染色，不受影响。
        //
        // 排在最前面：搬家引导、权限引导、正常启动三条分支的第一个窗口就得是对的外观。
        NSApp.appearance = NSAppearance(named: .aqua)

        // 位置分类必须排在接管其他实例和注册热键**之前**。
        // 挂载磁盘映像双击运行时，那份临时副本一旦执行 terminateOtherInstances()，
        // 就会把用户正在用的 /Applications 实例杀掉，自己却只显示一个搬家引导；
        // 抢注了全局热键还会让正常实例的 ⌥⇧⌘D 失灵。
        let location = AppInstallLocation(
            bundleURL: Bundle.main.bundleURL,
            isReadOnlyVolume: { [permissionService] in permissionService.isReadOnlyVolume($0) }
        )
        installLocation = location
        let trusted = permissionService.hasRequiredPermissions()
        cachedAccessibilityTrusted = trusted
        logPermissionLaunch(installLocation: location, isTrusted: trusted)

        if !location.isTransient {
            terminateOtherInstances()

            // 先注册热键再建状态菜单：菜单构建时要读注册状态决定是否显示快捷键提示。
            // Carbon 热键不依赖辅助功能权限，不用等权限引导分支。
            // 用户自定义过就用存的组合；坏数据在 store 读入时已回落 nil（= 默认 ⌥⇧⌘D）。
            let shortcut = settingsStore.edgeToggleShortcut.map(GlobalHotKeyShortcut.init(stored:))
                ?? .edgeAutoHideMode
            let hotKey = GlobalHotKeyMonitor(shortcut: shortcut) { [weak self] in
                self?.settingsStore.toggleEdgeAutoHideMode()
            }
            edgeToggleHotKey = hotKey
            let hotKeyStatus = hotKey.start()
            if hotKeyStatus != .registered {
                Logger(subsystem: "com.caye.macosdockcc.v2", category: "hotkey")
                    .warning("常驻切换全局快捷键注册失败：\(String(describing: hotKeyStatus), privacy: .public)，本次启动不重试")
            }

            _ = statusMenuController

            // 自动更新只在正常安装的副本上跑。挂载在 DMG 里的临时副本更新自己毫无意义
            // ——它卸载就没了——和上面不给它注册全局热键、不向系统申请权限是同一条理由。
            updateService.start()
        }

        let coordinator = PermissionRecoveryCoordinator(
            handler: self,
            permissionService: permissionService,
            installLocation: location
        )
        permissionCoordinator = coordinator
        coordinator.launched(trusted: trusted)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 用户从系统设置切回来时立刻复检，不用等下一次轮询。
        permissionCoordinator?.applicationDidBecomeActive()
        if !installLocation.isTransient {
            Task { @MainActor [weak self] in
                _ = await self?.settingsCoordinator.refreshLaunchAtLoginState()
            }
        }
    }

    private func logPermissionLaunch(installLocation: AppInstallLocation, isTrusted: Bool) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        permissionLogger.info("""
            permission launch version=\(version, privacy: .public) \
            build=\(build, privacy: .public) \
            location=\(installLocation.rawValue, privacy: .public) \
            trusted=\(isTrusted, privacy: .public) \
            bundlePath=\(Bundle.main.bundleURL.path, privacy: .private(mask: .hash))
            """)
    }

    /// 同一个 bundle id 的另一份包（`/Applications` 正式包 vs 构建目录里的开发包）可以
    /// 同时运行，屏幕上就会出现两条一模一样的任务条，测到的是哪个版本谁也说不清——
    /// 2026-07-21 因此把一个其实没验证过的修复判成「不行」并整个回退。
    ///
    /// 采取「后启动的接管」：新实例踢掉旧实例。反过来（新的自己退出）会挡住开发时的
    /// 验证构建，也和 `Scripts/build_and_run.sh` 先 pkill 再启动的既有行为矛盾。
    /// 用礼貌的 `terminate()` 而不是强杀，让旧实例的 `stopAndRestore` 把被抬起的窗口
    /// 还原回去；只有它迟迟不退时才强制结束，避免"两个任务条"这个原始症状复发。
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }
        guard !others.isEmpty else { return }

        let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "instance")
        for app in others {
            logger.warning("""
                发现另一个钨极实例，终止它：pid=\(app.processIdentifier, privacy: .public) \
                path=\(app.bundleURL?.path ?? "(unknown)", privacy: .public)
                """)
            app.terminate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for app in others where !app.isTerminated {
                logger.error("旧实例 pid=\(app.processIdentifier, privacy: .public) 3 秒内未退出，强制结束")
                app.forceTerminate()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 收尾等待（stopAndRestore）期间事件循环还在跑：先切断热键输入，避免设置被继续切换，
        // 并让协调器取消在飞的恢复任务——光设阶段拦不住已经进了 await 的 Task，
        // 那会在退出之后还去拉起一个新实例。
        edgeToggleHotKey?.stop()
        // 滚轮 tap 同理先拆：进程退出前多活一秒，全系统的滚动就多经手一秒。
        scrollReverserMonitor?.stop()
        scrollReverserMonitor = nil
        permissionCoordinator?.terminationRequested()

        guard let controller = windowLiftAvoidanceController else { return .terminateNow }
        // 没有权限时 AX 写不动窗口，等 stopAndRestore 只是白等。
        guard permissionService.hasRequiredPermissions() else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        terminationTask = Task { @MainActor [weak self] in
            await controller.stopAndRestore()
            self?.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        edgeToggleHotKey?.stop()
        scrollReverserMonitor?.stop()
        scrollReverserMonitor = nil
        DocumentUsageStore.shared.stop()
        permissionCoordinator?.terminationRequested()
        windowLiftAvoidanceController?.stop()
        // 私有空间进程一死 WindowServer 自会回收，这里只是不留垃圾空间。
        panelCoordinator?.overlaySpaceHost?.tearDown()
        runtime.stop()
    }

    // MARK: - 首次运行欢迎引导

    /// 首次运行的一次性引导：建议把系统 Dock 收起来。
    ///
    /// 只在 `startTaskbarRuntime()` 末尾调一次，也就是「权限已授、面板已建、任务条真的在跑」
    /// 的那一刻。临时副本（DMG 里双击运行的那份）永远走不到这里——它在
    /// `PermissionRecoveryMachine` 里只有 `showGuide` 一条效果——这是对的，那份副本
    /// 卸载就没了，不该教它配置系统。
    private func presentWelcomeGuideIfNeeded() {
        // 先用不需要 I/O 的两个条件挡一道，省掉绝大多数启动的那次异步读。
        guard !settingsStore.hasSeenWelcome else { return }

        let canWrite = nativeDockPreferencesService.isAvailable
        guard canWrite else {
            _ = WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: false,
                dockAutohideEnabled: nil
            )
            settingsStore.setHasSeenWelcome(true)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await self.nativeDockPreferencesService.currentAutohideState()
            // 这一轮 await 期间用户可能已经从别处看过/改过了，所以重新读一遍标记。
            switch WelcomeGuideDecision.evaluate(
                hasSeenWelcome: self.settingsStore.hasSeenWelcome,
                canWriteDockPreferences: true,
                dockAutohideEnabled: state?.enabled
            ) {
            case .present:
                self.showWelcomeWindow()
            case .skipAndMarkSeen:
                self.settingsStore.setHasSeenWelcome(true)
            case .skipWithoutMarking:
                break
            }
        }
    }

    private func showWelcomeWindow() {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = WelcomeGuideWindowContent(
            onApply: { [weak self] selection in self?.applyWelcomeSelection(selection) },
            onDismiss: { [weak self] in self?.dismissWelcomeGuide() }
        )
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WelcomeGuideView.contentWidth, height: 320),
            // 和权限引导不同，这一扇**可关**：权限没授时 app 根本不能用，那扇窗关掉没有意义；
            // 这一扇只是个建议，用户有权直接叉掉（叉掉等同「以后再说」，见 windowWillClose）。
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tungsten Edge 钨极"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.delegate = self
        welcomeWindow = window

        // 高度量法同权限引导：根视图外面套了 ScrollView，得用一次性探针量不加滚动时的自然高度。
        let probe = NSHostingView(rootView: WelcomeGuideView(onApply: { _ in }, onDismiss: {}))
        probe.setFrameSize(NSSize(width: WelcomeGuideView.contentWidth, height: 0))
        probe.layoutSubtreeIfNeeded()
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        window.setContentSize(NSSize(
            width: WelcomeGuideView.contentWidth,
            height: max(200, min(probe.fittingSize.height, available - 80))
        ))

        window.center()
        window.makeKeyAndOrderFront(nil)
        // 钨极此刻是 accessory app，不主动 activate 的话这扇窗会被压在前台应用后面，
        // 和 2026-07-29 那次「检查更新看起来失效」是同一个坑。
        // 注意**不要**顺手改成 .regular——那会让程序坞里冒出一个钨极图标，
        // 正好和这扇窗要讲的事情自相矛盾。
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 「应用推荐设置」：按用户勾了哪几条写系统 Dock 偏好。隐藏那一档是自动隐藏 + 不唤醒
    /// （owner 2026-08-20 定的推荐档位）。
    ///
    /// 走 `applyNativeDock(recommendations:)` 这个唯一写入口，四象限回读和镜像同步都是白拿的；
    /// 别在这里另起一条 defaults 写入。三条合成一次 `killall Dock`，屏幕只闪一次。
    private func applyWelcomeSelection(_ selection: WelcomeGuideSelection) {
        settingsStore.setHasSeenWelcome(true)
        closeWelcomeWindow()

        let recommendations = selection.recommendations(hideDelay: AppSettingsStore.neverWakeDelay)
        // 一条都没勾时按钮本就置灰，这是兜底：什么都不写，也就不该重启 Dock 让屏幕白闪一下。
        guard !recommendations.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.settingsCoordinator.applyNativeDock(
                recommendations: recommendations
            )
            guard let error = outcome.error else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Couldn’t Change Dock Settings")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// 「以后再说」，以及直接叉掉窗口。**照样记成已看过**——不再骚扰；
    /// 想改的人走状态栏菜单里那条系统 Dock 滑杆。
    private func dismissWelcomeGuide() {
        settingsStore.setHasSeenWelcome(true)
        closeWelcomeWindow()
    }

    private func closeWelcomeWindow() {
        guard let window = welcomeWindow else { return }
        welcomeWindow = nil
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    /// 引导窗口。文案长度随状态变化很大（排障区展开时几乎翻倍），
    /// 所以宽度固定、高度跟着内容走，并以当前屏幕可视高度封顶。
    private func showPermissionWindow() {
        guard let coordinator = permissionCoordinator else { return }
        if let permissionWindow {
            resizePermissionWindowToFit()
            permissionWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: PermissionOnboardingWindowContent(coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PermissionOnboardingView.contentWidth, height: 260),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tungsten Edge 钨极"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        permissionWindow = window
        permissionHostingView = hosting
        resizePermissionWindowToFit()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resizePermissionWindowToFit() {
        guard let window = permissionWindow, let coordinator = permissionCoordinator else { return }

        // 用一次性探针量「不加滚动时的自然高度」：真正的根视图外面套了 ScrollView，
        // 它自己的 fittingSize 量不出内容有多高。
        let probe = NSHostingView(rootView: PermissionOnboardingView(coordinator: coordinator))
        probe.setFrameSize(NSSize(width: PermissionOnboardingView.contentWidth, height: 0))
        probe.layoutSubtreeIfNeeded()
        let natural = probe.fittingSize.height

        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = max(200, min(natural, available - 80))
        let size = NSSize(width: PermissionOnboardingView.contentWidth, height: height)
        guard window.contentView?.frame.size != size else { return }

        let before = window.frame
        window.setContentSize(size)
        // 保持视觉中心不动，别让窗口在文案变长时往下窜。
        let after = window.frame
        window.setFrameOrigin(NSPoint(
            x: before.midX - after.width / 2,
            y: before.midY - after.height / 2
        ))
    }

    private func closePermissionWindow() {
        permissionWindow?.orderOut(nil)
        permissionWindow?.close()
        permissionWindow = nil
        permissionHostingView = nil
    }

    private func startTaskbarRuntime() {
        appMembershipController.reconcileInvalidMemberships()
        runningApplicationStore.start()
        runtime.start()

        // Auto tier of the messaging list: register an app only when it both matches the
        // whitelist / social-networking category **and** currently has an identifiable main
        // window, then seed kept on first registration (default-keep). Kept no longer excludes
        // messaging, so there is no kept filter.
        //
        // The window snapshot is combined in because the capability gate needs titles — the
        // process store alone cannot tell whether the zone can represent the app. Registration
        // is once-and-for-all (see `MessagingAppStore.autoRegister`), so the "identifiable right
        // now" reading is only ever consumed for apps not yet in the list; existing members are
        // never re-tested and therefore never flap out of the zone.
        messagingAutoRegisterSubscription = runningApplicationStore.$runningBundleIDs
            .combineLatest(runtime.$snapshot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running, snapshot in
                guard let self else { return }
                let identifiable = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
                    windows: StripItem.items(from: snapshot).map {
                        .init(bundleID: $0.bundleIdentifier ?? "",
                              title: $0.title,
                              isAppLevelFallback: $0.isAppLevelFallback)
                    },
                    titleMatchesAppName: { title, bundleID in
                        AppDisplayNameResolver.titleMatchesAppName(title, bundleID: bundleID)
                    }
                )
                self.appMembershipController.autoRegisterMessaging(
                    runningBundleIDs: running,
                    mainWindowIdentifiableBundleIDs: identifiable
                )
            }

        // 角标读取范围 = 消息应用**身份** ∩ 在跑 − 抽屉（2026-08-23 起不再要求在消息区里：
        // 信息 / Slack 这类进不了区的单窗口应用，红点画在它们常规区的卡上）。名单或在跑集合
        // 一变就推给 BadgeStore：可读集为空时它每 tick 零 AX 流量；集合变化触发重走 Dock 树，
        // 「消息应用刚启动、新磁贴上出角标」靠这条在 ~1s 内补上。订阅先于 badgeStore.start()，
        // 首次读取前上下文已就位（@Published 订阅即发当前值）。
        // `isMessagingApp` 回读 store：这里有 receive(on:) 异步派发，发布早已完成，读到的是新值。
        badgeContextSubscription = Publishers.CombineLatest3(
            messagingStore.$bundleIDs,
            drawerStore.$bundleIDs,
            runningApplicationStore.$runningBundleIDs
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, drawer, running in
            guard let self else { return }
            self.badgeStore.updateMessagingContext(
                visibleMessagingIDs: AppMembershipProjection.badgeEligibleIDs(
                    isMessagingApp: { self.messagingStore.isMessagingApp($0) },
                    drawerIDs: drawer,
                    runningIDs: running
                ),
                runningBundleIDs: running
            )
        }

        let coordinator = TaskbarScreenOrchestrator(
            runtime: runtime,
            drawerStore: drawerStore,
            messagingStore: messagingStore,
            badgeStore: badgeStore,
            stripOrderStore: stripOrderStore,
            drawerOrderStore: drawerOrderStore,
            settingsStore: settingsStore,
            pinnedFolderStore: pinnedFolderStore,
            folderCoverStore: folderCoverStore,
            shelfStore: shelfStore,
            keptAppStore: keptAppStore,
            runningApplicationStore: runningApplicationStore,
            appMembershipController: appMembershipController,
            displayTopologyStore: displayTopologyStore
        )
        panelCoordinator = coordinator
        runtime.onToggleDrawer = { [weak coordinator] in coordinator?.toggleDrawer() }
        coordinator.onAddFolder = { [weak self] in self?.presentAddPinnedFolderPanel() }
        // 右键任务条 / 胶囊弹钨极菜单。走到这里说明已授权且不是临时副本，
        // 状态栏菜单必然已经建好（`applicationDidFinishLaunching` 的非临时分支），
        // 不存在"凭空造出一个状态栏图标"的问题。
        coordinator.onRequestTaskbarMenu = { [weak self] event, view in
            self?.statusMenuController.popUpFromTaskbar(with: event, in: view)
        }
        coordinator.start()
        let windowLiftAvoidanceController = WindowLiftAvoidanceController(host: coordinator)
        self.windowLiftAvoidanceController = windowLiftAvoidanceController
        // 避让默认关，起步先把持久化的开关状态灌进去；start() 自己认这个标志位，
        // 没勾选时它直接空转返回，两个定时器（空闲 1 Hz / 会话期 5 Hz 的全局扫描，
        // 以及 20 Hz tracked probe）都不会起来。
        windowLiftAvoidanceController.setEnabledBySetting(settingsStore.windowLiftEnabled)
        windowLiftAvoidanceController.start()
        // sink 用闭包参数里的新值：@Published 在赋值完成前发布，此刻回读 store 是旧值。
        // 走 self?.windowLiftAvoidanceController 而不是强捕获控制器——权限恢复路径会把它置 nil。
        windowLiftSettingSubscription = settingsStore.$windowLiftEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.windowLiftAvoidanceController?.setEnabledBySetting(enabled)
            }
        // 最常用文件的计数账本：目录监视 + 激活重采样都挂在任务条运行期。
        DocumentUsageStore.shared.start()
        // 反转滚轮同款接线。sink 用闭包参数里的新值，不回读 store（@Published 在赋值前发布）。
        applyScrollReverser(enabled: settingsStore.scrollReverserEnabled)
        scrollReverserSettingSubscription = settingsStore.$scrollReverserEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.applyScrollReverser(enabled: enabled)
            }
        badgeStore.start()
        // 任务条真的起来了才谈得上「建议怎么配」。放在这里而不是启动那一刻，是因为
        // 用户得先看见任务条长什么样，那句「它俩都在屏幕底边会互相遮挡」才有所指。
        presentWelcomeGuideIfNeeded()
        // 探针结论（2026-07-06,阶段0探针3）：访达窗口 AX 属性表虽列有 AXDocument 但恒无值
        // （kAXErrorNoValue），AXProxy/AXTitleUIElement 也只有文件夹名无路径——「拖任务条访达
        // 窗口图标固定文件夹」不可行,已按预案砍掉,拖入固定区只走真实文件 URL（系统拖放）。
    }

    /// 文件夹 chip / 中转格右键的「添加固定文件夹…」入口。
    /// accessory app 必须先 activate，否则 NSOpenPanel 不上前台。
    func presentAddPinnedFolderPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Pin")
        panel.message = String(localized: "Choose a folder to pin to the taskbar")
        if panel.runModal() == .OK {
            for url in panel.urls { pinnedFolderStore.add(url.path) }
        }
    }

    /// 设置窗口的存在前提是「任务条正常在跑」。
    ///
    /// 临时副本、还没授权、以及权限丢失后的恢复态，此刻用户唯一该做的事都是处理引导窗口——
    /// 这时再开一个完整设置面，只会盖在引导窗口上，而且里面的开关全都作用于一条根本没起来的
    /// 任务条（少数派用户 2026-08-03 反馈的正是这个自相矛盾的画面）。所以一律改为把引导窗口置前。
    @objc func openSettings(_ sender: Any?) {
        guard !installLocation.isTransient,
              hasStartedApp,
              permissionService.hasRequiredPermissions() else {
            showPermissionWindow()
            return
        }
        settingsWindowController.present()
    }

    func exportDebugSnapshot() {
        runtime.exportDebugSnapshot()
    }

    func showDebugConsole() {
        if let existing = debugWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "任务条调试台"
        window.contentView = NSHostingView(
            rootView: DebugConsoleView()
                .environmentObject(runtime)
                .environmentObject(runtime.debugState)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window
    }

    /// 主线程卡顿探针：只在 `DOCK_HOVER_TRACE=1` 时才装（`HoverTrace.isEnabled` 是常量，
    /// 关闭时这个计时器根本不创建，日常一分钱开销都没有）。
    ///
    /// 8ms 一次、跑在 `.common`——**必须是 `.common`**，否则菜单/拖拽期间它自己先停了，
    /// 而那正是最想量的时段。
    private func startMainLoopStallProbeIfTracing() {
        guard HoverTrace.isEnabled else { return }
        // 计时器回调是 Sendable 闭包，不能直接改捕获的 var；装进一个只在主线程用的盒子。
        let clock = StallProbeClock(expected: CACurrentMediaTime() + 0.008)
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            let now = CACurrentMediaTime()
            HoverTrace.mainLoopStall(lateMs: (now - clock.expected) * 1000)
            clock.expected = now + 0.008
        }
        RunLoop.main.add(timer, forMode: .common)
        mainLoopStallProbe = timer
    }

}

// MARK: - 权限状态机的副作用执行

extension AppDelegate: PermissionEffectHandler {
    func startApp() {
        guard !hasStartedApp else { return }
        hasStartedApp = true
        startTaskbarRuntime()
    }

    func setActivationPolicy(_ policy: PermissionActivationPolicy) {
        switch policy {
        case .accessory:
            NSApp.setActivationPolicy(.accessory)
        case .regular:
            // 没有权限时任务条不会创建任何面板，保持 accessory 会让用户只能看到一个
            // 不一定明显的状态栏图标；先用普通应用策略把引导窗口带到前台。
            NSApp.setActivationPolicy(.regular)
        }
    }

    func showGuideWindow() { showPermissionWindow() }
    func updateGuideWindow() { resizePermissionWindowToFit() }
    func closeGuideWindow() { closePermissionWindow() }

    func openAccessibilitySettings() {
        guard let url = AccessibilitySettingsLink.url else { return }
        NSWorkspace.shared.open(url)
    }

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    func releaseHotKey() { edgeToggleHotKey?.stop() }

    func registerHotKey() { _ = edgeToggleHotKey?.start() }

    /// 反转滚轮的唯一开合入口：开 = 建 monitor + 起 tap，关 = 拆干净。
    /// `settingEnabled` 由调用方传（订阅的新值或起步时的 store 值），不在这里回读 store——
    /// @Published 在赋值完成前发布，sink 里回读拿到的是旧值（仓库惯例）。
    private func applyScrollReverser(enabled settingEnabled: Bool) {
        let enabled = ScrollReverserDecision.isEnabled(
            settingEnabled: settingEnabled,
            environment: ProcessInfo.processInfo.environment
        )
        if enabled {
            guard scrollReverserMonitor == nil else { return }
            let monitor = ScrollReverserMonitor()
            scrollReverserMonitor = monitor
            monitor.start()
        } else {
            scrollReverserMonitor?.stop()
            scrollReverserMonitor = nil
        }
    }

    func terminateSelf() { NSApp.terminate(nil) }

    // MARK: 运行期恢复

    /// 5 秒一采样。防抖判定在纯 `PermissionLossDetector` 里，这里只负责喂数据。
    /// 注意这**不是**窗口快照的保护机制——那个由 `WindowLiftAvoidanceController`
    /// 自己在轮询里自检；有会话/待还原状态时仍是 0.2 秒，空闲无快照时才降到 1 秒。
    func startWatchdog() {
        stopWatchdog()
        permissionWatchdogGate.start()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePermissionProbe()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        permissionWatchdogTimer = timer
    }

    func stopWatchdog() {
        permissionWatchdogTimer?.invalidate()
        permissionWatchdogTimer = nil
        permissionWatchdogGate.stop()
    }

    private func schedulePermissionProbe() {
        guard let generation = permissionWatchdogGate.beginProbe() else { return }
        let permissionService = permissionService
        permissionProbeQueue.async { [weak self] in
            let trusted = permissionService.hasRequiredPermissions()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.permissionWatchdogGate.completeProbe(generation: generation) else { return }
                self.cachedAccessibilityTrusted = trusted
                self.permissionCoordinator?.sampleTrust(trusted)
            }
        }
    }

    func freezeLiftSnapshots() {
        windowLiftAvoidanceController?.beginPermissionUncertainty()
    }

    func unfreezeLiftSnapshots() {
        windowLiftAvoidanceController?.endPermissionUncertainty()
    }

    func suspendPanelsAndStores() {
        // 设置窗口也要一起收：权限一丢任务条整条被拆掉，留着一扇改任务条外观的窗
        // 既没有意义，也会挡住紧接着弹出的恢复引导。
        settingsWindowController.close()
        // 欢迎引导同理，而且更刺眼：任务条已经没了，屏幕上还留着一扇教你怎么配置它的窗。
        closeWelcomeWindow()
        messagingAutoRegisterSubscription?.cancel()
        messagingAutoRegisterSubscription = nil
        badgeContextSubscription?.cancel()
        badgeContextSubscription = nil
        runtime.onToggleDrawer = nil
        scrollReverserSettingSubscription?.cancel()
        scrollReverserSettingSubscription = nil
        scrollReverserMonitor?.stop()
        scrollReverserMonitor = nil
        DocumentUsageStore.shared.stop()
        panelCoordinator?.suspendAndRelease()
        panelCoordinator = nil
        badgeStore.stop()
        runtime.stop()
        runningApplicationStore.stop()
    }

    /// 权限刚回来，AX 才写得动窗口——整条恢复链把还原推迟到这一刻就是为了这个。
    func restoreLiftedWindows(episode: UInt64) async {
        await windowLiftAvoidanceController?.restoreAndStopForPermissionRecovery()
        windowLiftAvoidanceController = nil
    }

    func launchNewInstance(episode: UInt64) async -> Result<Void, Error> {
        let configuration = NSWorkspace.OpenConfiguration()
        // 这里制造第二个实例是**故意**的：新实例的 terminateOtherInstances() 会来收掉本实例。
        // 和「build_and_run.sh 里禁用 open -n」那条护栏不是一回事——那条禁的是构建脚本
        // 不等旧进程退出就凭空多开一份，制造出两条一模一样的任务条。
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let url = Bundle.main.bundleURL

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                // 这个 completion 在并发队列上回调。这里只 resume，
                // 后续动状态机 / 热键 / 界面的活儿都在协调器的 @MainActor Task 里做。
                if let error {
                    continuation.resume(returning: .failure(error))
                } else {
                    continuation.resume(returning: .success(()))
                }
            }
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    /// 用户直接叉掉欢迎引导，等同「以后再说」——**照样要记成已看过**，
    /// 否则叉一次、下次启动又弹一次。
    ///
    /// 程序主动关窗那条路（`closeWelcomeWindow()`）不会走到这里：它先把 `welcomeWindow`
    /// 置 nil、把 delegate 摘掉，然后才 `close()`。所以这个回调只代表「用户自己关的」，
    /// 不会和 `applyWelcomeSelection(_:)` / `dismissWelcomeGuide()` 重复标记。
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === welcomeWindow else { return }
        welcomeWindow = nil
        window.delegate = nil
        settingsStore.setHasSeenWelcome(true)
    }
}

/// 主循环卡顿探针的时钟（只在主线程的定时器回调里读写；`@unchecked` 因为 Timer 闭包要求 Sendable）。
private final class StallProbeClock: @unchecked Sendable {
    var expected: CFTimeInterval
    init(expected: CFTimeInterval) { self.expected = expected }
}
