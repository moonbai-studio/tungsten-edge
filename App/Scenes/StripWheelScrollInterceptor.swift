import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Mouse wheel horizontal strip scrolling

struct WheelScrollInterceptorRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelScrollInterceptorView {
        WheelScrollInterceptorView()
    }

    func updateNSView(_ nsView: WheelScrollInterceptorView, context: Context) {
        nsView.resolveScrollViewIfNeeded()
    }
}

final class WheelScrollInterceptorView: NSView {
    /// 默认关的诊断：`DOCK_STRIP_WHEEL_TRACE=1` 才打。
    private static let trace = DebugSwitch.stripWheelTrace.isEnabled(in: ProcessInfo.processInfo.environment)

    private weak var scrollView: NSScrollView?
    private var reportedMissingScrollView = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollViewIfNeeded()
    }

    override func layout() {
        super.layout()
        resolveScrollViewIfNeeded()
    }

    /// **`point` 是父视图坐标系的点**，所以判定必须走 `super.hitTest`，不能拿它和自己的
    /// `bounds` 比（`MenuHostNSView` 是同一个写法）。条外层有 20pt 阴影边距，用 bounds 比
    /// 会整体错位，让条上一整条带子收不到滚轮。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil,
              let event = NSApp.currentEvent,
              event.type == .scrollWheel,
              StripWheelScroll.horizontalStep(for: Self.input(from: event)) != nil,
              overflowExtent() > 0 else {
            return nil
        }
        return self
    }

    /// 「反转鼠标滚轮方向」开着时**不用管**：那个 tap 插在 session 头部，这里收到的
    /// 已经是反转后的 delta，和别的应用看到的一致——条上的平移方向自然跟着一起反。
    override func scrollWheel(with event: NSEvent) {
        let input = Self.input(from: event)
        guard let delta = StripWheelScroll.horizontalStep(for: input),
              let scrollView = resolveScrollViewIfNeeded(),
              let documentView = scrollView.documentView else {
            super.scrollWheel(with: event)
            return
        }

        let clipView = scrollView.contentView
        let maxX = max(0, documentView.bounds.width - clipView.bounds.width)
        let currentX = clipView.bounds.origin.x
        let nextX = min(max(currentX + delta, 0), maxX)
        if Self.trace {
            print("[stripwheel] precise=\(input.hasPreciseDeltas) dx=\(input.deltaX) dy=\(input.deltaY)"
                + " inverted=\(input.isDirectionInverted) step=\(delta) x=\(currentX)->\(nextX) maxX=\(maxX)")
        }
        guard maxX > 0, nextX != currentX else { return }

        clipView.scroll(to: NSPoint(x: nextX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    private static func input(from event: NSEvent) -> StripWheelScroll.Input {
        StripWheelScroll.Input(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            isDirectionInverted: event.isDirectionInvertedFromDevice
        )
    }

    /// 还能往右滚多少 pt。`0` = 没溢出（或还没解析到 scrollView），此时一律不认领事件。
    ///
    /// **只在真的收到滚动事件时调**（`hitTest` 里已经过滤过事件类型）——「找不到
    /// `NSScrollView`」的告警挂在这里，就不会被启动早期那次「SwiftUI 还没建好」的
    /// 正常空查询误报。
    private func overflowExtent() -> CGFloat {
        guard let scrollView = resolveScrollViewIfNeeded(),
              let documentView = scrollView.documentView else {
            reportMissingScrollViewOnce()
            return 0
        }
        return max(0, documentView.bounds.width - scrollView.contentView.bounds.width)
    }

    /// 本功能**唯一的静默失效点**：SwiftUI 的 `ScrollView` 将来若不再由 `NSScrollView`
    /// 承载，整条横滚会一声不响地死掉，连一行日志都没有。只报一次。
    private func reportMissingScrollViewOnce() {
        guard !reportedMissingScrollView else { return }
        reportedMissingScrollView = true
        print("[stripwheel] 找不到 NSScrollView —— 任务条横向滚动已失效"
            + "（SwiftUI 的 ScrollView 可能不再由 NSScrollView 承载）")
    }

    @discardableResult
    func resolveScrollViewIfNeeded() -> NSScrollView? {
        if let scrollView, scrollView.window != nil {
            return scrollView
        }

        var ancestor = superview
        while let candidate = ancestor {
            if let found = findScrollView(in: candidate) {
                scrollView = found
                return found
            }
            ancestor = candidate.superview
        }
        scrollView = nil
        return nil
    }

    private func findScrollView(in root: NSView) -> NSScrollView? {
        guard root !== self else { return nil }
        if let scrollView = root as? NSScrollView {
            return scrollView
        }
        for subview in root.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}

extension View {
    /// macOS 14 的 `defaultScrollAnchor(.leading)` 在更老系统上不可用；横向 ScrollView 本来就从
    /// 前缘开始，所以旧系统走默认即可（仅 14+ 显式锚定，保持原行为）。
    @ViewBuilder
    func compatLeadingScrollAnchor() -> some View {
        if #available(macOS 14.0, *) {
            self.defaultScrollAnchor(.leading)
        } else {
            self
        }
    }
}
