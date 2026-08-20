import AppKit

/// Hosts manually sized panel content without letting the hosted view become the
/// window's content view and participate in automatic window sizing.
@MainActor
final class ManualPanelHost {
    let contentView: NSView

    init(contentView: NSView, in panel: NSPanel) {
        self.contentView = contentView

        let initialSize = panel.contentView?.bounds.size
            ?? panel.contentRect(forFrameRect: panel.frame).size
        let container = NSView(frame: NSRect(origin: .zero, size: initialSize))
        panel.contentView = container

        contentView.frame = container.bounds
        contentView.autoresizingMask = [.width, .height]
        container.addSubview(contentView)
    }

    var fittingSize: NSSize { contentView.fittingSize }
}

/// 关闭 AppKit 的窗口自动约束。系统默认会把靠近/跨越屏幕边缘的窗口挪回"当前屏"可用区内（避开菜单栏）。
/// 多屏**共享边**场景下这会致命：把任务条放到上方屏底部时，窗口原点 y 落在下方屏那一侧，系统就拿下方屏
/// 来约束，把整窗按到下方屏菜单栏正下方 → 任务条/胶囊跑到错误的屏（2026-06-23 三屏 bug 根因；实测 y=970
/// 被按成 y=857 = 下方屏可用区顶 949 − 窗口高 92）。我们的面板永远手动精确定位、永不盖菜单栏，故直接
/// 返回原 frame、不让系统二次约束。
class NonConstrainingPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Liquid Glass is hosted in a non-key floating panel. These private AppKit appearance hooks are
/// the same narrow override used by native-looking third-party docks to keep the material active.
final class DockLiquidGlassPanel: NonConstrainingPanel {
    @objc(_hasActiveAppearance)
    func bestDockHasActiveAppearance() -> Bool { true }

    @objc(_hasActiveAppearanceIgnoringKeyFocus)
    func bestDockHasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    @objc(_hasKeyAppearance)
    func bestDockHasKeyAppearance() -> Bool { true }

    @objc(_hasMainAppearance)
    func bestDockHasMainAppearance() -> Bool { true }

    @objc(_hasActiveControls)
    func bestDockHasActiveControls() -> Bool { true }
}
