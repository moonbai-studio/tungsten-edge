import AppKit
import os
import SwiftUI

/// A chip that represents an app by bundle identifier rather than a concrete window.
/// Renders the three launcher states (not running / running-no-window / running-hidden)
/// and handles tap-to-launch, tap-to-reopen, and the launch bounce animation.
///
/// Shared by the drawer (collected apps, scale 0.7) and the main strip (pinned
/// messaging apps, scale 1.0). The only call-site difference is the membership-removal
/// menu item, injected via `removeMenuLabel` + `onRemove`.
struct LauncherChip: View {
    let bundleID: String
    let isRunning: Bool   // derived from runtime.snapshot by the parent view
    let isHidden: Bool    // derived from runtime.snapshot by the parent view
    var scale: CGFloat = 0.7
    /// Drawer chips dim by run/hidden state; pinned messaging chips on the strip
    /// stay full-opacity (product decision: "always reachable", not degraded).
    var dimsWhenInactive: Bool = true
    /// Last context-menu item, e.g. "移回任务栏" (drawer) or "取消标记消息应用" (messaging).
    /// nil for 待启动 launch buttons: membership management lives on the running
    /// chip's context menu only (沉淀原则 2026-06-11, no menu on launch buttons).
    var removeMenuLabel: String? = nil
    var onRemove: () -> Void = {}
    /// When set, replaces the default tap behavior (drawer show/hide toggle). Used by
    /// the strip's messaging app chip, whose tap must always reopen the main window.
    var onTap: (() -> Void)? = nil
    /// Fired when this chip actually kicks off a launch (tap on a not-running app).
    /// The drawer wires it to `runtime.beginLaunch` for the 窗口出现门控 (keeps the
    /// app bouncing in the launch zone until its window shows, not just its process).
    var onLaunch: () -> Void = {}
    /// Fired after a primary tap action has been successfully dispatched (hide / unhide+activate / launch).
    /// Only set by DrawerView; strip messaging chips leave it nil.
    /// Guard failures (missing URL, isLaunching already) do NOT fire this — it means "action went out".
    var onPrimaryAction: (() -> Void)? = nil

