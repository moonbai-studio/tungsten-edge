import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var runtime = AppRuntime()
    let drawerStore = DrawerStore()
    let messagingStore = MessagingAppStore()
    let launchFavoriteStore = LaunchFavoriteStore()
    let badgeStore = BadgeStore()
    let stripOrderStore = StripOrderStore()
    let drawerOrderStore = DrawerOrderStore()
    private var panelCoordinator: PanelCoordinator?
    private var debugWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var messagingAutoRegisterSubscription: AnyCancellable?
    private var permissionModel: AccessibilityPermissionModel?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 行缓冲 stdout：从命令行/后台启动时，print() 输出到文件默认是块缓冲，
        // 日志要攒满缓冲区才落盘。改成行缓冲后每条 print 立即写出，便于实时读日志。
        setvbuf(stdout, nil, _IOLBF, 0)
        NSApp.setActivationPolicy(.accessory)
        setupStatusBarItem()

        // 调试旗：本地签名的开发版无法用 tccutil 可靠撤销辅助功能权限，
        // 设 DOCK_FORCE_ONBOARDING=1 可强制展示权限引导窗口（演示/截图用），
        // 窗口停在真实新用户看到的「待开启」状态。
        let forceOnboarding = ProcessInfo.processInfo.environment["DOCK_FORCE_ONBOARDING"] == "1"
        if AXIsProcessTrusted() && !forceOnboarding {
            startApp()
        } else {
            requestAccessibilityPermission(demo: forceOnboarding)
        }
    }

    private func requestAccessibilityPermission(demo: Bool = false) {
        // 系统原生提示框：既弹出"打开系统设置"按钮，又把本应用注册进辅助功能列表
        // （这样用户进设置页时已能直接看到 Tungsten Edge 的开关，无需点"+"号去找）。
        if !demo {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        let model = AccessibilityPermissionModel(demoMode: demo)
        model.onGranted = { [weak self] in self?.handlePermissionGranted() }
        permissionModel = model
        showOnboardingWindow(model: model)
        model.startPolling()
    }

    private func showOnboardingWindow(model: AccessibilityPermissionModel) {
        let hosting = NSHostingView(rootView: PermissionOnboardingView(model: model))
        // 固定一个稳妥的初始尺寸——不能直接 setContentSize(fittingSize)：刚挂上 contentView
        // 时 NSHostingView 尚未完成布局，fittingSize 会返回 0×0，窗口被缩成不可见。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tungsten Edge"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 下一轮 runloop 布局完成后，再按真实内容高度精修一次并重新居中。
        DispatchQueue.main.async {
            let fit = hosting.fittingSize
            if fit.width > 100, fit.height > 100 {
                window.setContentSize(fit)
                window.center()
            }
        }
        onboardingWindow = window
    }

    private func handlePermissionGranted() {
        permissionModel?.stop()
        permissionModel = nil
        onboardingWindow?.close()
        onboardingWindow = nil
        startApp()
    }

    private func startApp() {
        runtime.start()

        // Auto tier of the messaging list: whenever the snapshot updates, register any
        // running app that matches the whitelist / social-networking category.
        // Launch favorites are excluded: 待启动 is an explicit membership and the four
        // memberships are mutually exclusive — auto detection must not pull a
        // just-registered favorite back into the messaging zone.
        messagingAutoRegisterSubscription = runtime.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                let running = Set(snapshot.windows.values.compactMap(\.bundleIdentifier))
                    .filter { !self.launchFavoriteStore.contains($0) }
                self.messagingStore.autoRegister(runningBundleIDs: running)
            }

        let coordinator = PanelCoordinator(runtime: runtime, drawerStore: drawerStore, messagingStore: messagingStore, launchFavoriteStore: launchFavoriteStore, badgeStore: badgeStore, stripOrderStore: stripOrderStore, drawerOrderStore: drawerOrderStore)
        panelCoordinator = coordinator
        runtime.onToggleDrawer = { [weak coordinator] in coordinator?.toggleDrawer() }
        coordinator.start()
        badgeStore.start()
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

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.3.offgrid.fill", accessibilityDescription: "Dock")

        let menu = NSMenu()
        menu.addItem(withTitle: "显示调试台", action: #selector(showDebugConsoleFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "导出任务条快照", action: #selector(exportDebugSnapshotFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    @objc private func showDebugConsoleFromMenu() { showDebugConsole() }
    @objc private func exportDebugSnapshotFromMenu() { exportDebugSnapshot() }
}
