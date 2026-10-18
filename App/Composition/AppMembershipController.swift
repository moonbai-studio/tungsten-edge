import Foundation

/// Single mutation boundary for app membership conversions.
///
/// Drawer membership is placement; kept membership means an entry survives app
/// exit. Kept, drawer, and messaging identity may all coexist. Finder joins kept
/// and drawer like any other app (owner 2026-08-20) but is still barred from the
/// messaging zone — see `FinderTaskbarPolicy`.
@MainActor
final class AppMembershipController: ObservableObject {
    private let keptAppStore: KeptAppStore
    private let drawerStore: DrawerStore
    private let messagingStore: MessagingAppStore

    init(
        keptAppStore: KeptAppStore,
        drawerStore: DrawerStore,
        messagingStore: MessagingAppStore
    ) {
        self.keptAppStore = keptAppStore
        self.drawerStore = drawerStore
        self.messagingStore = messagingStore
    }

    /// Native check-menu toggle. It never changes placement. Kept may coexist with
    /// messaging identity under the unified model.
    func setKept(_ bundleID: String, enabled: Bool) {
        guard keptAppStore.canKeep(bundleID) else { return }
        if enabled {
            keptAppStore.add(bundleID)
        } else {
            keptAppStore.remove(bundleID)
        }
    }

    /// Placement-only move: this API never touches kept.
    ///
    /// Auto-enabling kept on stash is a **drag-landing** policy, not a placement-API one —
    /// `DragController.endDrag()` calls `applyDragLanding` below for it, and an app dropped from
    /// Finder onto the capsule (`PanelCoordinator.stashDroppedApplications`) sets kept itself.
    /// Menus offer no drawer placement action; drag is the only way in.
    func moveToDrawer(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        drawerStore.add(bundleID)
    }

    /// Placement-only move out of the drawer, for an app dropped from outside onto the bar: a kept
    /// app still placed in the drawer shows only there, so the drop would otherwise land nothing on
    /// the bar. Same transaction as dragging its drawer cell out (`DragController.convertDrawerToStrip`).
    func moveOutOfDrawer(_ bundleID: String) {
        guard drawerStore.contains(bundleID) else { return }
        drawerStore.remove(bundleID)
    }

    /// 拖动落定后的 kept 补勾（owner 2026-08-06）。规则本体仍是纯决策
    /// `DragConversionPlan.enablesKeptOnDrop`；这里只是把「唯一一处从控制器外面写 kept」收进
    /// 单一变更边界（2026-09-05）。**每次拖入都重新打开**，不是一次性播种——与 `markMessaging`
    /// 的首次补勾不同，见 drag-and-drawer 规则。只在 `endDrag()` 落定后、drawer 已是最终成员关系时调用。
    func applyDragLanding(bundleID: String, originSource: DragSource) {
        guard DragConversionPlan.enablesKeptOnDrop(originSource: originSource,
                                                   endedInDrawer: drawerStore.contains(bundleID)) else { return }
        keptAppStore.add(bundleID)
    }

    /// 「固定在 Dock 栏左侧」：mark + 首次加入补 kept（默认保留）。不改 drawer——位置只能拖动改。
    func markMessaging(_ bundleID: String) {
        guard FinderTaskbarPolicy.canMarkMessaging(bundleID) else { return }
        if messagingStore.mark(bundleID) {
            keptAppStore.add(bundleID)
        }
    }

    /// Auto-tier registration: seed kept for each newly auto-detected messaging app
    /// (first registration only, so a later user un-check is not reopened). Does not
    /// change drawer placement.
    func autoRegisterMessaging(runningBundleIDs: Set<String>,
                               mainWindowIdentifiableBundleIDs: Set<String>) {
        let added = messagingStore.autoRegister(
            runningBundleIDs: runningBundleIDs,
            mainWindowIdentifiableBundleIDs: mainWindowIdentifiableBundleIDs
        )
        for bundleID in added {
            keptAppStore.add(bundleID)
        }
    }

