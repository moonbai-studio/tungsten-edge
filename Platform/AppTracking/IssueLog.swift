import Darwin
import Foundation
import os

enum IssueKind: String, Codable, CaseIterable {
    case phantomHealed, appUnreadable, fullscreenFlapping, windowLiftStopped
    case tabFoldSplit, seatReleasedEarly, seatCreatedBySweep

    var isIssue: Bool {
        switch self {
        case .phantomHealed, .appUnreadable, .fullscreenFlapping, .windowLiftStopped: return true
        case .tabFoldSplit, .seatReleasedEarly, .seatCreatedBySweep: return false
        }
    }

    var sentence: String {
        switch self {
        case .phantomHealed: return String(localized: "An extra cell appeared")
        case .appUnreadable: return String(localized: "Its windows couldn't be read for a while; its cells may have lagged")
        case .fullscreenFlapping: return String(localized: "The taskbar kept showing and hiding around full screen")
        case .windowLiftStopped: return String(localized: "A maximized window couldn't be kept clear of the taskbar, so adjusting it was paused")
        case .tabFoldSplit, .seatReleasedEarly, .seatCreatedBySweep: return rawValue
        }
    }

    /// Shown beside each listed row so a self-healed event does not read as an open fault.
    var statusLabel: String {
        switch self {
        case .phantomHealed: return String(localized: "Fixed automatically")
        case .appUnreadable, .fullscreenFlapping, .windowLiftStopped: return String(localized: "Recorded")
        case .tabFoldSplit, .seatReleasedEarly, .seatCreatedBySweep: return ""
        }
    }
}

/// What the lift saw, not who caused it: a reverted frame may be the app, a tiling tool or the user.
enum IssueLiftStopReason: String, Codable {
    case didNotApply, reverted
}

/// The display a lift stop happened on, sampled at that moment: by the time the user copies
/// the report the external display may be unplugged or rescaled.
struct IssueScreen: Equatable {
    let width: Int
    let height: Int
    let scale: Double
    let builtIn: Bool
}

/// Only enum, numeric and boolean fields can cross the persistent-detail boundary.
struct IssueDetail: Codable, Equatable {
    var releaseReason: InventorySeatReleasedReason?
    var hasDestroyEvidence: Bool?
    var ageSeconds: Double?
    var consecutiveReads: Int?
    var toggles: Int?
    var liftStopReason: IssueLiftStopReason?
    var screenWidth: Int?
    var screenHeight: Int?
    var screenScale: Double?
    var builtInScreen: Bool?

    /// Splits aggregation so a built-in and an external display, or the two stop reasons,
    /// never fold into one entry that keeps only the last one's detail.
    var aggregationScope: String {
        guard let liftStopReason else { return "" }
        let screen = screenWidth.map { "\($0)x\(screenHeight ?? 0)@\(screenScale ?? 0)-\(builtInScreen == true)" }
        return liftStopReason.rawValue + "|" + (screen ?? "?")
    }
}

struct IssueEvent: Equatable {
    let kind: IssueKind
    var detail = IssueDetail()

    static func phantomHealed(didHeal: Bool) -> Self? {
        didHeal ? Self(kind: .phantomHealed) : nil
    }

    static func tabFoldSplit(isMinimized: Bool, hasPlacedSeat: Bool, createdNewSeat: Bool) -> Self? {
        isMinimized && hasPlacedSeat && createdNewSeat ? Self(kind: .tabFoldSplit) : nil
    }

    static func appUnreadable(consecutiveReads: Int) -> Self? {
        consecutiveReads == 3 ? Self(kind: .appUnreadable, detail: IssueDetail(consecutiveReads: 3)) : nil
    }

    static func fullscreenFlapping(toggles: Int, alreadyReported: Bool) -> Self? {
        toggles >= 4 && !alreadyReported ? Self(kind: .fullscreenFlapping, detail: IssueDetail(toggles: toggles)) : nil
    }

    static func seatReleasedEarly(_ seat: WindowEntry, reason: InventorySeatReleasedReason,
                                  hasDestroyEvidence: Bool, at: Date) -> Self? {
        let age = at.timeIntervalSince(seat.createdAt)
        guard age >= 0, age < 10, reason != .processGone else { return nil }
        return Self(kind: .seatReleasedEarly, detail: IssueDetail(
            releaseReason: reason, hasDestroyEvidence: reason == .leftCGList ? hasDestroyEvidence : nil,
            ageSeconds: age))
    }

