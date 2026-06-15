import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

struct AppEntry {
    let pid: pid_t
    let bundleIdentifier: String?
    let appName: String
    let activationPolicy: NSApplication.ActivationPolicy
    var windowsByID: [CGWindowID: WindowEntry]
    var windowOrder: [CGWindowID]
    var isHidden: Bool
}

struct WindowEntry {
    let cgWindowID: CGWindowID
    var title: String
    var bounds: CGRect?
    var isMinimized: Bool
    var isFocused: Bool
}

@MainActor
final class AppTracker: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot = .empty

    private var apps: [pid_t: AppEntry] = [:]
    private var appOrder: [pid_t] = []
    private var observers: [pid_t: AppWindowObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var reconcileTimer: Timer?
    private var frontmostPollTimer: Timer?
    private var isScanningCandidates = false
    private var destroyedCGIDs: [CGWindowID: Date] = [:]
    private static let tombstoneTTL: TimeInterval = 3.0

    /// 上次重建快照时的 CG on-screen 集合。前台轮询据此发现「切标签」——AX 可能完全不报，
    /// 但 on-screen 集合会即时变化，变了就重建（标签组可见标签随之即时更新）。
    private var lastOnScreenCGIDs: Set<CGWindowID> = []

    private let reader = AXWindowReader()
    private let eligibilityPolicy = DockWindowEligibilityPolicy()
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "app-tracker")

    func start() {
        guard workspaceObservers.isEmpty else { return }
        seedRunningApps()
        subscribeWorkspaceNotifications()
        startReconcileTimer()
        startFrontmostPollTimer()
    }

    func stop() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        frontmostPollTimer?.invalidate()
        frontmostPollTimer = nil
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        for obs in observers.values { obs.stop() }
        observers.removeAll()
        apps.removeAll()
        appOrder.removeAll()
        destroyedCGIDs.removeAll()
        snapshot = .empty
    }

    // MARK: - Tombstone

    private func isTombstoned(_ cgID: CGWindowID) -> Bool {
        guard let removedAt = destroyedCGIDs[cgID] else { return false }
        return Date().timeIntervalSince(removedAt) <= Self.tombstoneTTL
    }

    private func purgeStaleTombstones() {
        let now = Date()
        destroyedCGIDs = destroyedCGIDs.filter { _, date in
            now.timeIntervalSince(date) <= Self.tombstoneTTL
        }
    }

    // MARK: - CG Window Set

    private func cgWindowIDSet() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids = Set<CGWindowID>()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = info[kCGWindowNumber as String] as? Int else { continue }
            ids.insert(CGWindowID(num))
        }
        return ids
    }

    /// 「当前真正在屏」的窗口集合（含被遮挡的，但不含最小化 / 被 order-out 的后台标签 / 其它 Space）。
    /// 用于标签组里判定哪个标签可见——这是即时可靠的合成层信号，不像 AX min 会滞后数秒。
    private func onScreenCGWindowIDSet() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids = Set<CGWindowID>()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = info[kCGWindowNumber as String] as? Int else { continue }
            ids.insert(CGWindowID(num))
        }
        return ids
    }

    /// 属于某个「同 pid + 逐像素相同 frame」≥2 成员标签组的窗口 cgID 集合（与 StripItem 合并判据一致）。
    /// 只有这些窗口才改用 CG on-screen 判定可见性；普通单窗口仍走 AX。
    private func tabGroupedWindowIDs() -> Set<CGWindowID> {
        var groups: [String: [CGWindowID]] = [:]
        for pid in appOrder {
            guard let app = apps[pid] else { continue }
            for cgID in app.windowOrder {
                guard let b = app.windowsByID[cgID]?.bounds else { continue }
                let key = "\(pid)|\(Int(b.origin.x.rounded())):\(Int(b.origin.y.rounded())):\(Int(b.size.width.rounded())):\(Int(b.size.height.rounded()))"
                groups[key, default: []].append(cgID)
            }
        }
        var result: Set<CGWindowID> = []
        for (_, members) in groups where members.count > 1 { result.formUnion(members) }
        return result
    }

    // MARK: - Seed

    private func seedRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard isRegularNonSelf(app) else { continue }
            let windows = reader.windows(forPID: app.processIdentifier)
            let hasEligible = windows.contains {
                isEligible($0, bundleIdentifier: app.bundleIdentifier, activationPolicy: app.activationPolicy)
            }
            if hasEligible {
                addApp(app, enumerateImmediately: true)
            }
        }
        rebuildSnapshot()
    }

    // MARK: - Workspace Notifications

    private func subscribeWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.handleAppLaunched(app) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppTerminated(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppHidden(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppUnhidden(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.handleAppActivated(app) }
        })
    }

    // MARK: - Workspace Handlers

    private func handleAppLaunched(_ app: NSRunningApplication) {
        guard isRegularNonSelf(app) else { return }
        scheduleRetryAdmission(app: app, delays: [0.2, 0.5, 1.0, 2.0])
    }

    private func handleAppActivated(_ app: NSRunningApplication) {
        guard isRegularNonSelf(app) else { return }
        guard apps[app.processIdentifier] == nil else {
            rebuildSnapshot()  // frontmost changed → active highlight update
            return
        }
        addApp(app, enumerateImmediately: true)
        rebuildSnapshot()
    }

    private func handleAppTerminated(pid: pid_t) {
        observers[pid]?.stop()
        observers.removeValue(forKey: pid)
        apps.removeValue(forKey: pid)
        appOrder.removeAll { $0 == pid }
        rebuildSnapshot()
    }

    private func handleAppHidden(pid: pid_t) {
        apps[pid]?.isHidden = true
        rebuildSnapshot()
    }

    private func handleAppUnhidden(pid: pid_t) {
        apps[pid]?.isHidden = false
        rebuildSnapshot()
    }

    // MARK: - App Management

    private func addApp(_ app: NSRunningApplication, enumerateImmediately: Bool) {
        let pid = app.processIdentifier
        guard apps[pid] == nil else { return }

        apps[pid] = AppEntry(
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "\(pid)",
            activationPolicy: app.activationPolicy,
            windowsByID: [:],
            windowOrder: [],
            isHidden: app.isHidden
        )
        appOrder.append(pid)

        if AXIsProcessTrusted() {
            let obs = AppWindowObserver(pid: pid)
            obs.onWindowCreated = { [weak self] pid in self?.handleWindowCreated(pid: pid) }
            obs.onWindowDestroyed = { [weak self] pid, cgID in self?.handleWindowDestroyed(pid: pid, cgWindowID: cgID) }
            obs.onWindowMinimized = { [weak self] pid, cgID in self?.handleWindowMinimized(pid: pid, cgWindowID: cgID) }
            obs.onWindowDeminiaturized = { [weak self] pid, cgID in self?.handleWindowDeminiaturized(pid: pid, cgWindowID: cgID) }
            obs.onFocusedWindowChanged = { [weak self] pid in self?.handleFocusedWindowChanged(pid: pid) }
            obs.onTitleChanged = { [weak self] pid, cgID in self?.handleTitleChanged(pid: pid, cgWindowID: cgID) }
            obs.start()
            observers[pid] = obs
        }

        if enumerateImmediately {
            enumerateWindows(for: pid)
        }
    }

    private func scheduleRetryAdmission(app: NSRunningApplication, delays: [TimeInterval]) {
        let pid = app.processIdentifier
        for delay in delays {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                if self.apps[pid] != nil {
                    self.enumerateWindows(for: pid)
                    return
                }
                guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return }
                let windows = self.reader.windows(forPID: pid)
                let bundleID = app.bundleIdentifier
                let policy = app.activationPolicy
                let hasEligible = windows.contains {
                    self.isEligible($0, bundleIdentifier: bundleID, activationPolicy: policy)
                }
                if hasEligible {
                    self.addApp(app, enumerateImmediately: true)
                    self.rebuildSnapshot()
                }
            }
        }
    }

    // MARK: - Window Enumeration

    private func enumerateWindows(for pid: pid_t) {
        guard var app = apps[pid] else { return }
        let snapshots = reader.windows(forPID: pid)
        let eligible = snapshots.filter {
            isEligible($0, bundleIdentifier: app.bundleIdentifier, activationPolicy: app.activationPolicy)
        }

        // Build index for O(1) lookup
        var eligibleByID: [CGWindowID: AXWindowSnapshot] = [:]
        for snap in eligible {
            if let cgID = snap.cgWindowID { eligibleByID[cgID] = snap }
        }

        // CG set: used to veto removal of windows AX can't enumerate (minimized)
        let cgIDs = cgWindowIDSet()

        var newWindowsByID: [CGWindowID: WindowEntry] = [:]
        var newOrder: [CGWindowID] = []

        // Pass 1: existing tracked windows in their current order
        for cgID in app.windowOrder {
            if let snap = eligibleByID[cgID] {
                // AX can see it
                let existing = app.windowsByID[cgID]
                newWindowsByID[cgID] = WindowEntry(
                    cgWindowID: cgID,
                    title: snap.title ?? existing?.title ?? "",
                    bounds: snap.bounds ?? existing?.bounds,
                    isMinimized: snap.isMinimized,
                    isFocused: snap.isFocusedWindow
                )
                newOrder.append(cgID)
            } else if cgIDs.contains(cgID) && !isTombstoned(cgID) {
                // AX can't enumerate it but CG confirms it exists → minimized
                var entry = app.windowsByID[cgID] ?? WindowEntry(
                    cgWindowID: cgID, title: "", bounds: nil, isMinimized: true, isFocused: false
                )
                entry.isMinimized = true
                entry.isFocused = false
                newWindowsByID[cgID] = entry
                newOrder.append(cgID)
            }
            // else: not in AX, not in CG (or tombstoned) → truly closed; drop it
        }

        // Pass 2: new AX-visible windows not previously tracked
        for snap in eligible {
            guard let cgID = snap.cgWindowID, newWindowsByID[cgID] == nil else { continue }
            newWindowsByID[cgID] = WindowEntry(
                cgWindowID: cgID,
                title: snap.title ?? "",
                bounds: snap.bounds,
                isMinimized: snap.isMinimized,
                isFocused: snap.isFocusedWindow
            )
            newOrder.append(cgID)
            observers[pid]?.registerWindow(snap.element, cgWindowID: cgID)
        }

        app.windowsByID = newWindowsByID
        app.windowOrder = newOrder
        apps[pid] = app
        rebuildSnapshot()
    }

    private func isEligible(
        _ snap: AXWindowSnapshot,
        bundleIdentifier: String?,
        activationPolicy: NSApplication.ActivationPolicy
    ) -> Bool {
        if bundleIdentifier == DockWindowEligibilityPolicy.selfBundleIdentifier { return false }

        if FeishuBundleRules.isFeishu(bundleIdentifier: bundleIdentifier) {
            return AXTaskbarWindowRules.isMainWindow(role: snap.role, subrole: snap.subrole, bounds: snap.bounds)
        }

        if let bundleIdentifier {
            let candidate = DockWindowEligibilityPolicy.Candidate(
                bundleIdentifier: bundleIdentifier,
                appName: "",
                title: snap.title,
                bounds: snap.bounds,
                alpha: nil,
                activationPolicy: activationPolicy,
                executablePath: nil
            )
            if eligibilityPolicy.evaluate(candidate) == .filter { return false }
        }

        if bundleIdentifier == FinderWindowRules.bundleIdentifier {
            return FinderWindowRules.isTrackable(
                title: snap.title, role: snap.role, subrole: snap.subrole, bounds: snap.bounds
            )
        }

        return AXTaskbarWindowRules.isMainWindow(role: snap.role, subrole: snap.subrole, bounds: snap.bounds)
    }

    // MARK: - AX Event Handlers

    private func handleWindowCreated(pid: pid_t) {
        enumerateWindows(for: pid)
    }

    private func handleWindowDestroyed(pid: pid_t, cgWindowID: CGWindowID) {
        guard var app = apps[pid] else { return }
        destroyedCGIDs[cgWindowID] = Date()
        app.windowsByID.removeValue(forKey: cgWindowID)
        app.windowOrder.removeAll { $0 == cgWindowID }
        apps[pid] = app
        rebuildSnapshot()
    }

    private func handleWindowMinimized(pid: pid_t, cgWindowID: CGWindowID) {
        apps[pid]?.windowsByID[cgWindowID]?.isMinimized = true
        apps[pid]?.windowsByID[cgWindowID]?.isFocused = false
        rebuildSnapshot()
    }

    private func handleWindowDeminiaturized(pid: pid_t, cgWindowID: CGWindowID) {
        apps[pid]?.windowsByID[cgWindowID]?.isMinimized = false
        rebuildSnapshot()
    }

    private func handleFocusedWindowChanged(pid: pid_t) {
        enumerateWindows(for: pid)
    }

    private func handleTitleChanged(pid: pid_t, cgWindowID: CGWindowID) {
        enumerateWindows(for: pid)
    }

    // MARK: - Reconcile

    private func startReconcileTimer() {
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        reconcileTimer?.tolerance = 0.5
    }

    // 前台快轮询：原生标签组（如 Ghostty）切标签时 AX 可能完全不报，且 min 误报滞后数秒。
    // 真相在 CG on-screen 集合——切标签时它即时变化。对**前台且多窗口**的 app 以 0.5s 检测：
    // on-screen 变了（切了标签）就重建，标签组可见标签随之即时更新。同时顺带补 AX 标题/焦点。
    // 单窗口 app 无歧义，直接跳过，平时零开销。
    private func startFrontmostPollTimer() {
        frontmostPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollFrontmostApp() }
        }
        frontmostPollTimer?.tolerance = 0.05
    }

    private func pollFrontmostApp() {
        guard AXIsProcessTrusted() else { return }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              var app = apps[pid], app.windowOrder.count > 1 else { return }

        let snapshots = reader.windows(forPID: pid)
        let eligible = snapshots.filter {
            isEligible($0, bundleIdentifier: app.bundleIdentifier, activationPolicy: app.activationPolicy)
        }

        var changed = false
        for snap in eligible {
            guard let cgID = snap.cgWindowID, var entry = app.windowsByID[cgID] else { continue }
            let titleChanged = snap.title.map { !$0.isEmpty && $0 != entry.title } ?? false
            let stateChanged = snap.isMinimized != entry.isMinimized || snap.isFocusedWindow != entry.isFocused
            if titleChanged || stateChanged {
                if let t = snap.title, !t.isEmpty { entry.title = t }
                entry.isMinimized = snap.isMinimized
                entry.isFocused = snap.isFocusedWindow
                app.windowsByID[cgID] = entry
                apps[pid] = app
                changed = true
            }
        }

        // 切标签的即时信号：哪个标签在屏变了 → 重建（rebuildSnapshot 会读最新 on-screen 并刷新）。
        if onScreenCGWindowIDSet() != lastOnScreenCGIDs { changed = true }

        if changed { rebuildSnapshot() }
    }

    private func reconcile() {
        guard AXIsProcessTrusted() else { return }
        purgeStaleTombstones()
        var changed = false

        // Remove entries for processes that no longer exist. This handles multi-process apps where
        // didTerminateApplicationNotification fires for the host pid while the window was tracked
        // under a different pid — the workspace notification removes the wrong entry and the
        // tracked pid's app entry stays indefinitely.
        var deadPIDs: [pid_t] = []
        for pid in appOrder {
            if NSRunningApplication(processIdentifier: pid) == nil {
                deadPIDs.append(pid)
                logger.info("reconcile: pid=\(pid) no longer exists, removing stale entry")
            }
        }
        for pid in deadPIDs {
            observers[pid]?.stop()
            observers.removeValue(forKey: pid)
            apps.removeValue(forKey: pid)
            appOrder.removeAll { $0 == pid }
            changed = true
        }

        // Snapshot CG window set once for the entire reconcile pass
        let cgIDs = cgWindowIDSet()

        for pid in appOrder {
            guard var app = apps[pid] else { continue }
            let snapshots = reader.windows(forPID: pid)
            let eligible = snapshots.filter {
                isEligible($0, bundleIdentifier: app.bundleIdentifier, activationPolicy: app.activationPolicy)
            }
            let liveIDs = Set(eligible.compactMap(\.cgWindowID))
            let trackedIDs = Set(app.windowOrder)

            // Remove or CG-veto windows that AX no longer enumerates
            for cgID in trackedIDs.subtracting(liveIDs) {
                if cgIDs.contains(cgID) && !isTombstoned(cgID) {
                    // Still in CG → minimized; AX just can't enumerate it
                    app.windowsByID[cgID]?.isMinimized = true
                    app.windowsByID[cgID]?.isFocused = false
                    apps[pid] = app
                    changed = true
                } else {
                    // Not in CG, or recently destroyed → truly closed
                    app.windowsByID.removeValue(forKey: cgID)
                    app.windowOrder.removeAll { $0 == cgID }
                    apps[pid] = app
                    changed = true
                }
            }

            // Add newly discovered windows
            for snap in eligible {
                guard let cgID = snap.cgWindowID, !trackedIDs.contains(cgID) else { continue }
                app.windowsByID[cgID] = WindowEntry(
                    cgWindowID: cgID,
                    title: snap.title ?? "",
                    bounds: snap.bounds,
                    isMinimized: snap.isMinimized,
                    isFocused: snap.isFocusedWindow
                )
                app.windowOrder.append(cgID)
                observers[pid]?.registerWindow(snap.element, cgWindowID: cgID)
                apps[pid] = app
                changed = true
            }

            // Update attributes of AX-visible windows
            for snap in eligible {
                guard let cgID = snap.cgWindowID, var entry = app.windowsByID[cgID] else { continue }
                let titleChanged = snap.title.map { !$0.isEmpty && $0 != entry.title } ?? false
                let stateChanged = snap.isMinimized != entry.isMinimized || snap.isFocusedWindow != entry.isFocused
                if titleChanged || stateChanged {
                    if let t = snap.title, !t.isEmpty { entry.title = t }
                    entry.isMinimized = snap.isMinimized
                    entry.isFocused = snap.isFocusedWindow
                    app.windowsByID[cgID] = entry
                    apps[pid] = app
                    changed = true
                }
            }
        }

        if changed { rebuildSnapshot() }
        scanNonAdmittedApps()
    }

    private func scanNonAdmittedApps() {
        guard !isScanningCandidates else { return }
        let candidatePIDs: [pid_t] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard isRegularNonSelf(app), !app.isTerminated, apps[app.processIdentifier] == nil else { return nil }
            return app.processIdentifier
        }
        guard !candidatePIDs.isEmpty else { return }

        isScanningCandidates = true
        let reader = self.reader

        Task.detached { [weak self] in
            var found: [pid_t] = []
            for pid in candidatePIDs {
                let result = reader.inventoryWindows(forPID: pid, messagingTimeout: 0.1)
                if case .success(let snaps) = result, !snaps.isEmpty {
                    found.append(pid)
                }
            }
            let pidsWithWindows = found

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isScanningCandidates = false
                var admitted = false
                for pid in pidsWithWindows {
                    guard self.apps[pid] == nil,
                          let app = NSRunningApplication(processIdentifier: pid),
                          !app.isTerminated else { continue }
                    self.addApp(app, enumerateImmediately: true)
                    admitted = true
                }
                if admitted { self.rebuildSnapshot() }
            }
        }
    }

    // MARK: - Snapshot Building

    private func rebuildSnapshot() {
        // Read frontmost PID once; passed to windowStatus to determine active highlight
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // 原生标签组可见性的可靠真相源：CG on-screen 列表只含「当前真正在屏」的窗口。标签组里
        // 后台标签是被 order-out 的独立 NSWindow，不在该列表；每组恰好留 1 个可见标签（实测）。
        // 用它判定标签组成员的可见/最小化，压掉 AX min 那 ~4s 滞后误报（切标签延迟/变灰的根因）。
        let onScreen = onScreenCGWindowIDSet()
        lastOnScreenCGIDs = onScreen
        let groupedIDs = tabGroupedWindowIDs()

        var windows: [WindowID: WindowRecord] = [:]
        var orderedWindowIDs: [WindowID] = []

        for pid in appOrder {
            guard let app = apps[pid] else { continue }

            if app.windowOrder.isEmpty {
                let key = app.bundleIdentifier ?? app.appName
                let id = WindowID(rawValue: "app-\(key)")
                windows[id] = WindowRecord(
                    id: id,
                    appID: AppID(rawValue: app.bundleIdentifier ?? app.appName),
                    pid: pid,
                    bundleIdentifier: app.bundleIdentifier,
                    title: app.appName,
                    bounds: nil,
                    status: app.isHidden ? .hidden : .inactive,
                    isOnDesktop: pid == frontmostPID
                )
                orderedWindowIDs.append(id)
            } else {
                for cgID in app.windowOrder {
                    guard let window = app.windowsByID[cgID] else { continue }
                    let id = WindowID(rawValue: "cgw-\(cgID)")
                    // 标签组成员（同 frame ≥2）：可见性以 CG on-screen 为准——不在屏即视为最小化，
                    // 且不可能聚焦。非标签组窗口（单窗口等）维持 AX 判定不变。
                    let grouped = groupedIDs.contains(cgID)
                    let effectiveMinimized = grouped ? !onScreen.contains(cgID) : window.isMinimized
                    let effectiveFocused = grouped ? (window.isFocused && onScreen.contains(cgID)) : window.isFocused
                    windows[id] = WindowRecord(
                        id: id,
                        appID: AppID(rawValue: app.bundleIdentifier ?? app.appName),
                        pid: pid,
                        bundleIdentifier: app.bundleIdentifier,
                        title: window.title,
                        bounds: window.bounds,
                        status: windowStatus(isHidden: app.isHidden, isMinimized: effectiveMinimized, isFocused: effectiveFocused, pid: pid, frontmostPID: frontmostPID),
                        cgWindowID: cgID,
                        isOnDesktop: !effectiveMinimized && !app.isHidden
                    )
                    orderedWindowIDs.append(id)
                }
            }
        }

        snapshot = DockSnapshot(windows: windows, orderedWindowIDs: orderedWindowIDs)
    }

    private func windowStatus(isHidden: Bool, isMinimized: Bool, isFocused: Bool, pid: pid_t, frontmostPID: pid_t?) -> WindowStatus {
        if isHidden { return .hidden }
        if isMinimized { return .minimized }
        if isFocused && pid == frontmostPID { return .active }
        return .inactive
    }

    private func isRegularNonSelf(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular &&
        app.bundleIdentifier != DockWindowEligibilityPolicy.selfBundleIdentifier
    }
}
