import Combine
import Foundation
import SwiftUI

enum AppInstallLocation: String, Equatable {
    case applications
    case diskImage
    case appTranslocation
    case other

    init(bundleURL: URL) {
        let path = bundleURL.standardizedFileURL.path
        let components = path.split(separator: "/")

        if components.contains("AppTranslocation") {
            self = .appTranslocation
        } else if path == "/Volumes" || path.hasPrefix("/Volumes/") {
            self = .diskImage
        } else if path == "/Applications" || path.hasPrefix("/Applications/") {
            self = .applications
        } else {
            self = .other
        }
    }

    var allowsAccessibilityPrompt: Bool {
        switch self {
        case .applications, .other:
            return true
        case .diskImage, .appTranslocation:
            return false
        }
    }
}

enum PermissionOnboardingState: Equatable {
    case moveToApplications(AppInstallLocation)
    case waiting
    case stalled
    case granted

    static func initial(installLocation: AppInstallLocation, isTrusted: Bool) -> Self {
        guard installLocation.allowsAccessibilityPrompt else {
            return .moveToApplications(installLocation)
        }
        return isTrusted ? .granted : .waiting
    }

    func updated(
        isTrusted: Bool,
        elapsed: TimeInterval,
        stallAfter: TimeInterval
    ) -> Self {
        if case .moveToApplications = self { return self }
        if isTrusted { return .granted }
        return elapsed >= stallAfter ? .stalled : .waiting
    }
}

/// Owns the onboarding check cadence and state transitions. System AX calls stay
/// behind `PermissionService`, while the clock and service can be replaced in tests.
@MainActor
final class AccessibilityPermissionModel: ObservableObject {
    static let pollInterval: TimeInterval = 1
    static let defaultStallInterval: TimeInterval = 8

    @Published private(set) var state: PermissionOnboardingState
    var onGranted: (() -> Void)?
    var onTrustStatusChanged: ((Bool) -> Void)?

    private let permissionService: PermissionService
    private let installLocation: AppInstallLocation
    private let now: () -> Date
    private let stallAfter: TimeInterval
    private var pollingStartedAt: Date?
    private var timer: Timer?
    private var didRequestPrompt = false
    private var didNotifyGranted = false
    private var lastObservedTrust: Bool

    init(
        permissionService: PermissionService = PermissionService(),
        installLocation: AppInstallLocation = AppInstallLocation(bundleURL: Bundle.main.bundleURL),
        initialTrusted: Bool? = nil,
        now: @escaping () -> Date = { Date() },
        stallAfter: TimeInterval = 8
    ) {
        let trusted = initialTrusted ?? permissionService.hasRequiredPermissions()
        self.permissionService = permissionService
        self.installLocation = installLocation
        self.now = now
        self.stallAfter = stallAfter
        self.lastObservedTrust = trusted
        self.state = .initial(installLocation: installLocation, isTrusted: trusted)
    }

    func startPolling() {
        guard installLocation.allowsAccessibilityPrompt, !didNotifyGranted else { return }
        if pollingStartedAt == nil { pollingStartedAt = now() }
        checkNow()
        guard state != .granted, timer == nil else { return }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkNow() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Requests the native prompt at most once and only from a stable install location.
    func requestSystemPromptIfNeeded() {
        guard installLocation.allowsAccessibilityPrompt,
              state != .granted,
              !didRequestPrompt else { return }
        didRequestPrompt = true
        permissionService.requestAccessibilityPermission()
    }

    func applicationDidBecomeActive() {
        checkNow()
    }

    func checkNow() {
        guard installLocation.allowsAccessibilityPrompt, !didNotifyGranted else { return }
        if pollingStartedAt == nil { pollingStartedAt = now() }

        let trusted = permissionService.hasRequiredPermissions()
        if trusted != lastObservedTrust {
            lastObservedTrust = trusted
            onTrustStatusChanged?(trusted)
        }

        let elapsed = max(0, now().timeIntervalSince(pollingStartedAt ?? now()))
        state = state.updated(
            isTrusted: trusted,
            elapsed: elapsed,
            stallAfter: stallAfter
        )
        guard state == .granted else { return }

        didNotifyGranted = true
        stop()
        let callback = onGranted
        onGranted = nil
        callback?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct PermissionOnboardingView: View {
    @ObservedObject var model: AccessibilityPermissionModel
    let onOpenSettings: () -> Void
    let onOpenApplications: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
            }

            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                actions
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private var symbolName: String {
        switch model.state {
        case .moveToApplications:
            return "folder.badge.plus"
        case .waiting, .stalled:
            return "lock.shield"
        case .granted:
            return "checkmark.shield"
        }
    }

    private var title: String {
        switch model.state {
        case .moveToApplications:
            return "请先移到“应用程序”"
        case .waiting:
            return "需要开启辅助功能权限"
        case .stalled:
            return "权限尚未对当前副本生效"
        case .granted:
            return "权限已生效"
        }
    }

    private var subtitle: String {
        switch model.state {
        case .moveToApplications:
            return "当前副本位于临时或外部位置。"
        case .waiting, .stalled:
            return "Tungsten Edge 需要这项权限来读取和操作窗口。"
        case .granted:
            return "正在继续启动任务条。"
        }
    }

    private var message: String {
        switch model.state {
        case .moveToApplications:
            return "为避免 macOS 把权限绑定到临时副本，请将 Tungsten Edge 拖到“应用程序”文件夹，再从那里重新打开。"
        case .waiting:
            return "请在\(accessibilitySettingsPath)中，打开 Tungsten Edge 钨极的开关。开启后本窗口会自动关闭，任务条会继续启动。"
        case .stalled:
            return "请在辅助功能列表中选中旧的 Tungsten Edge，点击减号将它删除，再重新添加并开启“应用程序”文件夹中的当前副本。只切换旧条目的开关通常不会更新授权。"
        case .granted:
            return "辅助功能权限已确认。"
        }
    }

    private var accessibilitySettingsPath: String {
        if #available(macOS 13, *) {
            return "系统设置的“隐私与安全性 > 辅助功能”"
        }
        return "系统偏好设置的“安全性与隐私 > 隐私 > 辅助功能”"
    }

    @ViewBuilder
    private var actions: some View {
        switch model.state {
        case .moveToApplications:
            Button("退出") { onQuit() }
                .keyboardShortcut(.cancelAction)
            Button("打开“应用程序”") { onOpenApplications() }
                .keyboardShortcut(.defaultAction)
        case .waiting:
            Button("退出") { onQuit() }
                .keyboardShortcut(.cancelAction)
            Button("打开系统设置") { onOpenSettings() }
                .keyboardShortcut(.defaultAction)
        case .stalled:
            Button("退出") { onQuit() }
                .keyboardShortcut(.cancelAction)
            Button("重新检测") { model.checkNow() }
            Button("打开系统设置") { onOpenSettings() }
                .keyboardShortcut(.defaultAction)
        case .granted:
            ProgressView()
                .controlSize(.small)
        }
    }
}
