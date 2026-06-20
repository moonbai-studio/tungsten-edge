import AppKit
import SwiftUI

/// 跨面板拖动的唯一权威（拖卡进抽屉 路线 C 第一步，2026-06-20）。
///
/// 把"拖动的画面 + 落点判定 + 收尾"从任务条内部的 SwiftUI 手势里抽出来，统一收在这里：
/// - **画面**：起拖时弹一个铺满屏幕、点击穿透、透明的载体面板（`carrierPanel`），浮动卡片画在它上面，
///   所以能飘出任务条窗口、盖在抽屉上方而不被裁（任务条窗口高度只有 92pt，自绘 overlay 必被裁）。
/// - **跟手 + 落点**：起拖时装一对 local+global 鼠标监视器；探针实测（2026-06-20）：mouse-down 起拖后有
///   "隐式抓取"，整条拖拽事件被锁给本 app，全程走 **local** 监视器（global 永远 0 次，留作廉价兜底），
///   光标移到抽屉/别的窗口上方也照收，松手 `leftMouseUp` 每次都稳。坐标一律用屏幕坐标 `NSEvent.mouseLocation`。
/// - **收尾幂等**：监视器的 mouseUp、手势的 onEnded、轮询兜底三路都可能触发，`endDrag` 用 `draggingItem` 守卫只生效一次。
///
/// 任务条（`DockStripView`）只负责：手势识别起拖 → `beginDrag(...)`；读 `draggingItem` 把原位卡片设透明让出空位；
/// 读 `isOverDropZone` 在进入投放区时停掉条内重排。监视器/面板生命周期一概不碰，避免视图重建丢状态、监视器漏摘。
@MainActor
final class DragController: ObservableObject {
    /// 正在拖的卡片（nil = 没在拖）。驱动原位卡片隐藏 + 载体绘制 + 收尾幂等守卫。
    @Published private(set) var draggingItem: StripItem?
    /// 手指当前屏幕坐标（bottom-left 全局），驱动载体位置。
    @Published private(set) var globalLocation: CGPoint = .zero
    /// 手指是否压在投放区（胶囊内容区 + 容错）。驱动胶囊高亮反馈，并让任务条停掉条内重排。
    @Published private(set) var isOverDropZone = false

    /// 抓取偏移（卡片中心 − 按下点，strip 顶左 y-down 朝向，与载体一致）：边缘抓取时不把卡片中心硬吸到光标。
    private(set) var grabOffset: CGSize = .zero
    /// 载体面板当前覆盖的屏幕 frame（屏幕坐标），载体视图据此把屏幕坐标换算成面板内位置。
    private(set) var carrierScreenFrame: CGRect = .zero

    private let drawerStore: DrawerStore
    /// 当前投放候选区（屏幕坐标，已 inset + 容错）。PanelCoordinator 提供（胶囊常驻 + 抽屉打开时叠加）。
    private let dropZonesProvider: () -> [CGRect]
    /// 载体面板该覆盖的屏幕（通常 = 任务条所在屏）。
    private let screenProvider: () -> NSScreen
    /// 构造载体内容视图（注入 ChipView 需要的 EnvironmentObject）。由 PanelCoordinator 提供，
    /// 这样面板生命周期归本控制器、渲染所需的 store 注入归 PanelCoordinator，各管各的。
    private let carrierFactory: (DragController) -> NSView

    private var carrierPanel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pollTimer: Timer?

    init(drawerStore: DrawerStore,
         dropZonesProvider: @escaping () -> [CGRect],
         screenProvider: @escaping () -> NSScreen,
         carrierFactory: @escaping (DragController) -> NSView) {
        self.drawerStore = drawerStore
        self.dropZonesProvider = dropZonesProvider
        self.screenProvider = screenProvider
        self.carrierFactory = carrierFactory
    }

    // MARK: - 起拖

    func beginDrag(item: StripItem, startScreenLocation: CGPoint, grabOffset: CGSize) {
        guard draggingItem == nil else { return }
        self.grabOffset = grabOffset
        globalLocation = startScreenLocation
        draggingItem = item
        refreshDropZone()
        showCarrier()
        installMonitors()
        startPoll()
    }

    // MARK: - 跟手 / 落点

    private func update(_ loc: CGPoint) {
        globalLocation = loc
        refreshDropZone()
    }