    private static let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "LauncherChip")

    @State private var isLaunching = false
    @State private var isHovering = false

    /// 弹跳动画：偏移量由 isLaunching 声明式推导，动画类型也跟着 isLaunching 切换。
    /// 关键——绝不能用「withAnimation(.repeatForever) 起跳 + withAnimation 把值设回 0」
    /// 这种命令式写法：另一个动画停不掉已在运行的 .repeatForever，会留下永远跳动的
    /// 僵尸动画（2026-06-18 实测：弹跳不止的真凶）。声明式 .animation(value:) 在
    /// isLaunching 变 false 时自动换成有限动画，循环动画从根上消失。
    private var bounceAnimation: Animation {
        isLaunching
            ? .easeInOut(duration: 0.25).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.15)
    }

    var body: some View {
        let iconSize: CGFloat = isHovering ? 24 * scale : 36 * scale
        let iconOpacity: Double = dimsWhenInactive ? (!isRunning ? 0.35 : (isHidden ? 0.45 : 1.0)) : 1.0
        return VStack(spacing: 2) {
            Spacer(minLength: 0)
            Image(nsImage: AppIconResolver.icon(for: bundleID))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize / 4, style: .continuous))
                .opacity(iconOpacity)
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                .offset(y: isLaunching ? -6 : 0)
                .animation(bounceAnimation, value: isLaunching)
            if isHovering {
                Text(displayName)
                    .font(.system(size: max(8, 10 * scale), weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: 64 * scale)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 44 * scale, height: 52 * scale)
        .overlay(alignment: .bottom) {
            if isRunning {
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 4, height: 4)
                    .padding(.bottom, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if let onTap { onTap() } else { handleTap() }
        }
        .nativeContextMenu { buildLauncherMenu() }
        .help(displayName)
        .onDisappear { stopBounce() }
        .onChange(of: isRunning) { newValue in
            if newValue { stopBounce() }
        }
        .animation(.easeInOut(duration: 0.18), value: isHovering)
    }

    private func buildLauncherMenu() -> NSMenu {
        let menu = NSMenu()
        let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
        // 守沉淀原则「纯固定启动按钮无右键菜单」：该项菜单本就为空（未运行 + 无「移回」项）时
        // 不加最近文件；只给运行中或已收纳（removeMenuLabel 非 nil）的项置顶最近文件。
        if runningApp != nil || removeMenuLabel != nil {
            AppMenuBuilder.appendRecentDocumentsSubmenu(to: menu, bundleID: bundleID)
        }
        if let app = runningApp {
            if app.isHidden {
                menu.addItem(ClosureMenuItem("显示") {
                    _ = app.unhide()
                    app.activate(options: .activateIgnoringOtherApps)
                })
            } else {
                menu.addItem(ClosureMenuItem("隐藏") { _ = app.hide() })
            }
            AppMenuBuilder.appendQuitItems(to: menu, bundleID: bundleID) { _ = app.terminate() }
            if removeMenuLabel != nil { menu.addItem(.separator()) }
        }
        if let removeMenuLabel {
            menu.addItem(ClosureMenuItem(removeMenuLabel) { onRemove() })
        }
        return menu
    }

    private func handleTap() {
        if isRunning {
            let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
            if let app, app.isActive {
                // 在前台 → 收起
                _ = app.hide()
                onPrimaryAction?()
            } else {
                // 未激活 / 隐藏 / 窗口已关 → 唤出
                guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
                _ = app?.unhide()
                NSWorkspace.shared.openApplication(at: appURL, configuration: .init(), completionHandler: nil)
                onPrimaryAction?()
            }
        } else {
            guard !isLaunching else { return }
            launch()   // onPrimaryAction fired inside launch() after URL guard
        }
    }

    private var displayName: String {
        AppDisplayNameResolver.displayName(for: bundleID)
    }

    /// 停跳：只翻 isLaunching。偏移量与动画类型都声明式绑定它，置 false 即换成
    /// 有限动画收敛到 0，循环动画随之消失（见 bounceAnimation 注释）。
    private func stopBounce() {
        isLaunching = false
    }

    private func launch() {
        Self.logger.info("launch() 入口，bundleID=\(bundleID, privacy: .public)")
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Self.logger.warning("launch()：找不到 app URL，bundleID=\(bundleID, privacy: .public)")
            return
        }

        isLaunching = true
        onLaunch()
        onPrimaryAction?()

        // 8s timeout backstop（对 menubar-only app 无窗口回调的情况兜底）
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            stopBounce()
        }

        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, error in
            if let error {
                Self.logger.error("launch()：openApplication 失败，bundleID=\(bundleID, privacy: .public)，error=\(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                stopBounce()
            }
        }
    }
}

// MARK: - App Display Name Resolver

/// Resolves human-readable names for a bundle identifier, with caching (bundle plist
/// reads involve disk IO and these get called from SwiftUI body evaluations).
/// Also answers "does this window title look like the app's main window?" — the
/// 方案 B heuristic: a messaging app's main window is the one titled like the app
/// itself (微信 / WeChat / Telegram…), verified to hold for WeChat/QQ/Telegram.
enum AppDisplayNameResolver {
    private static var bundleNameCache: [String: Set<String>] = [:]

    static func displayName(for bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName, !name.isEmpty {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return Bundle(url: url)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    static func titleMatchesAppName(_ title: String, bundleID: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName,
           normalized == name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return true
        }
        return bundleDerivedNames(for: bundleID).contains(normalized)
    }

    /// Localized + unlocalized bundle names (covers e.g. 微信 vs WeChat), cached.
    private static func bundleDerivedNames(for bundleID: String) -> Set<String> {
        if let cached = bundleNameCache[bundleID] { return cached }
        var names: Set<String> = []
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            for dict in [bundle?.localizedInfoDictionary, bundle?.infoDictionary] {
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let name = dict?[key] as? String, !name.isEmpty {
                        names.insert(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                    }
                }
            }
            names.insert(url.deletingPathExtension().lastPathComponent.lowercased())
        }
        bundleNameCache[bundleID] = names
        return names
    }
}
