import AppKit
import SwiftUI

/// A chip that represents an app by bundle identifier rather than a concrete window.
/// Renders the three launcher states (not running / running-no-window / running-hidden)
/// and handles tap-to-launch, tap-to-reopen, and the launch bounce animation.
///
/// Shared by the drawer (collected apps, scale 0.7) and the main strip (messaging
/// and kept apps, scale 1.0). Call-site differences are injected via
/// `membershipItems` (在程序坞中保留 / 标记为消息应用).

struct LauncherChip: View {
    let bundleID: String
    let isRunning: Bool   // supplied by the displayed zone's runtime/process projection
    let isHidden: Bool    // supplied by the displayed zone's runtime/process projection
    /// Runtime-owned launch session state. The chip only renders this state; it does
    /// not infer readiness from process state or own a second launch timeout.
    let isLaunching: Bool
    /// 档位系数（条内传 `DockSize.scale`，抽屉恒定 0.7）。**故意不给默认值**——漏传必须是编译错误，
    /// 见 AGENTS《Taskbar Size Tiers》。
    let scale: CGFloat
    /// 悬停效果档位。**同样故意不给默认值**——漏传必须是编译错误，理由同 `scale`。
    /// 抽屉调用处有意写死 `.quiet`（抽屉不受该设置影响，owner 2026-08-02 / 2026-08-17）。
    let hoverStyle: HoverStyle
    /// 悬停从哪来。任务条传 `.resolved(…)`（整条一块跟踪区算好的），抽屉传 `.selfTracked`
    /// （那块面板没有跟踪区）。**故意不给默认值**，理由同 `scale` / `hoverStyle`。
    let hoverInput: ChipHoverInput
    /// 成员 / 管理菜单项（右键菜单末尾），如「在程序坞中保留」「标记为消息应用」。
    /// 空数组 = 无成员项。
    var membershipItems: [LauncherMembershipItem] = []
    /// 未读角标文本（消息区专用），`nil` = 不画。画在 chip 内部而不是由调用方叠 ZStack，
    /// 这样悬停放大、按压回缩、档位缩放它全都跟着走——理由见 `ChipBadgeView`。
    var badgeText: String? = nil
    /// 这张图标的格子此刻是不是因为**正被拎在手里**而空着（`DragController.hiddenSlotPayload`）。
    /// 一变 true 就清按压缩放：重排会挪动它、SwiftUI 取消按压手势，`isTapPressed` 只能靠 1s
    /// 看门狗复位，落地显形时可能还是 0.93——和以 1.0 停稳的载体差一截。理由同 `ChipView.slotHidden`。
    var slotHidden: Bool = false
    /// 悬停反馈按住（只有 `.selfTracked` 的抽屉需要）：刚落定、指针还没动的那一格
    /// （`DragController.hoverHoldPayload`）以及正被拎着的那一格。`.onHover` 在格子透明期间照样
    /// 为 true，不按住的话落地显形那一刻就直接是 1.10——安静档「落位抖动」在抽屉里的形态。
    /// 任务条走 `.resolved(…)`，悬停由整条跟踪区在源头压住，这里传默认 false。
    var hoverSuppressed: Bool = false
    /// When set, replaces the default tap behavior (drawer show/hide toggle). Used by
    /// app-level strip entries that must reopen a missing main window.
    var onTap: (() -> Void)? = nil
    /// Starts the runtime-owned launch session and returns whether launch dispatch
    /// succeeded. A false result keeps the drawer open and never starts local bounce.
    var onLaunch: () -> Bool = { false }
    /// Fired when the tap dispatches an "open" action: unhide+activate (running but not active) or launch (not running).
    /// Hide taps (app is active → minimize) do NOT fire this — the drawer stays open for those.
    /// Only set by DrawerView; strip messaging chips leave it nil.
    var onPrimaryAction: (() -> Void)? = nil

    private let theme = DockThemeTokens.standard
    /// 见 `EnvironmentValues.isDragCarrierSnapshot`：拍副本时不画圆点、不烘投影。
    @Environment(\.isDragCarrierSnapshot) private var isDragCarrierSnapshot

    /// `.selfTracked` 时才用得上（抽屉）。任务条走 `.resolved(…)`，这份状态原地不动。
    @State private var selfHovering = false
    @State private var bounceUp = false
    @State private var bounceTimer: Timer?
    /// 按压确认脉冲。2026-08-11 之前这个组件**完全没有按压反馈**——消息区（主窗关着 / 未运行）、
    /// kept 图标、抽屉图标点下去一动不动，而窗口卡和抽屉胶囊都有。纯视图层信号，永不喂
    /// planner / frontmost 轴（AGENTS）。
    @State private var isTapPressed = false
    private static let launchTraceEnabled =
        ProcessInfo.processInfo.environment["DOCK_LAUNCH_TRACE"] == "1"

