import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · 桌面（Space）相关：常驻所有桌面的成员资格修复（issue #19）与钉进私有空间。
// 2026-09-05 从 PanelCoordinator.swift 按 extension 拆出，只搬不改。
extension PanelCoordinator {
    /// 读回成员资格，把「本该在所有桌面上、实际只剩当前桌面」的面板补回去。
    ///
    /// 机制与为什么只有这一种形状管用，见 `AllSpacesMembership`。这里三件事一件都不能省：
    /// ① 先读回再决定动不动手——健康时零副作用；② 换值必须隔一轮 runloop 再赋回，
    /// 同一轮里改回去等于没改；③ 赋回之后还要再读一次，**单次修复不保证成功**。
    func repairAllSpacesMembershipIfNeeded(attempt: Int = 1) {
        guard Self.spaceMembershipRepairEnabled, !isSuspendedForPermissionLoss else { return }
        if attempt == 1 && spaceMembershipRepairInFlight { return }
        guard let dock = dockPanel else { return }
        // 钉进私有空间的面板不在任何桌面上，这个修复会把它当「丢了成员资格」反复清空重赋；
        // 只修没钉住的（宿主不可用时 = 全部，行为同旧）。
        let repairCandidates = allSpacesPanels.filter { panel in
            !(overlaySpaceHost?.isPinned(windowNumber: panel.windowNumber) ?? false)
        }
        guard !repairCandidates.isEmpty else {
            spaceMembershipRepairInFlight = false
            return
        }

        guard let uuid = DisplayIdentity.uuidString(for: panelCurrentScreen(panel: dock)),
              let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else {
            spaceMembershipRepairInFlight = false
            return
        }
        let desktops = layout.orderedSpaceIDs.filter { !layout.fullscreenSpaceIDs.contains($0) }

        let broken = repairCandidates.filter { panel in
            guard let owned = WindowSpaceMembershipReader.spaceIDs(forWindowNumber: panel.windowNumber)
            else { return false }   // 读不到 = 不知道，不能当成「丢了」
            return !AllSpacesMembership.missingSpaceIDs(
                windowSpaceIDs: owned,
                desktopSpaceIDs: desktops
            ).isEmpty
        }
        guard !broken.isEmpty else {
            if attempt > 1 {
                logger.info("[space-membership] repaired attempts=\(attempt - 1, privacy: .public)")
            }
            spaceMembershipRepairInFlight = false
            return
        }
        guard AllSpacesMembership.shouldRetry(attempt: attempt - 1) else {
            logger.error("[space-membership] give up after \(attempt - 1, privacy: .public) attempts")
            spaceMembershipRepairInFlight = false
            return
        }

        spaceMembershipRepairInFlight = true
        for panel in broken { panel.collectionBehavior = [] }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for panel in broken { panel.collectionBehavior = PanelCollectionBehavior.standard }
            DispatchQueue.main.asyncAfter(deadline: .now() + AllSpacesMembership.verifyDelay) { [weak self] in
                self?.repairAllSpacesMembershipIfNeeded(attempt: attempt + 1)
            }
        }
    }

    // MARK: - 常驻面板钉进私有空间（桌面互滑时底板不发灰）

    /// 把任务条 / 玻璃底板 / 胶囊钉进进程唯一的私有空间。机理与实测边界见 `OverlaySpaceHost`。
    func pinResidentPanelsIfNeeded() {
        guard let host = overlaySpaceHost, !isSuspendedForPermissionLoss else { return }
        let windowNumbers = allSpacesPanels.map(\.windowNumber)
        guard !windowNumbers.isEmpty else { return }
        if !host.pin(windowNumbers: windowNumbers) {
            logger.error("[overlay-space] pin failed windows=\(windowNumbers, privacy: .public)")
        }
    }

    /// 瞬时面板（抽屉 / 弹窗 / 名字气泡）**也要钉进同一空间**——它们都会和任务条那几扇窗口的范围
    /// （含 20pt 阴影透明边）重叠，而留在桌面空间的窗口不论 `level` 都被合成在私有空间**下面**：
    /// 抽屉最下一行压在胶囊窗口的阴影边里就发暗，启动弹跳往上一抬又变亮（owner 2026-09-03，
    /// `DOCK_OVERLAY_SPACE=0` A/B 坐实）。每次 order front 后补钉一次，已钉住的只是一次廉价读回。
    func pinOverlappingPanelIfNeeded(_ panel: NSPanel) {
        guard let host = overlaySpaceHost, !isSuspendedForPermissionLoss, panel.windowNumber > 0 else { return }
        if !host.pin(windowNumbers: [panel.windowNumber]) {
            logger.error("[overlay-space] pin failed window=\(panel.windowNumber, privacy: .public)")
        }
    }
}
