import SwiftUI
import AppKit
import ApplicationServices

/// 观察「辅助功能」权限状态：每秒轮询一次 `AXIsProcessTrusted()`，
/// 一旦授予就回调 `onGranted`，并把 `isTrusted` 推给引导窗口做实时反馈。
/// 轮询独立于窗口存活——即便用户关掉引导窗口，授权后 App 仍会自动启动。
@MainActor
final class AccessibilityPermissionModel: ObservableObject {
    @Published private(set) var isTrusted: Bool
    var onGranted: (() -> Void)?
    private var timer: Timer?
    /// 演示模式（DOCK_FORCE_ONBOARDING=1）：固定停在「待开启」、不轮询、不自动关窗，
    /// 仅用于在本地无法撤销权限时展示/截图引导窗口。
    private let demoMode: Bool

    init(demoMode: Bool = false) {
        self.demoMode = demoMode
        isTrusted = demoMode ? false : AXIsProcessTrusted()
    }

    func startPolling() {
        if demoMode { return }
        if isTrusted {
            onGranted?()
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let trusted = AXIsProcessTrusted()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if trusted != self.isTrusted { self.isTrusted = trusted }
                if trusted { self.onGranted?() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 直接深链接到「系统设置 → 隐私与安全性 → 辅助功能」那一页，
    /// 省去用户自己翻菜单。App 启动时已请求过权限，所以列表里已能看到本应用。
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 首次启动的权限引导窗口：用大白话解释为什么要权限，给一个直达设置页的按钮，
/// 并实时显示「待开启 / 已开启」，让用户确认成功——而不是对着会自动消失的系统框发懵。
struct PermissionOnboardingView: View {
    @ObservedObject var model: AccessibilityPermissionModel

    var body: some View {
        VStack(spacing: 22) {
            Text("Tungsten Edge 需要「辅助功能」权限才能管理你的窗口")
                .font(.title3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: { model.openAccessibilitySettings() }) {
                Text("打开系统设置授权")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(36)
        .frame(width: 380)
    }
}
