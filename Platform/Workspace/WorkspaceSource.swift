import AppKit
import ApplicationServices
import Foundation

struct WorkspaceObservationBatch {
    let observations: [SystemObservation]
    let unreadPIDs: Set<pid_t>
    let degradedPIDs: Set<pid_t>
    let duration: TimeInterval
}

final class WorkspaceSource {
    private static let inventoryMessagingTimeout: TimeInterval = 0.10
    private static let maxConcurrentInventoryReads = 12
    private static let degradedUnreadRoundThreshold = 30

    private let eligibilityPolicy = DockWindowEligibilityPolicy()
    private var previousWindowKindsBySignature: [String: SystemObservation.ObservationKind] = [:]
    private var previousObservationsBySignature: [String: SystemObservation] = [:]
    private var previousHiddenSignatures: Set<String> = []
    private var unreadRoundsByPID: [pid_t: Int] = [:]
    private var degradedPIDs: Set<pid_t> = []

    func observe() -> WorkspaceObservationBatch {
        guard AXIsProcessTrusted() else {
            return WorkspaceObservationBatch(
                observations: [],
                unreadPIDs: [],
                degradedPIDs: [],
                duration: 0
            )
        }

        let start = Date()
        let now = Date()
        let appContexts = NSWorkspace.shared.runningApplications.compactMap(AppContext.init(app:))
        let livePIDs = Set(appContexts.map(\.pid))
        pruneState(toLivePIDs: livePIDs)

        let reads = readApps(appContexts)
        var observations: [SystemObservation] = []
        var successfulPIDs: Set<pid_t> = []
        var unreadPIDs: Set<pid_t> = []
        var currentHiddenSignatures: Set<String> = []

        for read in reads {
            switch read.result {
            case let .success(windows):
                successfulPIDs.insert(read.context.pid)
                unreadRoundsByPID.removeValue(forKey: read.context.pid)
                degradedPIDs.remove(read.context.pid)

                let appObservations = observeWindows(windows, for: read.context, now: now)
                observations.append(contentsOf: appObservations)
                for observation in appObservations where observation.kind == .hidden {
                    currentHiddenSignatures.insert(observationSignature(observation))
                }

            case .unread:
                unreadPIDs.insert(read.context.pid)
                let unreadRounds = (unreadRoundsByPID[read.context.pid] ?? 0) + 1
                unreadRoundsByPID[read.context.pid] = unreadRounds
                if unreadRounds >= Self.degradedUnreadRoundThreshold {
                    degradedPIDs.insert(read.context.pid)
                }
            }
        }

        var nextKindsBySignature: [String: SystemObservation.ObservationKind] = [:]
        var nextObservationsBySignature: [String: SystemObservation] = [:]
        for observation in observations {
            let signature = observationSignature(observation)
            nextKindsBySignature[signature] = ObservationKindMergeRule.preferred(
                nextKindsBySignature[signature],
                observation.kind
            )
            nextObservationsBySignature[signature] = observation
        }

        for (signature, previous) in previousObservationsBySignature
            where nextObservationsBySignature[signature] == nil && successfulPIDs.contains(previous.pid) {
            observations.append(
                SystemObservation(
                    timestamp: now,
                    kind: .disappeared,
                    source: previous.source,
                    pid: previous.pid,
                    bundleIdentifier: previous.bundleIdentifier,
                    cgWindowID: previous.cgWindowID,
                    title: previous.title,
                    appName: previous.appName,
                    bounds: previous.bounds,
                    isMinimized: previous.isMinimized,
                    isFocusedWindow: false
                )
            )
        }

        previousWindowKindsBySignature = nextKindsBySignature
        previousObservationsBySignature = nextObservationsBySignature
        previousHiddenSignatures = currentHiddenSignatures

        return WorkspaceObservationBatch(
            observations: observations,
            unreadPIDs: unreadPIDs,
            degradedPIDs: degradedPIDs.intersection(livePIDs),
            duration: Date().timeIntervalSince(start)
        )
    }