    private var isHovering: Bool {
        guard !hoverSuppressed else { return false }
        switch hoverInput {
        case let .resolved(value): return value
        case .selfTracked: return selfHovering
        }
    }

    /// 悬停视觉的总闸：「安静」档下恒 false，图标不缩、名字不浮出，连动画事务都不产生。
    private var showsHover: Bool { hoverStyle.isExpressive && isHovering }
    /// 安静档的悬停反馈（标准档恒 false）。见 `HoverStyle.showsQuietHoverFeedback`。
    private var quietHoverFeedback: Bool {
        hoverStyle.showsQuietHoverFeedback(isHovering: isHovering)
    }

    var body: some View {
        let visual = LauncherChipVisualPlan.visual(isRunning: isRunning)
        // **悬停不改变任何像素，所以不挂动画驱动器**——与 `ChipView.bareIconChip` 逐字相同
        // （2026-08-17：那边先拆了，这边漏拆，白跑了一轮 0.18s 空动画）。
        // 理由见 `bareIconChip` 的注释：主线程一忙 macOS 就合并鼠标移动事件，横扫会漏格。
        //
        // **这里尤其不能让事务上祖先链**：启动弹跳（`bounceUp`）就住在下面那个图标里，
        // 祖先的 hover 事务会把它劫持掉。安静档的高亮因此走 `.background` 兄弟层。
        let hover = ChipHoverVisual.resolve(progress: 0, scale: scale)
        let _ = ChipAnimationTrace.record(
            chipID: bundleID,
            kind: "launcher",
            visual: hover,
            isTapPressed: isTapPressed,
            showsHover: showsHover
        )
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(nsImage: AppIconResolver.icon(for: bundleID))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: hover.bareIconSize, height: hover.bareIconSize)
                .clipShape(RoundedRectangle(cornerRadius: hover.bareIconSize / 4, style: .continuous))
                .offset(y: bounceUp ? -6 : 0)
                .animation(.easeInOut(duration: 0.25), value: bounceUp)
            // 槽位高度 = **静息**图标尺寸。槽位小于图标就会整块往下溢出（.top 对齐），
            // 结果就是「打开的应用图标和没打开的高度不一样」——本视图画的正是没打开的那种。
            // 与 `ChipView` 的 iconOnly 分支必须逐字相同。
            .frame(width: ChipPillMetrics.cardWidth * scale,
                   height: ChipPillMetrics.bareIconSlot * scale,
                   alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(width: ChipPillMetrics.cardWidth * scale,
               height: ChipPillMetrics.chipHeight * scale)
        // 同 `ChipView`：拖起来的副本不画圆点（原生 Dock 同款）。
        .overlay(alignment: .bottom) {
            if visual.showsRunningDot && !isDragCarrierSnapshot {
                Circle()
                    .fill(theme.runningDot.color)
                    .frame(width: 4, height: 4)
                    .padding(.bottom, 2)
            }
        }
        // 未读角标：**必须挂在两个缩放之前**（owner 2026-08-17）。见 `ChipBadgeView`。
        .overlay(alignment: .topTrailing) {
            if let badgeText {
                ChipBadgeView(text: badgeText, scale: scale)
            }
        }
        // 运行点原本挂在放大**之后**（点不跟着放大），和 `ChipView.bareIconChip` 不一致；
        // 这次一并对齐：两处都是「图标 + 点 + 角标」整体缩放。
        .chipQuietHoverScale(quietHoverFeedback,
                             cardWidth: ChipPillMetrics.cardWidth * scale,
                             scale: scale)
        .chipPressScale(isTapPressed)
        .contentShape(Rectangle())
        // 任务条上悬停由整条那块跟踪区算好后传进来；只有抽屉（`.selfTracked`）才自己挂
        // `.onHover`，因为那块面板没有跟踪区。成因见 `StripHoverResolution`。
        .modifier(SelfTrackedHover(enabled: hoverInput == .selfTracked, isHovering: $selfHovering))
        .onChange(of: isHovering) { hovering in
            trace("isHovering=\(hovering)")
            ChipAnimationTrace.event(
                chipID: bundleID,
                kind: "launcher",
                event: ChipAnimationTraceEvent.hover(hovering),
                isTapPressed: isTapPressed,
                showsHover: hoverStyle.isExpressive && hovering
            )
        }
        .onTapGesture { handlePrimaryTap() }
        // 启动会话期间点击本来就是 no-op（AGENTS），给按压反馈等于骗人；顺带避开和
        // 有限弹跳（bounceUp offset）叠在同一个图标上的动画事务。
        .chipPressGesture(
            isPressed: $isTapPressed,
            isEnabled: !isLaunching,
            onEvent: { pressed in
                ChipAnimationTrace.event(
                    chipID: bundleID,
                    kind: "launcher",
                    event: ChipAnimationTraceEvent.tap(pressed),
                    isTapPressed: pressed,
                    showsHover: showsHover
                )
            }
        )
        .nativeContextMenu { buildLauncherMenu() }
        .help(displayName)
        // 格子一空就清按压（理由见 `slotHidden`）。图标此刻透明，这次回弹没人看得见。
        .onChange(of: slotHidden) { hidden in
            if hidden, isTapPressed { isTapPressed = false }
        }
        .onAppear {
            trace("appear isLaunching=\(isLaunching)")
            if isLaunching { startBounce() }
        }
        .onDisappear {
            trace("disappear cleanup")
            cleanupBounce()
        }
        .onChange(of: isLaunching) { newValue in
            trace("isLaunching=\(newValue)")
            if newValue { startBounce() } else { stopBounce() }
        }
        .onChange(of: bounceUp) { trace("bounceUp=\($0)") }
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
                // 右键「打开」：复用 runtime 启动路径，但不触发 onPrimaryAction——
                // 否则抽屉图标右键打开会顺手关掉抽屉。
                menu.addItem(ClosureMenuItem(String(localized: "Open")) { launch(firePrimaryAction: false) })
            case .recentDocuments:
                AppMenuBuilder.appendRecentDocuments(to: menu, bundleID: bundleID)
            case .show:
                if !runningApps.isEmpty {
                    menu.addItem(ClosureMenuItem(String(localized: "Show")) {
                        for app in runningApps { _ = app.unhide() }
                        runningApps.first?.activate(options: .activateIgnoringOtherApps)
                    })
                }
            case .hide:
                if !runningApps.isEmpty {
                    menu.addItem(ClosureMenuItem(String(localized: "Hide")) {
                        for app in runningApps { _ = app.hide() }
                    })
                }
            case .quit:
                if !runningApps.isEmpty {
                    // 退出恒为末项，所以前置分隔线由本分支自己补（成员区已排在前面）；
                    // 守卫同 .membership：菜单为空或末项已是分隔线时不补，避免双线。
                    if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                        menu.addItem(.separator())
                    }
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

    /// The single left-click gate covers both injected app-level behavior and the
    /// default drawer behavior. Runtime still performs the authoritative duplicate
    /// check for clicks that arrive before SwiftUI publishes the new launch state.
    private func handlePrimaryTap() {
        guard !isLaunching else {
            trace("tap ignored while launching")
            return
        }
        if let onTap { onTap() } else { handleTap() }
    }

    private func handleTap() {
        Self.performDefaultTap(bundleID: bundleID, isRunning: isRunning,
                               launch: { launch() }, onOpen: onPrimaryAction)
    }

    /// 没有注入 `onTap` 时的默认左键行为（抽屉图标就是这一套）。抽成静态、供 `DrawerView` 复用的
    /// 唯一理由：归位飞行途中点一下载体（`DragController.carrierClicks`）也得走**同一份**逻辑，
    /// 不能在别处再抄一遍「前台就收起、否则唤出」。
    /// - Parameters:
    ///   - launch: 未运行时怎么启动（调用方自己决定要不要顺带 `onOpen`）。
    ///   - onOpen: 唤出（unhide + open）时的附带动作——抽屉传「关抽屉」。
    static func performDefaultTap(bundleID: String, isRunning: Bool,
                                  launch: () -> Void, onOpen: (() -> Void)?) {
        if isRunning {
            let runningApps = regularRunningApplications(bundleID: bundleID)
            if runningApps.contains(where: \.isActive) {
                // 在前台 → 收起（最小化）：抽屉保持打开
                for app in runningApps { _ = app.hide() }
            } else {
                // 未激活 / 隐藏 / 窗口已关 → 唤出：关闭抽屉
                guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
                for app in runningApps { _ = app.unhide() }
                NSWorkspace.shared.openApplication(at: appURL, configuration: .init(), completionHandler: nil)
                onOpen?()
            }
        } else {
            launch()
        }
    }

    private var displayName: String {
        AppDisplayNameResolver.displayName(for: bundleID)
    }

    private static func regularRunningApplications(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.activationPolicy == .regular
                && ProcessLiveness.isAlive(pid: $0.processIdentifier)
        }
    }

