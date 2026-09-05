import Darwin
import CoreGraphics
import Foundation
import os

enum InventoryReconcileSource: String, Codable {
    case seed
    case initialEnumeration
    case windowCreated
    case windowDestroyed
    case focusChanged
    case titleChanged
    case frontmostPoll
    case periodicReconcile
}

struct InventoryAXReadOutcome: Codable, Equatable {
    enum Kind: String, Codable {
        case success
        case unread
    }

    let kind: Kind
    let rawWindowCount: Int
    let errorCode: Int32?

    static func success(count: Int) -> Self {
        Self(kind: .success, rawWindowCount: count, errorCode: nil)
    }

    static func unread(errorCode: Int32) -> Self {
        Self(kind: .unread, rawWindowCount: 0, errorCode: errorCode)
    }
}

struct InventoryReconcileContext: Codable, Equatable {
    let roundID: UInt64
    let appReconcileOrdinal: UInt64
    let source: InventoryReconcileSource
    let gapMs: Int?
    let usedPreloadedAX: Bool
    let axReadOutcome: InventoryAXReadOutcome
}

enum InventoryReconcileReadMode: String, Codable {
    case timed
    case untimed
}

/// An unread reconcile round is recorded separately because it intentionally has no
/// `InventoryReconcileContext`: creating that context advances diagnostic round clocks.
struct InventoryReconcileUnreadPayload: Codable, Equatable {
    let pid: Int32
    let bundleID: String?
    let source: InventoryReconcileSource
    let readMode: InventoryReconcileReadMode
    let usedPreloadedAX: Bool
    let errorCode: Int32
}

struct InventoryTitleHeldPayload: Codable, Equatable {
    let context: InventoryReconcileContext
    let pid: Int32
    let bundleID: String?
    let seatToken: String
    let activeCgID: CGWindowID
    let errorCode: Int32
}

struct InventoryLogRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.width)
        height = Double(rect.height)
    }
}

struct InventorySeatRelation: Codable, Equatable {
    let seatToken: String
    let activeCgID: CGWindowID
    let isMinimized: Bool
    let everSeenVisible: Bool
    let bounds: InventoryLogRect?
    let formerCgIDs: [CGWindowID]
    let formerContainsCandidate: Bool
    let normalizedTitleMatches: Bool
    let exactFrameMatches: Bool
    let nearbyFrameMatches: Bool
    let sizeMatches: Bool
}

enum InventorySeatCreationReason: String, Codable {
    case firstSeat
    case tearOut
    case minimizedFoldMiss
    case offscreenNonMinimized
    case visibleUnclaimed

    static func classify(
        hasPlacedSeat: Bool,
        isTearOut: Bool,
        isMinimized: Bool,
        isOnScreen: Bool
    ) -> Self {
        if !hasPlacedSeat { return .firstSeat }
        if isTearOut { return .tearOut }
        if isMinimized { return .minimizedFoldMiss }
        if !isOnScreen { return .offscreenNonMinimized }
        return .visibleUnclaimed
    }
}

struct InventoryPhantomOwner: Equatable {
    let seatToken: String
    let activeCgID: CGWindowID
}

enum InventoryPhantomOwnerResolution {
    static func uniqueOwner(from candidates: [InventoryPhantomOwner]) -> InventoryPhantomOwner? {
        candidates.count == 1 ? candidates[0] : nil
    }
}

struct InventorySessionStartPayload: Codable, Equatable {
    let version: String?
    let build: String?
    let processID: Int32
    let operatingSystem: String
}

struct InventorySeatCreatedPayload: Codable, Equatable {
    let context: InventoryReconcileContext
    let pid: Int32
    let bundleID: String?
    let seatToken: String
    let activeCgID: CGWindowID
    let creationReason: InventorySeatCreationReason
    let isMinimized: Bool
    let isOnScreen: Bool
    let isFocused: Bool
    let appHidden: Bool
    let bounds: InventoryLogRect?
    let candidateKnownShadow: Bool
    let eligibleWindowCount: Int
    let minimizedEligibleCount: Int
    let onScreenEligibleCount: Int
    let cgWindowCount: Int
    let eligibleCgIDs: [CGWindowID]
    let cgWindowIDs: [CGWindowID]
    let shadowPool: [CGWindowID]
    let existingSeats: [InventorySeatRelation]
}

