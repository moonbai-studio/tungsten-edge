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
    private var isScanningCandidates = false

    private let reader = AXWindowReader()
    private let eligibilityPolicy = DockWindowEligibilityPolicy()
    private let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "app-tracker")

    func start() {
        guard workspaceObservers.isEmpty else { return }
        seedRunningApps()
        subscribeWorkspaceNotifications()
        startReconcileTimer()
    }

    func stop() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        for obs in observers.values { obs.stop() }
        observers.removeAll()
        apps.removeAll()
        appOrder.removeAll()
        snapshot = .empty
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
            } else if cgIDs.contains(cgID) {
                // AX can't enumerate it but CG confirms it exists → minimized
                var entry = app.windowsByID[cgID] ?? WindowEntry(
                    cgWindowID: cgID, title: "", bounds: nil, isMinimized: true, isFocused: false
                )
                entry.isMinimized = true
                entry.isFocused = false
                newWindowsByID[cgID] = entry
                newOrder.append(cgID)
            }
            // else: not in AX, not in CG → truly closed; drop it
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

    // MARK: - Reconcile

    private func startReconcileTimer() {
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
    }

    private func reconcile() {
        guard AXIsProcessTrusted() else { return }
        var changed = false

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
                if cgIDs.contains(cgID) {
                    // Still in CG → minimized; AX just can't enumerate it
                    app.windowsByID[cgID]?.isMinimized = true
                    app.windowsByID[cgID]?.isFocused = false
                    apps[pid] = app
                    changed = true
                } else {
                    // Not in CG → truly closed
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
                    status: app.isHidden ? .hidden : .inactive
                )
                orderedWindowIDs.append(id)
            } else {
                for cgID in app.windowOrder {
                    guard let window = app.windowsByID[cgID] else { continue }
                    let id = WindowID(rawValue: "cgw-\(cgID)")
                    windows[id] = WindowRecord(
                        id: id,
                        appID: AppID(rawValue: app.bundleIdentifier ?? app.appName),
                        pid: pid,
                        bundleIdentifier: app.bundleIdentifier,
                        title: window.title,
                        bounds: window.bounds,
                        status: windowStatus(entry: window, isHidden: app.isHidden, pid: pid, frontmostPID: frontmostPID),
                        cgWindowID: cgID
                    )
                    orderedWindowIDs.append(id)
                }
            }
        }

        snapshot = DockSnapshot(windows: windows, orderedWindowIDs: orderedWindowIDs)
    }

    private func windowStatus(entry: WindowEntry, isHidden: Bool, pid: pid_t, frontmostPID: pid_t?) -> WindowStatus {
        if isHidden { return .hidden }
        if entry.isMinimized { return .minimized }
        if entry.isFocused && !entry.isMinimized && pid == frontmostPID { return .active }
        return .inactive
    }

    private func isRegularNonSelf(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular &&
        app.bundleIdentifier != DockWindowEligibilityPolicy.selfBundleIdentifier
    }
}
