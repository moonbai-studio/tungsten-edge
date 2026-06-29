import Combine
import Foundation

enum DisplayMode: String {
    case single
    case multiple
}

@MainActor
final class AppSettingsStore: ObservableObject {
    static let delayStep: Double = 0.1
    static let finiteDelayMin: Double = 0.5
    static let finiteDelayMax: Double = 3.0
    static let neverHideDelay: Double = -1.0
    static let neverWakeDelay: Double = 999.0
    static let sliderIndexMax = 27

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var displayMode: DisplayMode
    @Published private(set) var nativeDockAutoHideDelay: Double
    @Published private(set) var edgeAutoHideDelay: Double

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
        defaults.register(defaults: [
            Keys.launchAtLogin: false,
            Keys.displayMode: DisplayMode.multiple.rawValue,
            Keys.nativeDockAutoHideDelay: 1.0,
            Keys.edgeAutoHideDelay: 0.5,
        ])

        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .multiple
        nativeDockAutoHideDelay = Self.snapDelay(defaults.double(forKey: Keys.nativeDockAutoHideDelay))
        edgeAutoHideDelay = Self.snapDelay(defaults.double(forKey: Keys.edgeAutoHideDelay))
    }

    func setLaunchAtLogin(_ value: Bool) {
        guard launchAtLogin != value else { return }
        launchAtLogin = value
        defaults.set(value, forKey: Keys.launchAtLogin)
    }

    func setDisplayMode(_ value: DisplayMode) {
        guard displayMode != value else { return }
        displayMode = value
        defaults.set(value.rawValue, forKey: Keys.displayMode)
    }

    func setNativeDockAutoHideDelay(_ value: Double) {
        let snapped = Self.snapDelay(value)
        guard nativeDockAutoHideDelay != snapped else { return }
        nativeDockAutoHideDelay = snapped
        defaults.set(snapped, forKey: Keys.nativeDockAutoHideDelay)
    }

    func setEdgeAutoHideDelay(_ value: Double) {
        let snapped = Self.snapDelay(value)
        guard edgeAutoHideDelay != snapped else { return }
        edgeAutoHideDelay = snapped
        defaults.set(snapped, forKey: Keys.edgeAutoHideDelay)
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

    static func snapDelay(_ value: Double) -> Double {
        if value <= neverHideDelay { return neverHideDelay }
        if value >= neverWakeDelay { return neverWakeDelay }
        let clamped = min(max(value, finiteDelayMin), finiteDelayMax)
        return delayFromSliderIndex(Int(((clamped - finiteDelayMin) / delayStep).rounded()) + 1)
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
    static let displayMode = "com.tungsten.edge.displayMode"
    static let nativeDockAutoHideEnabled = "com.tungsten.edge.autoHide.nativeDock.enabled"
    static let nativeDockAutoHideDelay = "com.tungsten.edge.autoHide.nativeDock.delay"
    static let edgeAutoHideEnabled = "com.tungsten.edge.autoHide.edge.enabled"
    static let edgeAutoHideDelay = "com.tungsten.edge.autoHide.edge.delay"
}