struct InventoryPhantomHeldPayload: Codable, Equatable {
    let context: InventoryReconcileContext
    let pid: Int32
    let bundleID: String?
    let seatToken: String
    let activeCgID: CGWindowID
    let absenceEpisodeID: UUID
    let holdReasons: [String]
    let appHidden: Bool
    let everSeenVisible: Bool
    let absentForMs: Int
    let thresholdMs: Int
    let eligibleWindowCount: Int
    let axPresentSiblingCount: Int
    let bounds: InventoryLogRect?
}

struct InventoryPhantomHealedPayload: Codable, Equatable {
    let context: InventoryReconcileContext
    let pid: Int32
    let bundleID: String?
    let releasedSeatToken: String
    let releasedActiveCgID: CGWindowID
    let absenceEpisodeID: UUID
    let ownerSeatToken: String?
    let ownerActiveCgID: CGWindowID?
    let ownerCandidateCount: Int
}

/// Stable-seat release reasons, including values retained for historical JSONL interpretation.
enum InventorySeatReleasedReason: String, Codable {
    case processGone
    case leftCGList
    /// Historical schema value. Current inventory code must not infer closure from AX absence.
    case absentBeyondGrace
    case phantomHealed
}

/// 座位释放日志载荷。批量 `processGone` 路径发生在 `reconcileSeats` 之外，没有本轮 AX/CG 采样，
/// 也没有 `InventoryReconcileContext`——因此这些字段一律省略或为 nil，绝不伪造为 0/false。
/// 身份字段用稳定的 `pid + seatToken`；附带内存中已有的 bundleID、当前 activeCgID 与座位状态。
struct InventorySeatReleasedPayload: Codable, Equatable {
    let reason: InventorySeatReleasedReason
    let context: InventoryReconcileContext?
    let pid: Int32
    let bundleID: String?
    let seatToken: String
    let activeCgID: CGWindowID
    let isMinimized: Bool
    let isFocused: Bool
    let appHidden: Bool
    let everSeenVisible: Bool
    let bounds: InventoryLogRect?
}

/// 座位释放的内存快照。从 `AppEntry` 投影出纯值，供批量和逐座位释放路径共用。
struct InventorySeatReleaseSnapshot {
    let pid: pid_t
    let bundleID: String?
    let appHidden: Bool
    let seats: [Seat]

    struct Seat {
        let seatToken: String
        let activeCgID: CGWindowID
        let isMinimized: Bool
        let isFocused: Bool
        let everSeenVisible: Bool
        let bounds: CGRect?
    }
}

/// 纯函数：把内存座位快照按原顺序转成 `processGone` 载荷。供单测验证顺序与数量。
enum InventorySeatReleasePlan {
    static func processGonePayloads(for snapshot: InventorySeatReleaseSnapshot) -> [InventorySeatReleasedPayload] {
        payloads(for: snapshot, reason: .processGone, context: nil)
    }

    static func payloads(
        for snapshot: InventorySeatReleaseSnapshot,
        reason: InventorySeatReleasedReason,
        context: InventoryReconcileContext?
    ) -> [InventorySeatReleasedPayload] {
        snapshot.seats.map { seat in
            InventorySeatReleasedPayload(
                reason: reason,
                context: context,
                pid: snapshot.pid,
                bundleID: snapshot.bundleID,
                seatToken: seat.seatToken,
                activeCgID: seat.activeCgID,
                isMinimized: seat.isMinimized,
                isFocused: seat.isFocused,
                appHidden: snapshot.appHidden,
                everSeenVisible: seat.everSeenVisible,
                bounds: seat.bounds.map(InventoryLogRect.init)
            )
        }
    }
}

struct InventoryOrderProjectionChangedPayload: Codable, Equatable {
    let previousLiveIDs: [String]
    let currentLiveIDs: [String]
    let absorbedMessagingMainIDs: [String]
    let visibleMessagingBundleIDs: [String]
    let drawerBundleIDs: [String]
    let appKeyByChipID: [String: String]
}

/// 调用方（视图层）能观测到的那一半：**不含 `previousLiveIDs`**。
/// 「上一轮是什么」只有顺序层自己知道，由它在落日志时补上——调用点传个空数组再被覆盖是误导。
/// 构造它本身有成本（整份 appKey 字典 + 三个数组），所以**只在日志开着时才构造**。
struct InventoryOrderProjectionSample: Equatable {
    let currentLiveIDs: [String]
    let absorbedMessagingMainIDs: [String]
    let visibleMessagingBundleIDs: [String]
    let drawerBundleIDs: [String]
    let appKeyByChipID: [String: String]

