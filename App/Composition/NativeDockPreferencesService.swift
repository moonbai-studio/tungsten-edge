import AppKit
import Foundation
import Security

typealias ShellRunner = @MainActor (_ executable: String, _ arguments: [String]) throws -> Void
typealias URLOpener = @MainActor (URL) -> Bool

/// 系统 Dock 自动隐藏的实际状态快照。delay 为 nil = autohide-delay 键不存在（系统默认值）。
struct NativeDockAutohideState: Equatable {
    var enabled: Bool
    var delay: Double?
}

/// 写系统 Dock 只剩 `apply(delay:)` 一条路径（owner 2026-08-01 定）：菜单里的显隐命令已删掉，
/// 整组由滑块 + 确认行表达——滑块能表达全部状态（常驻 / 秒数 / 不唤醒），命令是冗余的，
/// 而它只切 `autohide` 不碰 `autohide-delay`，字面承诺的「隐藏」大于实际效果，反而误导。
/// 一键显隐交还给系统自己的 ⌥⌘D（macOS 持有，恒生效，且沿用这里写下的延迟档）。
@MainActor
protocol NativeDockPreferencesServicing {
    var isAvailable: Bool { get }
    func apply(delay: Double) throws
    /// 系统 Dock 当前的自动隐藏状态。nil = 读不到（沙箱等），调用方回退本地存值推导。
    /// 必须读系统实际值：用户随时可用 ⌥⌘D / 系统设置改它，本地存值会过期。
    func currentAutohideState() async -> NativeDockAutohideState?
    /// 只打开系统设置里的 Dock 页面，不修改偏好，也不受写入路径的沙箱门控。
    func openSystemSettings() -> Bool
}

struct SandboxEnvironment {
    var isSandboxed: Bool

    static var current: SandboxEnvironment {
        let key = "com.apple.security.app-sandbox" as CFString
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key, nil) else {
            return SandboxEnvironment(isSandboxed: false)
        }
        return SandboxEnvironment(isSandboxed: (value as? Bool) == true)
    }
}

@MainActor
final class NativeDockPreferencesService: NativeDockPreferencesServicing {
    /// 系统 Dock 的「不唤醒」落值。刻意用 999 而不是极端浮点，Dock 偏好对后者解析不稳定。
    static let noWakeDelay = 999.0

    private let sandbox: SandboxEnvironment
    private let runner: ShellRunner
    private let autohideReader: () -> NativeDockAutohideState?
    private let urlOpener: URLOpener
    private let readerQueue = DispatchQueue(label: "com.caye.macosdockcc.v2.native-dock-reader", qos: .userInitiated)

    init(sandbox: SandboxEnvironment = .current,
         runner: @escaping ShellRunner = NativeDockPreferencesService.runProcess,
         autohideReader: @escaping () -> NativeDockAutohideState? = NativeDockPreferencesService.readAutohideStateFromSystem,
         urlOpener: @escaping URLOpener = NativeDockPreferencesService.openURL) {
        self.sandbox = sandbox
        self.runner = runner
        self.autohideReader = autohideReader
        self.urlOpener = urlOpener
    }

    var isAvailable: Bool { !sandbox.isSandboxed }

    func currentAutohideState() async -> NativeDockAutohideState? {
        guard isAvailable else { return nil }
        let autohideReader = autohideReader
        let readerQueue = readerQueue
        return await withCheckedContinuation { continuation in
            readerQueue.async {
                continuation.resume(returning: autohideReader())
            }
        }
    }

    /// Monterey 使用「程序坞与菜单栏」，Ventura 及以上映射到「桌面与程序坞」。
    /// 深链失败时交给系统打开 Dock.prefPane；两条路径都不启动子进程。
    func openSystemSettings() -> Bool {
        if let primary = URL(string: "x-apple.systempreferences:com.apple.preference.dock"),
           urlOpener(primary) {
            return true
        }
        return urlOpener(URL(fileURLWithPath: "/System/Library/PreferencePanes/Dock.prefPane"))
    }

    private static func openURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    nonisolated static func readAutohideStateFromSystem() -> NativeDockAutohideState? {
        let domain = "com.apple.dock" as CFString
        // 外部修改（⌥⌘D / 系统设置 / killall Dock）不会自动进入本进程的 CFPreferences 缓存，
        // 每次读取前必须先同步，否则可能一直拿到旧值。
        return readAutohideState(
            synchronize: { CFPreferencesAppSynchronize(domain) },
            valueForKey: { key in
                CFPreferencesCopyAppValue(key as CFString, domain)
            }
        )
    }

