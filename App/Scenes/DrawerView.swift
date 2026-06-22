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
    /// 抽屉内容区最大高度（胶囊上方锚点 → 屏幕上沿可用高度，PanelCoordinator 开抽屉时算好传入）。
    /// 内容超过它就内部滚动,绝不靠下压底边塞下（防与下方胶囊/任务条重叠）。
    let maxContentHeight: CGFloat

    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var launchFavoriteStore: LaunchFavoriteStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var drawerOrderStore: DrawerOrderStore
    @EnvironmentObject var dragController: DragController

    /// 抽屉图标在 `"drawer"` 坐标空间里的位置，喂给起拖抓取偏移 + 同区落点命中。
    @State private var drawerFrames: [String: CGRect] = [:]

    /// 抽屉根视图的屏幕 frame（bottom-left），判"光标在不在抽屉体" + 屏幕坐标→`"drawer"` 空间换算。
    @State private var drawerRootScreenRect: CGRect = .zero

    /// 入场动画：onAppear 翻 true,内容从胶囊那角轻微放大入场（配合面板 alpha 淡入）。
    @State private var isPresented = false
    /// 网格自然高度（量出来）。超过 maxContentHeight 就内部滚动。
    @State private var contentHeight: CGFloat = 0

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
        // 底部对齐：抽屉面板向上长时,内容底边钉死在锚点(胶囊上方)、只向上揭开,
        // 不会像顶部对齐那样底边先垂到锚点下方(向下压胶囊)再升回来（owner 2026-06-21：避让该直接向上扩展）。
        ZStack(alignment: .bottomLeading) {
            DockVisualEffectView()
                .padding(-2)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .ignoresSafeArea()

            // 内容超过可用高度就内部滚动（封顶,不下压底边）；否则正常贴合内容。
            Group {
                if contentHeight > maxContentHeight + 0.5 {
                    ScrollView(.vertical, showsIndicators: false) { gridStack }
                        .frame(height: maxContentHeight)
                } else {
                    gridStack
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        // 入场：从贴胶囊的右下角轻微放大入场（配合面板 alpha 淡入）。scaleEffect 是渲染变换,不改布局/命中。
        .scaleEffect(isPresented ? 1 : 0.96, anchor: .bottomTrailing)
        .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 8)
        .padding(PanelCoordinator.shadowPadding)
        .onAppear { withAnimation(.easeOut(duration: DrawerAnimation.duration)) { isPresented = true } }
        .onPreferenceChange(DrawerChipFramePreferenceKey.self) { drawerFrames = $0 }
        .onPreferenceChange(DrawerContentHeightKey.self) { contentHeight = $0 }
        // 拖动中被拖图标的 app 从成员里消失（外部移除等）→ 取消拖动，免得空位卡死。
        // 例外：转正进任务条（抽屉拖回任务条·精确落点）会**主动**把它移出抽屉，不算异常消失，不取消。
        .onChange(of: allMembers) { _, members in
            if let p = dragController.draggingPayload, p.source == .drawer,
               !dragController.isConvertedToStrip, !members.contains(p.id) {
                dragController.cancelDrag()
            }
        }
        // 任务条卡拖进抽屉时跟光标算运行区落点；抽屉内拖动时跟光标做重排。都由全局鼠标位置驱动,
        // 不在 body 里发布(用 onChange + 去重,Codex 二审 P2-6)。
        .onChange(of: dragController.globalLocation) { _, _ in updateStripDropPreview(); updateDrawerReorder() }
        .onChange(of: dragController.draggingPayload?.id) { _, _ in updateStripDropPreview() }
    }

    /// 两区网格本体。`.background` 量自然高度喂滚动判定；每区按各自 ID 列表做动画——增删/换行/重排都平滑。
    /// 任务条卡拖进抽屉是"即时转正成成员"（见 updateStripDropPreview），就是运行区多一个 id,无需占位格。
    private var gridStack: some View {
        let runningIDs = runningZoneIDs
        let launchIDs = launchZoneIDs
        let hasRunningZone = !runningIDs.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            if hasRunningZone {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(runningIDs, id: \.self) { id in drawerChip(id, zone: runningIDs, running: true) }
                }
                .animation(.easeInOut(duration: DrawerAnimation.duration), value: runningIDs)
            }
            if !launchIDs.isEmpty {
                Spacer().frame(height: hasRunningZone ? 12 : 0)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(launchIDs, id: \.self) { id in drawerChip(id, zone: launchIDs, running: false) }
                }
                .animation(.easeInOut(duration: DrawerAnimation.duration), value: launchIDs)
            }
        }
        .padding(12)
        .background(GeometryReader { g in
            Color.clear.preference(key: DrawerContentHeightKey.self, value: g.size.height)
        })
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
            // 本手势**只负责起拖一次**：拿到"是哪张卡 + 抓取偏移"后交给 DragController。
            // 重排**不在这里做**——第一次重排会把被拖图标在网格里挪位,SwiftUI 随即取消这个手势、
            // onChanged 不再触发 → "挤一下就卡住"（owner 2026-06-22）。重排改由 updateDrawerReorder()
            // 按 DragController 的全局鼠标位置驱动（见 onChange(globalLocation)），图标怎么换位都不受影响。
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("drawer"))
                    .onChanged { value in
                        guard dragController.draggingPayload == nil else { return }
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
            )
    }

    /// 抽屉内重排：按 DragController 全局鼠标位置驱动（替代会被取消的逐图标手势）。把屏幕坐标映回 `"drawer"`
    /// 空间,命中同区目标后让位。抽屉内重排不改成员数 → 抽屉不缩放 → 用实时 drawerRootScreenRect 映射即可。
    private func updateDrawerReorder() {
        guard let p = dragController.draggingPayload, p.source == .drawer,
              !dragController.isOverDropZone,            // 光标已在任务条上 = 移回,不重排
              drawerRootScreenRect != .zero else { return }
        let pt = CGPoint(x: dragController.globalLocation.x - drawerRootScreenRect.minX,
                         y: drawerRootScreenRect.maxY - dragController.globalLocation.y)   // 屏幕(左下) → drawer(左上)
        let zone = runningZoneIDs.contains(p.id) ? runningZoneIDs : launchZoneIDs
        reorderTarget(at: pt, dragging: p.id, zone: zone)
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

    // MARK: - 任务条卡进抽屉体 → 转成抽屉内拖动 / 拖出还原

    /// 任务条卡拖进**打开的抽屉体** → 即时转成抽屉内拖动（DragController.convertStripToDrawer：加入抽屉成员、
    /// 来源改 `.drawer`）。此后这张卡就是普通抽屉成员,由全局鼠标驱动的 `updateDrawerReorder` 重排——与抽屉内
    /// 拖动**完全同一套**(owner 2026-06-22：统一手感)。彻底绕开旧的"占位空格 + 面板反复缩放"机制（闪烁/卡顿源）。
    /// 底边/侧边留容差：载体相对鼠标有抓取偏移,鼠标常落在抽屉底边附近,容差让贴边也能稳定判"进了抽屉体"。
    private func updateStripDropPreview() {
        let dc = dragController
        guard dc.draggingPayload != nil, drawerRootScreenRect != .zero else { return }
        let g = dc.globalLocation
        let r = drawerRootScreenRect
        // 进入阈值松（容差大,好进）；撤销阈值更靠外（迟滞带,防边缘反复转正/撤销 → 抽屉一胀一缩抖）。
        let enterBody = g.x >= r.minX - 8  && g.x <= r.maxX + 8  && g.y >= r.minY - 28
        let clearlyOut = g.x < r.minX - 20 || g.x > r.maxX + 20 || g.y < r.minY - 48
        if let p = dc.draggingPayload, p.source == .strip, p.canExternalDrop, enterBody {
            dc.convertStripToDrawer()              // 进抽屉体 → 临时转正(挤开别人=预览)
        } else if dc.isConvertedFromStrip, clearlyOut {
            dc.revertStripFromDrawer()             // 拖出抽屉体 → 撤销还原(抽屉缩回最初样子)
        }
    }
}

/// 读取宿主视图在屏幕坐标系里的 frame（AppKit 换算,bottom-left）。绕开 SwiftUI `.global`/y 翻转/
/// shadowPadding 的坑（Codex 二审 P1-3）。去重由调用方负责。
/// 模块内可见：DrawerView 与 DockStripView（抽屉拖回任务条·精确落点）共用，不复制坐标读取逻辑。
struct ScreenRectReader: NSViewRepresentable {
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

/// 网格自然高度（量出来,喂"超高内部滚动"判定）。
private struct DrawerContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
