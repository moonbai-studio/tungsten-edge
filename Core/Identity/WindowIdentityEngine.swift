import Foundation

final class WindowIdentityEngine {
    private var memory = IdentityMemory()
    private let bridgeTTL: TimeInterval = 5.0
    private let inventoryBindingTTL: TimeInterval = 2.0
    private let inventoryCGFrameTolerance: CGFloat = 12
    private let rememberedSignatureTTL: TimeInterval = 6.0
    private let signatureStreakWindow: TimeInterval = 3.0
    private let rules = IdentityRuleEngine()

    func identify(observation: SystemObservation, snapshot: DockSnapshot? = nil) -> IdentityDecision {
        let ruleResult = rules.evaluate(observation)
        guard ruleResult.accepted else {
            return IdentityDecision(
                kind: .ambiguous,
                windowID: WindowID(rawValue: "filtered-\(observation.pid)"),
                confidence: .low,
                reason: "filtered-by-rule"
            )
        }

        if let fallbackIdentity = ruleResult.fallbackIdentity {
            let isKnown = memory.seenWindowIDs.contains(fallbackIdentity.windowID)
                || snapshot?.windows[fallbackIdentity.windowID] != nil
            let kind: DecisionKind = isKnown ? .knownWindow : .newWindow
            memory.seenWindowIDs.insert(fallbackIdentity.windowID)
            memory.record(
                observation: observation,
                normalizedTitle: ruleResult.normalizedTitle,
                resolvedID: fallbackIdentity.windowID
            )
            return IdentityDecision(
                kind: kind,
                windowID: fallbackIdentity.windowID,
                confidence: fallbackIdentity.confidence,
                reason: fallbackIdentity.reason
            )
        }

        let resolution = resolvedWindow(
            for: observation,
            normalizedTitle: ruleResult.normalizedTitle,
            snapshot: snapshot
        )
        let id = resolution.windowID
        let isKnown = memory.seenWindowIDs.contains(id) || snapshot?.windows[id] != nil
        let kind: DecisionKind = isKnown ? .knownWindow : .newWindow
        memory.seenWindowIDs.insert(id)
        memory.record(observation: observation, normalizedTitle: ruleResult.normalizedTitle, resolvedID: id)
        return IdentityDecision(
            kind: kind,
            windowID: id,
            confidence: resolution.confidence,
            reason: resolution.reason
        )
    }

    func retire(windowID: WindowID) {
        memory.retire(windowID: windowID)
    }