    static func windowLiftStopped(reason: IssueLiftStopReason, screen: IssueScreen?) -> Self {
        Self(kind: .windowLiftStopped, detail: IssueDetail(
            liftStopReason: reason, screenWidth: screen?.width, screenHeight: screen?.height,
            screenScale: screen?.scale, builtInScreen: screen?.builtIn))
    }

    static func seatCreatedBySweep(alreadyTracked: Bool, source: InventoryReconcileSource, isNewSeat: Bool) -> Self? {
        alreadyTracked && source == .periodicReconcile && isNewSeat ? Self(kind: .seatCreatedBySweep) : nil
    }
}

struct IssueUnreadStreak {
    private(set) var count = 0

    mutating func read(source: InventoryReconcileSource, timed: Bool, unread: Bool) -> IssueEvent? {
        if !unread { count = 0; return nil }
        guard source == .periodicReconcile, timed else { return nil }
        count = min(4, count + 1)
        return IssueEvent.appUnreadable(consecutiveReads: count)
    }
}

/// A burst ends when its rolling ten-second window no longer meets the threshold.
struct IssueFullscreenBurst {
    private var fullscreenHide = false
    private var times: [Date] = []
    private var reported = false

    mutating func change(visible: Bool, fullscreenReason: Bool, at: Date) -> IssueEvent? {
        times.removeAll { at.timeIntervalSince($0) > 10 || $0 > at }
        let qualifies = visible ? fullscreenHide : fullscreenReason
        fullscreenHide = !visible && fullscreenReason
        if qualifies { times.append(at) }
        if times.count < 4 { reported = false }
        guard qualifies else { return nil }
        let event = IssueEvent.fullscreenFlapping(toggles: times.count, alreadyReported: reported)
        if event != nil { reported = true }
        return event
    }
}

struct IssueLogEntry: Codable, Equatable {
    var ts: Date
    let kind: IssueKind
    let bundleID: String
    var count: Int
    var detail: IssueDetail

