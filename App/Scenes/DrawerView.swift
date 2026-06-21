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
                if hasRunningZone {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(runningIDs, id: \.self) { id in drawerChip(id, zone: runningIDs) }
                    }
                }
                if !launchIDs.isEmpty {
                    Spacer().frame(height: hasRunningZone ? 12 : 0)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(launchIDs, id: \.self) { id in drawerChip(id, zone: launchIDs) }
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
    }

    // MARK: - 单个图标（含拖动）

    private func isDragging(_ id: String) -> Bool {
        guard let p = dragController.draggingPayload else { return false }
        return p.source == .drawer && p.id == id
    }

    @ViewBuilder
    private func drawerChip(_ id: String, zone: [String]) -> some View {
        let stashed = drawerStore.contains(id)
        LauncherChip(bundleID: id,
                     isRunning: isRunning(id),
                     isHidden: isHiddenInSnapshot(id),
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
        let zoneSet = Set(zone)
        guard let hit = drawerFrames.first(where: { kv in
            kv.key != id && zoneSet.contains(kv.key) && kv.value.contains(point)
        }) else { return }
        drawerOrderStore.reorder(draggedID: id, relativeTo: hit.key,
                                 after: point.x > hit.value.midX, members: allMembers)
    }
}

// MARK: - Drawer drag-reorder preference

private struct DrawerChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