    private func resolvedWindow(
        for observation: SystemObservation,
        normalizedTitle: String?,
        snapshot: DockSnapshot?
    ) -> IdentityResolution {
        if let cgWindowID = observation.cgWindowID {
            if let bound = memory.lookupBoundCGWindowID(cgWindowID) {
                return IdentityResolution(
                    windowID: bound,
                    confidence: .high,
                    reason: "cg-window-id-bound"
                )
            }

            if let bridged = memory.lookupPendingBridge(
                for: observation,
                normalizedTitle: normalizedTitle,
                now: observation.timestamp,
                ttl: bridgeTTL
            ) {
                return IdentityResolution(
                    windowID: bridged,
                    confidence: .medium,
                    reason: "restored-via-bridge"
                )
            }

            if let inventoryBound = memory.lookupInventoryBinding(
                for: observation,
                normalizedTitle: normalizedTitle,
                now: observation.timestamp,
                ttl: inventoryBindingTTL,
                frameTolerance: inventoryCGFrameTolerance
            ) {
                return IdentityResolution(
                    windowID: inventoryBound,
                    confidence: .high,
                    reason: "cg-bound-to-inventory"
                )
            }

            if let retained = retainedWindowResolution(
                for: observation,
                normalizedTitle: normalizedTitle,
                snapshot: snapshot
            ) {
                return retained
            }

            if let existing = existingLiveWindowResolution(
                for: observation,
                normalizedTitle: normalizedTitle,
                snapshot: snapshot
            ) {
                return existing
            }

            return IdentityResolution(
                windowID: WindowID(rawValue: "cg-\(cgWindowID)"),
                confidence: .high,
                reason: "cg-window-id"
            )
        }

        switch memory.lookupRememberedIdentity(
            for: observation,
            normalizedTitle: normalizedTitle,
            now: observation.timestamp,
            ttl: rememberedSignatureTTL
        ) {
        case let .matched(matched, matchKind):
            let signatureStreak = memory.recentObservationCount(
                for: observation,
                normalizedTitle: normalizedTitle,
                now: observation.timestamp,
                window: signatureStreakWindow
            )
            let confidence: Confidence
            let reason: String
            if observation.isMinimized {
                confidence = .medium
                reason = "minimized-side-evidence"
            } else if matchKind == .frameOnly, observation.source == .accessibility {
                confidence = .medium
                reason = "frame-replay-accessibility"
            } else if observation.source == .accessibility, observation.bounds != nil {
                if signatureStreak >= 2 {
                    confidence = .high
                    reason = "signature-streak-accessibility"
                } else {
                    confidence = .medium
                    reason = "signature-replay-accessibility"
                }
            } else {
                confidence = .high
                reason = signatureStreak >= 2 ? "signature-streak" : "signature-replay"
            }
            return IdentityResolution(
                windowID: matched,
                confidence: confidence,
                reason: reason
            )
        case .conflict:
            return IdentityResolution(
                windowID: memory.makeTransientAXWindowID(pid: observation.pid),
                confidence: .low,
                reason: "conflicting-coarse-signature"
            )
        case .none:
            if let retained = retainedWindowResolution(
                for: observation,
                normalizedTitle: normalizedTitle,
                snapshot: snapshot
            ) {
                return retained
            }

            if let existing = existingLiveWindowResolution(
                for: observation,
                normalizedTitle: normalizedTitle,
                snapshot: snapshot
            ) {
                return existing
            }

            return IdentityResolution(
                windowID: memory.makeTransientAXWindowID(pid: observation.pid),
                confidence: .low,
                reason: observation.title ?? observation.appName ?? "unlabeled-window"
            )
        }
    }

    private func retainedWindowResolution(
        for observation: SystemObservation,
        normalizedTitle: String?,
        snapshot: DockSnapshot?
    ) -> IdentityResolution? {
        snapshotSeatResolution(
            for: observation,
            normalizedTitle: normalizedTitle,
            snapshot: snapshot,
            acceptsStatus: isRetainedSeatStatus,
            reasonPrefix: "retained-seat",
            allowsTitleOnly: true
        )
    }

    private func existingLiveWindowResolution(
        for observation: SystemObservation,
        normalizedTitle: String?,
        snapshot: DockSnapshot?
    ) -> IdentityResolution? {
        snapshotSeatResolution(
            for: observation,
            normalizedTitle: normalizedTitle,
            snapshot: snapshot,
            acceptsStatus: isLiveSeatStatus,
            reasonPrefix: "snapshot-seat",
            allowsTitleOnly: true
        )
    }

