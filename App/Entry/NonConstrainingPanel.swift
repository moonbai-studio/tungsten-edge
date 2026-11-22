import AppKit
import Combine
import SwiftUI

/// One owner for all layout inputs. Tokens survive cancellation so old event callbacks stay inert.
@MainActor
final class TaskbarLayoutSession {
    static func wakeUnitIndex(screenFrames: [CGRect?], settingsScreen: CGRect?, pointer: CGPoint) -> Int? {
        if screenFrames.count == 1 { return 0 }
        if let settingsScreen, let index = screenFrames.firstIndex(where: { $0 == settingsScreen }) { return index }
        return screenFrames.firstIndex(where: { $0?.contains(pointer) == true })
            ?? (screenFrames.isEmpty ? nil : 0)
    }

    struct Session: Equatable {
        let token: UInt64
        let kind: TaskbarLayoutKind
    }

    private(set) var active: Session?
    private var nextToken: UInt64 = 0
    var prepare: (TaskbarLayoutKind) -> Void = { _ in }
    var commit: () -> Void = {}
    var release: (TaskbarLayoutKind) -> Void = { _ in }

    @discardableResult
    func begin(_ kind: TaskbarLayoutKind) -> UInt64 {
        end()
        nextToken += 1
        active = Session(token: nextToken, kind: kind)
        withoutAnimations { prepare(kind) }
        return nextToken
    }

    func accepts(_ token: UInt64, kind: TaskbarLayoutKind) -> Bool {
        active == Session(token: token, kind: kind)
    }

    func change(_ kind: TaskbarLayoutKind, mutation: () -> Void) {
        let isShort = active?.kind != kind
        if isShort { begin(kind) }
        withoutAnimations {
            mutation()
            commit()
        }
        if isShort { end() }
    }

    func end(token: UInt64? = nil) {
        guard let session = active, token == nil || token == session.token else { return }
        withoutAnimations { commit() }
        active = nil
        withoutAnimations { release(session.kind) }
    }

    private func withoutAnimations(_ body: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}

/// Shared by both hosting roots. Only height sessions freeze icon rendering and window lift.
@MainActor
final class PanelHeightResizePresentation: ObservableObject {
    @Published var kind: TaskbarLayoutKind? {
        didSet {
            if kind != oldValue {
                invalidateQueuedLayouts()
                if kind != nil { animationResetToken &+= 1 }
            }
        }
    }
    @Published private(set) var animationResetToken: UInt64 = 0
    private(set) var generation: UInt64 = 0
    var isActive: Bool {
        get { kind != nil }
        set { kind = newValue ? .height : nil }
    }

    func invalidateQueuedLayouts() { generation &+= 1 }

    func deferredChanges<P: Publisher>(from publisher: P) -> AnyPublisher<P.Output, Never>
    where P.Failure == Never {
        publisher
            .filter { [weak self] _ in self?.isActive == false }
            .map { [weak self] value in (value, self?.generation) }
            .receive(on: DispatchQueue.main)
            .filter { [weak self] _, generation in
                guard let self else { return false }
                return !self.isActive && generation == self.generation
            }
            .map(\.0)
            .eraseToAnyPublisher()
    }

    func nonInteractiveHeightChanges(
        from heights: Published<DockPanelHeight>.Publisher
    ) -> AnyPublisher<DockPanelHeight, Never> {
        deferredChanges(from: heights
            .removeDuplicates()
            .dropFirst())
    }
}

private struct PanelHeightResizingKey: EnvironmentKey {
    static let defaultValue = false
}

private struct TaskbarLayoutChangingKey: EnvironmentKey {
    static let defaultValue = false
}

private struct LayoutAnimationResetTokenKey: EnvironmentKey {
    static let defaultValue: UInt64 = 0
}

extension EnvironmentValues {
    var layoutAnimationResetToken: UInt64 {
        get { self[LayoutAnimationResetTokenKey.self] }
        set { self[LayoutAnimationResetTokenKey.self] = newValue }
    }
    var isTaskbarLayoutChanging: Bool {
        get { self[TaskbarLayoutChangingKey.self] }
        set { self[TaskbarLayoutChangingKey.self] = newValue }
    }
    var isPanelHeightResizing: Bool {
        get { self[PanelHeightResizingKey.self] }
        set { self[PanelHeightResizingKey.self] = newValue }
    }
}

struct PanelHeightResizeModifier: ViewModifier {
    @ObservedObject var presentation: PanelHeightResizePresentation

    func body(content: Content) -> some View {
        content
            .environment(\.isPanelHeightResizing, presentation.kind == .height)
            .environment(\.isTaskbarLayoutChanging, presentation.isActive)
            // A same-target update cannot cancel an already interpolating Animatable view.
            .environment(\.layoutAnimationResetToken, presentation.animationResetToken)
            .transaction { transaction in
                if presentation.isActive {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

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

    /// ObservedObject invalidation alone does not refresh NSHostingView's fitting size in the
    /// publishing call stack. Lay out explicitly before measuring and after resizing its panel.
    func layoutContent() {
        contentView.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
    }
}

/// Window levels above `.floating`, the level every panel is created at.
enum PanelLevel {
    /// The drawer while a drag from outside has it open. The system Apps panel (Spotlight's app
    /// list, a window of `Siri`) sits at 23 on macOS 27; at `.floating` the drawer opened under it.
    static let raisedDrawer = NSWindow.Level.statusBar
    /// The drag carrier: above every panel of ours, the raised drawer included — an app dropped
    /// from outside lands on the carrier, into that drawer.
    static let carrier = NSWindow.Level(rawValue: raisedDrawer.rawValue + 1)
}

/// 七扇悬浮面板共用的窗口行为集合。**必须只有这一处字面量**：
/// issue #19 的修复要把这套值原样重新赋一遍来补回「常驻所有桌面」的成员资格，
/// 复原的值和创建时的值一旦分叉，修复就会静默地把面板改成另一种行为。
enum PanelCollectionBehavior {
    static let standard: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
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

    // `isMovable = false` only stops mouse drags: any process with Accessibility access can still
    // relocate the window through `kAXPositionAttribute`, and `PanelCoordinator` never puts it
    // back (`setFrames` compares targets, not live frames). A window manager reacting to the
    // per-tick frame changes of a grip drag is exactly such a process. NSWindow serves AX
    // position / size writes through the legacy attribute API below; disallowing
    // `setAccessibilityFrame(_:)` via `isAccessibilitySelectorAllowed` does not block them.
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        if attribute == .position || attribute == .size { return false }
        return super.accessibilityIsAttributeSettable(attribute)
    }

    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        if attribute == .position || attribute == .size { return }
        super.accessibilitySetValue(value, forAttribute: attribute)
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
