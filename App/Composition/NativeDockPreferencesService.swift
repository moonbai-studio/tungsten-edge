import Foundation
import Security

typealias ShellRunner = @MainActor (_ executable: String, _ arguments: [String]) throws -> Void

@MainActor
protocol NativeDockPreferencesServicing {
    var isAvailable: Bool { get }
    func apply(delay: Double) throws
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
    static let noWakeDelay = 999.0

    private let sandbox: SandboxEnvironment
    private let runner: ShellRunner

    init(sandbox: SandboxEnvironment = .current, runner: @escaping ShellRunner = NativeDockPreferencesService.runProcess) {
        self.sandbox = sandbox
        self.runner = runner
    }

    var isAvailable: Bool { !sandbox.isSandboxed }

    func apply(delay: Double) throws {
        guard isAvailable else { throw NativeDockPreferencesError.sandboxed }
        for command in Self.commands(for: delay) {
            try runner(command.executable, command.arguments)
        }
    }

    static func commands(for delay: Double) -> [(executable: String, arguments: [String])] {
        if delay <= AppSettingsStore.neverHideDelay {
            return [
                ("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"]),
                ("/usr/bin/killall", ["Dock"]),
            ]
        }

        // 999 seconds is intentionally large enough to behave like "do not wake",
        // without relying on extreme floating point values that Dock preferences may not parse consistently.
        let effectiveDelay = delay >= AppSettingsStore.neverWakeDelay ? noWakeDelay : AppSettingsStore.snapDelay(delay)
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
}

enum NativeDockPreferencesError: LocalizedError {
    case sandboxed
    case commandFailed(executable: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .sandboxed:
            return "沙箱环境不能直接修改系统 Dock 设置。"
        case .commandFailed(let executable, let status):
            return "\(executable) 执行失败（状态码 \(status)）。"
        }
    }
}
