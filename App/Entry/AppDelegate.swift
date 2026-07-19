import AppKit
import Combine
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var runtime = AppRuntime()
    let drawerStore = DrawerStore()
    let messagingStore = MessagingAppStore()
    let badgeStore = BadgeStore()
    let keptAppStore = KeptAppStore()
    lazy var stripOrderStore = StripOrderStore(keptIDsProvider: { [keptAppStore] in Set(keptAppStore.bundleIDs) })
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
    /// 常驻切换全局快捷键。回调只切设置（经 settingsStore），不经过 panelCoordinator——
    /// 后者在权限引导完成前是 nil，settingsStore 从 AppDelegate 构造起即存在。
    private var edgeToggleHotKey: GlobalHotKeyMonitor?
    private var terminationTask: Task<Void, Never>?
    private var debugWindow: NSWindow?
    private var permissionWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var messagingAutoRegisterSubscription: AnyCancellable?
    private var permissionModel: AccessibilityPermissionModel?
    private let permissionService = PermissionService()
    private let permissionLogger = Logger(
        subsystem: "com.caye.macosdockcc.v2",
        category: "permissions"
    )
    private var hasStartedApp = false
    private lazy var statusMenuController = StatusMenuController(
        store: settingsStore,
        launchAtLoginService: LaunchAtLoginService(),
        nativeDockPreferencesService: NativeDockPreferencesService(),
        updateChecker: GitHubUpdateChecker(),
        isAccessibilityTrusted: { [permissionService] in permissionService.hasRequiredPermissions() },
        onShowDebugConsole: { [weak self] in self?.showDebugConsole() },
        onExportDebugSnapshot: { [weak self] in self?.exportDebugSnapshot() },
        onQuit: { NSApp.terminate(nil) },
        toggleHotKeyShortcut: .edgeAutoHideMode,
        isToggleHotKeyRegistered: { [weak self] in self?.edgeToggleHotKey?.isRegistered ?? false }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 行缓冲 stdout：从命令行/后台启动时，print() 输出到文件默认是块缓冲，
        // 日志要攒满缓冲区才落盘。改成行缓冲后每条 print 立即写出，便于实时读日志。
        setvbuf(stdout, nil, _IOLBF, 0)

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

        let installLocation = AppInstallLocation(bundleURL: Bundle.main.bundleURL)
        let isTrusted = permissionService.hasRequiredPermissions()
        logPermissionLaunch(installLocation: installLocation, isTrusted: isTrusted)

        if installLocation.allowsAccessibilityPrompt, isTrusted {
            NSApp.setActivationPolicy(.accessory)
            startApp()
        } else {
            // 没有权限时任务条不会创建任何面板，保持 accessory 会让用户只能看到一个
            // 不一定明显的状态栏图标；先用普通应用策略把权限引导窗口带到前台。
            NSApp.setActivationPolicy(.regular)
            requestAccessibilityPermission(
                installLocation: installLocation,
                initialTrusted: isTrusted
            )
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissionModel?.applicationDidBecomeActive()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 收尾等待（stopAndRestore）期间事件循环还在跑：先切断热键输入，避免设置被继续切换。
        edgeToggleHotKey?.stop()
        guard let controller = windowLiftAvoidanceController else { return .terminateNow }
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
        permissionModel?.stop()
        windowLiftAvoidanceController?.stop()
        runtime.stop()
    }

    private func requestAccessibilityPermission(
        installLocation: AppInstallLocation,
        initialTrusted: Bool
    ) {
        let model = AccessibilityPermissionModel(
            permissionService: permissionService,
            installLocation: installLocation,
            initialTrusted: initialTrusted
        )
        model.onGranted = { [weak self] in self?.handlePermissionGranted() }
        model.onTrustStatusChanged = { [weak self] isTrusted in
            self?.permissionLogger.info(
                "accessibility trust changed trusted=\(isTrusted, privacy: .public)"
            )
        }
        permissionModel = model
        showPermissionWindow(model: model)
        model.startPolling()
        // 临时挂载或 App Translocation 分支由 model 拒绝，不会向 TCC 注册该副本。
        model.requestSystemPromptIfNeeded()
    }

    private func handlePermissionGranted() {
        guard !hasStartedApp else { return }
        permissionModel?.stop()
        permissionModel = nil
        permissionWindow?.orderOut(nil)
        permissionWindow?.close()
        permissionWindow = nil
        NSApp.setActivationPolicy(.accessory)
        startApp()
    }

    private func showPermissionWindow(model: AccessibilityPermissionModel) {
        if let permissionWindow {
            permissionWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tungsten Edge 钨极"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PermissionOnboardingView(
            model: model,
            onOpenSettings: { [weak self] in self?.openAccessibilitySettings() },
            onOpenApplications: { [weak self] in self?.openApplicationsFolder() },
            onQuit: { NSApp.terminate(nil) }
        ))
        window.center()
        permissionWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    private func logPermissionLaunch(
        installLocation: AppInstallLocation,
        isTrusted: Bool
    ) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        permissionLogger.info(
            "permission launch version=\(version, privacy: .public) build=\(build, privacy: .public) location=\(installLocation.rawValue, privacy: .public) trusted=\(isTrusted, privacy: .public) bundlePath=\(Bundle.main.bundleURL.path, privacy: .private(mask: .hash))"
        )
    }

    private func startApp() {
        guard !hasStartedApp else { return }
        hasStartedApp = true
        appMembershipController.reconcileInvalidMemberships()
        runningApplicationStore.start()
        runtime.start()

        // Auto tier of the messaging list: whenever the running set changes, register
        // any app matching the whitelist / social-networking category and seed kept on
        // first registration (default-keep). Kept no longer excludes messaging, so
        // there is no kept filter; the running source is the process store, not window
        // snapshots.
        messagingAutoRegisterSubscription = runningApplicationStore.$runningBundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.appMembershipController.autoRegisterMessaging(runningBundleIDs: running)
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
        coordinator.start()
        let windowLiftAvoidanceController = WindowLiftAvoidanceController(host: coordinator)
        self.windowLiftAvoidanceController = windowLiftAvoidanceController
        windowLiftAvoidanceController.start()
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
        window.contentView = NSHostingView(rootView: DebugConsoleView().environmentObject(runtime))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window
    }

}
