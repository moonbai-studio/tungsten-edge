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

/// 一个**物理窗口座位**（单座位模型）。`cgWindowID` 是它**当前**的可见标签（= 动作落点），会随
/// 切标签而变；`token` 是座位的稳定身份，一旦分配**永不变**（即使 activeCgID 被顶替）——这就是
/// 切标签/最小化时卡片不跳不裂的根。后台标签【不】单独占座位。
struct WindowEntry {
    var cgWindowID: CGWindowID   // 当前可见标签的 cgID（动作落点），切标签时被顶替
    let token: String            // 物理座位稳定身份（tabgrp-<pid>-<种子cgID>），永不变
    var title: String
    var bounds: CGRect?
    var isMinimized: Bool
    var isFocused: Bool
    /// 这个座位从 AX 枚举里消失、却只有 CG 还留着的「起始时刻」(nil = 当前 AX 能看到)。
    /// 仅作「曾经 AX 缺席」的标记，用来在 AX 重新看到它时清零；【不据此回收座位】——实测
    /// Safari 等正常窗口一最小化就整个离开 AX，按缺席回收会误删。座位回收只看 CG 全列表是否消失。
    var absentSince: Date? = nil
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
    /// 一个「本来正常、却离开了 AX、但还赖在 CG 全列表」的座位，持续多久判定为关窗后残留并删。
    /// 给一点 grace 扛 AX 偶发漏读（真窗口短暂漏一两次不该被删）。最小化/隐藏的座位不走这条（豁免）。
    private static let closedReapGrace: TimeInterval = 1.5

    /// 上次重建快照时的 CG on-screen 集合。前台轮询据此发现「切标签」——AX 可能完全不报，
    /// 但 on-screen 集合会即时变化，变了就重建（标签组可见标签随之即时更新）。
    private var lastOnScreenCGIDs: Set<CGWindowID> = []

    /// 物理座位 token 的全局自增序号。保证每个新座位拿到唯一 token（绝不从会复用的 cgID 派生）。
    private var nextSeatSerial: Int = 0

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

    /// 「同 pid + 逐像素相同 frame」键。物理座位据此认领"切标签顶替"的新当前标签：同一物理窗口的
    /// 各标签 frame 完全一致，新当前标签会出现在座位当前的 frame 上。
    private func frameKey(_ pid: pid_t, _ bounds: CGRect?) -> String? {
        guard let b = bounds else { return nil }
        return "\(pid)|\(Int(b.origin.x.rounded())):\(Int(b.origin.y.rounded())):\(Int(b.size.width.rounded())):\(Int(b.size.height.rounded()))"
    }