    private func snapshotSeatResolution(
        for observation: SystemObservation,
        normalizedTitle: String?,
        snapshot: DockSnapshot?,
        acceptsStatus: (WindowStatus) -> Bool,
        reasonPrefix: String,
        allowsTitleOnly: Bool
    ) -> IdentityResolution? {
        guard let snapshot else {
            return nil
        }

        let baseCandidates = snapshot.windows.values.filter { record in
            guard acceptsStatus(record.status) else { return false }
            guard record.id.rawValue.hasPrefix("app-") == false else { return false }
            guard record.pid == observation.pid else { return false }
            guard matchesApplication(observation: observation, record: record) else { return false }
            return true
        }
        let frameCandidates: [WindowRecord]
        if let observationBounds = observation.bounds {
            frameCandidates = baseCandidates.filter { record in
                guard let recordBounds = record.bounds else { return false }
                return WindowFrameMatchPolicy.areClose(observationBounds, recordBounds)
            }
        } else {
            frameCandidates = []
        }

        if let observationNormalizedTitle = normalizedTitle {
            let titleAndFrameCandidates = frameCandidates.filter { record in
                normalizedRecordTitle(for: record) == observationNormalizedTitle
            }

            if titleAndFrameCandidates.count == 1, let match = titleAndFrameCandidates.first {
                return IdentityResolution(
                    windowID: match.id,
                    confidence: .high,
                    reason: "\(reasonPrefix)-title-frame"
                )
            }

            if titleAndFrameCandidates.count > 1 {
                return nil
            }
        }

        guard frameCandidates.count == 1, let match = frameCandidates.first else {
            if allowsTitleOnly, let observationNormalizedTitle = normalizedTitle {
                let titleCandidates = baseCandidates.filter { record in
                    normalizedRecordTitle(for: record) == observationNormalizedTitle
                }

                if titleCandidates.count == 1, let titleMatch = titleCandidates.first {
                    return IdentityResolution(
                        windowID: titleMatch.id,
                        confidence: .medium,
                        reason: "\(reasonPrefix)-title"
                    )
                }
            }

            return nil
        }

        return IdentityResolution(
            windowID: match.id,
            confidence: .medium,
            reason: "\(reasonPrefix)-frame"
        )
    }

    private func isRetainedSeatStatus(_ status: WindowStatus) -> Bool {
        switch status {
        case .minimized, .hidden, .disappeared:
            return true
        case .active, .inactive, .closedPending:
            return false
        }
    }

    private func isLiveSeatStatus(_ status: WindowStatus) -> Bool {
        switch status {
        case .active, .inactive:
            return true
        case .minimized, .hidden, .disappeared, .closedPending:
            return false
        }
    }

    private func matchesApplication(observation: SystemObservation, record: WindowRecord) -> Bool {
        if let observationBundle = nonEmpty(observation.bundleIdentifier) {
            if let recordBundle = nonEmpty(record.bundleIdentifier) {
                return observationBundle == recordBundle
            }

            return record.appID.rawValue == observationBundle
        }

        if nonEmpty(record.bundleIdentifier) != nil {
            return false
        }

        if let appName = nonEmpty(observation.appName) {
            return record.appID.rawValue == appName || record.appID.rawValue == "pid-\(observation.pid)"
        }

        return record.appID.rawValue == "pid-\(observation.pid)"
    }

    private func normalizedRecordTitle(for record: WindowRecord) -> String? {
        let observation = SystemObservation(
            timestamp: Date(),
            kind: .unchanged,
            source: .appWindowInventory,
            pid: record.pid,
            bundleIdentifier: record.bundleIdentifier,
            cgWindowID: nil,
            title: record.title,
            appName: nil,
            bounds: record.bounds,
            isMinimized: record.status == .minimized,
            isFocusedWindow: false
        )

        return rules.evaluate(observation).normalizedTitle
            ?? record.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else { return nil }
        return trimmed
    }
}

private struct IdentityMemory {
    var seenWindowIDs: Set<WindowID> = []
    var rememberedExactIDBySignature: [String: TimedWindowID] = [:]
    var rememberedExactCandidatesBySignature: [String: [WindowID: Date]] = [:]
    var rememberedExactIDsByCoarseSignature: [String: [String: TimedWindowID]] = [:]
    var rememberedCoarseCandidatesBySignature: [String: [WindowID: Date]] = [:]
    var rememberedFrameCandidatesBySignature: [String: [WindowID: Date]] = [:]
    var rememberedFramesByCoarseSignature: [String: [WindowID: TimedFrame]] = [:]
    var recentInventoryCandidatesByCoarseSignature: [String: [WindowID: TimedOptionalFrame]] = [:]
    var windowIDByCGWindowID: [UInt32: WindowID] = [:]
    var recentDisappearanceIDBySignature: [String: TimedWindowID] = [:]
    var pendingMinimizedIDBySignature: [String: TimedWindowID] = [:]
    var recentObservationEvidenceBySignature: [String: TimedObservationEvidence] = [:]
    var nextTransientAXSequence: UInt64 = 1

