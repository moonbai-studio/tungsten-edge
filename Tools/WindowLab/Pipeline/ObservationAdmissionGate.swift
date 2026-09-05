import CoreGraphics
import Foundation

enum ObservationAdmissionKind: String, Hashable {
    case accepted
    case deferred
    case rejected
}

struct ObservationAdmissionDecision: Hashable {
    let kind: ObservationAdmissionKind
    let reason: String
}

enum ObservationRoundAdmissionKind: String, Hashable {
    case accepted
    case rejected
}

struct ObservationRoundAdmissionDecision: Equatable {
    let kind: ObservationRoundAdmissionKind
    let reason: String
    let baselineCount: Int
    let candidateCount: Int
    let sourceCounts: [SystemObservation.ObservationSource: Int]
}

final class ObservationRoundAnomalyFuse {
    private static let minimumSpikeCount = 48
    private static let spikeMultiplier = 3

    private let identityRules = IdentityRuleEngine()

    func decide(observations: [SystemObservation], snapshot: DockSnapshot) -> ObservationRoundAdmissionDecision {
        let baselineCount = snapshot.windows.values.filter { record in
            record.status != .disappeared && record.status != .closedPending
        }.count
        let candidates = observations.filter { $0.kind != .disappeared }
        let candidateCount = Set(candidates.compactMap(candidateKey)).count
        let sourceCounts = Dictionary(grouping: candidates, by: \.source).mapValues(\.count)

        guard baselineCount > 0,
              candidateCount >= Self.minimumSpikeCount,
              candidateCount >= baselineCount * Self.spikeMultiplier else {
            return ObservationRoundAdmissionDecision(
                kind: .accepted,
                reason: "plausible-round",
                baselineCount: baselineCount,
                candidateCount: candidateCount,
                sourceCounts: sourceCounts
            )
        }

        return ObservationRoundAdmissionDecision(
            kind: .rejected,
            reason: "count-spike",
            baselineCount: baselineCount,
            candidateCount: candidateCount,
            sourceCounts: sourceCounts
        )
    }

    private func candidateKey(for observation: SystemObservation) -> RoundCandidateKey? {
        RoundCandidateKey(observation: observation, identityRules: identityRules)
    }

    private struct RoundCandidateKey: Hashable {
        let pid: Int32
        let appKey: String
        let normalizedTitle: String
        let frameBucket: String

        init?(observation: SystemObservation, identityRules: IdentityRuleEngine) {
            pid = observation.pid
            appKey = observation.bundleIdentifier ?? observation.appName ?? "pid-\(observation.pid)"
            normalizedTitle = identityRules.evaluate(observation).normalizedTitle
                ?? observation.title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ?? "untitled"
            frameBucket = Self.frameBucket(for: observation.bounds)
        }

        private static func frameBucket(for bounds: CGRect?) -> String {
            guard let bounds else { return "no-frame" }
            let size = WindowFrameMatchPolicy.tolerance
            let x = Int((bounds.origin.x / size).rounded())
            let y = Int((bounds.origin.y / size).rounded())
            let width = Int((bounds.width / size).rounded())
            let height = Int((bounds.height / size).rounded())
            return "\(x):\(y):\(width):\(height)"
        }
    }
}

final class ObservationAdmissionGate {
    private static let stabilityWindow: TimeInterval = 3.0
    private static let pendingTTL: TimeInterval = 8.0
    private static let maxPendingClusters = 128

    private let mode: Mode
    private let identityRules = IdentityRuleEngine()
    private var pendingClusters: [ClusterKey: PendingCluster] = [:]
    private var roundIndex = 0
    private var inventoryMainlineAvailable = true

    init(mode: Mode = .current()) {
        self.mode = mode
    }

    func beginRound(at timestamp: Date, inventoryMainlineAvailable: Bool = true) {
        roundIndex += 1
        self.inventoryMainlineAvailable = inventoryMainlineAvailable
        cleanup(at: timestamp)
    }