    /// 物理座位对账（单座位模型 · 拽标签根治 step 1）。把一个 app 当前的 AX 合格窗口收敛成
    /// 「一个物理窗口 = 一个座位」。座位锚在 frame、token 一旦分配不随当前标签 cgID 变：
    /// - **切标签**：旧 activeCgID 离开 AX、新 cgID 在同 frame 顶上 → 座位原地换 activeCgID，token 不变（卡不跳）。
    /// - **拖当前标签出去**：旧 activeCgID 移到新 frame、另一标签在旧 frame 顶上 → 座位留旧 frame 换新标签，
    ///   旧 activeCgID 被「赶出」成新座位（拽出分卡）。
    /// - **最小化/后台无人顶替**：CG 还在就保座位标最小化，CG 没了才删（Safari 最小化不丢卡）。
    /// - 后台标签【不】单独留座位。同 frame 有多个老座位（窗口重叠）时不顶替、宁可新建，避免误并。
    /// 返回 true 表示座位集合或关键属性变了（调用方据此决定是否重建快照）。
    @discardableResult
    private func reconcileSeats(pid: pid_t, cgIDs: Set<CGWindowID>, now: Date) -> Bool {
        guard var app = apps[pid] else { return false }
        let eligible = reader.windows(forPID: pid).filter {
            isEligible($0, bundleIdentifier: app.bundleIdentifier, activationPolicy: app.activationPolicy)
        }
        let onScreenCGIDs = onScreenCGWindowIDSet()
        func fk(_ b: CGRect?) -> String? { frameKey(pid, b) }

        var eligibleByCgID: [CGWindowID: AXWindowSnapshot] = [:]
        for s in eligible { if let c = s.cgWindowID { eligibleByCgID[c] = s } }

        let before = seatSignature(app)
        var usedEligible: Set<CGWindowID> = []
        var newOrder: [CGWindowID] = []
        var newByID: [CGWindowID: WindowEntry] = [:]
        func place(_ e: WindowEntry) { newOrder.append(e.cgWindowID); newByID[e.cgWindowID] = e }
        func make(token: String, _ s: AXWindowSnapshot) -> WindowEntry {
            WindowEntry(cgWindowID: s.cgWindowID!, token: token, title: s.title ?? "",
                        bounds: s.bounds, isMinimized: s.isMinimized, isFocused: s.isFocusedWindow)
        }
        // 某 frame 当前有几个老座位认领（>1 = 窗口重叠歧义，切标签顶替时跳过，保守不误并）
        func seatsAtFrame(_ key: String) -> Int {
            app.windowOrder.filter { fk(app.windowsByID[$0]?.bounds) == key }.count
        }

        // Pass A：每个老座位尝试延续
        for cgID in app.windowOrder {
            guard var seat = app.windowsByID[cgID] else { continue }
            let X = seat.cgWindowID
            let seatKey = fk(seat.bounds)
            if let snapX = eligibleByCgID[X], !usedEligible.contains(X) {
                // X 仍可见。检查「拖当前标签出去」：X 移到了新 frame，旧 frame 上来了别的合格窗口 Y
                if let seatKey, fk(snapX.bounds) != seatKey,
                   let Y = eligible.first(where: { s in
                       guard let c = s.cgWindowID, c != X, !usedEligible.contains(c) else { return false }
                       return fk(s.bounds) == seatKey
                   }), let yc = Y.cgWindowID {
                    place(make(token: seat.token, Y))    // 座位留旧 frame、顶替成 Y，token 不变
                    usedEligible.insert(yc)
                    // X 不标 used → 落到 Pass B 成新座位（被赶出去的当前标签）
                } else {
                    place(make(token: seat.token, snapX))  // 普通：跟着 X（frame 可移动）
                    usedEligible.insert(X)
                }
            } else {
                // X 离开 AX：旧 frame 有没有新当前标签顶上 → 切标签
                if let seatKey, seatsAtFrame(seatKey) == 1,
                   let Y = eligible.first(where: { s in
                       guard let c = s.cgWindowID, !usedEligible.contains(c), app.windowsByID[c] == nil else { return false }
                       return fk(s.bounds) == seatKey
                   }), let yc = Y.cgWindowID {
                    place(make(token: seat.token, Y))    // 顶替，token 不变 → 卡不跳
                    usedEligible.insert(yc)
                } else if cgIDs.contains(X) && !isTombstoned(X) {
                    // X 离开 AX 但仍在 CG。区分「最小化/隐藏(保座位)」vs「关窗后窗口赖在 CG(该删)」:
                    // 信号 = 离开 AX 前最后一次是不是 min(最小化会先经 Miniaturized 通知标 min；关窗不会)。
                    if seat.isMinimized || app.isHidden {
                        seat.isFocused = false
                        seat.absentSince = nil
                        place(seat)                       // 真最小化(Safari 离开 AX)/ 应用隐藏 → 保座位
                    } else if let since = seat.absentSince, now.timeIntervalSince(since) >= Self.closedReapGrace {
                        // 正常窗口却离开 AX 且持续超过 grace → 判定关窗后赖在 CG,删座位（不 place）
                    } else {
                        if seat.absentSince == nil { seat.absentSince = now }
                        seat.isFocused = false
                        place(seat)                       // grace 内暂留(扛 AX 偶发漏读),【不强制标 min】
                    }
                }
                // else：连 CG 都没了 → 真关闭，丢弃
            }
        }

        // Pass B：没被认领的合格窗口 → 新座位（新窗口 / 被赶出去的当前标签）。
        // token 用全局自增序号,【绝不从 cgID 派生】——cgID 会被复用,从它派生会撞车（实测:旧座位
        // 种子=68、activeCgID 已换成 60,后来 68 独立成窗又生成同名 token → 两座位撞一张卡）。
        // **最小化折叠**：最小化一个多标签窗口时,Ghostty 会把该窗口的【所有标签】一下子都暴露成
        // AX 窗口(平时只暴露当前标签)。它们都 min=true——是同一个(已最小化)窗口的后台标签,折叠进
        // 已落座的座位,不另建座位（否则有几个标签就裂几张卡）。
        // 正常情况下 frame 精确匹配。特例：窗口被拖动后后台标签的 AX 坐标不会更新（order-out
        // 窗口不收 kAXWindowMovedNotification），导致后台标签 frame 与已移动的活跃标签 frame
        // 不一致 → 精确匹配失败。回退：同尺寸（宽高）+ 屏幕外 → 判定为同窗口后台标签，折叠。
        // 非 min 的同 frame 窗口是"两个独立窗口重叠"的合法场景,照常各自建座位。
        var placedFrames = Set(newOrder.compactMap { fk(newByID[$0]?.bounds) })
        for s in eligible {
            guard let c = s.cgWindowID, !usedEligible.contains(c), newByID[c] == nil else { continue }
            if s.isMinimized {
                let exactMatch = fk(s.bounds).map { placedFrames.contains($0) } ?? false
                // 窗口被移动后后台标签 AX 坐标过时：精确匹配失败时回退到尺寸匹配
                // 条件：屏幕外（非活跃标签）+ 与某个已放置的最小化座位宽高相同
                let sizeMatch: Bool = !exactMatch && !onScreenCGIDs.contains(c) && {
                    guard let sb = s.bounds else { return false }
                    return newOrder.contains { id in
                        guard let pb = newByID[id]?.bounds,
                              newByID[id]?.isMinimized == true else { return false }
                        return abs(pb.size.width  - sb.size.width)  < 3 &&
                               abs(pb.size.height - sb.size.height) < 3
                    }
                }()
                if exactMatch || sizeMatch {
                    usedEligible.insert(c)   // 后台标签 → 折叠进已有座位,不另建
                    continue
                }
            }
            nextSeatSerial += 1
            place(make(token: "tabgrp-\(pid)-s\(nextSeatSerial)", s))
            observers[pid]?.registerWindow(s.element, cgWindowID: c)
            if let key = fk(s.bounds) { placedFrames.insert(key) }
        }

        app.windowOrder = newOrder
        app.windowsByID = newByID
        apps[pid] = app
        return seatSignature(app) != before
    }

