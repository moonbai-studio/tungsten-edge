import AppKit
import SwiftUI

/// 窗口的根视图。滚动条平时不出现——窗口高度由内容自然高度决定，
/// 只有在被屏幕高度截断时才真的需要滚。
struct PermissionOnboardingWindowContent: View {
    @ObservedObject var coordinator: PermissionRecoveryCoordinator

    var body: some View {
        ScrollView(.vertical) {
            PermissionOnboardingView(coordinator: coordinator)
        }
        .frame(width: PermissionOnboardingView.contentWidth)
    }
}

struct PermissionOnboardingView: View {
    /// 视图只观察这一个源。
    @ObservedObject var coordinator: PermissionRecoveryCoordinator

    /// 内容宽度固定：窗口高度由 `fittingSize` 决定，宽度不能跟着文案长短抖。
    static let contentWidth: CGFloat = 520

    private var presentation: PermissionPresentation {
        coordinator.presentation ?? .waiting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if let troubleshooting {
                troubleshootingBox(troubleshooting)
            }
            HStack(spacing: 8) {
                Spacer()
                actions
            }
        }
        .padding(28)
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private var header: some View {
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
    }

    private func troubleshootingBox(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Switch already on but nothing happens?")
                .font(.callout.weight(.semibold))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
        )
    }

    // MARK: - 文案

    private var symbolName: String {
        switch presentation {
        case .moveToApplications: return "folder.badge.plus"
        case .waiting, .stalled: return "lock.shield"
        case .recoveryWaiting, .recoveryStalled: return "exclamationmark.shield"
        case .restoringWindows, .relaunching: return "arrow.clockwise"
        case .relaunchFailed: return "xmark.octagon"
        }
    }

    private var title: String {
        switch presentation {
        case .moveToApplications: return String(localized: "Move Tungsten Edge to Applications")
        case .waiting, .stalled: return String(localized: "Turn On Accessibility Permission")
        case .recoveryWaiting, .recoveryStalled: return String(localized: "Accessibility Permission Was Revoked")
        case .restoringWindows: return String(localized: "Restoring Windows…")
        case .relaunching: return String(localized: "Restarting Tungsten Edge…")
        case .relaunchFailed: return String(localized: "Restart Failed")
        }
    }

    private var subtitle: String {
        switch presentation {
        case .moveToApplications: return String(localized: "This copy is running from a temporary or read-only location.")
        case .waiting, .stalled: return String(localized: "Tungsten Edge needs this permission to read and manage your windows.")
        case .recoveryWaiting, .recoveryStalled: return String(localized: "Tungsten Edge will restart itself once you grant it again.")
        case .restoringWindows: return String(localized: "Putting the windows it moved back where they were.")
        case .relaunching: return String(localized: "This will only take a moment.")
        case .relaunchFailed: return String(localized: "Tungsten Edge is still running. You can try again.")
        }
    }

    private var message: String {
        switch presentation {
        case .moveToApplications:
            return String(localized: """
            macOS ties Accessibility permission to one specific copy of an app. This copy is running from a \
            temporary or read-only location, so turning the switch on will not take effect — and the permission \
            record stays behind in System Settings after the disk image is ejected. \
            Drag Tungsten Edge to your Applications folder and open it from there.
            """)
        case .waiting, .stalled:
            return String(format: String(localized: "Turn on Tungsten Edge in %@. This window closes by itself once you do, and the taskbar finishes starting."), settingsPath)
        case .recoveryWaiting, .recoveryStalled:
            return String(format: String(localized: "Tungsten Edge just lost its Accessibility permission, so the taskbar has been put away. Turn Tungsten Edge back on in %@."), settingsPath)
        case .restoringWindows, .relaunching:
            return String(localized: "Nothing to do here — just a moment.")
        case let .relaunchFailed(message):
            return String(format: String(localized: "Couldn’t start a new instance of Tungsten Edge: %@\n\nYou can click Retry, or quit and open it manually from your Applications folder."), message)
        }
    }

    /// 「删旧条目重加」只是**条件式排障建议**：我们读不到系统的授权数据库，
    /// 既证明不了用户有没有打开开关，也证明不了旧记录已经失配。文案必须保持不确定语气，
    /// 也不能预设签名方式——固定证书签的包授权是跨版本有效的。
    private var troubleshooting: String? {
        let steps = String(localized: """
        If the switch is already on and nothing happens, a permission record left by an older version may no \
        longer match this copy of Tungsten Edge. You can reset it:

        1. Quit Tungsten Edge first — while it is running, the minus button in the list is greyed out and the \
        entry cannot be removed.
        2. In Privacy & Security > Accessibility, select Tungsten Edge in the list and remove it with the minus \
        button. There may be more than one entry; remove them all.
        3. Open Tungsten Edge again from your Applications folder, then add it and turn the switch on when prompted.
        """)
        switch presentation {
        case .stalled:
            return steps
        case .recoveryStalled:
            return steps + String(localized: """


            If simply turning the switch back on works, Tungsten Edge restarts itself and there is nothing else \
            to do; going through the cleanup above means reopening it manually afterwards.
            Also, windows the taskbar had moved out of its way may sit one taskbar height short — maximizing \
            them once puts them back.
            """)
        default:
            return nil
        }
    }

    private var settingsPath: String {
        if #available(macOS 13, *) {
            return String(localized: "System Settings > Privacy & Security > Accessibility")
        }
        return String(localized: "System Preferences > Security & Privacy > Privacy > Accessibility")
    }

    // MARK: - 按钮

    @ViewBuilder
    private var actions: some View {
        switch presentation {
        case .moveToApplications:
            quitButton
            Button("Open Applications Folder") { coordinator.openApplications() }
                .keyboardShortcut(.defaultAction)

        case .waiting, .recoveryWaiting:
            quitButton
            Button("Open System Settings") { coordinator.openSettings() }
                .keyboardShortcut(.defaultAction)

        case .stalled, .recoveryStalled:
            quitButton
            Button("Check Again") { coordinator.recheck() }
            Button("Open System Settings") { coordinator.openSettings() }
                .keyboardShortcut(.defaultAction)

        case .restoringWindows, .relaunching:
            ProgressView()
                .controlSize(.small)

        case .relaunchFailed:
            quitButton
            Button("Retry") { coordinator.retryRelaunch() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var quitButton: some View {
        Button("Quit") { coordinator.quit() }
            .keyboardShortcut(.cancelAction)
    }
}