    func payload(previousLiveIDs: [String]) -> InventoryOrderProjectionChangedPayload {
        InventoryOrderProjectionChangedPayload(
            previousLiveIDs: previousLiveIDs,
            currentLiveIDs: currentLiveIDs,
            absorbedMessagingMainIDs: absorbedMessagingMainIDs,
            visibleMessagingBundleIDs: visibleMessagingBundleIDs,
            drawerBundleIDs: drawerBundleIDs,
            appKeyByChipID: appKeyByChipID
        )
    }
}

struct InventoryOrderMemoryDroppedPayload: Codable, Equatable {
    let chipID: String
    let appKey: String?
    let previousIndex: Int
    let absentForMs: Int
}

struct InventoryOrderChipPlacedPayload: Codable, Equatable {
    let chipID: String
    let appKey: String?
    let index: Int
    let reason: String
}

enum InventoryAdmissionProbeSource: String, Codable {
    case seed
    case scan
}

enum InventoryAdmissionReadMode: String, Codable {
    case timed
    case untimed
}

enum InventoryAdmissionProbeReadResult: String, Codable {
    case success
    case unread
}

enum InventoryAdmissionProbeVerdict: String, Codable {
    case admit
    case admitFinderPersistent
    case skipUnread
    case skipNoEligible
    case skipNotRegular
    case skipTerminated
    case skipAlreadyTracked
    case skipIdentityMismatch
    case skipProcessUnavailable
}

struct InventoryAdmissionProbePayload: Codable, Equatable {
    let source: InventoryAdmissionProbeSource
    let pid: Int32
    let bundleID: String?
    let processStartTimeSec: Int64?
    let processStartTimeUsec: Int32?
    let readMode: InventoryAdmissionReadMode
    let messagingTimeoutMs: Int?
    let maxAttempts: Int
    let readResult: InventoryAdmissionProbeReadResult
    let errorCode: Int32?
    let rawWindowCount: Int?
    let eligibleWindowCount: Int?
    let verdict: InventoryAdmissionProbeVerdict
}

enum InventoryShadowPoolStatus: String, Codable {
    case initialized
    case changed
    case updateSkipped
    case resumed
}

struct InventoryShadowPoolPayload: Codable, Equatable {
    let context: InventoryReconcileContext
    let pid: Int32
    let bundleID: String?
    let status: InventoryShadowPoolStatus
    let previousSuccessfulRoundID: UInt64?
    let before: [CGWindowID]
    let after: [CGWindowID]
    let added: [CGWindowID]
    let removed: [CGWindowID]
    let eligibleWindowCount: Int
    let cgWindowCount: Int
}

enum WindowInventoryLogEvent: Encodable {
    case sessionStart(InventorySessionStartPayload)
    case seatCreated(InventorySeatCreatedPayload)
    case phantomHeld(InventoryPhantomHeldPayload)
    case phantomHealed(InventoryPhantomHealedPayload)
    case shadowPoolState(InventoryShadowPoolPayload)
    case seatReleased(InventorySeatReleasedPayload)
    case orderProjectionChanged(InventoryOrderProjectionChangedPayload)
    case orderMemoryDropped(InventoryOrderMemoryDroppedPayload)
    case orderChipPlaced(InventoryOrderChipPlacedPayload)
    case admissionProbe(InventoryAdmissionProbePayload)
    case reconcileUnread(InventoryReconcileUnreadPayload)
    case titleHeld(InventoryTitleHeldPayload)

    var name: String {
        switch self {
        case .sessionStart: return "sessionStart"
        case .seatCreated: return "seatCreated"
        case .phantomHeld: return "phantomHeld"
        case .phantomHealed: return "phantomHealed"
        case .shadowPoolState: return "shadowPoolState"
        case .seatReleased: return "seatReleased"
        case .orderProjectionChanged: return "orderProjectionChanged"
        case .orderMemoryDropped: return "orderMemoryDropped"
        case .orderChipPlaced: return "orderChipPlaced"
        case .admissionProbe: return "admissionProbe"
        case .reconcileUnread: return "reconcileUnread"
        case .titleHeld: return "titleHeld"
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .sessionStart(let payload): try payload.encode(to: encoder)
        case .seatCreated(let payload): try payload.encode(to: encoder)
        case .phantomHeld(let payload): try payload.encode(to: encoder)
        case .phantomHealed(let payload): try payload.encode(to: encoder)
        case .shadowPoolState(let payload): try payload.encode(to: encoder)
        case .seatReleased(let payload): try payload.encode(to: encoder)
        case .orderProjectionChanged(let payload): try payload.encode(to: encoder)
        case .orderMemoryDropped(let payload): try payload.encode(to: encoder)
        case .orderChipPlaced(let payload): try payload.encode(to: encoder)
        case .admissionProbe(let payload): try payload.encode(to: encoder)
        case .reconcileUnread(let payload): try payload.encode(to: encoder)
        case .titleHeld(let payload): try payload.encode(to: encoder)
        }
    }
}

