import AppKit
import Combine
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let inventoryLog = WindowInventoryAnomalyLog()
    private(set) lazy var runtime = AppRuntime(
        inventoryLog: inventoryLog,
        isAccessibilityTrusted: { [weak self] in self?.cachedAccessibilityTrusted ?? false },
        finderAlwaysInDock: { [weak self] in self?.settingsStore.finderAlwaysInDock ?? true }
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
    private var panelCoordinator: PanelCoordinator?
    private var windowLiftAvoidanceController: WindowLiftAvoidanceController?
    private lazy var launchAtLoginService = LaunchAtLoginService()
    private lazy var nativeDockPreferencesService = NativeDockPreferencesService()
    private lazy var settingsCoordinator = SettingsCoordinator(
        store: settingsStore,
        launchAtLoginService: launchAtLoginService,
        nativeDockPreferencesService: nativeDockPreferencesService,
        updateChecker: GitHubUpdateChecker(),
        subscriptionSubmitter: WebsiteSubscriptionSubmitter()
    )
    private lazy var settingsWindowController = SettingsWindowController(
        store: settingsStore,
        coordinator: settingsCoordinator
    )
    /// 常驻切换全局快捷键。回调只切设置（经 settingsStore），不经过 panelCoordinator——
    /// 后者在权限引导完成前是 nil，settingsStore 从 AppDelegate 构造起即存在。
    private var edgeToggleHotKey: GlobalHotKeyMonitor?
    private var terminationTask: Task<Void, Never>?
    private var debugWindow: NSWindow?
    private var permissionWindow: NSWindow?
    private var permissionHostingView: NSHostingView<PermissionOnboardingWindowContent>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var messagingAutoRegisterSubscription: AnyCancellable?
    private var windowLiftSettingSubscription: AnyCancellable?
    private var finderPersistenceSubscription: AnyCancellable?
    private var appearanceSubscription: AnyCancellable?
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
        toggleHotKeyShortcut: .edgeAutoHideMode,
        isToggleHotKeyRegistered: { [weak self] in self?.edgeToggleHotKey?.isRegistered ?? false }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 行缓冲 stdout：从命令行/后台启动时，print() 输出到文件默认是块缓冲，
        // 日志要攒满缓冲区才落盘。改成行缓冲后每条 print 立即写出，便于实时读日志。
        setvbuf(stdout, nil, _IOLBF, 0)

        // 首装时间戳：**故意放在所有分支判断之前**，搬家引导、权限引导、正常启动都要记。
        // 这三条分支的用户都是真的运行过钨极的人，将来转收费判定老用户时不该把谁漏掉。
        // 只写一次、之后永不覆盖，理由见 `InstallationRecord`。
        InstallationRecord.recordFirstLaunchIfNeeded()

        // 外观档位排在最前面：搬家引导、权限引导、正常启动三条分支的第一个窗口就得是对的外观。
        // `@Published` 订阅时先发一次当前值，所以这一句同时完成「启动时应用」和「之后跟随」。
        appearanceSubscription = settingsStore.$appearanceMode
            .sink { NSApp.appearance = $0.nsAppearance }

        // 「任务条常驻访达」开关变化时主动重算快照：开关本身不产生窗口事件，tracker 的周期
        // reconcile 不会 rebuild，不主动刷新会让旧的 Finder 常驻卡一直留在任务条上（issue #7）。
        // 注意：@Published 在 willSet 里发值，sink 里读 store 属性拿到的是旧值（本次故障根因），
        // 必须把发出来的 newValue 显式传下去，不能依赖闭包回读。
        finderPersistenceSubscription = settingsStore.$finderAlwaysInDock
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.runtime.refreshFinderPersistence(finderAlwaysInDock: newValue)
            }

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
            let hotKey = GlobalHotKeyMonitor(shortcut: .edgeAutoHideMode) { [weak self] in
                self?.settingsStore.toggleEdgeAutoHideMode()
            }
            edgeToggleHotKey = hotKey
            let hotKeyStatus = hotKey.start()
            if hotKeyStatus != .registered {
                Logger(subsystem: "com.caye.macosdockcc.v2", category: "hotkey")
                    .warning("常驻切换全局快捷键注册失败：\(String(describing: hotKeyStatus), privacy: .public)，本次启动不重试")
            }

            _ = statusMenuController
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
        permissionCoordinator?.terminationRequested()
        windowLiftAvoidanceController?.stop()
        runtime.stop()
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

        let coordinator = PanelCoordinator(
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
            appMembershipController: appMembershipController
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
        badgeStore.start()
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
        panel.prompt = "固定"
        panel.message = "选择要固定到任务条的文件夹"
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
        messagingAutoRegisterSubscription?.cancel()
        messagingAutoRegisterSubscription = nil
        runtime.onToggleDrawer = nil
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
