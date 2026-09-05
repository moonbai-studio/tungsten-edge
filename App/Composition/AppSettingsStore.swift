import Combine
import Foundation

/// 悬停效果档位。
/// - `standard`：图标 36→24pt 缩放 + 下方冒出名字 + 文件夹格整块放大（原生程序坞手感）。
/// - `quiet`：鼠标划过任务条时**完全静止**——不缩放、不移动、不冒名字、胶囊底色不提亮。
///
/// 两个不受本档位影响的地方（owner 2026-08-02 定）：**抽屉面板里的图标**照旧，
/// **抽屉入口胶囊**里的九宫格照旧轻微放大——胶囊属于抽屉。
/// 「标题太长时弹出全文浮层」在两档下都保留：它是看全被截断标题的唯一途径，且不移动任何卡片。
///
/// **对外只是一个勾选项**：菜单上叫「鼠标悬停显示应用名」，**勾选 = `.standard`**，
/// 取消勾选 = `.quiet`（owner 2026-08-02 改名，原来的「悬停效果 ▸ 标准 / 安静」太抽象）。
/// 那个名字**有意只说了一半**——取消勾选同时也停掉图标缩放和文件夹格放大；
/// 别为了对齐名字去缩小行为范围，理由见 `Docs/27`。代码里其余地方仍按内部概念叫
/// 「安静档」（= `.quiet` = 取消勾选），枚举保留也是为了以后可能加第三档。
enum HoverStyle: String, CaseIterable {
    case standard
    case quiet

    /// **默认 `.quiet`**（owner 2026-09-01 定，此前是 `.standard`）：全新装上时鼠标划过
    /// 任务条不弹应用名气泡，只有轻微放大。老用户键里已有值，不受影响。
    static let `default` = HoverStyle.quiet

    /// 悬停是否产生**表现型**变化（名字气泡、文件夹格放大）。chip 视图统一用它做判据，
    /// 不各自比 case；菜单的勾选态也读它（`.on` ⟺ `isExpressive`）。
    var isExpressive: Bool { self == .standard }

    /// 表现型悬停此刻是否在发生（名字气泡 / 文件夹格放大）。各 chip 共用，不各自写 `isExpressive && isHovered`。
    func showsExpressiveHover(isHovering: Bool) -> Bool { isExpressive && isHovering }

    /// 安静档的悬停反馈：整块**轻微放大**。
    ///
    /// **标准档恒 false**——那一档的反馈是名字气泡，owner 2026-08-17 要求标准档一个像素不变。
    /// 加这个是因为安静档原本**一点反馈都没有**：2026-08-16 把应用名挪进气泡时顺手冻结了
    /// chip 的悬停几何（图标不缩、药丸不让位），标准档还剩气泡，安静档就归零了。
    ///
    /// 形式先做过「不改尺寸的淡底色」（`Docs/27` 早年预判的那条），owner 2026-08-17 实机
    /// 看完说「一般」，改成轻微放大。**放大在今天是安全的**：当年否掉它的理由是「改尺寸会让
    /// 整行重排」，而那说的是把应用名写在图标下方、名字一冒出来卡就变宽的老布局；
    /// 名字挪进气泡之后两档都不再重排，且这里用的是 `scaleEffect`（纯渲染变换，不改布局）。
    ///
    func showsQuietHoverFeedback(isHovering: Bool) -> Bool {
        !isExpressive && isHovering
    }
}

/// 用户自定义的显隐任务条快捷键（nil = 默认 ⌥⇧⌘D）。
/// `glyphs` 在录制那一刻由 NSEvent 的字符定格（理由见 `HotKeyGlyphs`），展示端只读它。
struct StoredHotKeyShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let glyphs: String
}