    func decide(observation: SystemObservation, snapshot: DockSnapshot) -> ObservationAdmissionDecision {
        if mode == .legacy {
            return ObservationAdmissionDecision(kind: .accepted, reason: "legacy-mode")
        }

        if observation.source == .appWindowInventory {
            return ObservationAdmissionDecision(kind: .accepted, reason: "app-window-inventory")
        }

        if FinderWindowRules.isFinder(bundleIdentifier: observation.bundleIdentifier) {
            return ObservationAdmissionDecision(kind: .accepted, reason: "finder-source")
        }

        if FeishuBundleRules.isFeishu(bundleIdentifier: observation.bundleIdentifier) {
            return ObservationAdmissionDecision(kind: .accepted, reason: "feishu-fallback")
        }

        if matchesExistingWindow(observation, snapshot: snapshot) {
            return ObservationAdmissionDecision(kind: .accepted, reason: "matches-existing-window")
        }

        if observation.source == .coreGraphics || observation.cgWindowID != nil {
            if inventoryMainlineAvailable == false {
                return ObservationAdmissionDecision(kind: .accepted, reason: "cg-permission-fallback")
            }

            if observation.isInventoryDegraded {
                return ObservationAdmissionDecision(kind: .accepted, reason: "cg-inventory-degraded")
            }

            return ObservationAdmissionDecision(kind: .rejected, reason: "cg-orphan-inventory-required")
        }

        if observation.kind == .disappeared {
            return ObservationAdmissionDecision(kind: .rejected, reason: "orphan-disappeared")
        }

        if observation.source == .accessibility {
            return ObservationAdmissionDecision(kind: .rejected, reason: "accessibility-orphan-inventory-required")
        }

        guard let clusterKey = ClusterKey(observation: observation, identityRules: identityRules) else {
            return ObservationAdmissionDecision(kind: .rejected, reason: "missing-cluster-signals")
        }

        let now = observation.timestamp
        guard var cluster = pendingClusters[clusterKey] else {
            pendingClusters[clusterKey] = PendingCluster(
                firstSeenAt: now,
                lastSeenAt: now,
                lastSeenRound: roundIndex,
                consecutiveRounds: 1
            )
            cleanup(at: now)
            return ObservationAdmissionDecision(kind: .deferred, reason: "pending-stability")
        }

        if cluster.lastSeenRound == roundIndex {
            pendingClusters[clusterKey] = cluster
            return ObservationAdmissionDecision(kind: .deferred, reason: "pending-same-round")
        }

        if roundIndex - cluster.lastSeenRound == 1,
           now.timeIntervalSince(cluster.lastSeenAt) <= Self.stabilityWindow {
            cluster.consecutiveRounds += 1
        } else {
            cluster.consecutiveRounds = 1
        }

        cluster.lastSeenAt = now
        cluster.lastSeenRound = roundIndex
        pendingClusters[clusterKey] = cluster
        cleanup(at: now)

        if cluster.consecutiveRounds >= 2 {
            pendingClusters.removeValue(forKey: clusterKey)
            return ObservationAdmissionDecision(kind: .accepted, reason: "stable-ax-only")
        }

        return ObservationAdmissionDecision(kind: .deferred, reason: "pending-stability")
    }

    func pendingClusterCount(at timestamp: Date) -> Int {
        cleanup(at: timestamp)
        return pendingClusters.count
    }

    private func matchesExistingWindow(_ observation: SystemObservation, snapshot: DockSnapshot) -> Bool {
        if matchingExistingWindowCount(observation, snapshot: snapshot) == 1 {
            return true
        }

        if observation.source == .coreGraphics || observation.cgWindowID != nil {
            return matchingExistingTitleOnlyCount(observation, snapshot: snapshot) == 1
        }

        return false
    }

