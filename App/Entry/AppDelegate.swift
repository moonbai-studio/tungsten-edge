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
    private var panelCoordinator: PanelCoordinator?
    private var debugWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var messagingAutoRegisterSubscription: AnyCancellable?
    private var permissionPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 行缓冲 stdout：从命令行/后台启动时，print() 输出到文件默认是块缓冲，
        // 日志要攒满缓冲区才落盘。改成行缓冲后每条 print 立即写出，便于实时读日志。
        setvbuf(stdout, nil, _IOLBF, 0)
        NSApp.setActivationPolicy(.accessory)
        setupStatusBarItem()

        if AXIsProcessTrusted() {
            startApp()
        } else {
            requestAccessibilityPermission()
        }
    }

    private func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() {
                DispatchQueue.main.async { self?.handlePermissionGranted() }
            }
        }
    }

    private func handlePermissionGranted() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
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

        let coordinator = PanelCoordinator(runtime: runtime, drawerStore: drawerStore, messagingStore: messagingStore, launchFavoriteStore: launchFavoriteStore, badgeStore: badgeStore, stripOrderStore: stripOrderStore)
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