@MainActor
final class AppSettingsStore: ObservableObject {
    static let delayStep: Double = 0.1
    static let finiteDelayMin: Double = 0.1
    static let finiteDelayMax: Double = 3.0
    static let neverHideDelay: Double = -1.0
    static let neverWakeDelay: Double = 999.0
    static let sliderIndexMax = 31
    // nonisolated：要在 snapDelay 的默认参数（nonisolated 求值上下文）里引用。
    nonisolated static let defaultNativeDockAutoHideDelay: Double = 1.0
    /// **全新安装时钨极自己那条的档位：常驻**（owner 2026-09-01 定，此前是 0.1 秒唤醒的自动隐藏）。
    /// 只用在 `register` 那一处。
    ///
    /// ⚠️ **和下面那个是两个常量，永远不许合并。** 这个是「首次装上是什么样」，
    /// 下面那个是「自动隐藏开着时用哪一档」——后者必须是**有限值**，被两处兜底依赖：
    /// remembered 值不许是 `-1`（否则 ⌥⇧⌘D 从常驻切走还是常驻，快捷键变空操作），
    /// `snapDelay` 的非有限兜底也不许是 `-1`（否则 NaN 会被解释成「常驻」这个哨兵）。
    nonisolated static let firstRunEdgeAutoHideDelay: Double = AppSettingsStore.neverHideDelay
    /// 自动隐藏**开着**时的默认档，也是 remembered 与非有限值的兜底。见上面那条 ⚠️。
    nonisolated static let defaultEnabledEdgeAutoHideDelay: Double = 0.1

    @Published private(set) var launchAtLogin: Bool
    /// 中转格是否显示在固定文件夹区头位。关掉后它不再渲染，暂存的文件不受影响。
    @Published private(set) var showShelf: Bool
    /// 任务条尺寸档位。面板几何与条内所有 chip 尺寸都由它派生。
    @Published private(set) var dockSize: DockSize
    /// 悬停效果档位。只影响条内 chip 的悬停视觉，静息布局逐像素不变（因此无需 relayout）。
    @Published private(set) var hoverStyle: HoverStyle
    /// 最大化窗口避让任务条（菜单「最大化窗口避开任务条」）。
    /// **全新安装播种为开，老用户维持关**（owner 2026-09-01；此前所有人默认关）——
    /// 它配的是同一轮定的「任务条默认常驻」：常驻会压住最大化窗口的底边，避让正好补上。
    /// 但这个功能会真的去改写**别人应用**的窗口尺寸，所以不能因为一次升级就替老用户打开，
    /// 播种走 `seedWindowLiftEnabledForFreshInstall()`，见那里的注释。
    @Published private(set) var windowLiftEnabled: Bool
    /// 标准绿灯 / Control-Command-F 输入投递前预测隐藏任务条，默认开启。
    @Published private(set) var fullscreenIntentEnabled: Bool
    /// 自定义显隐任务条快捷键；nil = 默认 ⌥⇧⌘D。**只由 `SettingsCoordinator.applyEdgeToggleShortcut`
    /// 在注册成功后写入**——先落盘再注册失败会让存的键和实际生效的键分家。
    @Published private(set) var edgeToggleShortcut: StoredHotKeyShortcut?
    /// 全局反转鼠标滚轮（只反离散滚轮，触控板 / 妙控鼠标不动）。**默认关**——
    /// 改写全系统输入事件的能力必须由用户主动选择，理由同 `windowLiftEnabled`。
    @Published private(set) var scrollReverserEnabled: Bool
    /// 任务条显示位置。默认 `.followMouse` = 现状（底边停留切屏）；`.pinned` 固定到某屏。
    @Published private(set) var taskbarScreenPlacement: TaskbarScreenPlacement
    /// 这台机器上已经成功提交过邮箱订阅。只用来把设置里那段订阅区块收起来，
    /// 免得已经留过邮箱的人被同一段话反复看见。**不是**「是否为原始用户」的凭据——
    /// 那个凭据是 `InstallationRecord` 的首装时间戳，以及服务端那份名单。
    @Published private(set) var hasSubscribed: Bool
    /// 这台机器已经看过首次运行的欢迎引导（建议隐藏系统 Dock 那一屏）。
    /// 一次性显示状态，和「有没有真的去隐藏」无关——用户点了「以后再说」也算看过，
    /// 不再骚扰；想改的人走状态栏菜单里那条系统 Dock 滑杆。
    @Published private(set) var hasSeenWelcome: Bool
    @Published private(set) var nativeDockAutoHideDelay: Double
    @Published private(set) var edgeAutoHideDelay: Double
    /// 「自动隐藏」切换（菜单/全局快捷键）从常驻恢复时要回到的延迟值。
    /// 只允许有限档位（0.1...3.0）或不唤醒（999），绝不允许常驻（-1）本身。
    private(set) var lastEnabledEdgeAutoHideDelay: Double
    /// 系统 Dock 组的镜像 remembered，规则同上（回退默认档位是 1.0）。
    private(set) var lastEnabledNativeDockAutoHideDelay: Double