    private func refreshDropZone() {
        isOverDropZone = dropZonesProvider().contains { $0.contains(globalLocation) }
    }

    // MARK: - 收尾（幂等）

    /// 正常松手：在投放区且可收纳 → 收进抽屉；否则什么都不做（卡片缩回）。
    func endDrag() {
        guard let item = draggingItem else { return }
        let shouldStash = isOverDropZone
        teardown()
        if shouldStash, let bid = item.bundleIdentifier, Self.canStash(item) {
            drawerStore.add(bid)
        }
    }

    /// 取消：拖动中窗口消失、切屏等异常路径，纯收尾不收纳。
    func cancelDrag() {
        guard draggingItem != nil else { return }
        teardown()
    }

    private func teardown() {
        draggingItem = nil
        isOverDropZone = false
        removeMonitors()
        pollTimer?.invalidate(); pollTimer = nil
        carrierPanel?.orderOut(nil)
    }

    /// 只拦两类：① 无 bundleID（没法收纳）；② Finder（项目铁律：永远保留任务条入口）。
    /// **不**拦 app-level fallback —— 后台/没激活的 app 窗口来不及采样时卡片会临时退化成应用级图标，
    /// 但抽屉运行区本就支持显示应用级图标，拦它会导致"Safari/Dia 没激活时拖不进、激活后又能拖"（2026-06-20 owner 报告）。
    static func canStash(_ item: StripItem) -> Bool {
        guard let bid = item.bundleIdentifier, !bid.isEmpty else { return false }
        if bid == "com.apple.finder" { return false }
        return true
    }

    // MARK: - 载体面板

    private func showCarrier() {
        let screen = screenProvider()
        carrierScreenFrame = screen.frame
        let panel = carrierPanel ?? makeCarrierPanel()
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        carrierPanel = panel
    }

    private func makeCarrierPanel() -> NSPanel {
        let panel = NSPanel(contentRect: screenProvider().frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .popUpMenu                 // 压在抽屉(.floating)之上，卡片骑在抽屉上方
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 1.0, alpha: 0.0)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true          // 纯绘制，绝不抢事件（拖动靠任务条窗口的隐式抓取）
        let host = carrierFactory(self)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        panel.contentView = host
        return panel
    }

    /// 屏幕坐标(bottom-left) → 载体面板内 SwiftUI 坐标(top-left, y-down) 的卡片中心位置。
    func carrierPosition() -> CGPoint {
        CGPoint(x: globalLocation.x - carrierScreenFrame.minX + grabOffset.width,
                y: carrierScreenFrame.maxY - globalLocation.y + grabOffset.height)
    }

    // MARK: - 监视器 + 轮询兜底

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self else { return ev }
            let loc = NSEvent.mouseLocation
            if ev.type == .leftMouseUp { self.update(loc); self.endDrag() }
            else { self.update(loc) }
            return ev
        }
        // global 实测全程 0 次（事件被隐式抓取锁给本 app），留作廉价兜底，万一抓取丢失还能跟。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            if ev.type == .leftMouseUp { self.update(loc); self.endDrag() }
            else { self.update(loc) }
        }
    }

    private func removeMonitors() {
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    /// `watchDragEnd` 等价兜底：DragGesture/监视器都可能在某些路径下不回调 onEnded/up（视图重建、抓取异常），
    /// 轮询硬件按键，松开瞬间收尾，避免原位卡片空位卡死。
    private func startPoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.draggingItem != nil else { return }
                if NSEvent.pressedMouseButtons == 0 { self.endDrag() }
            }
        }
        pollTimer?.tolerance = 0.02
    }
}

// MARK: - 全屏载体视图

/// 铺在载体面板上的浮动卡片：跟着 `DragController.globalLocation` 走，点击穿透。
/// 渲染与任务条同一个 `ChipView`，强制 hover 视觉（光标本就压在它上，且它不可命中、自身 hover 不会亮）。
struct DragCarrierView: View {
    @ObservedObject var controller: DragController

    var body: some View {
        if let item = controller.draggingItem {
            ChipView(item: item, forceHover: true)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                .scaleEffect(controller.isOverDropZone ? 0.82 : 1.05)
                .animation(.easeOut(duration: 0.12), value: controller.isOverDropZone)
                .position(controller.carrierPosition())
                .allowsHitTesting(false)
        }
    }
}
