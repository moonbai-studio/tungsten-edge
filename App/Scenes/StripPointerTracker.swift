import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 整条一块的指针跟踪区

/// 最后一次指针位置的引用盒。放进 `@State` 只为了跨 body 存活；**改它不触发重算**，
/// 这正是要的——指针每动一次都重算整条 body 太贵，重算只发生在拥有者真的变了的时候。
final class PointerBox {
    var value: CGPoint?
}

/// 盖住整条任务条的一块 `NSTrackingArea`，把指针位置报上去。谁被悬停由纯判定
/// `StripHoverResolution` 算——**这是全条唯一的悬停来源**，每张卡不再各自挂 `.onHover`
///（漏格 + 边界带方向，成因见那个类型）。
///
/// **进出用跟踪区，位置靠自己按帧轮询。** 第一版全指望跟踪区的 `.mouseMoved`，实测是死路：
/// 一趟 34 步的合成扫描只报上来 **6** 次，而且 5 次挤在最后 80ms 里一起到（2026-08-17）。
/// 原因是这几块面板都是 `.nonactivatingPanel`、永远不会成为 key 窗口，而 AppKit 只保证把
/// 鼠标移动事件送给 key 窗口——`acceptsMouseMovedEvents` 也救不回来（试过）。
/// 进入 / 离开倒是可靠的（SwiftUI 的 `.onHover(true)` 一直就是靠它）。
///
/// 所以：`mouseEntered` 起一个 60Hz 的定时器读 `NSEvent.mouseLocation`，指针走出本视图
/// 就报 `nil` 并停表。**只在指针压在任务条上时存在**，不是常驻轮询；位置没变的那一拍直接跳过，
/// 归属没变也不写 `@State`，所以停在条上不动是零开销。
///
/// 这不是 AGENTS 禁掉的常驻 `.mouseMoved` 全局监视器：那条禁的是 `addGlobalMonitorForEvents`
///（事件 tap，全系统鼠标事件先过我们进程，我们自己弹菜单时会被拖慢 100ms）。定时器不是 tap。
///
/// 另外两件承重的事：
/// - `.activeAlways`：面板永远不是 key 窗口，默认的 `.activeInKeyWindow` 连进出都收不到。
/// - `hitTest` 返回 `nil`：它是 `.background`，只观测、绝不吃点击。
struct StripPointerTracker: NSViewRepresentable {
    /// 屏幕坐标（bottom-left）；`nil` = 指针离开了任务条。
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove   // 刷新闭包，捕获最新 @State 写入口
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
        nsView.stopPolling()
        nsView.onMove = nil
    }

    final class TrackingView: NSView {
        /// 关掉轮询、只留跟踪区自己的 `.mouseMoved`（`DOCK_STRIP_HOVER_POLL=0`）。
        /// 留着它才有办法回答「轮询到底是不是必需的」——2026-08-17 就是靠这个 A/B 定的。
        static let pollingEnabled =
            DebugSwitch.stripHoverPoll.isEnabled(in: ProcessInfo.processInfo.environment)

        var onMove: ((CGPoint?) -> Void)?
        private var area: NSTrackingArea?
        private var poll: Timer?
        private var lastReported: CGPoint?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopPolling() }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(next)
            area = next
        }

        override func mouseEntered(with event: NSEvent) { pointerEvent() }
        override func mouseMoved(with event: NSEvent) { pointerEvent() }
        override func mouseDragged(with event: NSEvent) { pointerEvent() }

        /// 跟踪区确实送到了一个事件：位置照报（这条永远走），顺便起表。
        private func pointerEvent() {
            report(NSEvent.mouseLocation)
            guard Self.pollingEnabled else { return }
            startPolling()
        }

        /// 跟踪区的 exit 只是**其中一条**收尾路径：它在指针快速划出时会漏
        ///（AGENTS 里那条"气泡看门狗"的存在理由就是这个）。轮询自己判出界更可靠，
        /// 所以这里只是提前一步停表。
        override func mouseExited(with event: NSEvent) { leave() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func startPolling() {
            guard poll == nil else { return }
            tick()
            // 60Hz：屏幕就这个刷新率，再密也看不出来。2400pt/s 横扫时每 42pt 一格
            // 约 17.5ms，这个节奏刚好一格不漏。
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            poll = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func stopPolling() {
            poll?.invalidate()
            poll = nil
        }

        private func leave() {
            stopPolling()
            guard lastReported != nil else { return }
            lastReported = nil
            onMove?(nil)
        }

        private func tick() {
            guard let window, window.isVisible else {
                leave()
                return
            }
            let location = NSEvent.mouseLocation
            guard window.convertToScreen(convert(bounds, to: nil)).contains(location) else {
                leave()
                return
            }
            report(location)
        }

        /// 位置没变的那一拍直接跳过：停在条上不动 = 零开销。
        private func report(_ location: CGPoint) {
            guard location != lastReported else { return }
            lastReported = location
            onMove?(location)
        }
    }
}
