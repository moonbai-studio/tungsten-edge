import Foundation

/// 全部 `DOCK_*` 环境变量开关的唯一登记表（2026-09-05 起）。读开关一律经这里，源码里不再出现
/// `"DOCK_…"` 字面量——`Scripts/check_debug_switches.py`（CI 与发版预检都跑）会拦。三种极性：
/// - `.killSwitch`：默认**开**，`=0` 关。给已转正的机制留一条现场回退路。
/// - `.trace`：默认**关**，`=1` 开。诊断打印 / 追踪文件 / 尚在实验的行为。
/// - `.value`：取原始字符串，由调用点自己解析（毫秒数、材质名、层级值……）。
///
/// 传给 dev 版的方式见 `Docs/28`：`launchctl setenv K V` → `open` → `launchctl unsetenv K`。
enum DebugSwitch: String, CaseIterable, Sendable {
    enum Kind: Sendable { case killSwitch, trace, value }

    // MARK: 默认开的机制开关（=0 关）
    /// AX 事件读走限时后台批读；=0 退回主线程不限时同步读
    case eventAxAsync = "DOCK_EVENT_AX_ASYNC"
    /// 5s 周期对账的 per-pid 跳过门（PeriodicReconcileSkipDecision）
    case reconcileSkip = "DOCK_RECONCILE_SKIP"
    /// 未纳管 App 的扫描探针门（ScanProbeGateDecision）
    case scanGate = "DOCK_SCAN_GATE"
    /// 前台 pid 走事件维护的缓存，不查 NSWorkspace
    case frontmostCache = "DOCK_FRONTMOST_CACHE"
    /// 事件读的 CG 全表复用门（CGSnapshotReuseDecision）
    case cgSnapshotReuse = "DOCK_CG_SNAPSHOT_REUSE"
    /// AX 元素缓存（AXElementCache）
    case axElementCache = "DOCK_AX_ELEMENT_CACHE"
    /// 切前台走 SkyLight 私有接口
    case skylightFocus = "DOCK_SKYLIGHT_FOCUS"
    /// AX 窗口句柄快速路径
    case fastWindowHandle = "DOCK_FAST_WINDOW_HANDLE"
    /// 角标只读消息 App 的 Dock 元素而不整树遍历
    case badgeTargeted = "DOCK_BADGE_TARGETED"
    /// 任务条隐藏 / 无可读 App 时停掉角标轮询
    case badgePause = "DOCK_BADGE_PAUSE"
    /// 最小化后的乐观状态落定门
    case minimizeSettleGate = "DOCK_MINIMIZE_SETTLE_GATE"
    /// 最小化交接期的前台宽限
    case handoffActiveGrace = "DOCK_HANDOFF_ACTIVE_GRACE"
    /// 最小化交接后的前台预测
    case handoffActivePrediction = "DOCK_HANDOFF_ACTIVE_PREDICTION"
    /// 动作规划里的「前台判断已过期」守卫
    case staleActiveGuard = "DOCK_STALE_ACTIVE_GUARD"
    /// 拖动落定动画（DragLandingPlan）
    case dragLanding = "DOCK_DRAG_LANDING"
    /// macOS 26 Liquid Glass 底板；=0 退回毛玻璃
    case liquidGlass = "DOCK_LIQUID_GLASS"
    /// 桌面 / 全屏空间切换意图监听（session 事件 tap）
    case spaceIntent = "DOCK_SPACE_INTENT"
    /// 原生全屏进入前的预测让位
    case fullscreenIntent = "DOCK_FULLSCREEN_INTENT"
    /// 全屏判定问 SkyLight 空间类型
    case fullscreenSlsVerdict = "DOCK_FULLSCREEN_SLS_VERDICT"
    /// 常驻所有桌面的成员资格修复（issue #19）
    case spaceMembershipRepair = "DOCK_SPACE_MEMBERSHIP_REPAIR"
    /// 常驻面板钉进私有空间（桌面互滑不发灰）
    case overlaySpace = "DOCK_OVERLAY_SPACE"
    /// 任务条上滚轮方向反转
    case scrollReverser = "DOCK_SCROLL_REVERSER"
    /// 最大化窗口避让
    case windowLift = "DOCK_WINDOW_LIFT"
    /// 避让用动画写 frame
    case windowLiftAnim = "DOCK_WINDOW_LIFT_ANIM"
    /// 菜单打开时暂停悬停监视
    case menuHoverSuspend = "DOCK_MENU_HOVER_SUSPEND"
    /// 悬停监视精简模式
    case hoverMonitorLean = "DOCK_HOVER_MONITOR_LEAN"
    /// 任务条整条一块的指针轮询
    case stripHoverPoll = "DOCK_STRIP_HOVER_POLL"
    /// 按下 chip 的即时按压反馈
    case chipPressDown = "DOCK_CHIP_PRESS_DOWN"