    var nativeDockAutoHideEnabled: Bool { nativeDockAutoHideDelay != Self.neverHideDelay }
    var edgeAutoHideEnabled: Bool { edgeAutoHideDelay != Self.neverHideDelay }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyEnabledKey(
            defaults: defaults,
            enabledKey: Keys.nativeDockAutoHideEnabled,
            delayKey: Keys.nativeDockAutoHideDelay
        )
        Self.migrateLegacyEnabledKey(
            defaults: defaults,
            enabledKey: Keys.edgeAutoHideEnabled,
            delayKey: Keys.edgeAutoHideDelay
        )
        // remembered 键（lastEnabledDelay）不注册默认值：区分「从未写过」和「真实写过」，
        // 从未写过时由下面的播种逻辑决定，而不是静默拿到一个注册出来的假历史值。
        defaults.register(defaults: [
            Keys.launchAtLogin: false,
            Keys.showShelf: true,
            Keys.fullscreenIntentEnabled: true,
            Keys.nativeDockAutoHideDelay: Self.defaultNativeDockAutoHideDelay,
            // 首次安装 = 常驻；remembered 的种子仍是有限档，见常量注释。
            Keys.edgeAutoHideDelay: Self.firstRunEdgeAutoHideDelay,
        ])

        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        showShelf = defaults.bool(forKey: Keys.showShelf)
        // 有意**不**进上面的 register：缺键即 false = 老用户维持关。
        // 全新安装那一次由 `seedWindowLiftEnabledForFreshInstall()` 显式写成 true——
        // register 一个 true 会把**所有**从没碰过这个开关的老用户一并打开，而这个功能
        // 会改写别人应用的窗口尺寸，不能靠一次升级静默生效。
        windowLiftEnabled = defaults.bool(forKey: Keys.windowLiftEnabled)
        // 同样有意不进 register：缺键即 false = 还没订阅过。
        hasSubscribed = defaults.bool(forKey: Keys.hasSubscribed)
        // 同上：缺键即 false = 还没看过欢迎引导。
        hasSeenWelcome = defaults.bool(forKey: Keys.hasSeenWelcome)
        fullscreenIntentEnabled = defaults.bool(forKey: Keys.fullscreenIntentEnabled)
        // 有意不 register：缺键即 nil = 默认 ⌥⇧⌘D；坏数据（手改过、类型不对）也回落 nil。
        edgeToggleShortcut = Self.storedHotKeyShortcut(defaults.dictionary(forKey: Keys.edgeToggleShortcut))
        // 同样有意不 register：缺键即 false 正好是「默认关」，注册个 false 会让人误读成默认开。
        scrollReverserEnabled = defaults.bool(forKey: Keys.scrollReverserEnabled)
        // 有意不 register：缺键即 followMouse = 现状行为，老用户升级无感。
        let pinnedSelection = Self.storedPinnedScreenSelection(
            defaults.dictionary(forKey: Keys.taskbarScreenPinned)
        )
        switch defaults.string(forKey: Keys.taskbarScreenMode) {
        case nil, TaskbarScreenMode.followMouse.rawValue:
            taskbarScreenPlacement = .followMouse
        case TaskbarScreenMode.allScreens.rawValue:
            taskbarScreenPlacement = .allScreens
        case TaskbarScreenMode.allScreensPerDisplay.rawValue:
            taskbarScreenPlacement = .allScreensPerDisplay
        case TaskbarScreenMode.pinned.rawValue:
            if let pinnedSelection {
                taskbarScreenPlacement = .pinned(pinnedSelection)
            } else {
                // pinned 但选择缺失/坏 → 回退并立刻重写 mode 键（对齐 dockSize 的坏值即重写惯例）。
                taskbarScreenPlacement = .followMouse
                defaults.set(TaskbarScreenMode.followMouse.rawValue, forKey: Keys.taskbarScreenMode)
            }
        default:
            // 未知字符串（将来版本的新档被老版本读到）→ 按 followMouse 跑但**不重写键**，
            // 降级不毁掉用户在新版本里做的选择。
            taskbarScreenPlacement = .followMouse
        }
        // 坏值（手改过、旧版本残留、类型不对）一律回退中档并**立刻重写**，
        // 否则每次启动都要重新走一遍回退，且 UI 上勾选的档位和存的值对不上。
        dockSize = DockSize(rawValue: defaults.string(forKey: Keys.dockSize) ?? "") ?? .default
        hoverStyle = HoverStyle(rawValue: defaults.string(forKey: Keys.hoverStyle) ?? "") ?? .default
        let nativeDelay = Self.sanitizedStoredDelay(
            defaults.object(forKey: Keys.nativeDockAutoHideDelay),
            fallback: Self.defaultNativeDockAutoHideDelay
        )
        nativeDockAutoHideDelay = nativeDelay
        if nativeDelay == Self.neverHideDelay {
            lastEnabledNativeDockAutoHideDelay = Self.sanitizedLastEnabledDelay(
                Self.storedNumericValue(defaults.object(forKey: Keys.nativeDockAutoHideLastEnabledDelay)),
                fallback: Self.defaultNativeDockAutoHideDelay
            )
        } else {
            lastEnabledNativeDockAutoHideDelay = nativeDelay
        }
        let edgeDelay = Self.sanitizedStoredDelay(
            defaults.object(forKey: Keys.edgeAutoHideDelay),
            fallback: Self.defaultEnabledEdgeAutoHideDelay
        )
        edgeAutoHideDelay = edgeDelay
        if edgeDelay == Self.neverHideDelay {
            lastEnabledEdgeAutoHideDelay = Self.sanitizedLastEnabledDelay(
                Self.storedNumericValue(defaults.object(forKey: Keys.edgeAutoHideLastEnabledDelay)),
                fallback: Self.defaultEnabledEdgeAutoHideDelay
            )
        } else {
            lastEnabledEdgeAutoHideDelay = edgeDelay
        }
        defaults.set(dockSize.rawValue, forKey: Keys.dockSize)
        defaults.set(hoverStyle.rawValue, forKey: Keys.hoverStyle)
        defaults.set(nativeDelay, forKey: Keys.nativeDockAutoHideDelay)
        defaults.set(lastEnabledNativeDockAutoHideDelay, forKey: Keys.nativeDockAutoHideLastEnabledDelay)
        defaults.set(edgeDelay, forKey: Keys.edgeAutoHideDelay)
        defaults.set(lastEnabledEdgeAutoHideDelay, forKey: Keys.edgeAutoHideLastEnabledDelay)
    }

    func setDockSize(_ value: DockSize) {
        guard dockSize != value else { return }
        dockSize = value
        defaults.set(value.rawValue, forKey: Keys.dockSize)
    }

    /// 只应由 `SettingsCoordinator.applyEdgeToggleShortcut` 在**注册成功后**调用（见属性注释）。
    func setEdgeToggleShortcut(_ value: StoredHotKeyShortcut?) {
        guard edgeToggleShortcut != value else { return }
        edgeToggleShortcut = value
        guard let value else {
            defaults.removeObject(forKey: Keys.edgeToggleShortcut)
            return
        }
        defaults.set(
            [
                "keyCode": Int(value.keyCode),
                "modifiers": Int(value.carbonModifiers),
                "glyphs": value.glyphs,
            ],
            forKey: Keys.edgeToggleShortcut
        )
    }

    func setScrollReverserEnabled(_ value: Bool) {
        guard scrollReverserEnabled != value else { return }
        scrollReverserEnabled = value
        defaults.set(value, forKey: Keys.scrollReverserEnabled)
    }

    func setTaskbarScreenPlacement(_ value: TaskbarScreenPlacement) {
        guard taskbarScreenPlacement != value else { return }
        taskbarScreenPlacement = value
        defaults.set(value.mode.rawValue, forKey: Keys.taskbarScreenMode)
        if let selection = value.pinnedSelection {
            defaults.set(
                ["uuid": selection.uuid, "name": selection.name],
                forKey: Keys.taskbarScreenPinned
            )
        }
        // 切回 followMouse 时**保留** pinned 字典不删（remembered 惯例，
        // 同 lastEnabledEdgeAutoHideDelay 的精神：再切回固定档时还记得上次选的屏）。
    }

    private static func storedPinnedScreenSelection(_ dict: [String: Any]?) -> PinnedScreenSelection? {
        guard let dict,
              let uuid = dict["uuid"] as? String, !uuid.isEmpty,
              let name = dict["name"] as? String
        else { return nil }
        return PinnedScreenSelection(uuid: uuid, name: name)
    }

    private static func storedHotKeyShortcut(_ dict: [String: Any]?) -> StoredHotKeyShortcut? {
        guard let dict,
              let keyCode = dict["keyCode"] as? Int, keyCode >= 0, keyCode <= 0xFFFF,
              let modifiers = dict["modifiers"] as? Int, modifiers >= 0,
              let glyphs = dict["glyphs"] as? String, !glyphs.isEmpty
        else { return nil }
        return StoredHotKeyShortcut(
            keyCode: UInt32(keyCode),
            carbonModifiers: UInt32(modifiers),
            glyphs: glyphs
        )
    }

    func setHoverStyle(_ value: HoverStyle) {
        guard hoverStyle != value else { return }
        hoverStyle = value
        defaults.set(value.rawValue, forKey: Keys.hoverStyle)
    }

    func setShowShelf(_ value: Bool) {
        guard showShelf != value else { return }
        showShelf = value
        defaults.set(value, forKey: Keys.showShelf)
    }

    /// 全新安装把「最大化窗口避开 Dock 栏」播种为开（owner 2026-09-01）。
    ///
    /// **只允许 `AppDelegate` 在判定为全新安装时调一次**：判据是 `InstallationRecord`
    /// 的首装键在本次启动**之前**是否存在——老用户机器上它早就有值，只有全新安装那一次是空的，
    /// 所以不需要再新建一个播种标记键（也就没有新的数据边界）。⚠️ 调用点必须排在
    /// `recordFirstLaunchIfNeeded()` **之前**取那个判据，写完再问就永远是「老用户」。
    ///
    /// 键已存在 = 用户自己拨过（哪怕拨成关），一律尊重，不覆盖。
    func seedWindowLiftEnabledForFreshInstall() {
        guard defaults.object(forKey: Keys.windowLiftEnabled) == nil else { return }
        setWindowLiftEnabled(true)
    }

    func setWindowLiftEnabled(_ value: Bool) {
        guard windowLiftEnabled != value else { return }
        windowLiftEnabled = value
        defaults.set(value, forKey: Keys.windowLiftEnabled)
    }

    func setHasSubscribed(_ value: Bool) {
        guard hasSubscribed != value else { return }
        hasSubscribed = value
        defaults.set(value, forKey: Keys.hasSubscribed)
    }

    func setHasSeenWelcome(_ value: Bool) {
        guard hasSeenWelcome != value else { return }
        hasSeenWelcome = value
        defaults.set(value, forKey: Keys.hasSeenWelcome)
    }

    func setFullscreenIntentEnabled(_ value: Bool) {
        guard fullscreenIntentEnabled != value else { return }
        fullscreenIntentEnabled = value
        defaults.set(value, forKey: Keys.fullscreenIntentEnabled)
    }

    func setLaunchAtLogin(_ value: Bool) {
        guard launchAtLogin != value else { return }
        launchAtLogin = value
        defaults.set(value, forKey: Keys.launchAtLogin)
    }

    func setNativeDockAutoHideDelay(_ value: Double) {
        guard value.isFinite else { return }
        let snapped = Self.snapDelay(value, fallbackForNonFinite: Self.defaultNativeDockAutoHideDelay)
        // remembered 同步先于 active 去重：active 未变时也要修正 remembered。
        if snapped != Self.neverHideDelay, lastEnabledNativeDockAutoHideDelay != snapped {
            lastEnabledNativeDockAutoHideDelay = snapped
            defaults.set(snapped, forKey: Keys.nativeDockAutoHideLastEnabledDelay)
        }
        guard nativeDockAutoHideDelay != snapped else { return }
        nativeDockAutoHideDelay = snapped
        defaults.set(snapped, forKey: Keys.nativeDockAutoHideDelay)
    }

    // 系统 Dock 组刻意不提供盲翻的 toggle 方法：系统状态可被外部改（⌥⌘D / 系统设置），
    // 盲翻本地存值会在两者脱节时翻错方向。菜单里的显隐命令已于 2026-08-01 删除，
    // 整组改由滑块 + 确认行表达，翻转这件事交还给系统自己的 ⌥⌘D。
    //
    // 因此 `lastEnabledNativeDockAutoHideDelay` 目前**没有读取方**（原先只有那条命令用它来
    // 恢复「上次的档」）：滑块自己带着位置，不需要记忆。字段与持久化保留——它是用户数据，
    // 删键属于有损迁移，且命令一旦回归就还要用。不是漏读。

    func setEdgeAutoHideDelay(_ value: Double) {
        guard value.isFinite else { return }
        let snapped = Self.snapDelay(value, fallbackForNonFinite: Self.defaultEnabledEdgeAutoHideDelay)
        // remembered 同步先于 active 去重：active 未变时也要修正 remembered。
        if snapped != Self.neverHideDelay, lastEnabledEdgeAutoHideDelay != snapped {
            lastEnabledEdgeAutoHideDelay = snapped
            defaults.set(snapped, forKey: Keys.edgeAutoHideLastEnabledDelay)
        }
        guard edgeAutoHideDelay != snapped else { return }
        edgeAutoHideDelay = snapped
        defaults.set(snapped, forKey: Keys.edgeAutoHideDelay)
    }

    /// 钨极的「自动隐藏」切换：常驻 ⇄ 上一次的延迟（含不唤醒 999）。
    /// 命名避免 "Now"——切到自动隐藏侧不是立即隐藏，仍走原空闲计时与鼠标判定。
    func toggleEdgeAutoHideMode() {
        if edgeAutoHideDelay == Self.neverHideDelay {
            setEdgeAutoHideDelay(lastEnabledEdgeAutoHideDelay)
        } else {
            setEdgeAutoHideDelay(Self.neverHideDelay)
        }
    }

    static func delayFromSliderIndex(_ index: Int) -> Double {
        let clamped = min(max(index, 0), sliderIndexMax)
        switch clamped {
        case 0:
            return neverHideDelay
        case sliderIndexMax:
            return neverWakeDelay
        case sliderIndexMax - 1:
            return finiteDelayMax
        default:
            return ((finiteDelayMin + Double(clamped - 1) * delayStep) * 10).rounded() / 10
        }
    }

    static func sliderIndexFromDelay(_ value: Double) -> Int {
        guard value > neverHideDelay else { return 0 }
        guard value < neverWakeDelay else { return sliderIndexMax }
        let clamped = min(max(value, finiteDelayMin), finiteDelayMax)
        return Int(((clamped - finiteDelayMin) / delayStep).rounded()) + 1
    }

    static func snapDelay(_ value: Double, fallbackForNonFinite fallback: Double = AppSettingsStore.defaultEnabledEdgeAutoHideDelay) -> Double {
        // NaN/±inf 穿透到下面的 Int(...) 转换会直接 crash（NaN 的比较全为 false，clamp 不生效）。
        guard value.isFinite else { return fallback }
        if value <= neverHideDelay { return neverHideDelay }
        if value >= neverWakeDelay { return neverWakeDelay }
        let clamped = min(max(value, finiteDelayMin), finiteDelayMax)
        return delayFromSliderIndex(Int(((clamped - finiteDelayMin) / delayStep).rounded()) + 1)
    }

    /// UserDefaults 的 active delay 读取入口。只接受真正的数值对象；字符串、布尔值和非有限值
    /// 都按该组默认档位回退，避免 `double(forKey:)` 把坏类型静默变成 0.0。
    static func sanitizedStoredDelay(_ value: Any?, fallback: Double) -> Double {
        guard let value = storedNumericValue(value) else { return fallback }
        return snapDelay(value, fallbackForNonFinite: fallback)
    }

    /// remembered 值的防御收口：缺失、类型错误、非有限、吸附后为常驻，一律回退默认档位
    /// （edge 组 0.1，系统 Dock 组 1.0）。
    static func sanitizedLastEnabledDelay(_ value: Double?, fallback: Double = AppSettingsStore.defaultEnabledEdgeAutoHideDelay) -> Double {
        guard let value, value.isFinite else { return fallback }
        let snapped = snapDelay(value, fallbackForNonFinite: fallback)
        return snapped == neverHideDelay ? fallback : snapped
    }

    private static func storedNumericValue(_ value: Any?) -> Double? {
        DefaultsValueParsing.finiteNumericValue(value)
    }

    private static func migrateLegacyEnabledKey(defaults: UserDefaults, enabledKey: String, delayKey: String) {
        if let storedEnabled = defaults.object(forKey: enabledKey) as? Bool, storedEnabled == false {
            defaults.set(neverHideDelay, forKey: delayKey)
        }
        defaults.removeObject(forKey: enabledKey)
    }
}

