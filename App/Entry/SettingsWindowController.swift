import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: AppSettingsStore
    private let coordinator: SettingsCoordinator
    private var window: NSWindow?
    private var hostingView: NSHostingView<SettingsWindowView>?
    private var sessionSubscriptions: Set<AnyCancellable> = []
    private var closedFrame: NSRect?
    private var hasPresented = false

    init(store: AppSettingsStore, coordinator: SettingsCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    func present() {
        Task { @MainActor [weak coordinator] in
            _ = await coordinator?.refreshLaunchAtLoginState()
        }

        let window = window ?? makeWindow()
        if let closedFrame {
            window.setFrame(closedFrame, display: false)
            self.closedFrame = nil
        }
        let host = NSHostingView(rootView: SettingsWindowView(store: store, coordinator: coordinator))
        window.contentView = host
        hostingView = host

        sessionSubscriptions.removeAll()
        coordinator.$launchAtLoginState
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizeToFitKeepingTopEdge() }
            }
            .store(in: &sessionSubscriptions)

        resizeToFitKeepingTopEdge()
        repairPlacement(isFirstPresentation: !hasPresented)
        hasPresented = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 外部收尾入口（权限丢失挂起）。`close()` 会触发 `windowWillClose`，清理走那一条路。
    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        closedFrame = window.frame
        sessionSubscriptions.removeAll()
        window.contentView = NSView()
        hostingView = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsWindowView.contentWidth, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Tungsten Edge Settings")
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    private func resizeToFitKeepingTopEdge() {
        guard let window else { return }
        let probe = NSHostingView(rootView: SettingsWindowContent(store: store, coordinator: coordinator))
        probe.setFrameSize(NSSize(width: SettingsWindowView.contentWidth, height: 0))
        probe.layoutSubtreeIfNeeded()
        let naturalHeight = probe.fittingSize.height
        let visibleHeight = preferredScreen()?.visibleFrame.height ?? 900
        let contentHeight = max(320, min(naturalHeight, visibleHeight - 80))
        let oldTop = window.frame.maxY
        window.setContentSize(NSSize(width: SettingsWindowView.contentWidth, height: contentHeight))
        if hasPresented {
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: oldTop - window.frame.height))
            repairPlacement(isFirstPresentation: false)
        }
    }

    private func repairPlacement(isFirstPresentation: Bool) {
        guard let window else { return }
        let screens = NSScreen.screens
        let visibleFrames = screens.map(\.visibleFrame)
        let preferred = preferredScreen()?.visibleFrame
        let titlebarHeight = max(1, window.frame.height - window.contentLayoutRect.height)
        guard let repaired = AccessoryWindowPresentation.repairedFrame(
            windowFrame: window.frame,
            titlebarHeight: titlebarHeight,
            visibleFrames: visibleFrames,
            preferredVisibleFrame: preferred,
            isFirstPresentation: isFirstPresentation
        ) else { return }
        window.setFrame(repaired, display: false)
    }

    private func preferredScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? window?.screen ?? NSScreen.main
    }
}
