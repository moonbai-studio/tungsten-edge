import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var runtime = AppRuntime()
    let drawerStore = DrawerStore()
    let messagingStore = MessagingAppStore()
    private var panelCoordinator: PanelCoordinator?
    private var debugWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        runtime.start()

        let coordinator = PanelCoordinator(runtime: runtime, drawerStore: drawerStore, messagingStore: messagingStore)
        panelCoordinator = coordinator
        runtime.onToggleDrawer = { [weak coordinator] in coordinator?.toggleDrawer() }
        coordinator.start()

        setupStatusBarItem()
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
