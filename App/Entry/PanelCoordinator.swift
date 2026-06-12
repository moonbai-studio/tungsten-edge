import AppKit
import ApplicationServices
import Combine
import SwiftUI
import os

@MainActor
final class PanelCoordinator: NSObject {
    static let panelHeight: CGFloat = 52

    private let runtime: AppRuntime
    private let drawerStore: DrawerStore
    private let messagingStore: MessagingAppStore
    private let badgeStore: BadgeStore
    private var dockPanel: NSPanel?
    private var drawerPanel: NSPanel?
    private var capsulePanel: NSPanel?
    private var drawerLocalMonitor: Any?
    private var drawerGlobalMonitor: Any?
    private var snapshotWidthSubscription: AnyCancellable?
    private var drawerStoreWidthSubscription: AnyCancellable?
    private var messagingStoreWidthSubscription: AnyCancellable?
    private var lastDesiredWidth: CGFloat = 0
    private var lastDrawerSize: CGSize = CGSize(width: 210, height: 60)
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "dock-panel")

    private var isHiddenForFullscreen = false
    private var fullscreenReconcileTimer: Timer?

    init(runtime: AppRuntime, drawerStore: DrawerStore, messagingStore: MessagingAppStore, badgeStore: BadgeStore) {
        self.runtime = runtime
        self.drawerStore = drawerStore
        self.messagingStore = messagingStore
        self.badgeStore = badgeStore
        super.init()
    }

    func start() {
        setupDockPanel()
        setupCapsulePanel()
        subscribeSnapshotWidth()
        subscribeDrawerStoreWidth()
        subscribeMessagingStoreWidth()
        setupFullscreenMonitor()
        setupHoverDiagnostics()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func toggleDrawer() {
        guard let mainPanel = dockPanel else { return }

        if let panel = drawerPanel, panel.isVisible {
            closeDrawer()
            return
        }

        if drawerPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: lastDrawerSize),
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
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            let hosting = NSHostingView(rootView: DrawerView().environmentObject(runtime).environmentObject(drawerStore).environmentObject(messagingStore))
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = CGColor.clear
            panel.contentView = hosting
            drawerPanel = panel
        }

        guard let capsule = capsulePanel else { return }
        let screen = panelCurrentScreen(panel: mainPanel)
        let vf = screen.visibleFrame
        let capsuleFrame = capsule.frame
        let s = lastDrawerSize
        let rawX = capsuleFrame.maxX - s.width
        let rawY = capsuleFrame.maxY + 8
        let clampedX = min(max(rawX, vf.minX), vf.maxX - s.width)
        let clampedY = min(max(rawY, vf.minY), vf.maxY - s.height)
        drawerPanel?.setFrame(NSRect(x: clampedX, y: clampedY, width: s.width, height: s.height), display: false)
        drawerPanel?.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.syncDrawerPanel()
            }
        }

        drawerLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.dismissDrawerIfOutside()
            return event
        }
        drawerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dismissDrawerIfOutside()
        }
    }

    private func syncDrawerPanel() {
        guard let drawer = drawerPanel, drawer.isVisible,
              let capsule = capsulePanel,
              let dock = dockPanel,
              let hosting = drawer.contentView else { return }
        let fitting = hosting.fittingSize
        let drawerSize = CGSize(width: max(fitting.width, 60), height: max(fitting.height, 60))
        lastDrawerSize = drawerSize
        let screen = panelCurrentScreen(panel: dock)
        let vf = screen.visibleFrame
        let capsuleFrame = capsule.frame
        let rawX = capsuleFrame.maxX - drawerSize.width
        let rawY = capsuleFrame.maxY + 8
        let clampedX = min(max(rawX, vf.minX), vf.maxX - drawerSize.width)
        let clampedY = min(max(rawY, vf.minY), vf.maxY - drawerSize.height)
        drawer.setFrame(NSRect(x: clampedX, y: clampedY, width: drawerSize.width, height: drawerSize.height), display: true)
    }

    private func closeDrawer() {
        drawerPanel?.orderOut(nil)
        if let m = drawerLocalMonitor  { NSEvent.removeMonitor(m); drawerLocalMonitor  = nil }
        if let m = drawerGlobalMonitor { NSEvent.removeMonitor(m); drawerGlobalMonitor = nil }
    }

    private func dismissDrawerIfOutside() {
        guard let drawer = drawerPanel, drawer.isVisible,
              let dock   = dockPanel else { return }
        let mouse = NSEvent.mouseLocation
        guard !drawer.frame.contains(mouse),
              !dock.frame.contains(mouse),
              !(capsulePanel?.frame.contains(mouse) ?? false) else { return }
        closeDrawer()
    }

    private func setupDockPanel() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let s = screen.frame

        let panel = NSPanel(
            contentRect: NSRect(x: s.minX, y: s.minY + Self.bottomGap, width: s.width, height: Self.panelHeight),
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
        panel.hasShadow = true

        let hosting = NSHostingView(rootView: DockStripView().environmentObject(runtime).environmentObject(drawerStore).environmentObject(messagingStore).environmentObject(badgeStore))
        hosting.autoresizingMask = [.width, .height]
        // Prevent NSHostingView from adding its own opaque background over the blur
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        panel.contentView = hosting
        panel.orderFrontRegardless()
        dockPanel = panel
    }

    private func setupCapsulePanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: Self.capsuleWidth, height: Self.capsuleWidth)),
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
        panel.hasShadow = true
        let hosting = NSHostingView(rootView:
            DrawerCapsuleButton { [weak self] in self?.toggleDrawer() }
                .environmentObject(runtime)
                .environmentObject(drawerStore)
        )
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        panel.contentView = hosting
        panel.orderFrontRegardless()
        capsulePanel = panel
    }

    private func syncCapsulePanel() {
        guard let dock = dockPanel, let capsule = capsulePanel else { return }
        let screen = panelCurrentScreen(panel: dock)
        let vf = screen.visibleFrame
        let dockFrame = dock.frame
        let rawX = dockFrame.maxX + Self.capsuleGap
        let rawY = dockFrame.minY + (Self.panelHeight - Self.capsuleWidth) / 2
        let clampedX = min(max(rawX, vf.minX), vf.maxX - Self.capsuleWidth)
        let clampedY = min(max(rawY, vf.minY), vf.maxY - Self.capsuleWidth)
        let targetFrame = NSRect(x: clampedX, y: clampedY, width: Self.capsuleWidth, height: Self.capsuleWidth)
        capsule.setFrame(targetFrame, display: true)
        Logger(subsystem: "com.caye.macosdockcc.v2", category: "Drawer")
            .info("syncCapsule dockFrame=(\(dockFrame.minX, privacy: .public),\(dockFrame.minY, privacy: .public),\(dockFrame.width, privacy: .public),\(dockFrame.height, privacy: .public)) capsuleFrame=(\(targetFrame.minX, privacy: .public),\(targetFrame.minY, privacy: .public),\(targetFrame.width, privacy: .public),\(targetFrame.height, privacy: .public)) vf=(\(vf.minX, privacy: .public),\(vf.minY, privacy: .public),\(vf.width, privacy: .public),\(vf.height, privacy: .public))")
    }

    // MARK: - Content Width via fittingSize

    private func subscribeSnapshotWidth() {
        snapshotWidthSubscription = runtime.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Defer one run-loop cycle so SwiftUI finishes layout before we read fittingSize
                DispatchQueue.main.async { [weak self] in
                    self?.measureAndApplyWidth()
                }
            }
    }

    private func subscribeDrawerStoreWidth() {
        drawerStoreWidthSubscription = drawerStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.measureAndApplyWidth()
                }
            }
    }

    private func subscribeMessagingStoreWidth() {
        messagingStoreWidthSubscription = messagingStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.measureAndApplyWidth()
                }
            }
    }

    private func measureAndApplyWidth() {
        guard let hosting = dockPanel?.contentView else { return }
        let contentWidth = hosting.fittingSize.width
        lastDesiredWidth = contentWidth
        applyPanelWidth(contentWidth)
    }

    private func repositionPanel(width desiredWidth: CGFloat, on screen: NSScreen) {
        guard let panel = dockPanel else { return }
        let maxWidth = screen.visibleFrame.width - 2 * (Self.outerMargin + Self.capsuleGap + Self.capsuleWidth)
        let panelWidth = max(min(desiredWidth, maxWidth), 120)
        let frame = centeredPanelFrame(panelWidth: panelWidth, screen: screen)
        panel.setFrame(frame, display: true)
        syncCapsulePanel()
    }

    private func applyPanelWidth(_ contentWidth: CGFloat) {
        guard let panel = dockPanel else { return }
        let screen = panelCurrentScreen(panel: panel)
        let visibleFrame = screen.visibleFrame
        let maxWidth = screen.visibleFrame.width - 2 * (Self.outerMargin + Self.capsuleGap + Self.capsuleWidth)
        let panelWidth = max(min(contentWidth, maxWidth), 120)
        let frame = centeredPanelFrame(panelWidth: panelWidth, screen: screen)

        logger.info("applyPanelWidth contentWidth=\(contentWidth, privacy: .public) panelWidth=\(panelWidth, privacy: .public) maxWidth=\(maxWidth, privacy: .public) frame=(\(frame.origin.x, privacy: .public),\(frame.origin.y, privacy: .public),\(frame.width, privacy: .public),\(frame.height, privacy: .public)) visibleFrame=(\(visibleFrame.origin.x, privacy: .public),\(visibleFrame.origin.y, privacy: .public),\(visibleFrame.width, privacy: .public),\(visibleFrame.height, privacy: .public))")

        repositionPanel(width: contentWidth, on: screen)
    }

    @objc private func screenParametersChanged() {
        guard let panel = dockPanel else { return }
        let screen = panelCurrentScreen(panel: panel)
        let contentWidth = panel.contentView?.fittingSize.width ?? 0
        let maxWidth = screen.visibleFrame.width - 2 * (Self.outerMargin + Self.capsuleGap + Self.capsuleWidth)
        let panelWidth = max(min(contentWidth, maxWidth), 120)
        panel.setFrame(centeredPanelFrame(panelWidth: panelWidth, screen: screen), display: true, animate: false)
        syncCapsulePanel()
    }

    // MARK: - Fullscreen Monitor

    private func setupFullscreenMonitor() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleSpaceChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleAppActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        fullscreenReconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fullscreenReconcileIfNeeded() }
        }
    }

    @objc private func handleSpaceChange() {
        // Sync CG check: fires before the panel has a chance to appear, no AX = no main-thread risk
        let cgFullscreen = checkFullscreenViaCGSync()
        applyFullscreenVisibility(cgFullscreen)
        // Async AX secondary check: catches edge cases CG misses (e.g. games on a non-zero layer)
        triggerAsyncFullscreenCheck()
    }

    @objc private func handleAppActivated() {
        triggerAsyncFullscreenCheck()
    }

    // MARK: - Sync CG fullscreen probe (main thread only, no AX)

    private func checkFullscreenViaCGSync() -> Bool {
        guard let panel = dockPanel else { return false }
        let screen = panelCurrentScreen(panel: panel)
        let screenCGFrame = Self.toCGRect(screen)
        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ourPID else { continue }
            guard let dict = info[kCGWindowBounds as String] as? [String: Any],
                  let cgBounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            // Only consider windows on the panel's screen (must overlap significantly)
            guard cgBounds.intersects(screenCGFrame), cgBounds.width > screenCGFrame.width * 0.7 else { continue }
            // Frontmost matching window found — check if it fills the screen
            let t: CGFloat = 8
            return abs(cgBounds.width  - screenCGFrame.width)  < t
                && abs(cgBounds.height - screenCGFrame.height) < t
                && abs(cgBounds.minX   - screenCGFrame.minX)   < t
                && abs(cgBounds.minY   - screenCGFrame.minY)   < t
        }
        return false
    }

    // MARK: - Async AX fullscreen probe (secondary / fallback)

    private func triggerAsyncFullscreenCheck() {
        guard let panel = dockPanel else { return }
        // Convert to CG coords on main thread; AX kAXPositionAttribute also uses CG (top-left origin)
        let screenCGFrame = Self.toCGRect(panelCurrentScreen(panel: panel))
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task.detached { [weak self] in
            let fullscreen = Self.detectFullscreenViaAX(pid: frontPID, screenCGFrame: screenCGFrame)
            await MainActor.run { [weak self] in self?.applyFullscreenVisibility(fullscreen) }
        }
    }

    private func fullscreenReconcileIfNeeded() {
        guard isHiddenForFullscreen else { return }
        triggerAsyncFullscreenCheck()
    }

    private func applyFullscreenVisibility(_ isFullscreen: Bool) {
        guard isFullscreen != isHiddenForFullscreen else { return }
        isHiddenForFullscreen = isFullscreen
        guard let panel = dockPanel else { return }
        if isFullscreen {
            panel.orderOut(nil)
            logger.info("[fullscreen] panel hidden")
        } else {
            panel.orderFront(nil)
            logger.info("[fullscreen] panel restored")
        }
    }

    private func panelCurrentScreen(panel: NSPanel) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // AppKit frame (bottom-left origin) → CG/Quartz frame (top-left origin of primary screen)
    private static func toCGRect(_ screen: NSScreen) -> CGRect {
        let primaryH = NSScreen.main?.frame.height ?? 0
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
    }

    nonisolated private static func detectFullscreenViaAX(pid: pid_t?, screenCGFrame: CGRect) -> Bool {
        guard let pid else { return false }
        let reader = AXWindowReader()
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.5)

        guard let focused = reader.elementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement) else {
            return false
        }
        _ = AXUIElementSetMessagingTimeout(focused, 0.5)

        let isAXFullscreen = reader.boolAttribute("AXFullScreen" as CFString, from: focused, maxAttempts: 1) ?? false
        // AX kAXPositionAttribute uses CG coordinates (top-left origin) — matches screenCGFrame directly
        let windowFrame = reader.frame(of: focused, maxAttempts: 1)

        if isAXFullscreen {
            guard let wf = windowFrame else { return true }
            return wf.intersects(screenCGFrame) && wf.width > screenCGFrame.width * 0.7
        }

        // Fallback: frame ≈ full screen (games / HTML5 that skip the AXFullScreen flag)
        if let wf = windowFrame {
            let t: CGFloat = 8
            return abs(wf.width  - screenCGFrame.width)  < t
                && abs(wf.height - screenCGFrame.height) < t
                && abs(wf.minX   - screenCGFrame.minX)   < t
                && abs(wf.minY   - screenCGFrame.minY)   < t
        }

        return false
    }

    // MARK: - HoverSwitch Diagnostics

    private let hoverLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "HoverSwitch")
    private static let hoverHotZone: CGFloat = 4.0
    private static let hoverVerboseLogging = false
    private var hoverPollTimer: Timer?
    private var hoverLastScreenIndex: Int? = nil
    private var hoverLastInHotZone: Bool? = nil

    private func setupHoverDiagnostics() {
        if Self.hoverVerboseLogging { logScreenMap() }
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollMousePosition() }
        }
    }

    private func logScreenMap() {
        let screens = NSScreen.screens
        for (i, screen) in screens.enumerated() {
            let f = screen.frame
            let vf = screen.visibleFrame
            hoverLogger.info("screen-map index=\(i, privacy: .public) name=\(screen.localizedName, privacy: .public) frame=(\(f.minX, privacy: .public),\(f.minY, privacy: .public),\(f.width, privacy: .public),\(f.height, privacy: .public)) visibleFrame=(\(vf.minX, privacy: .public),\(vf.minY, privacy: .public),\(vf.width, privacy: .public),\(vf.height, privacy: .public)) isMain=\(screen == NSScreen.main, privacy: .public) isScreens0=\(i == 0, privacy: .public)")
        }
    }

    private func pollMousePosition() {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens

        var curScreenIdx: Int? = nil
        var curScreen: NSScreen? = nil
        for (i, s) in screens.enumerated() {
            if s.frame.contains(mouse) { curScreenIdx = i; curScreen = s; break }
        }

        let dyFromBottom: CGFloat
        let inHotZone: Bool
        if let s = curScreen {
            dyFromBottom = mouse.y - s.frame.minY
            inHotZone = dyFromBottom <= Self.hoverHotZone
        } else {
            dyFromBottom = -1
            inHotZone = false
        }

        guard curScreenIdx != hoverLastScreenIndex || inHotZone != hoverLastInHotZone else { return }
        hoverLastScreenIndex = curScreenIdx
        hoverLastInHotZone = inHotZone

        if Self.hoverVerboseLogging {
            let panelScreenIdx = dockPanel.map { p -> String in
                let ps = panelCurrentScreen(panel: p)
                return screens.firstIndex(of: ps).map { "\($0)" } ?? "?"
            } ?? "nil"
            if let s = curScreen, let idx = curScreenIdx {
                let f = s.frame
                let vf = s.visibleFrame
                hoverLogger.info("cursor screen=\(idx, privacy: .public) name=\(s.localizedName, privacy: .public) mouse=(\(mouse.x, privacy: .public),\(mouse.y, privacy: .public)) frame=(\(f.minX, privacy: .public),\(f.minY, privacy: .public),\(f.width, privacy: .public),\(f.height, privacy: .public)) visibleFrame=(\(vf.minX, privacy: .public),\(vf.minY, privacy: .public),\(vf.width, privacy: .public),\(vf.height, privacy: .public)) dyFromBottom=\(dyFromBottom, privacy: .public) inHotZone=\(inHotZone, privacy: .public) panelScreen=\(panelScreenIdx, privacy: .public)")
            } else {
                hoverLogger.info("cursor screen=none mouse=(\(mouse.x, privacy: .public),\(mouse.y, privacy: .public)) dyFromBottom=none inHotZone=false panelScreen=\(panelScreenIdx, privacy: .public)")
            }
        }

        // Hover switch: cursor just entered hot zone of a different screen → move panel there
        if inHotZone, let targetScreen = curScreen, let panel = dockPanel {
            let panelScreen = panelCurrentScreen(panel: panel)
            if targetScreen != panelScreen {
                let fromIdx = screens.firstIndex(of: panelScreen).map { "\($0)" } ?? "?"
                let toIdx = screens.firstIndex(of: targetScreen).map { "\($0)" } ?? "?"
                let actualWidth = max(min(lastDesiredWidth, targetScreen.visibleFrame.width - 2 * Self.outerMargin), 120)
                repositionPanel(width: lastDesiredWidth, on: targetScreen)
                hoverLogger.info("switch toScreen=\(toIdx, privacy: .public) name=\(targetScreen.localizedName, privacy: .public) actualWidth=\(actualWidth, privacy: .public) fromScreen=\(fromIdx, privacy: .public)")
            }
        }
    }

    // MARK: - Frame Helpers

    private static let bottomGap: CGFloat = 8
    private static let outerMargin: CGFloat = 12
    private static let capsuleWidth: CGFloat = 52
    private static let capsuleGap: CGFloat = 8

    private func centeredPanelFrame(panelWidth: CGFloat, screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let x = vf.minX + (vf.width - panelWidth) / 2
        return NSRect(x: x, y: screen.frame.minY + Self.bottomGap, width: panelWidth, height: Self.panelHeight)
    }
}