    // MARK: 默认关的追踪 / 实验（=1 开）
    /// 多屏归属写入日志（category display-trace）
    case displayTrace = "DOCK_DISPLAY_TRACE"
    /// 启动反馈时间线打印
    case launchTrace = "DOCK_LAUNCH_TRACE"
    /// chip 点击探针打印
    case chipProbe = "DOCK_CHIP_PROBE"
    /// 点击延迟分段记录（ClickLatencyTrace）
    case clickTrace = "DOCK_CLICK_TRACE"
    /// 悬停 / 帧变化追踪文件（HoverTrace）
    case hoverTrace = "DOCK_HOVER_TRACE"
    /// 边缘悬停 / 切屏诊断打印
    case edgehoverTrace = "DOCK_EDGEHOVER_TRACE"
    /// 滚轮横向滚动打印
    case stripWheelTrace = "DOCK_STRIP_WHEEL_TRACE"
    /// chip 动画 / 气泡追踪
    case chipAnimTrace = "DOCK_CHIP_ANIM_TRACE"
    /// 空间切换意图追踪
    case spaceIntentTrace = "DOCK_SPACE_INTENT_TRACE"
    /// 滚轮反转事件打印
    case scrollReverserTrace = "DOCK_SCROLL_REVERSER_TRACE"
    /// 窗口避让追踪
    case windowLiftTrace = "DOCK_WINDOW_LIFT_TRACE"
    /// 实验：最小化失败时退回 App 级 hide
    case minimizeAppFallback = "DOCK_MINIMIZE_APP_FALLBACK"