    /// Every leg is a finite animation. The common-mode timer only schedules the next
    /// leg, so hover/layout transactions cannot turn the bounce into a repeatForever
    /// animation that survives launch completion.
    private func startBounce() {
        guard bounceTimer == nil else { return }
        bounceUp = true

        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            bounceUp.toggle()
        }
        timer.tolerance = 0.02
        bounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        trace("bounce timer started")
    }

    private func stopBounce() {
        bounceTimer?.invalidate()
        bounceTimer = nil
        bounceUp = false
        trace("bounce timer stopped")
    }

    /// View teardown is local cleanup only. It must not cancel the runtime session;
    /// a newly-created drawer chip resumes from the external `isLaunching` value.
    private func cleanupBounce() {
        bounceTimer?.invalidate()
        bounceTimer = nil
        bounceUp = false
    }

    /// - Parameter firePrimaryAction: 左键点击传 true（保持原行为：抽屉图标启动后关抽屉）；
    ///   右键「打开」传 false，只启动、不关抽屉。runtime owns URL resolution,
    ///   launch dispatch, readiness, timeout, and duplicate-session rejection.
    private func launch(firePrimaryAction: Bool = true) {
        guard !isLaunching else {
            trace("launch ignored while launching")
            return
        }
        guard onLaunch() else {
            trace("runtime rejected launch")
            return
        }
        trace("runtime accepted launch")
        if firePrimaryAction { onPrimaryAction?() }
    }

    private func trace(_ message: String) {
        guard Self.launchTraceEnabled else { return }
        let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        print("[launch] BOUNCE bid=\(bundleID) t=\(timestamp) \(message)")
    }
}