    private let observationStreakDefaultWindow: TimeInterval = 3.0

    mutating func record(observation: SystemObservation, normalizedTitle: String?, resolvedID: WindowID) {
        let exactSignature = observation.exactSignature(normalizedTitle: normalizedTitle)
        let coarseSignature = observation.coarseSignature(normalizedTitle: normalizedTitle)

        let timed = TimedWindowID(id: resolvedID, timestamp: observation.timestamp)
        rememberedExactIDBySignature[exactSignature] = timed
        var exactCandidates = rememberedExactCandidatesBySignature[exactSignature] ?? [:]
        exactCandidates[resolvedID] = observation.timestamp
        rememberedExactCandidatesBySignature[exactSignature] = exactCandidates

        var exactEntries = rememberedExactIDsByCoarseSignature[coarseSignature] ?? [:]
        exactEntries[exactSignature] = timed
        rememberedExactIDsByCoarseSignature[coarseSignature] = exactEntries

        var coarseCandidates = rememberedCoarseCandidatesBySignature[coarseSignature] ?? [:]
        coarseCandidates[resolvedID] = observation.timestamp
        rememberedCoarseCandidatesBySignature[coarseSignature] = coarseCandidates

        if let frameSignature = observation.frameSignature() {
            var frameCandidates = rememberedFrameCandidatesBySignature[frameSignature] ?? [:]
            frameCandidates[resolvedID] = observation.timestamp
            rememberedFrameCandidatesBySignature[frameSignature] = frameCandidates
        }
        if let bounds = observation.bounds {
            var frameEntries = rememberedFramesByCoarseSignature[coarseSignature] ?? [:]
            frameEntries[resolvedID] = TimedFrame(bounds: bounds, timestamp: observation.timestamp)
            rememberedFramesByCoarseSignature[coarseSignature] = frameEntries
        }
        if observation.source == .appWindowInventory {
            var inventoryEntries = recentInventoryCandidatesByCoarseSignature[coarseSignature] ?? [:]
            inventoryEntries[resolvedID] = TimedOptionalFrame(
                bounds: observation.bounds,
                timestamp: observation.timestamp
            )
            recentInventoryCandidatesByCoarseSignature[coarseSignature] = inventoryEntries
        }
        if let cgWindowID = observation.cgWindowID {
            windowIDByCGWindowID[cgWindowID] = resolvedID
        }

        for signature in [exactSignature, coarseSignature] {
            recentObservationEvidenceBySignature[signature] = nextObservationEvidence(
                previous: recentObservationEvidenceBySignature[signature],
                timestamp: observation.timestamp
            )
        }

        switch observation.kind {
        case .disappeared:
            for signature in [exactSignature, coarseSignature] {
                recentDisappearanceIDBySignature[signature] = timed
            }
        case .minimized, .hidden:
            for signature in [exactSignature, coarseSignature] {
                pendingMinimizedIDBySignature[signature] = timed
                recentDisappearanceIDBySignature[signature] = timed
            }
        case .restored, .appeared, .unchanged, .titleChanged, .unhidden:
            if !observation.isMinimized {
                for signature in [exactSignature, coarseSignature] {
                    pendingMinimizedIDBySignature.removeValue(forKey: signature)
                    recentDisappearanceIDBySignature.removeValue(forKey: signature)
                }
            }
        }
    }

