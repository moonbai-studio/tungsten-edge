import AppKit
import os
import SwiftUI

/// 抽屉 = **app 视角**：一个 bundleID 一个图标，顺序由 [[DrawerOrderStore]] 统一供给、永久记住
/// （2026-06-21 重做）。两区仍按"在不在运行"分：
/// - 运行区：收纳的、且进程在跑的 app（亮图标 + 圆点）。点击 = app 级唤出/收起（`LauncherChip.handleTap`）。
/// - 启动区：没在跑的 app —— 收纳但已退出的 + 固定到启动台当前关着的（暗图标，点击启动）。
///
/// 顺序与成员解耦：显示先后只读 `DrawerOrderStore`（按收纳∪固定全集记），"是收纳还是固定"仍归原两份
/// 名单（语义不变、支持共存）。拖动两向：抽屉内同区落点 = 排序；拖到任务条 = 移回（仅收纳项，走
/// `DragController` 整屏自绘载体）。
struct DrawerView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var launchFavoriteStore: LaunchFavoriteStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var drawerOrderStore: DrawerOrderStore
    @EnvironmentObject var dragController: DragController

    /// 抽屉图标在 `"drawer"` 坐标空间里的位置，喂给起拖抓取偏移 + 同区落点命中。
    @State private var drawerFrames: [String: CGRect] = [:]

    // MARK: - 任务条→抽屉运行区 精确落位 preview 状态

    /// 任务条卡正拖进抽屉时,在运行区的本地插入位(0..运行数);nil = 没有卡拖进来。驱动让位空格。
    @State private var previewK: Int?
    /// 抽屉根视图的屏幕 frame（bottom-left），判"光标在不在抽屉里" + 屏幕坐标→`"drawer"` 空间换算。
    @State private var drawerRootScreenRect: CGRect = .zero
    /// 进入抽屉首帧（空格还没插）捕获的运行区格子位置（`"drawer"` 空间）。命中**始终用这份稳定快照**,
    /// 不用插了空格后位移的实时 frame —— 否则空格一插、格子右移、命中就跳动。
    @State private var baseRunningFrames: [String: CGRect] = [:]

    private let columns = Array(repeating: GridItem(.fixed(44 * 0.7), spacing: 8), count: 5)

    // MARK: - 成员与分区（全 bundleID 级）

    /// 成员全集（收纳 ∪ 固定），喂给顺序层记忆——绝不按"当前可见"裁，否则纯固定项运行离开抽屉后顺序丢。
    private var allMembers: [String] {
        drawerStore.bundleIDs + launchFavoriteStore.bundleIDs.filter { !drawerStore.contains($0) }
    }

    private var displayOrder: [String] { drawerOrderStore.reconciled(members: allMembers) }

    private var snapshotBundleIDs: Set<String> {
        Set(StripItem.items(from: runtime.snapshot).compactMap(\.bundleIdentifier))
    }

    /// 有真窗口的 app（用于启动门控判定）。
    private var windowBackedIDs: Set<String> {
        Set(StripItem.items(from: runtime.snapshot).filter { !$0.isAppLevelFallback }.compactMap(\.bundleIdentifier))
    }

    /// 窗口出现门控（2026-06-18）：刚点启动、进程已起但还没真窗口，视作仍在启动 → 留启动区弹跳。
    private func isLaunchingWithoutWindow(_ id: String) -> Bool {
        runtime.launchingBundleIDs.contains(id) && !windowBackedIDs.contains(id)
    }

    private func isRunning(_ id: String) -> Bool { snapshotBundleIDs.contains(id) }

    private func isHiddenInSnapshot(_ id: String) -> Bool {
        StripItem.items(from: runtime.snapshot).first { $0.bundleIdentifier == id }?.status == "hidden"
    }

    /// 运行区 = 收纳 + 在跑 + 不在启动门控期。
    private var runningZoneIDs: [String] {
        displayOrder.filter { drawerStore.contains($0) && isRunning($0) && !isLaunchingWithoutWindow($0) }
    }

    /// 启动区 = 没在跑（或仍在启动门控期）的成员：收纳已退出 + 固定当前关着（共存项已在 displayOrder 去重）。
    private var launchZoneIDs: [String] {
        displayOrder.filter { id in
            let notReady = !isRunning(id) || isLaunchingWithoutWindow(id)
            return notReady && (drawerStore.contains(id) || launchFavoriteStore.contains(id))
        }
    }

    // MARK: - Body

    var body: some View {
        let runningIDs = runningZoneIDs
        let launchIDs = launchZoneIDs
        let hasRunningZone = !runningIDs.isEmpty

        ZStack(alignment: .topLeading) {
            DockVisualEffectView()
                .padding(-2)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // 运行区：任务条卡拖进抽屉时,在 previewK 处撑开一个让位空格(精确定位)。
                // 空运行区但正有卡拖进来时也渲染(只含那个空格),反馈更明确(Codex 二审 P3)。
                if hasRunningZone || previewK != nil {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(runningCells(runningIDs)) { cell in
                            switch cell {
                            case .chip(let id): drawerChip(id, zone: runningIDs, running: true)
                            case .placeholder:  dropPlaceholder
                            }
                        }
                    }
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: previewK)
                }
                if !launchIDs.isEmpty {
                    Spacer().frame(height: hasRunningZone ? 12 : 0)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(launchIDs, id: \.self) { id in drawerChip(id, zone: launchIDs, running: false) }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        }
        // 抽屉根视图的屏幕 frame（AppKit 换算,绕开 .global/y 翻转/shadowPadding 的坑,Codex 二审 P1-3）。
        // 与 `"drawer"` 命名空间挂在同一视图上 → 既能判"光标在不在抽屉里",又能把屏幕坐标映回 drawer 空间命中格子。
        .background(ScreenRectReader { rect in
            if rect != drawerRootScreenRect { drawerRootScreenRect = rect }
        })
        .coordinateSpace(name: "drawer")
        .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 8)
        .padding(PanelCoordinator.shadowPadding)
        .onPreferenceChange(DrawerChipFramePreferenceKey.self) { drawerFrames = $0 }
        // 拖动中被拖图标的 app 从成员里消失（外部移除等）→ 取消拖动，免得空位卡死。
        .onChange(of: allMembers) { _, members in
            if let p = dragController.draggingPayload, p.source == .drawer, !members.contains(p.id) {
                dragController.cancelDrag()
            }
        }
        // 任务条卡拖进抽屉时,跟着光标实时算运行区落点(不在 body 里发布,用 onChange + 去重,Codex 二审 P2-6)。
        .onChange(of: dragController.globalLocation) { _, _ in updateStripDropPreview() }
        .onChange(of: dragController.draggingPayload?.id) { _, _ in updateStripDropPreview() }
    }

    // MARK: - 单个图标（含拖动）

    private func isDragging(_ id: String) -> Bool {
        guard let p = dragController.draggingPayload else { return false }
        return p.source == .drawer && p.id == id
    }

    /// `running` 按**区**传(运行区 true / 启动区 false),不传真实运行态——启动区的 app 进程一起来
    /// `isRunning` 就翻 true 会让 `LauncherChip` 的 `onChange(of:isRunning)` 提前 `stopBounce`,弹跳被掐断
    /// （owner 2026-06-21 报告"启动弹跳没了"的真因）。窗口出现门控期内它仍在启动区,该一直弹到真窗口出现。
    @ViewBuilder
    private func drawerChip(_ id: String, zone: [String], running: Bool) -> some View {
        let stashed = drawerStore.contains(id)
        LauncherChip(bundleID: id,
                     isRunning: running,
                     isHidden: running ? isHiddenInSnapshot(id) : false,
                     scale: 0.7,
                     removeMenuLabel: stashed ? "移回任务栏" : nil,
                     onRemove: { if stashed { drawerStore.remove(id) } },
                     onLaunch: { runtime.beginLaunch(id) })
            .opacity(isDragging(id) ? 0 : 1)
            // `"drawer"` 空间里的 frame，背景 GeometryReader（不夺点击），喂抓取偏移 + 同区落点。
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: DrawerChipFramePreferenceKey.self,
                                           value: [id: geo.frame(in: .named("drawer"))])
                }
            )
            // 起拖交给 DragController；本手势只负责起拖一次 + 同区排序（进投放区即停）。
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("drawer"))
                    .onChanged { value in
                        if dragController.draggingPayload == nil {
                            let grab: CGSize = drawerFrames[id].map {
                                CGSize(width: $0.midX - value.startLocation.x,
                                       height: $0.midY - value.startLocation.y)
                            } ?? .zero
                            let payload = DragPayload(source: .drawer, id: id, bundleID: id, item: nil,
                                                      visualKind: .drawerIcon, canExternalDrop: stashed)
                            dragController.beginDrag(payload: payload,
                                                     startScreenLocation: NSEvent.mouseLocation,
                                                     grabOffset: grab)
                        }
                        if !dragController.isOverDropZone {
                            reorderTarget(at: value.location, dragging: id, zone: zone)
                        }
                    }
                    .onEnded { _ in dragController.endDrag() }
            )
    }

    /// 抽屉内排序：只在**同一区**内命中落点（Codex 二审 ⑤——跨区改顺序会"偷偷"改、状态变才显现）。
    private func reorderTarget(at point: CGPoint, dragging id: String, zone: [String]) {
        // 命中 frame 外扩一圈(覆盖 8pt 格间空隙)→ 判定区更大、好定位(owner 2026-06-21 反馈太小)。
        // 按 zone 顺序遍历:dict.first(where:) 顺序不定,外扩后相邻格会重叠 → 必须有序取最左。
        for tid in zone where tid != id {
            guard let f = drawerFrames[tid], f.insetBy(dx: -6, dy: -6).contains(point) else { continue }
            drawerOrderStore.reorder(draggedID: id, relativeTo: tid, after: point.x > f.midX, members: allMembers)
            return
        }
    }

    // MARK: - 任务条→抽屉运行区 精确落位 preview（仅 strip 来源、抽屉已打开）

    /// 运行区网格单元：真 chip 或一个让位占位。
    private enum DrawerRunCell: Identifiable {
        case chip(String)
        case placeholder
        var id: String {
            switch self {
            case .chip(let s): return s
            case .placeholder: return "__drawer_drop_placeholder__"
            }
        }
    }

    private func runningCells(_ running: [String]) -> [DrawerRunCell] {
        var cells = running.map { DrawerRunCell.chip($0) }
        // 多加"拖动仍在进行中"的条件：松手瞬间 draggingPayload 立刻变 nil → 空格同帧撤掉,
        // 和真图标落位在同一帧完成,不会多挂一帧导致所有图标抖一下（owner 2026-06-21 报告）。
        if let k = previewK, dragController.draggingPayload?.source == .strip {
            cells.insert(.placeholder, at: max(0, min(k, cells.count)))
        }
        return cells
    }

    /// 隐形让位空格：只占位撑开,不画任何边框（与抽屉内拖动的空槽一致,owner 2026-06-21 反馈不要虚线框）。
    private var dropPlaceholder: some View {
        Color.clear.frame(width: 44 * 0.7, height: 52 * 0.7)
    }

    /// 跟随光标算"任务条卡落进运行区第几位",并把对应的**全局插入位**发布给 DragController。
    private func updateStripDropPreview() {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .strip, dc.isOverDropZone,
              drawerRootScreenRect.contains(dc.globalLocation) else {
            if previewK != nil { previewK = nil; baseRunningFrames = [:]; dc.setDropPreview(nil) }
            return
        }
        let running = runningZoneIDs
        // 进入抽屉首帧（previewK 还是 nil、还没空格）捕获一份稳定的运行区格子位置,后续都用它命中。
        if previewK == nil {
            baseRunningFrames = drawerFrames.filter { running.contains($0.key) }
        }
        let k = runningInsertionIndex(among: running, at: dc.globalLocation)
        if k != previewK {
            previewK = k
            dc.setDropPreview(globalIndex(forRunningK: k, running: running))
        }
    }

    /// 屏幕坐标 → `"drawer"` 空间,命中运行区某格按左/右半给插入位;没命中 → 运行区末尾。
    private func runningInsertionIndex(among running: [String], at screenLoc: CGPoint) -> Int {
        let pt = CGPoint(x: screenLoc.x - drawerRootScreenRect.minX,
                         y: drawerRootScreenRect.maxY - screenLoc.y)   // bottom-left 屏幕 → top-left drawer 空间
        for (i, id) in running.enumerated() {
            if let f = baseRunningFrames[id], f.insetBy(dx: -6, dy: -6).contains(pt) {   // 外扩,判定区更大
                return pt.x > f.midX ? i + 1 : i
            }
        }
        return running.count
    }

    /// 运行区本地插入位 K → 抽屉全局顺序里的插入位（运行区是 displayOrder 的子序列）。
    private func globalIndex(forRunningK k: Int, running: [String]) -> Int {
        let order = displayOrder
        guard !running.isEmpty else { return 0 }   // 运行区空 → 插到最前（渲染在启动区之上）
        if k >= running.count {
            let last = running[running.count - 1]
            return (order.firstIndex(of: last).map { $0 + 1 }) ?? order.count
        }
        let at = running[k]
        return order.firstIndex(of: at) ?? order.count
    }
}

/// 读取宿主视图在屏幕坐标系里的 frame（AppKit 换算,bottom-left）。绕开 SwiftUI `.global`/y 翻转/
/// shadowPadding 的坑（Codex 二审 P1-3）。去重由调用方负责。
private struct ScreenRectReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void
    func makeNSView(context: Context) -> NSView { TrackingView(onChange: onChange) }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? TrackingView)?.report() }

    final class TrackingView: NSView {
        let onChange: (CGRect) -> Void
        init(onChange: @escaping (CGRect) -> Void) { self.onChange = onChange; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { report() }
        override func layout() { super.layout(); report() }
        func report() {
            guard let window else { return }
            let onScreen = window.convertToScreen(convert(bounds, to: nil))
            DispatchQueue.main.async { [onChange] in onChange(onScreen) }
        }
    }
}

// MARK: - Drawer drag-reorder preference

private struct DrawerChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