struct WindowInventoryLogConfiguration {
    static let defaultsKey = "InventoryLog"

    let enabled: Bool
    let directoryURL: URL
    let maxFileSize: Int
    let archiveCount: Int

    static func resolvedEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        switch DebugSwitch.inventoryLog.value(in: environment) {
        case "1": return true
        case "0": return false
        default: return defaults.bool(forKey: defaultsKey)
        }
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Self {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return Self(
            enabled: resolvedEnabled(environment: environment, defaults: defaults),
            directoryURL: library
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("com.caye.macosdockcc.v2", isDirectory: true),
            maxFileSize: 1_048_576,
            archiveCount: 4
        )
    }
}

enum WindowInventoryDiagnosticRelations {
    static func normalizedTitlesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
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
}

enum InventoryAbsenceEpisode {
    static func beginIfNeeded(
        absentSince: inout Date?,
        episodeID: inout UUID?,
        now: Date,
        makeID: () -> UUID = UUID.init
    ) {
        if absentSince == nil {
            absentSince = now
            episodeID = makeID()
        } else if episodeID == nil {
            episodeID = makeID()
        }
    }

    static func clear(absentSince: inout Date?, episodeID: inout UUID?) {
        absentSince = nil
        episodeID = nil
    }
}

struct InventoryPhantomHeldDeduplicator {
    private struct Key: Hashable {
        let pid: Int32
        let seatToken: String
        let episodeID: UUID
    }

    private var reasonsByEpisode: [Key: Set<PhantomSeatDecision.HoldReason>] = [:]

    mutating func shouldRecord(
        pid: Int32,
        seatToken: String,
        episodeID: UUID,
        reasons: Set<PhantomSeatDecision.HoldReason>
    ) -> Bool {
        let key = Key(pid: pid, seatToken: seatToken, episodeID: episodeID)
        guard reasonsByEpisode[key] != reasons else { return false }
        reasonsByEpisode[key] = reasons
        return true
    }

    mutating func clear(pid: Int32, seatToken: String, episodeID: UUID) {
        reasonsByEpisode.removeValue(forKey: Key(pid: pid, seatToken: seatToken, episodeID: episodeID))
    }

    mutating func removeAll(pid: Int32) {
        reasonsByEpisode = reasonsByEpisode.filter { $0.key.pid != pid }
    }

    mutating func removeAll() {
        reasonsByEpisode.removeAll()
    }
}

final class WindowInventoryAnomalyLog {
    private struct Envelope: Encodable {
        let schemaVersion: Int
        let sessionID: UUID
        let seq: UInt64
        let timestamp: String
        let event: String
        let payload: WindowInventoryLogEvent
    }

    private static let systemLogger = Logger(
        subsystem: "com.caye.macosdockcc.v2",
        category: "window-inventory-log"
    )
    private static let processWriteLock = NSLock()

    let sessionID: UUID
    let configuration: WindowInventoryLogConfiguration

    private let queue: DispatchQueue?
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let fileManager: FileManager
    private let failureReporter: (String) -> Void
    private var sequence: UInt64 = 0
    private var disabledAfterFailure = false
    private var didReportFailure = false

    var isEnabled: Bool { configuration.enabled }
    var currentFileURL: URL { configuration.directoryURL.appendingPathComponent("window-inventory.jsonl") }
    var lockFileURL: URL { configuration.directoryURL.appendingPathComponent("window-inventory.lock") }