    func lookupRememberedIdentity(
        for observation: SystemObservation,
        normalizedTitle: String?,
        now: Date,
        ttl: TimeInterval
    ) -> RememberedIdentityLookup {
        let exactSignature = observation.exactSignature(normalizedTitle: normalizedTitle)
        let exactMatches = freshExactCandidates(for: exactSignature, now: now, ttl: ttl)
        if exactMatches.count == 1 {
            return .matched(exactMatches[0], .coarse)
        }
        if exactMatches.count > 1 {
            return .conflict
        }

        let coarseSignature = observation.coarseSignature(normalizedTitle: normalizedTitle)
        if let tolerantMatches = freshTolerantFrameCandidates(
            for: observation,
            coarseSignature: coarseSignature,
            now: now,
            ttl: ttl
        ) {
            if tolerantMatches.count == 1 {
                return .matched(tolerantMatches[0], .frameOnly)
            }
            if tolerantMatches.count > 1 {
                return .conflict
            }
        }

        if observation.bounds != nil,
           hasConflictingFreshExactSignature(
            for: coarseSignature,
            excluding: exactSignature,
            now: now,
            ttl: ttl
           ) {
            return .conflict
        }

        let coarseMatches = freshCoarseCandidates(for: coarseSignature, now: now, ttl: ttl)
        if coarseMatches.count == 1 {
            return .matched(coarseMatches[0], .coarse)
        }
        if coarseMatches.count > 1 {
            return .conflict
        }

        if let frameSignature = observation.frameSignature() {
            let frameMatches = freshFrameCandidates(for: frameSignature, now: now, ttl: ttl)
            if frameMatches.count == 1 {
                return .matched(frameMatches[0], .frameOnly)
            }
            if frameMatches.count > 1 {
                return .conflict
            }
        }

        return .none
    }

    func lookupBoundCGWindowID(_ cgWindowID: UInt32) -> WindowID? {
        windowIDByCGWindowID[cgWindowID]
    }

    func lookupInventoryBinding(
        for observation: SystemObservation,
        normalizedTitle: String?,
        now: Date,
        ttl: TimeInterval,
        frameTolerance: CGFloat
    ) -> WindowID? {
        let coarseSignature = observation.coarseSignature(normalizedTitle: normalizedTitle)
        guard let candidates = recentInventoryCandidatesByCoarseSignature[coarseSignature] else {
            return nil
        }

        let freshCandidates = candidates.filter { _, candidate in
            now.timeIntervalSince(candidate.timestamp) <= ttl
        }
        guard freshCandidates.isEmpty == false else { return nil }

        if let bounds = observation.bounds {
            let tightFrameMatches = freshCandidates.compactMap { windowID, candidate -> WindowID? in
                guard let candidateBounds = candidate.bounds else { return nil }
                return WindowFrameMatchPolicy.areClose(
                    bounds,
                    candidateBounds,
                    tolerance: frameTolerance
                ) ? windowID : nil
            }
            if tightFrameMatches.count == 1 {
                return tightFrameMatches[0]
            }
            if tightFrameMatches.count > 1 {
                return nil
            }
        }

        if freshCandidates.count == 1 {
            return freshCandidates.keys.first
        }

        return nil
    }

    func lookupPendingBridge(for observation: SystemObservation, normalizedTitle: String?, now: Date, ttl: TimeInterval) -> WindowID? {
        for signature in observation.candidateSignatures(normalizedTitle: normalizedTitle) {
            if let minimized = pendingMinimizedIDBySignature[signature],
               now.timeIntervalSince(minimized.timestamp) <= ttl {
                return minimized.id
            }
            if let disappeared = recentDisappearanceIDBySignature[signature],
               now.timeIntervalSince(disappeared.timestamp) <= ttl {
                return disappeared.id
            }
        }
        return nil
    }

    func recentObservationCount(
        for observation: SystemObservation,
        normalizedTitle: String?,
        now: Date,
        window: TimeInterval
    ) -> Int {
        let exactSignature = observation.exactSignature(normalizedTitle: normalizedTitle)
        if observation.bounds != nil {
            let exactCount = freshObservationEvidenceCount(
                for: exactSignature,
                now: now,
                window: window
            )
            if exactCount > 0 {
                return exactCount
            }
        }

        return freshObservationEvidenceCount(
            for: observation.coarseSignature(normalizedTitle: normalizedTitle),
            now: now,
            window: window
        )
    }

