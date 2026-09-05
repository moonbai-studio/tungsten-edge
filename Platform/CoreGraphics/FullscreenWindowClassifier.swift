import ApplicationServices
import CoreGraphics

// 焦点窗口「是否全屏、是否属于本屏」的纯判定。Platform 层：`FullscreenIntentMonitor` 在事件 tap
// 线程上调用它，`PanelCoordinator` 的异步 AX 探测也调；这里不允许出现 AX 调用 / AppKit / 日志。
// 2026-09-05 从 App/Composition/PanelVisibilityState.swift 搬来，消掉唯一一处 Platform→App 反向依赖。

// 异步 AX 全屏探测的纯判定（PanelCoordinator.detectFullscreenViaAX 调用）。
// role 门禁是硬约束：Finder 挂着一个桌面伪窗口（role=AXScrollArea，frame 恰好等于整屏），
// 恢复最小化窗口的瞬间它会成为 AXFocusedWindow —— 没有门禁就命中 frame≈整屏兜底，任务条被误隐藏。
/// 焦点窗口相对**这一块屏**的三态裁决（多屏任务条，2026-09-02）。
/// `.notOnThisScreen` = 焦点窗口的主体在别的屏上——对本屏的条而言它**不是证据**：
/// 本屏此刻可能正显示着别的 app 的全屏空间，此时要改问 SkyLight 本屏的当前空间类型
///（`PanelCoordinator.triggerAsyncFullscreenCheck`），而不是当成「不全屏」把条放出来。
enum FullscreenAXVerdict: Equatable {
    case fullscreen
    case windowed
    case notOnThisScreen
}

enum FullscreenWindowClassifier {
    static let frameTolerance: CGFloat = 8

    /// 布尔口径保留给单屏语义的调用方（`FullscreenIntentMonitor.readAXState`、探针副本）：
    /// 只有 `.fullscreen` 为 true——与三态引入前逐字等价。
    static func isFullscreen(
        role: String?,
        isAXFullscreen: Bool,
        windowFrame: CGRect?,
        screenCGFrame: CGRect
    ) -> Bool {
        classify(role: role, isAXFullscreen: isAXFullscreen, windowFrame: windowFrame, screenCGFrame: screenCGFrame)
            == .fullscreen
    }

    static func classify(
        role: String?,
        isAXFullscreen: Bool,
        windowFrame: CGRect?,
        screenCGFrame: CGRect
    ) -> FullscreenAXVerdict {
        guard role == kAXWindowRole else { return .windowed }

        if isAXFullscreen {
            guard let wf = windowFrame else { return .fullscreen }
            // 归属判据（面积主体在本屏），不是宽度判据。原来的 `width > screen × 0.7` 兼任
            // 多屏护栏，但把**全屏幕拼贴（真分屏）的半宽 tile 误否**——2026-08-30 实测
            // （macOS 26.5.2，`scratch/space-probe-20260830-2106.log`）：分屏 tile 报
            // AXFullScreen=true、frame=(0,40 1278×1400)，1278 < 2560×0.7 被否，任务条
            // 因此盖在分屏内容上（0.9.10 反馈 `02525cc5`）。面积归属保住护栏的本意：
            // 同日实测另一块屏上的全屏窗口与本屏不相交，照样拦下。
            return mostlyBelongsToScreen(wf, screenCGFrame) ? .fullscreen : .notOnThisScreen
        }

        // Fallback: frame ≈ full screen (games / HTML5 that skip the AXFullScreen flag)
        if let wf = windowFrame {
            let t = frameTolerance
            if abs(wf.width  - screenCGFrame.width)  < t
                && abs(wf.height - screenCGFrame.height) < t
                && abs(wf.minX   - screenCGFrame.minX)   < t
                && abs(wf.minY   - screenCGFrame.minY)   < t {
                return .fullscreen
            }
            return mostlyBelongsToScreen(wf, screenCGFrame) ? .windowed : .notOnThisScreen
        }

        return .windowed
    }

    /// 窗口面积的一半以上落在这块屏上才算「属于本屏」。纯 CGRect 数学——
    /// `FullscreenIntentMonitor.readAXState` 也调本判定，结果在事件 tap 线程上消费，
    /// 这里不允许出现 AX / AppKit / 日志（见 panels-and-screens 规则）。
    /// 与 `WindowLiftAvoidance` 里私有的同名方法是同一个面积法，刻意不共享——
    /// 避让那份冻结在自己的规则文件里，两边耦合反而让改动更危险。
    private static func mostlyBelongsToScreen(_ frame: CGRect, _ screen: CGRect) -> Bool {
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        let overlap = frame.intersection(screen)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        return overlap.width * overlap.height >= frameArea * 0.5
    }
}
