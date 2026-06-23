import ApplicationServices
import AppKit

/// 轮询「辅助功能」权限状态：每秒一次 `AXIsProcessTrusted()`，
/// 一旦授予就回调 `onGranted` 启动 app。
@MainActor
final class AccessibilityPermissionModel: ObservableObject {
    var onGranted: (() -> Void)?
    private var timer: Timer?

    func startPolling() {
        if AXIsProcessTrusted() { onGranted?(); return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard AXIsProcessTrusted() else { return }
            Task { @MainActor [weak self] in
                self?.onGranted?()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