    init(
        configuration: WindowInventoryLogConfiguration = .live(),
        fileManager: FileManager = .default,
        sessionID: UUID = UUID(),
        failureReporter: ((String) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.sessionID = sessionID
        self.failureReporter = failureReporter ?? { message in
            Self.systemLogger.error("inventory log disabled after error: \(message, privacy: .public)")
        }
        if configuration.enabled {
            self.queue = DispatchQueue(label: "com.caye.macosdockcc.v2.window-inventory-log", qos: .utility)
        } else {
            self.queue = nil
        }
        self.queue?.setSpecific(key: queueKey, value: 1)
    }

    func record(_ event: WindowInventoryLogEvent, at occurredAt: Date = Date()) {
        guard let queue else { return }
        queue.async { [self] in
            guard !disabledAfterFailure else { return }
            do {
                sequence += 1
                let envelope = Envelope(
                    schemaVersion: 1,
                    sessionID: sessionID,
                    seq: sequence,
                    timestamp: Self.timestampString(from: occurredAt),
                    event: event.name,
                    payload: event
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var data = try encoder.encode(envelope)
                data.append(0x0A)
                try append(data)
            } catch {
                disable(after: error)
            }
        }
    }

    func flush() {
        guard let queue else { return }
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
    }

    func archiveURL(_ index: Int) -> URL {
        configuration.directoryURL.appendingPathComponent("window-inventory.\(index).jsonl")
    }

    private func append(_ data: Data) throws {
        Self.processWriteLock.lock()
        defer { Self.processWriteLock.unlock() }

        try ensureDirectory()

        let lockFD = Darwin.open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw posixError("open lock") }
        defer { Darwin.close(lockFD) }
        guard Darwin.lockf(lockFD, F_LOCK, 0) == 0 else { throw posixError("lock") }
        defer { _ = Darwin.lockf(lockFD, F_ULOCK, 0) }
        guard Darwin.chmod(lockFileURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw posixError("chmod lock")
        }

        var fileFD = try openCurrentFile()
        var shouldClose = true
        defer { if shouldClose { Darwin.close(fileFD) } }

        let repairedSize = try repairTrailingPartialLine(fileFD: fileFD)
        if repairedSize > 0, repairedSize + off_t(data.count) > off_t(configuration.maxFileSize) {
            Darwin.close(fileFD)
            shouldClose = false
            try rotateFiles()
            fileFD = try openCurrentFile()
            shouldClose = true
        }

        try writeAll(data, to: fileFD)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: configuration.directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard Darwin.chmod(configuration.directoryURL.path, S_IRWXU) == 0 else {
            throw posixError("chmod directory")
        }
    }

    private func openCurrentFile() throws -> Int32 {
        let fd = Darwin.open(currentFileURL.path, O_CREAT | O_RDWR | O_APPEND, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixError("open log") }
        guard Darwin.chmod(currentFileURL.path, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(fd)
            throw posixError("chmod log")
        }
        return fd
    }

    private func repairTrailingPartialLine(fileFD: Int32) throws -> off_t {
        let end = Darwin.lseek(fileFD, 0, SEEK_END)
        guard end >= 0 else { throw posixError("seek log") }
        guard end > 0 else { return 0 }

        let data = try Data(contentsOf: currentFileURL)
        guard data.last != 0x0A else { return end }
        let length = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        guard Darwin.ftruncate(fileFD, off_t(length)) == 0 else { throw posixError("truncate log") }
        guard Darwin.lseek(fileFD, 0, SEEK_END) >= 0 else { throw posixError("seek repaired log") }
        return off_t(length)
    }

    private func rotateFiles() throws {
        let oldest = archiveURL(configuration.archiveCount)
        if fileManager.fileExists(atPath: oldest.path) {
            try fileManager.removeItem(at: oldest)
        }
        if configuration.archiveCount > 1 {
            for index in stride(from: configuration.archiveCount - 1, through: 1, by: -1) {
                let source = archiveURL(index)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.moveItem(at: source, to: archiveURL(index + 1))
            }
        }
        if fileManager.fileExists(atPath: currentFileURL.path) {
            try fileManager.moveItem(at: currentFileURL, to: archiveURL(1))
        }
    }

    private func writeAll(_ data: Data, to fileFD: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(fileFD, baseAddress.advanced(by: written), rawBuffer.count - written)
                guard result > 0 else { throw posixError("write log") }
                written += result
            }
        }
    }

    private func disable(after error: Error) {
        disabledAfterFailure = true
        guard !didReportFailure else { return }
        didReportFailure = true
        failureReporter(String(describing: error))
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"]
        )
    }

    private static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