// MARK: - App Display Name Resolver

/// Resolves human-readable names for a bundle identifier, with caching (bundle plist
/// reads involve disk IO and these get called from SwiftUI body evaluations).
/// Also answers "does this window title look like the app's main window?" — the
/// 方案 B heuristic: a messaging app's main window is the one titled like the app
/// itself (微信 / WeChat / Telegram…), verified to hold for WeChat/QQ/Telegram.
enum AppDisplayNameResolver {
    private static let displayNameCache = AppDisplayNameCache()
    /// 应用名匹配走单调注册表，**不再每帧现查 LaunchServices**（成因与代价见
    /// `AppNameRegistry` 的注释：一次瞬时查空就让飞书/微信同时掉出消息区吸收）。
    private static let nameRegistry = AppNameRegistry(
        bundleNamesLoader: bundleDerivedNames(for:),
        runningNameLoader: { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.localizedName
        }
    )
    private static let workspaceObservers: [NSObjectProtocol] = {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        return names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                invalidateDisplayName(for: bundleID)
                // 启动通知自带 `NSRunningApplication`，名字白拿——省掉一次查询，
                // 也让刚启动的 app 第一帧就有权威名字可比。
                if name == NSWorkspace.didLaunchApplicationNotification,
                   let localized = app.localizedName {
                    nameRegistry.observe(name: localized, for: bundleID)
                }
            }
        }
    }()

    static func displayName(for bundleID: String) -> String {
        _ = workspaceObservers
        return displayNameCache.value(for: bundleID) {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let name = running.localizedName, !name.isEmpty {
                nameRegistry.observe(name: name, for: bundleID)   // 顺手记进注册表，白拿
                return name
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            return Bundle(url: url)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent
        }
    }

    static func invalidateDisplayName(for bundleID: String) {
        displayNameCache.invalidate(bundleID: bundleID)
        nameRegistry.invalidate(bundleID: bundleID)
    }

    static func titleMatchesAppName(_ title: String, bundleID: String) -> Bool {
        _ = workspaceObservers
        return nameRegistry.matches(title: title, bundleID: bundleID)
    }

    /// Localized + unlocalized bundle names (covers e.g. 微信 vs WeChat). 归一化后交给注册表缓存。
    /// 注意本机实测：飞书/微信在这里只解析得出英文名（`{feishu, lark}` / `{wechat}`），
    /// 中文标题得靠注册表里记住的 `localizedName` 才匹配得上。
    private static func bundleDerivedNames(for bundleID: String) -> Set<String> {
        var names: Set<String> = []
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            for dict in [bundle?.localizedInfoDictionary, bundle?.infoDictionary] {
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let name = dict?[key] as? String, !name.isEmpty {
                        names.insert(AppNameRegistry.normalize(name))
                    }
                }
            }
            names.insert(AppNameRegistry.normalize(url.deletingPathExtension().lastPathComponent))
        }
        return names
    }
}

/// 只有在没有外部跟踪区的面板（抽屉）上才挂 `.onHover`。
///
/// 条件写成 `if`/`else` 而不是"总是挂上、值不用就忽略"：多留一块跟踪区就多一份事件派发，
/// 而我们改这一轮**正是为了不再依赖每张卡各自的进出事件**（见 `StripHoverResolution`）。
/// `enabled` 在同一个调用点上永不翻转，所以 `_ConditionalContent` 的身份切换不会真的发生。
private struct SelfTrackedHover: ViewModifier {
    let enabled: Bool
    @Binding var isHovering: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onHover { isHovering = $0 }
        } else {
            content
        }
    }
}