    /// 注入同步与取值动作，既隔离 CFPreferences I/O，也让同步失败等分支可直接单测。
    nonisolated static func readAutohideState(
        synchronize: () -> Bool,
        valueForKey: (String) -> Any?
    ) -> NativeDockAutohideState? {
        guard synchronize() else { return nil }
        return decodeAutohideState(
            autohideValue: valueForKey("autohide"),
            delayValue: valueForKey("autohide-delay")
        )
    }

    /// 纯解码规则：autohide 缺键代表关闭；存在却不是布尔值代表整份快照不可读。
    /// 开启时，delay 缺键代表系统默认，坏类型代表不可读；关闭时 delay 不影响开关真值。
    nonisolated static func decodeAutohideState(
        autohideValue: Any?,
        delayValue: Any?
    ) -> NativeDockAutohideState? {
        let enabled: Bool
        if let autohideValue {
            guard let decoded = strictBooleanValue(autohideValue) else { return nil }
            enabled = decoded
        } else {
            enabled = false
        }

        if !enabled {
            let delay = delayValue.flatMap { finiteNumericValue($0) }
            return NativeDockAutohideState(enabled: false, delay: delay)
        }

        let delay: Double?
        if let delayValue {
            guard let decoded = finiteNumericValue(delayValue) else { return nil }
            delay = decoded
        } else {
            delay = nil
        }
        return NativeDockAutohideState(enabled: enabled, delay: delay)
    }

    /// 滑块：整档写入。常驻档只关 `autohide`，不写延迟——延迟此时无意义，写了反而覆盖用户原值。
    func apply(delay: Double) throws {
        guard isAvailable else { throw NativeDockPreferencesError.sandboxed }
        for command in Self.commands(for: delay) {
            try runner(command.executable, command.arguments)
        }
    }

    static func autohideCommands(enabled: Bool) -> [(executable: String, arguments: [String])] {
        [
            ("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", enabled ? "true" : "false"]),
            ("/usr/bin/killall", ["Dock"]),
        ]
    }

    static func commands(for delay: Double) -> [(executable: String, arguments: [String])] {
        if delay <= AppSettingsStore.neverHideDelay {
            return autohideCommands(enabled: false)
        }

        let effectiveDelay = delay >= AppSettingsStore.neverWakeDelay
            ? noWakeDelay
            : AppSettingsStore.snapDelay(delay, fallbackForNonFinite: AppSettingsStore.defaultNativeDockAutoHideDelay)
        return [
            ("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"]),
            ("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", String(format: "%.1f", effectiveDelay)]),
            ("/usr/bin/killall", ["Dock"]),
        ]
    }

    private static func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NativeDockPreferencesError.commandFailed(executable: executable, status: process.terminationStatus)
        }
    }

    nonisolated private static func strictBooleanValue(_ value: Any) -> Bool? {
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    nonisolated private static func finiteNumericValue(_ value: Any) -> Double? {
        guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}

/// 冻结键：`d08e8d6` 的「彻底隐藏」曾用这三个键记录隐藏前的精确 delay。滑块回归后这套快照
/// 不再需要，但**不读、不写、也不删**——已有用户机器上可能存着精确旧值（如 0.75，滑块 0.1 步进
/// 本来就表达不了），删掉既丢值又破坏 `git revert d08e8d6` 的数据边界。留作孤儿键，无害。
/// 要做有损迁移必须先问 owner。这里只保留名字，防止将来撞键。
///
/// - `com.tungsten.edge.nativeDock.restoreDelay.captured`
/// - `com.tungsten.edge.nativeDock.restoreDelay.present`
/// - `com.tungsten.edge.nativeDock.restoreDelay.value`

enum NativeDockPreferencesError: LocalizedError {
    case sandboxed
    case commandFailed(executable: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .sandboxed:
            return String(localized: "Dock settings can’t be changed directly from a sandboxed environment.")
        case .commandFailed(let executable, let status):
            return String(format: String(localized: "%@ failed (status code %d)."), executable, status)
        }
    }
}
