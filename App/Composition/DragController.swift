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

    /// 抽屉拖回任务条·精确落点：drawer 图标拖进任务条区即"转正"成任务条窗口卡（`drawerStore.remove`），
    /// 这里记下被转正的 bundleID（非 nil = 当前处于"抽屉卡已临时转正进任务条"态）。落点排序归 DockStripView
    /// + StripOrderStore，本控制器只管成员变更 + 把"成功松手落定"经回调通知出去。
    /// `@Published`：载体视图（`DragCarrierView`）靠它从抽屉小图标切到任务条卡，必须能驱动刷新（Codex 三审 P1）。
    @Published private(set) var convertedDrawerBundleID: String?
    var isConvertedToStrip: Bool { convertedDrawerBundleID != nil }
    /// 转正后载体改画的**唯一代表卡**：载体（画哪张卡）与任务条空位（隐藏哪张卡）都认它，避免"手里拎 A、
    /// 条里空出 B"（Codex 三审 P1）。由 DockStripView 在窗口卡实体化后写入（显示序里该 app 第一张已实体化的
    /// 卡），未实体化前为 nil（载体仍画抽屉小图标）。`revert`/`teardown` 清空。
    @Published private(set) var convertedRepresentative: StripItem?
    func setConvertedRepresentative(_ item: StripItem?) {
        if convertedRepresentative != item { convertedRepresentative = item }
    }
    /// 成功松手落定（converted 态）时回调，组合层接到后 `stripOrderStore.commitExternalBlock()`。
    /// 唯一收到 mouseUp 的是 `endDrag`，commit 必须由它触发，不靠 DockStripView 推断 payload 变 nil。
    var onDrawerToStripCommitted: ((String) -> Void)?
    /// 抽屉图标松手落进任务条时回调（精确落点路径 + 降级路径都会触发）。
    /// PanelCoordinator 用它关闭抽屉；与 onDrawerToStripCommitted 独立，互不替代。
    var onDrawerToStripCompleted: ((String) -> Void)?

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

    // MARK: - 任务条卡进抽屉体 → 转成抽屉内拖动（统一手感，owner 2026-06-22）

    /// 转正前的原始任务条载荷：非 nil 表示"当前这张卡是任务条卡、已临时转正进抽屉"。撤销时据此还原。
    private var stripPayloadBeforeConvert: DragPayload?
    /// 当前是不是"任务条卡临时转正进抽屉"的状态（供 DrawerView 决定何时撤销还原）。
    /// `@Published`：PanelCoordinator 据此冻结/解冻任务条宽度（"拖卡进抽屉松手才变窄"，与拖回任务条对称）。
    @Published private(set) var isConvertedFromStrip: Bool = false

    /// 任一方向的跨面板转正进行中（进抽屉 或 出抽屉）。转正期间任务条宽度冻结，松手/还原才重排。
    var isCrossPanelConverted: Bool { isConvertedToStrip || isConvertedFromStrip }

    /// 任务条卡拖进**打开的抽屉体** → 即时"转正"成抽屉成员、把来源改成 `.drawer`。之后完全走抽屉内
    /// 重排路径（全局鼠标驱动、无占位空格、无面板反复缩放）——彻底绕开旧的"占位+面板缩放"机制。
    /// **可逆**：转正只是临时插入(挤开别人=预览);卡拖出抽屉体 → `revertStripFromDrawer` 撤销还原;
    /// 真正松手落在抽屉里那刻才算落定（owner 2026-06-22：再开抽屉要是最初的样子,不是被挤过的）。
    /// `guard source==.strip` 保证幂等（转一次后不再触发）。
    func convertStripToDrawer() {
        guard let p = draggingPayload, p.source == .strip, p.canExternalDrop else { return }
        stripPayloadBeforeConvert = p
        isConvertedFromStrip = true   // 先置（同步触发宽度冻结、capture 拖动前宽度），再动 drawerStore
        drawerStore.add(p.bundleID)
        draggingPayload = DragPayload(source: .drawer, id: p.bundleID, bundleID: p.bundleID,
                                      item: p.item, visualKind: p.visualKind, canExternalDrop: true)
        refreshDropZone()   // 投放区集合随来源变,重算
    }

    /// 撤销转正：卡拖出抽屉体 → 从抽屉成员里移除（抽屉缩回原样、其他图标归位）、来源还原成任务条卡。
    /// 之后再次拖进抽屉体会重新 `convertStripToDrawer`。让"再开抽屉=最初的样子"。
    func revertStripFromDrawer() {
        guard let original = stripPayloadBeforeConvert, draggingPayload?.source == .drawer else { return }
        drawerStore.remove(original.bundleID)
        draggingPayload = original
        stripPayloadBeforeConvert = nil
        isConvertedFromStrip = false   // 解冻 + 触发 relayout（拖出抽屉还原 → 任务条恢复原宽）
        refreshDropZone()
    }

    // MARK: - 抽屉图标拖进任务条区 → 转正成任务条窗口卡 / 拖出还原（抽屉拖回任务条·精确落点，2026-06-22）

    /// 抽屉图标拖进**任务条面板区** → 即时"转正"：`drawerStore.remove(bid)`，该 app 的窗口卡随即进 live 区。
    /// 落点排序（暂存 + sync 内落子）归 DockStripView，本方法只管成员变更 + 记 bundleID。**不翻 source**——保
    /// `.drawer` 让 `isOverUnstashZone` 高亮与 `endDrag` 的 `.drawer` 分支继续成立。`guard` 保幂等。
    func convertDrawerToStrip() {
        guard let p = draggingPayload, p.source == .drawer, p.canExternalDrop, convertedDrawerBundleID == nil else { return }
        convertedDrawerBundleID = p.bundleID   // 先置（同步触发宽度冻结、capture 拖动前宽度），再动 drawerStore
        drawerStore.remove(p.bundleID)
    }

    /// 撤销转正：拖出任务条区 → `drawerStore.add(bid)` 还原收纳（固定标志本就独立、不受影响）。
    /// 顺序层的撤销（删 boundIDs + 清 absentSince）由 DockStripView 在调本方法**之前** `cancelExternalBlock`。
    func revertDrawerToStrip() {
        guard let bid = convertedDrawerBundleID else { return }
        drawerStore.add(bid)
        convertedDrawerBundleID = nil
        convertedRepresentative = nil   // 载体恢复抽屉小图标
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
        let external = isOverDropZone
        let converted = isConvertedToStrip
        let convertedBid = convertedDrawerBundleID
        teardown()
        switch p.source {
        case .strip:
            // 进过抽屉体的卡已被 convertStripToDrawer 转成 .drawer（落在里面 = 已是成员、不走这里）。
            // 走到这支 = 没进抽屉体的卡：在投放区(胶囊)松手 → 追加末尾收纳；否则什么都不做。
            if external { drawerStore.add(p.bundleID) }
        case .drawer:
            if converted {
                // 已转正进任务条（成员已 remove、窗口卡已落子）→ 视为落定，不再据 external 动成员。
                // 撤销已在实时离区时发生；这里只通知顺序层 commit（清暂存追踪）。
                let bid = convertedBid ?? p.bundleID
                onDrawerToStripCommitted?(bid)
                onDrawerToStripCompleted?(bid)
            } else {
                // 没转正（没运行 / app-fallback / 消息应用走旧路）：落任务条 → 移回；否则留抽屉。
                guard external else { return }
                drawerStore.remove(p.bundleID)
                onDrawerToStripCompleted?(p.bundleID)
            }
        }
    }

    /// 取消：拖动中目标消失、切屏等异常路径，纯收尾不动作。
    func cancelDrag() {
        guard draggingPayload != nil else { return }
        teardown()
    }

    private func teardown() {
        stripPayloadBeforeConvert = nil   // 落定/取消都清掉（落在抽屉里 = 已 add，不撤销）
        isConvertedFromStrip = false      // 解冻任务条宽度（拖卡进抽屉落定/取消）
        convertedDrawerBundleID = nil     // 抽屉拖回任务条：落定/取消都清转正态
        convertedRepresentative = nil
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
        // NonConstrainingPanel: 载体覆盖整屏，若被系统约束到"当前屏"可用区会错位（多屏共享边场景），同 dock/胶囊。
        let panel = NonConstrainingPanel(contentRect: screenProvider().frame,
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

    /// 弹簧开抽屉后把载体重新提到最前——新开的抽屉 orderFront 后可能盖住先于它创建的载体（owner 2026-06-21
    /// 报告"拖进弹簧开的抽屉时浮动图标消失"）。仅拖动进行中才动。
    func bringCarrierToFront() {
        guard draggingPayload != nil, let c = carrierPanel else { return }
        c.orderFrontRegardless()
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
            // 转正进任务条后就是在条内重排,**不缩小**（保持 1.05,与条内载体一致）；只有"未转正且命中投放区"
            // （任务条卡悬胶囊 / 抽屉图标悬任务条但还没转正）才缩 0.82。动画跟 shrink 走,0.82↔1.05 平滑(Codex 三审 P2)。
            let shrink = controller.isOverDropZone && !controller.isConvertedToStrip
            content(p)
                .scaleEffect(shrink ? 0.82 : 1.05)
                .animation(.easeOut(duration: 0.12), value: shrink)
                .position(controller.carrierPosition())
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func content(_ p: DragPayload) -> some View {
        // 抽屉拖回任务条·转正后:载体改画**代表卡**整张(与条内载体同款),让"拖回来"和"条内拖动"观感一致。
        // 代表卡由 DockStripView 在窗口卡实体化后写入;未实体化前 nil → 仍按 visualKind 画(抽屉里就是小图标)。
        if let rep = controller.convertedRepresentative {
            ChipView(item: rep, forceHover: false)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        } else {
            switch p.visualKind {
            case .stripChip:
                if let item = p.item {
                    // forceHover: false —— 悬停态会在图标下方带出 app 名,拖动时不想要（owner 2026-06-21）。
                    // 非悬停态 = 干净的大图标(单窗口卡),贴近抽屉拖动的观感。代价是起拖瞬间图标略放大,可接受。
                    ChipView(item: item, forceHover: false)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                }
            case .drawerIcon:
                DrawerDragIconView(bundleID: p.bundleID)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            }
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
