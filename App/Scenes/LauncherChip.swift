import AppKit
import os
import SwiftUI

/// A chip that represents an app by bundle identifier rather than a concrete window.
/// Renders the three launcher states (not running / running-no-window / running-hidden)
/// and handles tap-to-launch, tap-to-reopen, and the launch bounce animation.
///
/// Shared by the drawer (collected apps, scale 0.7) and the main strip (messaging
/// and kept apps, scale 1.0). Call-site differences are injected via
/// `membershipItems` (在程序坞中保留 / 取消标记消息应用).

/// 一条成员 / 管理菜单项（标签 + 动作）。LauncherChip 右键菜单末尾按序渲染，
/// 可多项——收纳 + 启动收藏共存图标可同时给转换、移出与取消收藏入口。
struct LauncherMembershipItem {
    let label: String
    /// nil = ordinary command; non-nil = native check-menu state.
    var isChecked: Bool? = nil
    let action: () -> Void
}

extension LauncherMembershipItem {
    /// 从纯 `AppMembershipMenuPlan` 生成成员项并接线到 controller。四条菜单构造路径
    /// （strip 窗口卡 / kept 图标 / 消息 chip / drawer 图标）统一消费，保证矩阵一致。
    @MainActor
    static func items(
        surface: AppMembershipMenuPlan.Surface,
        bundleID: String,
        isKept: Bool,
        isMessaging: Bool,
        controller: AppMembershipController
    ) -> [LauncherMembershipItem] {
        AppMembershipMenuPlan.items(
            surface: surface,
            isFinder: bundleID == KeptAppStore.forbiddenBundleID,
            isKept: isKept,
            isMessaging: isMessaging
        ).map { item in
            switch item {
            case let .keep(isChecked):
                return LauncherMembershipItem(label: "在程序坞中保留", isChecked: isChecked) {
                    controller.setKept(bundleID, enabled: !isChecked)
                }
            case .markMessaging:
                return LauncherMembershipItem(label: "标记为消息应用") {
                    controller.markMessaging(bundleID)
                }
            case .unmarkMessaging:
                return LauncherMembershipItem(label: "取消标记消息应用") {
                    controller.unmarkMessaging(bundleID)
                }
            }
        }
    }
}