private enum Keys {
    static let launchAtLogin = "com.tungsten.edge.launchAtLogin"
    static let showShelf = "com.tungsten.edge.showShelf"
    static let dockSize = "com.tungsten.edge.dockSize"
    static let hoverStyle = "com.tungsten.edge.hoverStyle"
        // `com.tungsten.edge.appearanceMode` 已随深色模式一起删除（owner 2026-08-16）。
        // **键留成孤儿，不读不写不删**——回退这轮改动时还读得回用户原来的选择。
    static let windowLiftEnabled = "com.tungsten.edge.windowLiftEnabled"
    static let fullscreenIntentEnabled = "com.tungsten.edge.fullscreenIntentEnabled"
    /// 自定义显隐快捷键（字典：keyCode / modifiers / glyphs）。缺键 = 默认 ⌥⇧⌘D。
    static let edgeToggleShortcut = "com.tungsten.edge.hotKey.edgeAutoHideMode"
    static let scrollReverserEnabled = "com.tungsten.edge.scrollReverserEnabled"
    /// 任务条显示位置（followMouse / pinned / allScreens / allScreensPerDisplay）。缺键 = followMouse。
    /// ⚠️ 旧的 `com.tungsten.edge.displayMode`（早期「单屏/多屏」档，已随功能删除）是孤儿键，
    /// **永不再读**（`Docs/05`）——新功能只认下面这两个键。
    static let taskbarScreenMode = "com.tungsten.edge.taskbarScreen.mode"
    /// 固定屏身份（字典：uuid / name）。切回 followMouse 时保留不删。
    static let taskbarScreenPinned = "com.tungsten.edge.taskbarScreen.pinned"
    /// ⚠️ 这个键名进了用户磁盘。改名 = 所有已订阅的人重新看到订阅区块。
    static let hasSubscribed = "com.tungsten.edge.hasSubscribed"
    /// ⚠️ 同上：改名 = 所有老用户下次启动被欢迎引导再拦一次。
    static let hasSeenWelcome = "com.tungsten.edge.hasSeenWelcome"
    static let nativeDockAutoHideEnabled = "com.tungsten.edge.autoHide.nativeDock.enabled"
    static let nativeDockAutoHideDelay = "com.tungsten.edge.autoHide.nativeDock.delay"
    static let nativeDockAutoHideLastEnabledDelay = "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay"
    static let edgeAutoHideEnabled = "com.tungsten.edge.autoHide.edge.enabled"
    static let edgeAutoHideDelay = "com.tungsten.edge.autoHide.edge.delay"
    static let edgeAutoHideLastEnabledDelay = "com.tungsten.edge.autoHide.edge.lastEnabledDelay"
}