    /// 座位集合的轻量指纹（顺序 + token + 标题 + 最小化/焦点），用来判断这次对账有没有实际变化。
    private func seatSignature(_ app: AppEntry) -> String {
        app.windowOrder.map { id -> String in
            let e = app.windowsByID[id]
            return "\(id):\(e?.token ?? ""):\(e?.title ?? ""):\(e?.isMinimized == true ? 1 : 0):\(e?.isFocused == true ? 1 : 0)"
        }.joined(separator: "|")
    }

    // MARK: - Seed

    private func seedRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard isRegularNonSelf(app) else { continue }
            // Finder always gets a slot so its chip persists even when all windows are closed.
            if FinderWindowRules.isFinder(bundleIdentifier: app.bundleIdentifier) {
                addApp(app, enumerateImmediately: true)
                continue
            }
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
        if FinderWindowRules.isFinder(bundleIdentifier: app.bundleIdentifier) {
            // Remove any stale Finder entry left over from a quit/relaunch cycle,
            // then add the fresh entry with the new pid.
            if let stalePID = appOrder.first(where: {
                FinderWindowRules.isFinder(bundleIdentifier: apps[$0]?.bundleIdentifier)
            }), stalePID != app.processIdentifier {
                observers[stalePID]?.stop()
                observers.removeValue(forKey: stalePID)
                apps.removeValue(forKey: stalePID)
                appOrder.removeAll { $0 == stalePID }
            }
            addApp(app, enumerateImmediately: true)
            rebuildSnapshot()
            return
        }
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