struct LauncherChip: View {
    let bundleID: String
    let isRunning: Bool   // supplied by the displayed zone's runtime/process projection
    let isHidden: Bool    // supplied by the displayed zone's runtime/process projection
    var scale: CGFloat = 0.7
    /// 只控制「运行但隐藏」要不要降级变暗（抽屉 / 普通 kept 传 true → 0.45；消息区传 false → 保持全亮）。
    /// **未运行恒定灰显（0.35）与本标志无关**——消息区退出态因此也会变灰，与所有退出应用统一
    /// （owner 2026-07-19，反转了旧的「消息图标常亮、随时可点」决策）。决策见 `LauncherChipVisualPlan`。
    var dimsWhenHidden: Bool = true
    /// 成员 / 管理菜单项（右键菜单末尾），如「在程序坞中保留」「取消标记消息应用」。
    /// 空数组 = 无成员项。
    var membershipItems: [LauncherMembershipItem] = []
    /// When set, replaces the default tap behavior (drawer show/hide toggle). Used by
    /// app-level strip entries that must reopen a missing main window.
    var onTap: (() -> Void)? = nil
    /// Fired when this chip actually kicks off a launch (tap on a not-running app).
    /// The drawer wires it to `runtime.beginLaunch` for the 窗口出现门控 (keeps the
    /// app bouncing in the launch zone until its window shows, not just its process).
    var onLaunch: () -> Void = {}
    /// Optional external launch gate. `nil` preserves the legacy behavior: a running
    /// process or a successful open completion stops the bounce. When non-nil, the
    /// caller owns readiness and the bounce stops only after this becomes `true`
    /// (or launch fails / the 8-second backstop fires).
    var launchReady: Bool? = nil
    /// Fired when the tap dispatches an "open" action: unhide+activate (running but not active) or launch (not running).
    /// Hide taps (app is active → minimize) do NOT fire this — the drawer stays open for those.
    /// Only set by DrawerView; strip messaging chips leave it nil.
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
        let visual = LauncherChipVisualPlan.visual(isRunning: isRunning,
                                                   isHidden: isHidden,
                                                   dimsWhenHidden: dimsWhenHidden)
        let iconOpacity: Double = visual.opacity
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
            if visual.showsRunningDot {
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
            if launchReady == nil, newValue { stopBounce() }
        }
        .onChange(of: launchReady) { newValue in
            if newValue == true { stopBounce() }
        }
        .animation(.easeInOut(duration: 0.18), value: isHovering)
    }

    private func buildLauncherMenu() -> NSMenu {
        let menu = NSMenu()
        // 菜单运行态跟随「图标所在区的显示态」(isRunning prop)，不再独立问 NSWorkspace——否则待启动区里
        // 进程仍活（关窗不退 / 常驻）的图标会误报「隐藏 / 退出」，与其「已退出」的灰显外观矛盾。
        let kinds = LauncherMenuPlan.itemKinds(isRunning: isRunning,
                                               isHidden: isHidden,
                                               hasMembership: !membershipItems.isEmpty)
        // 仅在真要执行 显示/隐藏/退出 时才取 app 对象；取不到就跳过该项（快照短暂陈旧的兜底）。
        let runningApps = Self.regularRunningApplications(bundleID: bundleID)
        for kind in kinds {
            switch kind {
            case .open:
                // 右键「打开」：复用启动路径（弹跳 / 窗口出现门控 / 8s 兜底 / 防重复启动都在 launch()），
                // 但不触发 onPrimaryAction——否则抽屉图标右键打开会顺手关掉抽屉。
                menu.addItem(ClosureMenuItem("打开") { launch(firePrimaryAction: false) })
            case .recentDocuments:
                AppMenuBuilder.appendRecentDocuments(to: menu, bundleID: bundleID)
            case .show:
                if !runningApps.isEmpty {
                    menu.addItem(ClosureMenuItem("显示") {
                        for app in runningApps { _ = app.unhide() }
                        runningApps.first?.activate(options: .activateIgnoringOtherApps)
                    })
                }
            case .hide:
                if !runningApps.isEmpty {
                    menu.addItem(ClosureMenuItem("隐藏") {
                        for app in runningApps { _ = app.hide() }
                    })
                }
            case .quit:
                if !runningApps.isEmpty {
                    AppMenuBuilder.appendQuitItems(
                        to: menu,
                        bundleID: bundleID,
                        onForceQuit: { for app in runningApps { _ = app.forceTerminate() } }
                    ) {
                        for app in runningApps { _ = app.terminate() }
                    }
                }
            case .membership:
                // 成员区前只在「菜单非空且末项不是分隔线」时补线：既给 打开/最近文件 与成员项之间补上
                // 分隔线，又避免最近文件区已自带尾部分隔线时出现双线（也兜住运行态动作被竞态跳过的情况）。
                if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
                for item in membershipItems {
                    menu.addItem(AppMenuBuilder.membershipItem(item))
                }
            }
        }
        return menu
    }

    private func handleTap() {
        if isRunning {
            let runningApps = Self.regularRunningApplications(bundleID: bundleID)
            if runningApps.contains(where: \.isActive) {
                // 在前台 → 收起（最小化）：抽屉保持打开
                for app in runningApps { _ = app.hide() }
            } else {
                // 未激活 / 隐藏 / 窗口已关 → 唤出：关闭抽屉
                guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
                for app in runningApps { _ = app.unhide() }
                NSWorkspace.shared.openApplication(at: appURL, configuration: .init(), completionHandler: nil)
                onPrimaryAction?()
            }
        } else {
            launch()   // onPrimaryAction fired inside launch() after URL guard；防重复启动也在 launch()
        }
    }

    private var displayName: String {
        AppDisplayNameResolver.displayName(for: bundleID)
    }

    private static func regularRunningApplications(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            !$0.isTerminated && $0.activationPolicy == .regular
        }
    }

    /// 停跳：只翻 isLaunching。偏移量与动画类型都声明式绑定它，置 false 即换成
    /// 有限动画收敛到 0，循环动画随之消失（见 bounceAnimation 注释）。
    private func stopBounce() {
        isLaunching = false
    }

    /// - Parameter firePrimaryAction: 左键点击传 true（保持原行为：抽屉图标启动后关抽屉）；
    ///   右键「打开」传 false，只弹跳启动、不关抽屉。防重复启动的 `!isLaunching` 门控集中在此，
    ///   左键 `handleTap` 与右键「打开」共用同一路径，不另写启动逻辑。
    private func launch(firePrimaryAction: Bool = true) {
        guard !isLaunching else { return }
        Self.logger.info("launch() 入口，bundleID=\(bundleID, privacy: .public)")
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Self.logger.warning("launch()：找不到 app URL，bundleID=\(bundleID, privacy: .public)")
            return
        }

        isLaunching = true
        let usesExternalLaunchGate = launchReady != nil
        onLaunch()
        if firePrimaryAction { onPrimaryAction?() }

        // 8s timeout backstop（对 menubar-only app 无窗口回调的情况兜底）
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            stopBounce()
        }

        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, error in
            if let error {
                Self.logger.error("launch()：openApplication 失败，bundleID=\(bundleID, privacy: .public)，error=\(error.localizedDescription, privacy: .public)")
                Task { @MainActor in stopBounce() }
            } else if !usesExternalLaunchGate {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    stopBounce()
                }
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