    private func matchingExistingWindowCount(_ observation: SystemObservation, snapshot: DockSnapshot) -> Int {
        matchingExistingRecords(observation, snapshot: snapshot).filter { record in
            if let observationBounds = observation.bounds, let recordBounds = record.bounds {
                return WindowFrameMatchPolicy.areClose(observationBounds, recordBounds)
            }

            return observation.bounds == nil || record.bounds == nil
        }.count
    }

    private func matchingExistingTitleOnlyCount(_ observation: SystemObservation, snapshot: DockSnapshot) -> Int {
        matchingExistingRecords(observation, snapshot: snapshot).count
    }

    private func matchingExistingRecords(_ observation: SystemObservation, snapshot: DockSnapshot) -> [WindowRecord] {
        snapshot.windows.values.filter { record in
            guard record.status != .closedPending else { return false }
            guard record.pid == observation.pid else { return false }

            if let observationBundle = observation.bundleIdentifier,
               let recordBundle = record.bundleIdentifier,
               observationBundle != recordBundle {
                return false
            }

            guard normalizedTitle(for: observation) == normalizedTitle(for: record) else {
                return false
            }

            return true
        }
    }

    private func normalizedTitle(for observation: SystemObservation) -> String? {
        identityRules.evaluate(observation).normalizedTitle
            ?? observation.title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedTitle(for record: WindowRecord) -> String? {
        let observation = SystemObservation(
            timestamp: Date(),
            kind: .unchanged,
            source: .coreGraphics,
            pid: record.pid,
            bundleIdentifier: record.bundleIdentifier,
            cgWindowID: nil,
            title: record.title,
            appName: nil,
            bounds: record.bounds,
            isMinimized: false,
            isFocusedWindow: false
        )
        return normalizedTitle(for: observation)
    }

    private func cleanup(at timestamp: Date) {
        pendingClusters = pendingClusters.filter { _, cluster in
            timestamp.timeIntervalSince(cluster.lastSeenAt) <= Self.pendingTTL
        }

        guard pendingClusters.count > Self.maxPendingClusters else { return }
        let overflow = pendingClusters.count - Self.maxPendingClusters
        let oldestKeys = pendingClusters
            .sorted { $0.value.lastSeenAt < $1.value.lastSeenAt }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys {
            pendingClusters.removeValue(forKey: key)
        }
    }

    enum Mode: Equatable {
        case strict
        case legacy

        static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Mode {
            #if DEBUG
            if environment["DOCK_INVENTORY_FIRST_ENABLED"] == "0" {
                return .legacy
            }
            if environment["DOCK_AX_ADMISSION_MODE"] == "legacy" {
                return .legacy
            }
            #endif
            return .strict
        }
    }

    private struct PendingCluster {
        let firstSeenAt: Date
        var lastSeenAt: Date
        var lastSeenRound: Int
        var consecutiveRounds: Int
    }

    private struct ClusterKey: Hashable {
        let pid: Int32
        let appKey: String
        let normalizedTitle: String
        let frameBucket: String

        init?(observation: SystemObservation, identityRules: IdentityRuleEngine) {
            let title = identityRules.evaluate(observation).normalizedTitle
                ?? observation.title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let title, title.isEmpty == false else { return nil }

            pid = observation.pid
            appKey = observation.bundleIdentifier ?? observation.appName ?? "pid-\(observation.pid)"
            normalizedTitle = title
            frameBucket = Self.frameBucket(for: observation.bounds)
        }

        private static func frameBucket(for bounds: CGRect?) -> String {
            guard let bounds else { return "no-frame" }
            let size = WindowFrameMatchPolicy.tolerance
            let x = Int((bounds.origin.x / size).rounded())
            let y = Int((bounds.origin.y / size).rounded())
            let width = Int((bounds.width / size).rounded())
            let height = Int((bounds.height / size).rounded())
            return "\(x):\(y):\(width):\(height)"
        }
    }
}