        // Finder relaunches immediately via launchd. Keep the entry (no windows) so the chip
        // stays visible during the gap. handleAppLaunched will replace this stale entry with
        // the new pid when Finder comes back up.
        if FinderWindowRules.isFinder(bundleIdentifier: apps[pid]?.bundleIdentifier) {
            apps[pid]?.windowsByID = [:]
            apps[pid]?.windowOrder = []
            rebuildSnapshot()
            return
        }

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
        guard apps[pid] != nil else { return }
        if reconcileSeats(pid: pid, cgIDs: cgWindowIDSet(), now: Date()) {
            rebuildSnapshot()
        }
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
        guard apps[pid] != nil else { return }
        destroyedCGIDs[cgWindowID] = Date()
        // 不直接删座位：若这是某标签窗口的当前标签被关、而同一物理窗口还有别的标签顶上，
        // reconcileSeats 会让座位原地换 activeCgID、保住 token（卡不闪不换身份）。整窗关掉则真删。
        if reconcileSeats(pid: pid, cgIDs: cgWindowIDSet(), now: Date()) { rebuildSnapshot() }
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
              apps[pid] != nil else { return }

        // 单座位模型下：标签窗口切标签 = 座位 activeCgID 被顶替，reconcileSeats 即时收敛。
        // 前台 app 每 0.5s 跑一次,切标签/最小化/拽出都能秒级反映(不再依赖 AX 事件可靠性)。
        var changed = reconcileSeats(pid: pid, cgIDs: cgWindowIDSet(), now: Date())
        // on-screen 变了(切了标签)也强制刷新一次,兜住座位指纹没变但可见标签换了的边角。
        let onScreen = onScreenCGWindowIDSet()
        if onScreen != lastOnScreenCGIDs { changed = true }
        if changed { rebuildSnapshot() }
    }

    private func reconcile() {
        guard AXIsProcessTrusted() else { return }
        purgeStaleTombstones()
        let now = Date()
        var changed = false

        // Remove entries for processes that no longer exist. This handles multi-process apps where
        // didTerminateApplicationNotification fires for the host pid while the window was tracked
        // under a different pid — the workspace notification removes the wrong entry and the
        // tracked pid's app entry stays indefinitely.
        var deadPIDs: [pid_t] = []
        for pid in appOrder {
            if NSRunningApplication(processIdentifier: pid) == nil {
                // Finder's entry is intentionally kept alive across quit/relaunch cycles
                // (handleAppTerminated clears windows but preserves the slot).
                if FinderWindowRules.isFinder(bundleIdentifier: apps[pid]?.bundleIdentifier) { continue }
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
            if reconcileSeats(pid: pid, cgIDs: cgIDs, now: now) { changed = true }
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
        lastOnScreenCGIDs = onScreenCGWindowIDSet()

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
                    isOnDesktop: pid == frontmostPID,
                    groupID: id.rawValue   // 兜底卡自成一组，永不并入别人
                )
                orderedWindowIDs.append(id)
            } else {
                // 单座位模型：一个座位 = 一个物理窗口 = 一张卡。卡片稳定身份 = 座位 token（不随
                // 当前标签 cgID 变）；动作落点 = 当前 activeCgID。可见性直接用座位状态（当前标签
                // 离开 AX 即被新标签顶替，不会留陈旧 min；真最小化座位标 isMinimized）。
                for cgID in app.windowOrder {
                    guard let seat = app.windowsByID[cgID] else { continue }
                    let id = WindowID(rawValue: "cgw-\(cgID)")
                    windows[id] = WindowRecord(
                        id: id,
                        appID: AppID(rawValue: app.bundleIdentifier ?? app.appName),
                        pid: pid,
                        bundleIdentifier: app.bundleIdentifier,
                        title: seat.title,
                        bounds: seat.bounds,
                        status: windowStatus(isHidden: app.isHidden, isMinimized: seat.isMinimized, isFocused: seat.isFocused, pid: pid, frontmostPID: frontmostPID),
                        cgWindowID: cgID,
                        isOnDesktop: !seat.isMinimized && !app.isHidden,
                        groupID: seat.token
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