    // MARK: 取值型（调用点自己解析）
    /// 周期对账 AX 读超时毫秒（默认 100；0 = 旧同步路径）
    case reconcileAxTimeoutMs = "DOCK_RECONCILE_AX_TIMEOUT_MS"
    /// 启动 seed 探针 AX 超时毫秒（0 = 不限时）
    case seedAxTimeoutMs = "DOCK_SEED_AX_TIMEOUT_MS"
    /// 拖动落定飞行时长毫秒
    case dragFlightMs = "DOCK_DRAG_FLIGHT_MS"
    /// 窗口清单诊断日志：1 / 0 覆盖 UserDefaults InventoryLog
    case inventoryLog = "DOCK_INVENTORY_LOG"
    /// 实验：三块任务条面板的 NSWindow.Level 原始值
    case panelLevel = "DOCK_PANEL_LEVEL"
    /// 实验：面板材质名
    case panelMaterial = "DOCK_PANEL_MATERIAL"
    /// 实验：面板饱和度
    case panelSaturation = "DOCK_PANEL_SATURATION"
    /// 实验：面板厚度档（=1 开）
    case panelThickness = "DOCK_PANEL_THICKNESS"
    /// 实验：chip 药丸填充
    case chipPillFill = "DOCK_CHIP_PILL_FILL"
    /// 实验：非活动标签颜色
    case labelInactive = "DOCK_LABEL_INACTIVE"
    /// 中转格瓷砖配色 blue|graphite|light
    case shelfTile = "DOCK_SHELF_TILE"
    /// 玻璃调参：清透度
    case liquidGlassClearTint = "DOCK_LIQUID_GLASS_CLEAR_TINT"
    /// 玻璃调参：白色覆盖
    case liquidGlassWhiteOverlay = "DOCK_LIQUID_GLASS_WHITE_OVERLAY"
    /// 玻璃调参：压暗
    case liquidGlassDimming = "DOCK_LIQUID_GLASS_DIMMING"
    /// 玻璃调参：描边峰值
    case liquidGlassBorder = "DOCK_LIQUID_GLASS_BORDER"
    /// 玻璃调参：描边边缘
    case liquidGlassBorderEdge = "DOCK_LIQUID_GLASS_BORDER_EDGE"
    /// 玻璃调参：描边角切
    case liquidGlassBorderCut = "DOCK_LIQUID_GLASS_BORDER_CUT"
    /// 玻璃调参：描边角扩散
    case liquidGlassBorderSpread = "DOCK_LIQUID_GLASS_BORDER_SPREAD"
    /// 玻璃调参：描边线宽
    case liquidGlassBorderWidth = "DOCK_LIQUID_GLASS_BORDER_WIDTH"
    /// 玻璃调参：内描边
    case liquidGlassBorderInner = "DOCK_LIQUID_GLASS_BORDER_INNER"
    /// 玻璃调参：背景材质不透明度
    case liquidGlassBackgroundOpacity = "DOCK_LIQUID_GLASS_BACKGROUND_OPACITY"
    /// 玻璃调参：窗口模糊半径
    case liquidGlassWindowBlur = "DOCK_LIQUID_GLASS_WINDOW_BLUR"
    /// 玻璃调参：内容内缩
    case liquidGlassContentInset = "DOCK_LIQUID_GLASS_CONTENT_INSET"

    var kind: Kind {
        switch self {
        case .eventAxAsync, .reconcileSkip, .scanGate, .frontmostCache,
             .cgSnapshotReuse, .axElementCache, .skylightFocus, .fastWindowHandle,
             .badgeTargeted, .badgePause, .minimizeSettleGate, .handoffActiveGrace,
             .handoffActivePrediction, .staleActiveGuard, .dragLanding, .liquidGlass,
             .spaceIntent, .fullscreenIntent, .fullscreenSlsVerdict, .spaceMembershipRepair,
             .overlaySpace, .scrollReverser, .windowLift, .windowLiftAnim,
             .menuHoverSuspend, .hoverMonitorLean, .stripHoverPoll, .chipPressDown:
            return .killSwitch
        case .displayTrace, .launchTrace, .chipProbe, .clickTrace,
             .hoverTrace, .edgehoverTrace, .stripWheelTrace, .chipAnimTrace,
             .spaceIntentTrace, .scrollReverserTrace, .windowLiftTrace, .minimizeAppFallback:
            return .trace
        case .reconcileAxTimeoutMs, .seedAxTimeoutMs, .dragFlightMs, .inventoryLog,
             .panelLevel, .panelMaterial, .panelSaturation, .panelThickness,
             .chipPillFill, .labelInactive, .shelfTile, .liquidGlassClearTint,
             .liquidGlassWhiteOverlay, .liquidGlassDimming, .liquidGlassBorder, .liquidGlassBorderEdge,
             .liquidGlassBorderCut, .liquidGlassBorderSpread, .liquidGlassBorderWidth, .liquidGlassBorderInner,
             .liquidGlassBackgroundOpacity, .liquidGlassWindowBlur, .liquidGlassContentInset:
            return .value
        }
    }

    /// 原始字符串（未设置 → nil）。取值型开关的唯一读法；布尔型也可用它看原文。
    func value(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[rawValue]
    }

    /// 布尔读法，极性由 `kind` 决定，与迁移前各调用点的 `!= "0"` / `== "1"` 逐字等价。
    func isEnabled(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch kind {
        case .killSwitch: return environment[rawValue] != "0"
        case .trace: return environment[rawValue] == "1"
        case .value:
            assertionFailure("\(rawValue) is a value switch; read it with value(in:)")
            return environment[rawValue] != nil
        }
    }
}