    private func observeWindows(
        _ windows: [AXWindowSnapshot],
        for app: AppContext,
        now: Date
    ) -> [SystemObservation] {
        windows.compactMap { window in
            let title = window.title
            guard title != nil else { return nil }
            guard window.role == (kAXWindowRole as String) else { return nil }
            if let subrole = window.subrole,
               subrole != (kAXStandardWindowSubrole as String) {
                return nil
            }

            let decision = eligibilityPolicy.evaluate(
                DockWindowEligibilityPolicy.Candidate(
                    bundleIdentifier: app.bundleIdentifier,
                    appName: app.localizedName ?? "",
                    title: title,
                    bounds: window.bounds,
                    alpha: nil,
                    activationPolicy: app.activationPolicy,
                    executablePath: app.executablePath
                )
            )
            guard decision == .keep else { return nil }

            let baseObservation = SystemObservation(
                timestamp: now,
                kind: .unchanged,
                source: .appWindowInventory,
                pid: app.pid,
                bundleIdentifier: app.bundleIdentifier,
                cgWindowID: window.cgWindowID,
                title: title,
                appName: app.localizedName,
                bounds: window.bounds,
                isMinimized: window.isMinimized,
                isFocusedWindow: window.isFocusedWindow
            )
            let signature = observationSignature(baseObservation)
            let previousKind = previousWindowKindsBySignature[signature]
            let wasHidden = previousHiddenSignatures.contains(signature)
            let kind: SystemObservation.ObservationKind

            if window.isMinimized {
                kind = .minimized
            } else if app.isHidden {
                kind = .hidden
            } else if wasHidden || previousKind == .hidden {
                kind = .unhidden
            } else {
                kind = .unchanged
            }

            return SystemObservation(
                timestamp: now,
                kind: kind,
                source: .appWindowInventory,
                pid: app.pid,
                bundleIdentifier: app.bundleIdentifier,
                cgWindowID: window.cgWindowID,
                title: title,
                appName: app.localizedName,
                bounds: window.bounds,
                isMinimized: window.isMinimized,
                isFocusedWindow: window.isFocusedWindow
            )
        }
    }

    private func readApps(_ contexts: [AppContext]) -> [AppWindowRead] {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = Self.maxConcurrentInventoryReads

        let lock = NSLock()
        var reads: [AppWindowRead] = []

        for context in contexts {
            queue.addOperation {
                let result = AXWindowReader().inventoryWindows(
                    forPID: context.pid,
                    messagingTimeout: Self.inventoryMessagingTimeout
                )
                lock.lock()
                reads.append(AppWindowRead(context: context, result: result))
                lock.unlock()
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        return reads.sorted { $0.context.pid < $1.context.pid }
    }

    private func pruneState(toLivePIDs livePIDs: Set<pid_t>) {
        unreadRoundsByPID = unreadRoundsByPID.filter { livePIDs.contains($0.key) }
        degradedPIDs = degradedPIDs.intersection(livePIDs)
        previousObservationsBySignature = previousObservationsBySignature.filter { _, observation in
            livePIDs.contains(observation.pid)
        }
        previousWindowKindsBySignature = previousWindowKindsBySignature.filter { signature, _ in
            previousObservationsBySignature[signature] != nil
        }
        previousHiddenSignatures = previousHiddenSignatures.filter {
            previousObservationsBySignature[$0] != nil
        }
    }

    private func observationSignature(_ observation: SystemObservation) -> String {
        let title = observation.title?.lowercased() ?? "<untitled>"
        let frame = observation.bounds.map {
            "\($0.origin.x.rounded()):\($0.origin.y.rounded()):\($0.width.rounded()):\($0.height.rounded())"
        } ?? "<unknown>"
        return "\(observation.pid)|\(title)|\(frame)"
    }

    private struct AppContext {
        let pid: pid_t
        let bundleIdentifier: String?
        let localizedName: String?
        let activationPolicy: NSApplication.ActivationPolicy
        let executablePath: String?
        let isHidden: Bool

        init?(app: NSRunningApplication) {
            guard app.isTerminated == false else { return nil }
            guard app.activationPolicy != .prohibited else { return nil }
            guard FinderWindowRules.isFinder(bundleIdentifier: app.bundleIdentifier) == false else { return nil }
            guard FeishuBundleRules.isFeishu(bundleIdentifier: app.bundleIdentifier) == false else { return nil }

            pid = app.processIdentifier
            bundleIdentifier = app.bundleIdentifier
            localizedName = app.localizedName
            activationPolicy = app.activationPolicy
            executablePath = app.executableURL?.path
            isHidden = app.isHidden
        }
    }

    private struct AppWindowRead {
        let context: AppContext
        let result: AXWindowReadResult
    }
}