    mutating func makeTransientAXWindowID(pid: Int32) -> WindowID {
        let id = WindowID(rawValue: "ax-\(pid)-transient-\(nextTransientAXSequence)")
        nextTransientAXSequence += 1
        return id
    }

    mutating func retire(windowID: WindowID) {
        let exactSignatures = rememberedExactIDBySignature.compactMap { signature, timed in
            timed.id == windowID ? signature : nil
        }
        let coarseSignatures = rememberedCoarseCandidatesBySignature.compactMap { signature, entries in
            entries.keys.contains(windowID) ? signature : nil
        }
        let frameSignatures = rememberedFrameCandidatesBySignature.compactMap { signature, entries in
            entries.keys.contains(windowID) ? signature : nil
        }

        seenWindowIDs.remove(windowID)
        rememberedExactIDBySignature = rememberedExactIDBySignature.filter { $0.value.id != windowID }
        rememberedExactCandidatesBySignature = rememberedExactCandidatesBySignature.compactMapValues { entries in
            let filtered = entries.filter { $0.key != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        rememberedExactIDsByCoarseSignature = rememberedExactIDsByCoarseSignature.compactMapValues { entries in
            let filtered = entries.filter { $0.value.id != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        rememberedCoarseCandidatesBySignature = rememberedCoarseCandidatesBySignature.compactMapValues { entries in
            let filtered = entries.filter { $0.key != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        rememberedFramesByCoarseSignature = rememberedFramesByCoarseSignature.compactMapValues { entries in
            let filtered = entries.filter { $0.key != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        recentInventoryCandidatesByCoarseSignature = recentInventoryCandidatesByCoarseSignature.compactMapValues { entries in
            let filtered = entries.filter { $0.key != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        windowIDByCGWindowID = windowIDByCGWindowID.filter { $0.value != windowID }
        rememberedFrameCandidatesBySignature = rememberedFrameCandidatesBySignature.compactMapValues { entries in
            let filtered = entries.filter { $0.key != windowID }
            return filtered.isEmpty ? nil : filtered
        }
        recentDisappearanceIDBySignature = recentDisappearanceIDBySignature.filter { $0.value.id != windowID }
        pendingMinimizedIDBySignature = pendingMinimizedIDBySignature.filter { $0.value.id != windowID }
        for signature in Set(exactSignatures + coarseSignatures + frameSignatures) {
            recentObservationEvidenceBySignature.removeValue(forKey: signature)
        }
    }

    private func nextObservationEvidence(
        previous: TimedObservationEvidence?,
        timestamp: Date
    ) -> TimedObservationEvidence {
        guard let previous,
              timestamp.timeIntervalSince(previous.timestamp) <= observationStreakDefaultWindow else {
            return TimedObservationEvidence(count: 1, timestamp: timestamp)
        }

        return TimedObservationEvidence(count: previous.count + 1, timestamp: timestamp)
    }

    private func freshExactMatch(
        for signature: String,
        now: Date,
        ttl: TimeInterval
    ) -> WindowID? {
        guard let match = rememberedExactIDBySignature[signature],
              now.timeIntervalSince(match.timestamp) <= ttl else {
            return nil
        }
        return match.id
    }

    private func freshExactCandidates(
        for signature: String,
        now: Date,
        ttl: TimeInterval
    ) -> [WindowID] {
        guard let candidates = rememberedExactCandidatesBySignature[signature] else {
            if let single = freshExactMatch(for: signature, now: now, ttl: ttl) {
                return [single]
            }
            return []
        }

        return candidates.compactMap { candidate, timestamp in
            now.timeIntervalSince(timestamp) <= ttl ? candidate : nil
        }
    }

    private func hasConflictingFreshExactSignature(
        for coarseSignature: String,
        excluding exactSignature: String,
        now: Date,
        ttl: TimeInterval
    ) -> Bool {
        guard let exactEntries = rememberedExactIDsByCoarseSignature[coarseSignature] else {
            return false
        }

        for (candidateSignature, timed) in exactEntries {
            guard candidateSignature != exactSignature else { continue }
            if now.timeIntervalSince(timed.timestamp) <= ttl {
                return true
            }
        }

        return false
    }

    private func freshCoarseCandidates(
        for coarseSignature: String,
        now: Date,
        ttl: TimeInterval
    ) -> [WindowID] {
        guard let candidates = rememberedCoarseCandidatesBySignature[coarseSignature] else {
            return []
        }

        return candidates.compactMap { candidate, timestamp in
            now.timeIntervalSince(timestamp) <= ttl ? candidate : nil
        }
    }

    private func freshFrameCandidates(
        for frameSignature: String,
        now: Date,
        ttl: TimeInterval
    ) -> [WindowID] {
        guard let candidates = rememberedFrameCandidatesBySignature[frameSignature] else {
            return []
        }

        return candidates.compactMap { candidate, timestamp in
            now.timeIntervalSince(timestamp) <= ttl ? candidate : nil
        }
    }

    private func freshTolerantFrameCandidates(
        for observation: SystemObservation,
        coarseSignature: String,
        now: Date,
        ttl: TimeInterval
    ) -> [WindowID]? {
        guard let bounds = observation.bounds,
              let entries = rememberedFramesByCoarseSignature[coarseSignature] else {
            return nil
        }

        return entries.compactMap { windowID, frame in
            guard now.timeIntervalSince(frame.timestamp) <= ttl else { return nil }
            return WindowFrameMatchPolicy.areClose(bounds, frame.bounds) ? windowID : nil
        }
    }

    private func freshObservationEvidenceCount(
        for signature: String,
        now: Date,
        window: TimeInterval
    ) -> Int {
        guard let evidence = recentObservationEvidenceBySignature[signature],
              now.timeIntervalSince(evidence.timestamp) <= window else {
            return 0
        }
        return evidence.count
    }
}

private struct IdentityResolution {
    let windowID: WindowID
    let confidence: Confidence
    let reason: String
}

private enum RememberedIdentityLookup {
    case matched(WindowID, RememberedMatchKind)
    case conflict
    case none
}

private enum RememberedMatchKind {
    case coarse
    case frameOnly
}

private struct TimedWindowID {
    let id: WindowID
    let timestamp: Date
}

private struct TimedFrame {
    let bounds: CGRect
    let timestamp: Date
}

private struct TimedOptionalFrame {
    let bounds: CGRect?
    let timestamp: Date
}

private struct TimedObservationEvidence {
    let count: Int
    let timestamp: Date
}

private extension SystemObservation {
    func exactSignature(normalizedTitle: String?) -> String {
        let normalizedTitle = normalizedTitle ?? title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "untitled"
        let boundsPart: String
        boundsPart = WindowFrameMatchPolicy.signature(for: bounds)

        return "\(pid)|\(normalizedTitle)|\(boundsPart)"
    }

    func coarseSignature(normalizedTitle: String?) -> String {
        let normalizedTitle = normalizedTitle ?? title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "untitled"
        return "\(pid)|\(normalizedTitle)"
    }

    func frameSignature() -> String? {
        guard let bounds else { return nil }
        return "\(pid)|frame-only|\(WindowFrameMatchPolicy.signature(for: bounds))"
    }

    func candidateSignatures(normalizedTitle: String?) -> [String] {
        if bounds != nil {
            return [exactSignature(normalizedTitle: normalizedTitle), coarseSignature(normalizedTitle: normalizedTitle)]
        }
        return [coarseSignature(normalizedTitle: normalizedTitle)]
    }
}
