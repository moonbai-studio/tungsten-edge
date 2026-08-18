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

    static let `default` = HoverStyle.standard

    /// 悬停是否产生视觉变化。chip 视图统一用它做判据，不各自比 case；
    /// 菜单的勾选态也读它（`.on` ⟺ `isExpressive`）。
    var isExpressive: Bool { self == .standard }
}

/// 外观档位（设置窗口「通用 → 外观」）。作用于**整个 app**：任务条、抽屉、各弹窗、
/// 右键菜单、状态栏菜单、设置窗口一起变（owner 2026-08-06）。
///
/// 实现上只翻一个开关 `NSApp.appearance`（映射见 `DockTheme.swift` 的 `nsAppearance`），
/// 因为主题取值链路是隐式的：`DockThemeTokens.resolve` 读 SwiftUI 的 `\.colorScheme`，
/// 而那个值和毛玻璃 `NSVisualEffectView` 的材质**都**来自窗口的 `effectiveAppearance`。
///
/// rawValue 会落进 UserDefaults：**改名 = 把所有老用户重置回跟随系统**（同 `DockSize`）。
enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    static let `default` = AppearanceMode.system

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
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
    nonisolated static let defaultEdgeAutoHideDelay: Double = 0.1

    @Published private(set) var launchAtLogin: Bool
    /// 中转格是否显示在固定文件夹区头位。关掉后它不再渲染，暂存的文件不受影响。
    @Published private(set) var showShelf: Bool
    /// 任务条尺寸档位。面板几何与条内所有 chip 尺寸都由它派生。
    @Published private(set) var dockSize: DockSize
    /// 悬停效果档位。只影响条内 chip 的悬停视觉，静息布局逐像素不变（因此无需 relayout）。
    @Published private(set) var hoverStyle: HoverStyle
    /// 浅 / 深色档位，默认跟随系统。应用方式见 `AppearanceMode`。
    @Published private(set) var appearanceMode: AppearanceMode
    /// 最大化窗口避让任务条（菜单「最大化窗口避开任务条」）。**默认关**——
    /// 这个功能会真的去改写别人应用的窗口尺寸，没主动选过的人不该被改。
    @Published private(set) var windowLiftEnabled: Bool
    /// 访达是否常驻任务条。**默认开**（还原系统 Dock 行为：无窗口也有入口，点击打开个人文件夹）。
    /// 关闭后访达与普通应用一致：只在有窗口时出现，无窗口即从任务条消失（issue #7）。
    @Published private(set) var finderAlwaysInDock: Bool
    /// 标准绿灯 / Control-Command-F 输入投递前预测隐藏任务条，默认开启。
    @Published private(set) var fullscreenIntentEnabled: Bool
    /// 这台机器上已经成功提交过邮箱订阅。只用来把设置里那段订阅区块收起来，
    /// 免得已经留过邮箱的人被同一段话反复看见。**不是**「是否为原始用户」的凭据——
    /// 那个凭据是 `InstallationRecord` 的首装时间戳，以及服务端那份名单。
    @Published private(set) var hasSubscribed: Bool
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
            Keys.finderAlwaysInDock: true,
            Keys.nativeDockAutoHideDelay: Self.defaultNativeDockAutoHideDelay,
            Keys.edgeAutoHideDelay: Self.defaultEdgeAutoHideDelay,
        ])

        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        showShelf = defaults.bool(forKey: Keys.showShelf)
        // 有意**不**进上面的 register：缺键即 false 正好是我们要的默认关。
        // 注册一个 false 只会让人误以为它跟 showShelf 一样是「默认开」。
        windowLiftEnabled = defaults.bool(forKey: Keys.windowLiftEnabled)
        // 同样有意不进 register：缺键即 false = 还没订阅过。
        hasSubscribed = defaults.bool(forKey: Keys.hasSubscribed)
        fullscreenIntentEnabled = defaults.bool(forKey: Keys.fullscreenIntentEnabled)
        finderAlwaysInDock = defaults.bool(forKey: Keys.finderAlwaysInDock)
        // 坏值（手改过、旧版本残留、类型不对）一律回退中档并**立刻重写**，
        // 否则每次启动都要重新走一遍回退，且 UI 上勾选的档位和存的值对不上。
        dockSize = DockSize(rawValue: defaults.string(forKey: Keys.dockSize) ?? "") ?? .default
        hoverStyle = HoverStyle(rawValue: defaults.string(forKey: Keys.hoverStyle) ?? "") ?? .default
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .default
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
            fallback: Self.defaultEdgeAutoHideDelay
        )
        edgeAutoHideDelay = edgeDelay
        if edgeDelay == Self.neverHideDelay {
            lastEnabledEdgeAutoHideDelay = Self.sanitizedLastEnabledDelay(
                Self.storedNumericValue(defaults.object(forKey: Keys.edgeAutoHideLastEnabledDelay)),
                fallback: Self.defaultEdgeAutoHideDelay
            )
        } else {
            lastEnabledEdgeAutoHideDelay = edgeDelay
        }
        defaults.set(dockSize.rawValue, forKey: Keys.dockSize)
        defaults.set(hoverStyle.rawValue, forKey: Keys.hoverStyle)
        defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode)
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

    func setHoverStyle(_ value: HoverStyle) {
        guard hoverStyle != value else { return }
        hoverStyle = value
        defaults.set(value.rawValue, forKey: Keys.hoverStyle)
    }

    func setAppearanceMode(_ value: AppearanceMode) {
        guard appearanceMode != value else { return }
        appearanceMode = value
        defaults.set(value.rawValue, forKey: Keys.appearanceMode)
    }

    func setShowShelf(_ value: Bool) {
        guard showShelf != value else { return }
        showShelf = value
        defaults.set(value, forKey: Keys.showShelf)
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

    func setFullscreenIntentEnabled(_ value: Bool) {
        guard fullscreenIntentEnabled != value else { return }
        fullscreenIntentEnabled = value
        defaults.set(value, forKey: Keys.fullscreenIntentEnabled)
    }

    func setFinderAlwaysInDock(_ value: Bool) {
        guard finderAlwaysInDock != value else { return }
        finderAlwaysInDock = value
        defaults.set(value, forKey: Keys.finderAlwaysInDock)
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
        let snapped = Self.snapDelay(value, fallbackForNonFinite: Self.defaultEdgeAutoHideDelay)
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

    static func snapDelay(_ value: Double, fallbackForNonFinite fallback: Double = AppSettingsStore.defaultEdgeAutoHideDelay) -> Double {
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
    static func sanitizedLastEnabledDelay(_ value: Double?, fallback: Double = AppSettingsStore.defaultEdgeAutoHideDelay) -> Double {
        guard let value, value.isFinite else { return fallback }
        let snapped = snapDelay(value, fallbackForNonFinite: fallback)
        return snapped == neverHideDelay ? fallback : snapped
    }

    private static func storedNumericValue(_ value: Any?) -> Double? {
        guard let value else { return nil }
        // Bool/CFBoolean 也能桥接成 NSNumber，必须先按 CF 类型排除，否则 true 会被误读成 1.0。
        guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        let result = number.doubleValue
        return result.isFinite ? result : nil
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
    static let appearanceMode = "com.tungsten.edge.appearanceMode"
    static let windowLiftEnabled = "com.tungsten.edge.windowLiftEnabled"
    static let fullscreenIntentEnabled = "com.tungsten.edge.fullscreenIntentEnabled"
    static let finderAlwaysInDock = "com.tungsten.edge.finderAlwaysInDock"
    /// ⚠️ 这个键名进了用户磁盘。改名 = 所有已订阅的人重新看到订阅区块。
    static let hasSubscribed = "com.tungsten.edge.hasSubscribed"
    static let nativeDockAutoHideEnabled = "com.tungsten.edge.autoHide.nativeDock.enabled"
    static let nativeDockAutoHideDelay = "com.tungsten.edge.autoHide.nativeDock.delay"
    static let nativeDockAutoHideLastEnabledDelay = "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay"
    static let edgeAutoHideEnabled = "com.tungsten.edge.autoHide.edge.enabled"
    static let edgeAutoHideDelay = "com.tungsten.edge.autoHide.edge.delay"
    static let edgeAutoHideLastEnabledDelay = "com.tungsten.edge.autoHide.edge.lastEnabledDelay"
}
