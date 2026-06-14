import AppKit
import Combine
import CoreGraphics
import Foundation
import os

@MainActor
final class AppRuntime: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot = .empty
    @Published private(set) var hasRequiredPermissions: Bool = false
    @Published private(set) var feedbackEntriesByWindowID: [String: IntentFeedbackState.Entry] = [:]
    /// 乐观状态 overlay（见 OptimisticWindowState 注释）。UI 渲染与 toggle 规划
    /// 优先读这里；快照兑现预测或超时（静默回弹）后清除。
    @Published private(set) var optimisticStatesByWindowID: [String: OptimisticWindowState] = [:]
    @Published private(set) var observationStatusText: String = "正在启动"

    private let tracker = AppTracker()
    private let intentPipeline = IntentPipeline(actionPlanning: LifecycleActionPlanner())
    private let actionExecutor = PlatformActionExecutor()
    private let permissionService = PermissionService()
    private var snapshotSubscription: AnyCancellable?
    private var feedbackTimer: Timer?
    private var startedAt: Date?
    var onToggleDrawer: (() -> Void)?

    private let debugSnapshotLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "debug-snapshot")
    private let chipProbeLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "ChipProbe")

    func start() {
        guard snapshotSubscription == nil else { return }
        startedAt = Date()
        hasRequiredPermissions = permissionService.hasRequiredPermissions()
        tracker.start()

        snapshotSubscription = tracker.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSnapshot in
                self?.handleSnapshotUpdate(newSnapshot)
            }

        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFeedback() }
        }
        feedbackTimer?.tolerance = 0.05
    }

    func stop() {
        tracker.stop()
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        feedbackTimer?.invalidate()
        feedbackTimer = nil
    }

    deinit {
        feedbackTimer?.invalidate()
        snapshotSubscription?.cancel()
    }

    func exportDebugSnapshot() {
        do {
            let url = try TaskbarDebugSnapshotExporter.export(snapshot: snapshot)
            debugSnapshotLogger.info("exported debug snapshot path=\(url.path, privacy: .public)")
        } catch {
            debugSnapshotLogger.error("export failed error=\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Actions

    func toggle(windowID: String) { trigger(.toggle(WindowID(rawValue: windowID))) }
    func activate(windowID: String) { trigger(.activate(WindowID(rawValue: windowID))) }
    func minimize(windowID: String) { trigger(.minimize(WindowID(rawValue: windowID))) }
    func hide(windowID: String) { trigger(.hide(WindowID(rawValue: windowID))) }
    func close(windowID: String) { trigger(.close(WindowID(rawValue: windowID))) }
    func quit(windowID: String) { trigger(.quit(WindowID(rawValue: windowID))) }
    func newWindow(windowID: String) { trigger(.newWindow(WindowID(rawValue: windowID))) }

    // MARK: - Private

    private func trigger(_ intent: UserIntent) {
        // 可打断（2026-06-13）：显隐类动作不再锁 pending —— 执行本身是几十毫秒的
        // 一次性 AX 调用，没有需要取消的并发；一致性靠乐观 overlay 驱动规划 +
        // 真实快照最终对账。只有 close / quit（窗口会消失）保持锁到确认。
        switch intent.action {
        case .close, .quit:
            guard intentPipeline.canBegin(intent: intent) else { return }
        default:
            break
        }
        let request = intentPipeline.plan(
            intent: intent,
            snapshot: snapshot,
            optimisticStates: optimisticStatesByWindowID
        )

        // ChipProbe: log chip state + planned action at tap time (main thread, no AX)
        if case .toggle(let wid) = intent, let record = snapshot.windows[wid] {
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let appIsFrontmost = frontPID == record.pid
            let runningApp = NSRunningApplication(processIdentifier: record.pid)
            let policyStr: String
            switch runningApp?.activationPolicy {
            case .regular: policyStr = "regular"
            case .accessory: policyStr = "accessory"
            case .prohibited: policyStr = "prohibited"
            default: policyStr = "nil"
            }
            chipProbeLogger.info("toggle-planned app=\(runningApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(record.bundleIdentifier ?? "(none)", privacy: .public) activationPolicy=\(policyStr, privacy: .public) status=\(record.status.rawValue, privacy: .public) isOnDesktop=\(record.isOnDesktop, privacy: .public) appIsFrontmost=\(appIsFrontmost, privacy: .public) plannedAction=\(request.kind.rawValue, privacy: .public)")
        }

        applyOptimisticState(for: request)
        intentPipeline.registerPending(intent: intent, request: request)
        feedbackEntriesByWindowID = intentPipeline.feedbackState.entriesByWindowID

        let executor = actionExecutor
        let capturedSnapshot = snapshot
        Task.detached { [weak self] in
            let success = executor.execute(request, snapshot: capturedSnapshot)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.intentPipeline.registerExecutionResult(intent: intent, request: request, success: success)
                self.feedbackEntriesByWindowID = self.intentPipeline.feedbackState.entriesByWindowID
            }
        }
    }

    private func handleSnapshotUpdate(_ newSnapshot: DockSnapshot) {
        snapshot = newSnapshot
        hasRequiredPermissions = permissionService.hasRequiredPermissions()
        intentPipeline.reconcile(with: newSnapshot)
        feedbackEntriesByWindowID = intentPipeline.feedbackState.entriesByWindowID
        reconcileOptimisticStates()
        if startedAt != nil {
            let ms = Int(Date().timeIntervalSince(startedAt!) * 1000)
            observationStatusText = hasRequiredPermissions ? "实时 \(ms)ms" : "仅窗口列表"
            startedAt = nil
        }
    }

    private func tickFeedback() {
        intentPipeline.reconcile(with: snapshot)
        feedbackEntriesByWindowID = intentPipeline.feedbackState.entriesByWindowID
        reconcileOptimisticStates()
    }

    // MARK: - Optimistic Overlay

    /// 超时上限对齐 pending retention（IntentFeedbackState.FeedbackPhase.pending）。
    private static let optimisticTimeout: TimeInterval = 4.0

    /// 按计划出的动作写预测态。hideApp 只盖被点的那张 chip，同 app 其他窗口
    /// 等快照（v1 接受）。close / quit / newWindow 不写（窗口要消失 / 是别的窗口）。
    private func applyOptimisticState(for request: PlatformActionRequest) {
        let state: OptimisticWindowState?
        switch request.kind {
        case .activateWindow:
            state = OptimisticWindowState(status: .active, isAppFrontmost: true, createdAt: Date())
        case .minimizeWindow:
            state = OptimisticWindowState(status: .minimized, isAppFrontmost: false, createdAt: Date())
        case .hideApp:
            state = OptimisticWindowState(status: .hidden, isAppFrontmost: false, createdAt: Date())
        case .closeWindow, .quitApp, .newWindow:
            state = nil
        }
        guard let state, let windowID = request.windowID else { return }
        optimisticStatesByWindowID[windowID.rawValue] = state
    }

    /// 兑现 / 回滚：真实快照达到预测态（或窗口消失）→ 清除；超时没兑现 → 静默
    /// 回弹到真实态（不加额外提示，AX 动作失败本身罕见）。
    private func reconcileOptimisticStates(now: Date = Date()) {
        guard !optimisticStatesByWindowID.isEmpty else { return }
        let next = optimisticStatesByWindowID.filter { windowID, state in
            if now.timeIntervalSince(state.createdAt) > Self.optimisticTimeout { return false }
            guard let record = snapshot.windows[WindowID(rawValue: windowID)] else { return false }
            return !Self.optimisticConfirmed(predicted: state.status, actual: record.status)
        }
        if next != optimisticStatesByWindowID {
            optimisticStatesByWindowID = next
        }
    }

    /// 对齐 feedback reconcile 的口径：minimize / hide 可能短暂表现为 disappeared
    ///（Finder 最小化反馈 bug 的教训），也算兑现。
    private static func optimisticConfirmed(predicted: WindowStatus, actual: WindowStatus) -> Bool {
        if predicted == actual { return true }
        if (predicted == .minimized || predicted == .hidden) && actual == .disappeared { return true }
        return false
    }
}

// MARK: - Debug Snapshot Export

private enum TaskbarDebugSnapshotExporter {
    static func export(snapshot: DockSnapshot, generatedAt: Date = Date()) throws -> URL {
        let report = TaskbarDebugReport(snapshot: snapshot, generatedAt: generatedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(report)
        let timestamp = fileTimestamp.string(from: generatedAt)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macos-dock-cc-v2-debug-snapshot-\(timestamp).json")
        let latestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macos-dock-cc-v2-debug-snapshot-latest.json")
        try data.write(to: url, options: .atomic)
        try data.write(to: latestURL, options: .atomic)
        return url
    }

    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private struct TaskbarDebugReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let trackedCount: Int
    let visibleCount: Int
    let cards: [TaskbarDebugCard]
    let duplicateGroups: [TaskbarDebugDuplicateGroup]
    let liveWindows: [TaskbarDebugLiveWindow]

    init(snapshot: DockSnapshot, generatedAt: Date) {
        let records = snapshot.orderedWindowIDs.compactMap { snapshot.windows[$0] }
        let liveWindows = TaskbarDebugLiveWindow.sample(for: records)
        let duplicateGroupsByKey = Dictionary(grouping: records) { record in
            TaskbarDebugReport.duplicateKey(for: record)
        }
        let duplicateKeys = Set(
            duplicateGroupsByKey.compactMap { key, groupedRecords in
                groupedRecords.count > 1 ? key : nil
            }
        )

        self.schemaVersion = 1
        self.generatedAt = generatedAt
        self.trackedCount = records.count
        self.visibleCount = records.filter { $0.status != .disappeared }.count
        self.liveWindows = liveWindows
        self.duplicateGroups = duplicateGroupsByKey
            .compactMap { key, groupedRecords in
                guard groupedRecords.count > 1 else { return nil }
                return TaskbarDebugDuplicateGroup(
                    key: key,
                    count: groupedRecords.count,
                    ids: groupedRecords.map(\.id.rawValue),
                    titles: groupedRecords.map(\.title)
                )
            }
            .sorted { $0.key < $1.key }
        self.cards = records.enumerated().map { index, record in
            TaskbarDebugCard(
                order: index,
                record: record,
                duplicateKey: Self.duplicateKey(for: record),
                isDuplicateCandidate: duplicateKeys.contains(Self.duplicateKey(for: record)),
                liveWindows: liveWindows
            )
        }
    }

    private static func duplicateKey(for record: WindowRecord) -> String {
        let app = record.bundleIdentifier ?? record.appID.rawValue
        return "\(record.pid)|\(app)|\(TaskbarDebugRect.signature(for: record.bounds))"
    }
}

private struct TaskbarDebugCard: Codable {
    let order: Int
    let id: String
    let title: String
    let status: String
    let pid: Int32
    let bundleIdentifier: String?
    let appID: String
    let bounds: TaskbarDebugRect?
    let duplicateKey: String
    let processAlive: Bool
    let liveAXTitleMatches: Int
    let liveAXMinimizedTitleMatches: Int
    let liveAXFrameMatches: Int
    let liveAXTitleFrameMatches: Int
    let liveCGFrameMatches: Int
    let liveCGTitleFrameMatches: Int
    let classification: String

    init(
        order: Int,
        record: WindowRecord,
        duplicateKey: String,
        isDuplicateCandidate: Bool,
        liveWindows: [TaskbarDebugLiveWindow]
    ) {
        let matchingLiveWindows = liveWindows.filter { $0.pid == record.pid }
        let axTitleMatches = Self.titleMatches(record: record, liveWindows: matchingLiveWindows, source: "ax")
        let axMinimizedTitleMatches = axTitleMatches.filter { $0.isMinimized == true }
        let axFrameMatches = Self.frameMatches(record: record, liveWindows: matchingLiveWindows, source: "ax")
        let axTitleFrameMatches = axFrameMatches.filter { Self.titleMatches(record.title, $0.title) }
        let cgFrameMatches = Self.frameMatches(record: record, liveWindows: matchingLiveWindows, source: "cg")
        let cgTitleFrameMatches = cgFrameMatches.filter { Self.titleMatches(record.title, $0.title) }
        let processAlive = Self.isProcessAlive(pid: record.pid)

        self.order = order
        self.id = record.id.rawValue
        self.title = record.title
        self.status = record.status.rawValue
        self.pid = record.pid
        self.bundleIdentifier = record.bundleIdentifier
        self.appID = record.appID.rawValue
        self.bounds = record.bounds.map(TaskbarDebugRect.init)
        self.duplicateKey = duplicateKey
        self.processAlive = processAlive
        self.liveAXTitleMatches = axTitleMatches.count
        self.liveAXMinimizedTitleMatches = axMinimizedTitleMatches.count
        self.liveAXFrameMatches = axFrameMatches.count
        self.liveAXTitleFrameMatches = axTitleFrameMatches.count
        self.liveCGFrameMatches = cgFrameMatches.count
        self.liveCGTitleFrameMatches = cgTitleFrameMatches.count
        self.classification = Self.classification(
            record: record,
            processAlive: processAlive,
            isDuplicateCandidate: isDuplicateCandidate,
            axTitleMatches: axTitleMatches.count,
            axMinimizedTitleMatches: axMinimizedTitleMatches.count,
            axFrameMatches: axFrameMatches.count,
            axTitleFrameMatches: axTitleFrameMatches.count,
            cgFrameMatches: cgFrameMatches.count,
            cgTitleFrameMatches: cgTitleFrameMatches.count
        )
    }

    private static func classification(
        record: WindowRecord,
        processAlive: Bool,
        isDuplicateCandidate: Bool,
        axTitleMatches: Int,
        axMinimizedTitleMatches: Int,
        axFrameMatches: Int,
        axTitleFrameMatches: Int,
        cgFrameMatches: Int,
        cgTitleFrameMatches: Int
    ) -> String {
        if isDuplicateCandidate { return "duplicate-candidate-same-pid-bundle-frame" }
        if !processAlive { return "stale-process-dead" }
        if record.status == .minimized, axFrameMatches > 0 || axMinimizedTitleMatches > 0 {
            return "retained-minimized-ax-present"
        }
        if record.status == .hidden, axFrameMatches > 0 || axTitleMatches == 1 {
            return "retained-hidden-ax-present"
        }
        if axTitleFrameMatches > 0 || cgTitleFrameMatches > 0 { return "live-title-frame-match" }
        if axFrameMatches > 0 || cgFrameMatches > 0 { return "title-drift-candidate" }
        if processAlive { return "missing-live-window-candidate" }
        return "unknown"
    }

    private static func frameMatches(
        record: WindowRecord,
        liveWindows: [TaskbarDebugLiveWindow],
        source: String
    ) -> [TaskbarDebugLiveWindow] {
        guard let bounds = record.bounds else { return [] }
        return liveWindows.filter { liveWindow in
            guard liveWindow.source == source, let liveBounds = liveWindow.bounds else { return false }
            return WindowFrameMatchPolicy.areClose(bounds, liveBounds.cgRect)
        }
    }

    private static func titleMatches(
        record: WindowRecord,
        liveWindows: [TaskbarDebugLiveWindow],
        source: String
    ) -> [TaskbarDebugLiveWindow] {
        liveWindows.filter { $0.source == source && titleMatches(record.title, $0.title) }
    }

    private static func titleMatches(_ lhs: String, _ rhs: String?) -> Bool {
        let lhs = normalizedTitle(lhs)
        let rhs = normalizedTitle(rhs)
        return !lhs.isEmpty && lhs == rhs
    }

    private static func normalizedTitle(_ title: String?) -> String {
        let scalars = title?.unicodeScalars.filter { scalar in
            scalar.value != 0x200B && scalar.value != 0x200C
                && scalar.value != 0x200D && scalar.value != 0x2060
                && scalar.value != 0xFEFF
        } ?? []
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func isProcessAlive(pid: pid_t) -> Bool {
        errno = 0
        let result = kill(pid, 0)
        if result == 0 || errno == EPERM { return true }
        return errno != ESRCH && NSRunningApplication(processIdentifier: pid)?.isTerminated == false
    }
}

private struct TaskbarDebugDuplicateGroup: Codable {
    let key: String
    let count: Int
    let ids: [String]
    let titles: [String]
}

private struct TaskbarDebugLiveWindow: Codable {
    let source: String
    let pid: Int32
    let bundleIdentifier: String?
    let title: String?
    let bounds: TaskbarDebugRect?
    let isMinimized: Bool?

    static func sample(for records: [WindowRecord]) -> [TaskbarDebugLiveWindow] {
        let pids = Set(records.map(\.pid))
        return sampleAXWindows(for: pids) + sampleCGWindows(for: pids)
    }

    private static func sampleAXWindows(for pids: Set<Int32>) -> [TaskbarDebugLiveWindow] {
        let reader = AXWindowReader()
        return pids.flatMap { pid in
            switch reader.inventoryWindows(forPID: pid, messagingTimeout: 0.10) {
            case let .success(windows):
                let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                return windows.map { window in
                    TaskbarDebugLiveWindow(
                        source: "ax",
                        pid: pid,
                        bundleIdentifier: bundleIdentifier,
                        title: window.title,
                        bounds: window.bounds.map(TaskbarDebugRect.init),
                        isMinimized: window.isMinimized
                    )
                }
            case .unread:
                return []
            }
        }
    }

    private static func sampleCGWindows(for pids: Set<Int32>) -> [TaskbarDebugLiveWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        return rawList.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else { return nil }
            let title = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bounds = (info[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }

            return TaskbarDebugLiveWindow(
                source: "cg",
                pid: pid,
                bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                title: title?.isEmpty == false ? title : nil,
                bounds: bounds.map(TaskbarDebugRect.init),
                isMinimized: false
            )
        }
    }
}

private struct TaskbarDebugRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    static func signature(for rect: CGRect?) -> String {
        guard let rect else { return "no-frame" }
        return "\(Int(rect.origin.x.rounded())):\(Int(rect.origin.y.rounded())):\(Int(rect.width.rounded())):\(Int(rect.height.rounded()))"
    }
}
