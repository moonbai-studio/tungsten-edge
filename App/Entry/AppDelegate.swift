import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let panelHeight: CGFloat = 52

    private(set) var runtime = AppRuntime()
    private var dockPanel: NSPanel?
    private var debugWindow: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        runtime.start()
        setupDockPanel()
        setupStatusBarItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
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

    private func setupDockPanel() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = panelFrame(for: screen)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        let hosting = NSHostingView(rootView: DockStripView().environmentObject(runtime))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        dockPanel = panel
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

    @objc private func showDebugConsoleFromMenu() {
        showDebugConsole()
    }

    @objc private func exportDebugSnapshotFromMenu() {
        exportDebugSnapshot()
    }

    @objc private func screenParametersChanged() {
        guard let panel = dockPanel, let screen = NSScreen.main else { return }
        panel.setFrame(panelFrame(for: screen), display: true, animate: false)
    }

    private func panelFrame(for screen: NSScreen) -> NSRect {
        let s = screen.frame
        return NSRect(x: s.minX, y: s.minY, width: s.width, height: Self.panelHeight)
    }
}