    var rawLine: String {
        // The report carries the exact JSON object; its tier is an explicit report-only label.
        let line = (try? Self.encoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return kind.isIssue ? line : "observation " + line
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum IssueList {
    static func rows(_ entries: [IssueLogEntry], calendar: Calendar = .current) -> [IssueLogEntry] {
        struct Key: Hashable { let day: Date; let kind: IssueKind; let bundleID: String }
        var merged: [Key: IssueLogEntry] = [:]
        for entry in entries where entry.kind.isIssue {
            let key = Key(day: calendar.startOfDay(for: entry.ts), kind: entry.kind, bundleID: entry.bundleID)
            if let previous = merged[key] {
                var latest = entry.ts > previous.ts ? entry : previous
                latest.count = previous.count + entry.count
                merged[key] = latest
            } else { merged[key] = entry }
        }
        return merged.values.sorted {
            if $0.ts != $1.ts { return $0.ts > $1.ts }
            if $0.bundleID != $1.bundleID { return $0.bundleID < $1.bundleID }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }
}

final class IssueLog {
    // Unit tests recompile app sources and drive real AppTracker paths; without this the
    // release preflight's test run would write fake events into the user's own issue log.
    static let shared = IssueLog(enabled: DebugSwitch.issueLog.isEnabled() && NSClassFromString("XCTestCase") == nil)
    static let retention: TimeInterval = 14 * 24 * 60 * 60
    static let byteLimit = 256 * 1024
    static let aggregationInterval: TimeInterval = 10 * 60

    private struct Key: Hashable { let kind: IssueKind; let bundleID: String; let scope: String }
    private struct Pending { let openedAt: Date; var entry: IssueLogEntry }
    private let queue = DispatchQueue(label: "com.caye.macosdockcc.v2.issue-log", qos: .utility)
    private let directory: URL
    private let enabled: Bool
    private let now: () -> Date
    private let schedulesTimer: Bool
    private let aggregationInterval: TimeInterval
    private var pending: [Key: Pending] = [:]
    private var timer: DispatchSourceTimer?
    private var failed = false
    var fileURL: URL { directory.appendingPathComponent("issues.jsonl") }

    init(directory: URL = WindowInventoryLogConfiguration.live().directoryURL,
         enabled: Bool = DebugSwitch.issueLog.isEnabled(), now: @escaping () -> Date = Date.init,
         schedulesTimer: Bool = true, aggregationInterval: TimeInterval = IssueLog.aggregationInterval) {
        self.directory = directory
        self.enabled = enabled
        self.now = now
        self.schedulesTimer = schedulesTimer
        self.aggregationInterval = aggregationInterval
        if enabled {
            queue.async { [self] in perform { try trim(at: now()) } }
        }
    }

    deinit { timer?.cancel() }

    func record(_ event: IssueEvent?, bundleID: String?, at: Date = Date()) {
        guard enabled, let event else { return }
        queue.async { [self] in
            perform {
                try flushClosed(at: at)
                let key = Key(kind: event.kind, bundleID: bundleID ?? "unknown", scope: event.detail.aggregationScope)
                if var value = pending[key] {
                    value.entry.count += 1
                    value.entry.ts = max(value.entry.ts, at)
                    value.entry.detail = event.detail
                    pending[key] = value
                } else {
                    pending[key] = Pending(openedAt: at, entry: IssueLogEntry(
                        ts: at, kind: event.kind, bundleID: key.bundleID, count: 1, detail: event.detail))
                }
                armTimer()
            }
        }
    }

    /// A read never seals an open aggregation window.
    func entries() -> [IssueLogEntry] {
        guard enabled else { return [] }
        return queue.sync { snapshot() }
    }

    func reportLines() -> [String] {
        guard enabled else { return [] }
        return queue.sync { snapshot().suffix(50).map(\.rawLine) }
    }

    private func snapshot() -> [IssueLogEntry] {
        guard !failed else { return [] }
        let cutoff = now().addingTimeInterval(-Self.retention)
        return (readEntries() + pending.values.map(\.entry)).filter { $0.ts >= cutoff }
            .sorted { $0.ts < $1.ts }
    }

    /// Termination is the only caller that seals windows before their deadlines.
    func flush() {
        guard enabled else { return }
        queue.sync {
            perform {
                for value in pending.values.sorted(by: { $0.entry.ts < $1.entry.ts }) { try append(value.entry) }
                pending.removeAll()
                timer?.cancel()
                timer = nil
            }
        }
    }

    func flushClosedWindows(at: Date) {
        queue.sync { perform { try flushClosed(at: at) } }
    }

    private func flushClosed(at: Date) throws {
        let closed = pending.filter { at.timeIntervalSince($0.value.openedAt) >= aggregationInterval }
        for (key, value) in closed.sorted(by: { $0.value.entry.ts < $1.value.entry.ts }) {
            try append(value.entry)
            pending.removeValue(forKey: key)
        }
    }

    private func armTimer() {
        timer?.cancel()
        timer = nil
        guard schedulesTimer, let deadline = pending.values.map({ $0.openedAt }).min() else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, deadline.addingTimeInterval(aggregationInterval).timeIntervalSince(now())))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.perform { try self.flushClosed(at: self.now()); self.armTimer() }
        }
        self.timer = timer
        timer.resume()
    }

    private func readEntries() -> [IssueLogEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = IssueLogEntry.decoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(IssueLogEntry.self, from: Data($0)) }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func write(_ data: Data, append: Bool) throws {
        try prepareDirectory()
        let fd = Darwin.open(fileURL.path, O_WRONLY | O_CREAT | O_NOFOLLOW | (append ? O_APPEND : O_TRUNC), 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += written
            }
        }
    }

    private func append(_ entry: IssueLogEntry) throws {
        var data = try IssueLogEntry.encoder().encode(entry)
        data.append(0x0A)
        try write(data, append: true)
        let size = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > Self.byteLimit { try trim(at: now()) }
    }

    private func trim(at: Date) throws {
        let cutoff = at.addingTimeInterval(-Self.retention)
        let originalSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        var lines = try readEntries().filter { $0.ts >= cutoff }.sorted { $0.ts < $1.ts }.map { entry -> Data in
            var data = try IssueLogEntry.encoder().encode(entry)
            data.append(0x0A)
            return data
        }
        var bytes = lines.reduce(0) { $0 + $1.count }
        if originalSize > Self.byteLimit {
            let target = Self.byteLimit * 4 / 5
            while bytes > target, !lines.isEmpty { bytes -= lines.removeFirst().count }
        }
        try write(lines.reduce(into: Data()) { $0.append($1) }, append: false)
    }

    private func perform(_ action: () throws -> Void) {
        guard !failed else { return }
        do { try action() }
        catch {
            failed = true
            timer?.cancel()
            timer = nil
            Logger(subsystem: "com.caye.macosdockcc.v2", category: "issue-log")
                .error("问题记录写入失败，已停用：\(String(describing: error), privacy: .public)")
        }
    }
}