    /// 取消「固定在 Dock 栏左侧」勾选：只清消息身份 + 记 opt-out；kept 与 drawer 保持不变。
    func unmarkMessaging(_ bundleID: String) {
        messagingStore.unmark(bundleID)
    }

    func showsUnreadBadge(_ bundleID: String) -> Bool {
        messagingStore.showsUnreadBadge(bundleID)
    }

    /// 只改角标偏好，不改保留、左侧固定或抽屉位置。
    func setShowsUnreadBadge(_ bundleID: String, enabled: Bool) {
        messagingStore.setShowsUnreadBadge(bundleID, enabled: enabled)
    }

    /// Startup repair. The only illegal membership left is Finder in the messaging
    /// zone — since 2026-08-20 Finder may be kept and may sit in the drawer, and this
    /// runs on every launch, so clearing drawer placement here would wipe the user's
    /// own stash. Kept and messaging deliberately coexist, so there is no
    /// kept/messaging reconciliation.
    func reconcileInvalidMemberships() {
        let finder = FinderTaskbarPolicy.bundleID
        if messagingStore.contains(finder) {
            messagingStore.unmark(finder)
        }
    }
}

/// Defensive, side-effect-free projections used by the strip, drawer, and capsule.
enum AppMembershipProjection {
    /// Full placement list. Hidden members remain here so their drawer order is
    /// stable when a later launch makes them visible again.
    static func drawerMembers(drawerIDs: [String]) -> [String] {
        filteredUnique(drawerIDs, excluding: [])
    }

    /// Core drawer visibility rule: placement is durable, but a chip is rendered
    /// only while the app runs or kept keeps it reachable. Messaging identity is no
    /// longer an independent retention condition — kept alone decides.
    static func visibleDrawerIDs(
        drawerIDs: [String],
        keptIDs: [String],
        runningIDs: Set<String>
    ) -> [String] {
        let retained = Set(keptIDs).union(runningIDs)
        return filteredUnique(drawerIDs, excluding: []).filter { retained.contains($0) }
    }

    /// Messaging-zone visibility: a messaging app not stashed in the drawer, shown
    /// only while running or kept. Order-preserving, deduped.
    static func visibleMessagingIDs(
        messagingIDs: [String],
        drawerIDs: [String],
        keptIDs: [String],
        runningIDs: Set<String>
    ) -> [String] {
        let retained = Set(keptIDs).union(runningIDs)
        return filteredUnique(messagingIDs, excluding: Set(drawerIDs)).filter { retained.contains($0) }
    }

    /// 角标读取范围：允许显示角标 ∩ 在跑 − 抽屉；显式选择与左侧固定独立。
    /// 抽屉里的图标不画角标，条上也没有它的卡，读了也没处画，所以剔掉省一趟 AX。
    /// 输出按字典序，让 `BadgeStore` 的「变了才重走」比较稳定。
    static func badgeEligibleIDs(
        showsUnreadBadge: (String) -> Bool,
        drawerIDs: [String],
        runningIDs: Set<String>
    ) -> [String] {
        let drawer = Set(drawerIDs)
        return runningIDs
            .filter { !$0.isEmpty && !drawer.contains($0) && showsUnreadBadge($0) }
            .sorted()
    }

    static func drawerPreview(
        drawerIDs: [String],
        keptIDs: [String],
        runningIDs: Set<String>,
        limit: Int
    ) -> [String] {
        Array(visibleDrawerIDs(
            drawerIDs: drawerIDs,
            keptIDs: keptIDs,
            runningIDs: runningIDs
        ).prefix(max(0, limit)))
    }

    private static func filteredUnique(_ bundleIDs: [String], excluding excluded: Set<String>) -> [String] {
        var seen = Set<String>()
        return bundleIDs.filter { bundleID in
            !bundleID.isEmpty && !excluded.contains(bundleID) && seen.insert(bundleID).inserted
        }
    }
}
