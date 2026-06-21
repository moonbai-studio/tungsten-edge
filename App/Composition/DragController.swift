import AppKit
import SwiftUI

/// 拖动来源：决定投放区、落点动作、载体绘制三处分支。
enum DragSource { case strip, drawer }

/// 载体（飘浮副本）画成什么样。
enum DragVisualKind { case stripChip, drawerIcon }

/// 通用拖动载荷。任务条卡片有 `StripItem`；抽屉很多图标（无窗口运行项 / 未运行收纳项 / 纯固定项）
/// 只有 bundleID、没有 `StripItem`，故 `item` 可空，主键统一用 `bundleID`。`id` 给来源面板自己
/// 排序用（strip = chip 身份令牌 `item.id`，drawer = bundleID），免得来源面板从载荷里猜。
struct DragPayload {
    let source: DragSource
    let id: String          // strip = item.id（chip token）；drawer = bundleID
    let bundleID: String
    let item: StripItem?     // 仅任务条窗口卡有
    let visualKind: DragVisualKind
    /// 能否投到「另一面板」触发收纳/移回。strip = `canStash`；drawer = 真收纳项（`drawerStore.contains`）。
    /// 纯固定项 = false：只能抽屉内排序，拖到任务条不高亮、不动作（Codex 二审）。
    let canExternalDrop: Bool
}

/// 跨面板拖动的唯一权威（拖卡进抽屉 路线 C / 抽屉拖回任务条，2026-06-20→21）。
///
/// 对称两向：任务条卡拖到胶囊=收纳；抽屉图标拖到任务条=移回。整屏自绘载体 + local 监视器一套机制
/// 反向复用（机制探针 2026-06-20 已验证：mouse-down 起拖后隐式抓取使 local 监视器全程接事件含松手）。
/// 全部收在这里：载体面板生命周期、监视器、落点判定、幂等收尾。来源面板只 `beginDrag` + 读
/// `draggingPayload`（隐藏原位）/ `isOverDropZone`（停区内排序）。
@MainActor
final class DragController: ObservableObject {
    @Published private(set) var draggingPayload: DragPayload?
    @Published private(set) var globalLocation: CGPoint = .zero
    @Published private(set) var isOverDropZone = false

    private(set) var grabOffset: CGSize = .zero
    private(set) var carrierScreenFrame: CGRect = .zero

    /// 胶囊高亮只在「任务条卡正悬在收纳区」时亮；任务条移回高亮只在「抽屉图标正悬在任务条」时亮。
    var isOverStashZone: Bool { isOverDropZone && draggingPayload?.source == .strip }
    var isOverUnstashZone: Bool { isOverDropZone && draggingPayload?.source == .drawer }

    private let drawerStore: DrawerStore
    /// 按来源给投放候选区（屏幕坐标，已 inset+容错）：strip→胶囊(+抽屉)；drawer→任务条 dock 面板。
    private let dropZonesProvider: (DragSource) -> [CGRect]
    private let screenProvider: () -> NSScreen
    private let carrierFactory: (DragController) -> NSView

    private var carrierPanel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pollTimer: Timer?

    init(drawerStore: DrawerStore,
         dropZonesProvider: @escaping (DragSource) -> [CGRect],
         screenProvider: @escaping () -> NSScreen,
         carrierFactory: @escaping (DragController) -> NSView) {
        self.drawerStore = drawerStore
        self.dropZonesProvider = dropZonesProvider
        self.screenProvider = screenProvider
        self.carrierFactory = carrierFactory
    }

    // MARK: - 起拖

    func beginDrag(payload: DragPayload, startScreenLocation: CGPoint, grabOffset: CGSize) {
        guard draggingPayload == nil else { return }
        self.grabOffset = grabOffset
        globalLocation = startScreenLocation
        draggingPayload = payload
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
        guard let p = draggingPayload, p.canExternalDrop else { isOverDropZone = false; return }
        isOverDropZone = dropZonesProvider(p.source).contains { $0.contains(globalLocation) }
    }

    // MARK: - 收尾（幂等，先清后提交）

    /// 正常松手：在投放区 → 按来源收纳/移回；否则什么都不做（区内排序已在拖动中实时提交）。
    func endDrag() {
        guard let p = draggingPayload else { return }
        let shouldExternal = isOverDropZone
        teardown()
        guard shouldExternal else { return }
        switch p.source {
        case .strip:  drawerStore.add(p.bundleID)     // 收纳（canExternalDrop 已含 canStash）
        case .drawer: drawerStore.remove(p.bundleID)  // 移回任务栏（= 右键「移回任务栏」同语义）
        }
    }

    /// 取消：拖动中目标消失、切屏等异常路径，纯收尾不动作。
    func cancelDrag() {
        guard draggingPayload != nil else { return }
        teardown()
    }

    private func teardown() {
        draggingPayload = nil
        isOverDropZone = false
        removeMonitors()
        pollTimer?.invalidate(); pollTimer = nil
        carrierPanel?.orderOut(nil)
    }

    /// 任务条卡能否收纳：只拦无 bundleID 与 Finder（Finder 永远保留任务条入口）。
    /// 不拦 app-level fallback —— 抽屉运行区本就显示应用级图标。
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
        panel.level = .popUpMenu                 // 压在抽屉(.floating)之上
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 1.0, alpha: 0.0)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true          // 纯绘制，绝不抢事件
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
        // global 实测全程 0 次（隐式抓取锁给本 app），留作廉价兜底。
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

    private func startPoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.draggingPayload != nil else { return }
                if NSEvent.pressedMouseButtons == 0 { self.endDrag() }
            }
        }
        pollTimer?.tolerance = 0.02
    }
}

// MARK: - 全屏载体视图

/// 铺在载体面板上的浮动副本：跟着 `DragController.globalLocation` 走，点击穿透。按来源选画法。
struct DragCarrierView: View {
    @ObservedObject var controller: DragController

    var body: some View {
        if let p = controller.draggingPayload {
            content(p)
                .scaleEffect(controller.isOverDropZone ? 0.82 : 1.05)
                .animation(.easeOut(duration: 0.12), value: controller.isOverDropZone)
                .position(controller.carrierPosition())
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func content(_ p: DragPayload) -> some View {
        switch p.visualKind {
        case .stripChip:
            if let item = p.item {
                ChipView(item: item, forceHover: true)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            }
        case .drawerIcon:
            DrawerDragIconView(bundleID: p.bundleID)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
    }
}

/// 抽屉拖动副本：只画 app 图标，不带 `LauncherChip` 的菜单/弹跳/tap（Codex 二审：载体要轻）。
/// 尺寸与抽屉里 `LauncherChip`（scale 0.7）一致，免得起拖瞬间变大小。
struct DrawerDragIconView: View {
    let bundleID: String
    var scale: CGFloat = 0.7

    var body: some View {
        let iconSize: CGFloat = 36 * scale
        Image(nsImage: AppIconResolver.icon(for: bundleID))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: iconSize, height: iconSize)
            .clipShape(RoundedRectangle(cornerRadius: iconSize / 4, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
            .frame(width: 44 * scale, height: 52 * scale)
    }
}
