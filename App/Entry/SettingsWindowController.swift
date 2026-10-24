import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: AppSettingsStore
    private let coordinator: SettingsCoordinator
    private let licenseStore: LicenseStore
    /// 「通用」页那颗「重新打开新手引导」按钮。闭包注入：引导窗归 `AppDelegate` 开
    /// （必须直通 `showWelcomeWindow()`，见那边的注释）。
    private let onShowWelcomeGuide: () -> Void
    private var window: NSWindow?
    private var hostingView: NSHostingView<SettingsWindowView>?
    private var sessionSubscriptions: Set<AnyCancellable> = []
    private var closedFrame: NSRect?
    private var hasPresented = false
    /// 所选标签（2026-08-24 分页）。controller 持有唯一一份 = 会话内记忆；
    /// 量高探针必须共享它，否则量的是别的页。有意不跨重启持久化。
    private let tabState = SettingsTabState()
    /// Feedback drafts outlive the window for the same reason: closing drops the host, and with
    /// it every `@State`. Deliberately not persisted across launches.
    private let feedbackDraft = FeedbackDraftState()
    private var diagnosticsSession: DiagnosticsSession?
    private let collectDiagnostics: (Bool, @escaping (String) -> Void) -> Void

    init(
        store: AppSettingsStore,
        coordinator: SettingsCoordinator,
        licenseStore: LicenseStore,
        collectDiagnostics: @escaping (Bool, @escaping (String) -> Void) -> Void,
        onShowWelcomeGuide: @escaping () -> Void
    ) {
        self.store = store
        self.coordinator = coordinator
        self.licenseStore = licenseStore
        self.collectDiagnostics = collectDiagnostics
        self.onShowWelcomeGuide = onShowWelcomeGuide
    }

    func present() {
        let window = window ?? makeWindow()
        let diagnostics = diagnosticsSession ?? DiagnosticsSession()
        diagnosticsSession = diagnostics
        if let closedFrame {
            window.setFrame(closedFrame, display: false)
            self.closedFrame = nil
        }
        let host = NSHostingView(
            rootView: SettingsWindowView(
                store: store,
                coordinator: coordinator,
                licenseStore: licenseStore,
                tabState: tabState,
                feedbackDraft: feedbackDraft,
                diagnostics: diagnostics,
                collectDiagnostics: collectDiagnostics,
                onShowWelcomeGuide: onShowWelcomeGuide
            )
        )
        window.contentView = host
        hostingView = host
        // 重开时把标题与工具栏选中态对齐会话记忆（便宜的保险，防将来有闭窗改选中的路径）。
        window.title = tabState.selected.title
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tabState.selected.rawValue)

        sessionSubscriptions.removeAll()
        // 登录项 2026-08-24 起只在状态栏菜单，设置窗口没有会变高矮的登录行了，它那条量高订阅随之删除。
        // 剩下两条都在「授权」页：激活成功后少掉输入框那一行，留完邮箱后订阅块塌成一行。
        // 少了订阅，内容原地变矮不会重新量高度，只会在窗口里留一片空白。
        licenseStore.$state
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizeToFitKeepingTopEdge() }
            }
            .store(in: &sessionSubscriptions)
        // 订阅块 2026-09-01 从「关于」搬到「授权」页。留完邮箱后整块塌成一行，
        // 这一页原地变矮——不补这条 sink 就只会在窗口里留一片空白。
        store.$hasSubscribed
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
        diagnosticsSession?.close()
        diagnosticsSession = nil
        sessionSubscriptions.removeAll()
        window.contentView = NSView()
        hostingView = nil
        // tabState 与 feedbackDraft 有意不重置：重开回到同一标签，写了一半的反馈还在。
    }

    /// A window losing key keeps its first responder, so a recorder left recording would still
    /// be recording when the user clicks back and swallow the next ⌘W as the new hot key.
    func windowDidResignKey(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window,
              window.firstResponder is HotKeyRecorderNSView else { return }
        window.makeFirstResponder(nil)
    }

    // MARK: 标签页

    /// 防 NSToolbar 自动校验把图标项置灰（我们的五个标签恒可点）。
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { true }

    @objc private func selectToolbarTab(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(tab: tab)
    }

    private func select(tab: SettingsTab) {
        // 点已选中的标签早退，不空放一遍高度动画。
        guard tabState.selected != tab else { return }
        // **先改再量**：量高探针共享这份 tabState，改完它量到的才是新页。
        tabState.selected = tab
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
        window?.title = tab.title
        resizeToFitKeepingTopEdge(animated: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsWindowView.contentWidth, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // 标题跟随所选标签（偏好设置惯例）；原静态标题的本地化 key 已随之删除。
        window.title = tabState.selected.title
        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        // 不落 NSToolbar Configuration 偏好键——与「不开 frame autosave」同族。
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(tabState.selected.rawValue)
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    /// `animated` 只有切页路径传 true（顶边左边固定、底边动画到新页高度）。
    /// `present()` 与授权 sink 走默认 false——与一页式时代的行为一致。
    private func resizeToFitKeepingTopEdge(animated: Bool = false) {
        guard let window, let diagnosticsSession else { return }
        // The probe must carry the same fixed width as the real window (`SettingsWindowView` puts
        // `.frame(width:)` outside its ScrollView). `fittingSize` proposes no width, so without it
        // every wrapping note measures single-line and the window comes up short by one line per
        // note that wraps — invisible in English, 30–45pt of clipped content in German and French.
        let probe = NSHostingView(
            rootView: SettingsWindowContent(
                store: store,
                coordinator: coordinator,
                licenseStore: licenseStore,
                tabState: tabState,
                feedbackDraft: feedbackDraft,
                diagnostics: diagnosticsSession,
                collectDiagnostics: collectDiagnostics,
                onShowWelcomeGuide: onShowWelcomeGuide
            )
            .frame(width: SettingsWindowView.contentWidth)
        )
        probe.setFrameSize(NSSize(width: SettingsWindowView.contentWidth, height: 0))
        probe.layoutSubtreeIfNeeded()
        let naturalHeight = probe.fittingSize.height
        let visibleHeight = preferredScreen()?.visibleFrame.height ?? 900
        // 下限 160：320 是一页式的地板，分页后最矮的「高级」页自然高不到它，硬撑会留一段空白。
        let contentHeight = max(160, min(naturalHeight, visibleHeight - 80))
        let oldTop = window.frame.maxY
        guard animated else {
            window.setContentSize(NSSize(width: SettingsWindowView.contentWidth, height: contentHeight))
            if hasPresented {
                window.setFrameOrigin(NSPoint(x: window.frame.minX, y: oldTop - window.frame.height))
                repairPlacement(isFirstPresentation: false)
            }
            return
        }
        // 切页动画：必须用**实例**的 frameRect(forContentRect:)——它含标题栏 + 工具栏高度，
        // 类方法不含，会让窗口每切一页长高一个工具栏。修位在动画**前**做：
        // 动画进行中读 window.frame 是插值，动画后再修会按半路的帧去钳。
        let contentRect = NSRect(x: 0, y: 0, width: SettingsWindowView.contentWidth, height: contentHeight)
        var target = window.frameRect(forContentRect: contentRect)
        target.origin.x = window.frame.minX
        target.origin.y = oldTop - target.height
        let titlebarHeight = max(1, window.frame.height - window.contentLayoutRect.height)
        let repaired = AccessoryWindowPresentation.repairedFrame(
            windowFrame: target,
            titlebarHeight: titlebarHeight,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            preferredVisibleFrame: preferredScreen()?.visibleFrame,
            isFirstPresentation: false
        )
        window.setFrame(repaired ?? target, display: true, animate: true)
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

extension SettingsWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// 漏掉这一条，标签点了会响应但**永不高亮**——AppKit 只给 selectable 集里的项画选中态。
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectToolbarTab(_:))
        return item
    }
}
