import Foundation
import os

/// Publishes [bundleID: badge text] read from the system Dock (see DockBadgeReader).
/// Polls every 0.5s off the main thread (clearing an unread badge must feel immediate —
/// the cadence while visible is a product requirement and never stretches). Since the
/// targeted-read rework the per-tick work is 1-3 AX round trips against cached AXDockItem
/// elements instead of a full Dock-tree walk, and the published dict is scoped to the
/// messaging apps that can actually show a badge (messaging **identity** ∩ running, minus
/// drawer — since 2026-08-23 the badge follows the app, not the zone: a messaging app's
/// leftmost strip card paints it whether it sits in the zone or in the live zone). A tick
/// with no readable messaging app performs zero AX traffic. Publishes only on change so
/// SwiftUI doesn't re-render chips for identical badge state.
/// Kill switch DOCK_BADGE_TARGETED=0 restores the legacy full-tree walk every tick.
@MainActor
final class BadgeStore: ObservableObject {
    @Published private(set) var badgesByBundleID: [String: String] = [:]

    private let reader: any DockBadgeReading
    private let targetedEnabled: Bool
    /// 零感知门控（看板卡「没有消息应用时暂停角标轮询」）：可读集为空或任务条逻辑隐藏时
    /// 连计时器一起停；恢复条件出现即重启并**立即读一次**。DOCK_BADGE_PAUSE=0 关闭
    ///（计时器常驻，行为回到「空 tick 零 AX 流量」）。
    private let pauseEnabled: Bool
    private let uptimeProvider: () -> TimeInterval
    private var timer: Timer?
    private var isStarted = false
    private var isReading = false
    private var itemCache: DockItemCache?
    private var cacheCapturedAt: TimeInterval = 0
    private var pathToBundleID: [String: String] = [:]
    private var rewalkRequested = false
    /// 可读集 = 消息应用身份 ∩ 在跑 − 抽屉（`AppMembershipProjection.badgeEligibleIDs`，AppDelegate 推进来）。
    private var readableMessagingIDs: [String] = []
    private var taskbarVisible = true
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "Badge")

    init(
        reader: any DockBadgeReading = DockBadgeReader(),
        targetedEnabled: Bool = DebugSwitch.badgeTargeted.isEnabled(in: ProcessInfo.processInfo.environment),
        pauseEnabled: Bool = DebugSwitch.badgePause.isEnabled(in: ProcessInfo.processInfo.environment),
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.reader = reader
        self.targetedEnabled = targetedEnabled
        self.pauseEnabled = pauseEnabled
        self.uptimeProvider = uptimeProvider
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        reconcileTimerState()
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    /// 任务条逻辑显隐（PanelCoordinator 的两条隐藏路径都要通知到）。隐藏期间保留上次
    /// 发布值——重新显示时 chip 立即带着旧角标出现，恢复读在 ~50ms 内校正，不闪。
    func setTaskbarVisible(_ visible: Bool) {
        guard visible != taskbarVisible else { return }
        taskbarVisible = visible
        reconcileTimerState()
    }

    private var shouldPauseTimer: Bool {
        guard targetedEnabled, pauseEnabled else { return false }
        return readableMessagingIDs.isEmpty || !taskbarVisible
    }

    /// 门控状态机：暂停 → 拆计时器；恢复 → 重建计时器并立即读一次（清角标即时性的产品要求
    /// 靠这一读衔接）。start()/名单变化/显隐变化都汇到这里。
    private func reconcileTimerState() {
        guard isStarted else { return }
        if shouldPauseTimer {
            timer?.invalidate()
            timer = nil
            // 没有任何可读消息应用时字典必然为空集；隐藏态则保留旧值（见 setTaskbarVisible）。
            if readableMessagingIDs.isEmpty, !badgesByBundleID.isEmpty { publishIfChanged([:]) }
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.readOnce() }
            }
            timer?.tolerance = 0.05
            readOnce()
        }
    }

    deinit {
        timer?.invalidate()
    }

    /// 消息名单或在跑集合变化：Dock 磁贴集随消息应用启动/退出而变，缓存作废重走。
    /// 「消息应用刚启动、新磁贴上出角标」靠这条在 ~1s 内补上（磁贴新生 = 该应用进入在跑集合）。
    func updateMessagingContext(visibleMessagingIDs: [String], runningBundleIDs: Set<String>) {
        let readable = visibleMessagingIDs.filter { runningBundleIDs.contains($0) }
        guard readable != readableMessagingIDs else { return }
        readableMessagingIDs = readable
        rewalkRequested = true
        reconcileTimerState()
    }

    private func readOnce() {
        guard !isReading else { return }   // serialize: skip a tick if the last read is still running
        guard targetedEnabled else {
            performLegacyRead()
            return
        }
        switch BadgeReadPlan.verdict(.init(
            messagingBundleIDs: readableMessagingIDs,
            taskbarVisible: taskbarVisible,
            hasCache: itemCache != nil,
            cacheAgeSeconds: uptimeProvider() - cacheCapturedAt,
            rewalkRequested: rewalkRequested
        )) {
        case .pause:
            if readableMessagingIDs.isEmpty, !badgesByBundleID.isEmpty { publishIfChanged([:]) }
        case .fullWalk:
            performFullWalk()
        case .targeted(let bundleIDs):
            guard let cache = itemCache else {
                performFullWalk()
                return
            }
            performTargetedRead(cache: cache, bundleIDs: bundleIDs)
        }
    }

    private func performFullWalk() {
        isReading = true
        // 起步即清 rewalk 标志：走树期间名单再变会重新置位，下一 tick 再走（landing 时清会吞掉它）。
        rewalkRequested = false
        let reader = reader
        let pathMap = pathToBundleID
        Task.detached { [weak self] in
            let outcome = reader.fullWalk(previousPathMap: pathMap)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isReading = false
                self.itemCache = outcome.cache
                self.cacheCapturedAt = self.uptimeProvider()
                self.pathToBundleID = outcome.pathToBundleID
                self.publishIfChanged(
                    outcome.badges.filter { self.readableMessagingIDs.contains($0.key) }
                )
            }
        }
    }

    private func performTargetedRead(cache: DockItemCache, bundleIDs: [String]) {
        isReading = true
        let reader = reader
        let previous = badgesByBundleID
        Task.detached { [weak self] in
            let outcome = reader.targetedRead(
                cache: cache,
                bundleIDs: bundleIDs,
                previousBadges: previous
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isReading = false
                switch outcome {
                case .ok(let badges):
                    self.publishIfChanged(badges)
                case .cacheInvalid:
                    // 瞬态读错不发布缺失（角标不能闪没）：沿用上次值，下一 tick 重走全树。
                    self.rewalkRequested = true
                }
            }
        }
    }

    /// DOCK_BADGE_TARGETED=0：改造前的原样路径——整棵树、全部角标、无范围过滤。
    private func performLegacyRead() {
        isReading = true
        let reader = reader
        Task.detached { [weak self] in
            let badges = reader.readBadges()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isReading = false
                self.publishIfChanged(badges)
            }
        }
    }

    private func publishIfChanged(_ badges: [String: String]) {
        guard badges != badgesByBundleID else { return }
        badgesByBundleID = badges
        // Diagnostic: badge dict as published, logged on change only. Scoped to messaging
        // apps since the targeted-read rework (legacy kill-switch path still logs all).
        logger.info("badges-changed \(badges.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "), privacy: .public)")
    }

    #if DEBUG
    func readOnceForTesting() {
        readOnce()
    }

    var isReadingForTesting: Bool { isReading }
    var isTimerRunningForTesting: Bool { timer != nil }
    #endif
}
