import Foundation

struct ProcessedObservation {
    let observation: SystemObservation
    let identity: IdentityDecision
    let lifecycle: LifecycleDecision
}

final class ObservationPipeline {
    private let state: DockState
    private let identity: WindowIdentityEngine
    private let transitions: LifecycleTransitionEngine
    private let placement: PlacementEngine
    private let pendingCloseTracker: PendingCloseTracker

    init(
        state: DockState,
        identity: WindowIdentityEngine,
        transitions: LifecycleTransitionEngine,
        placement: PlacementEngine,
        pendingCloseTracker: PendingCloseTracker
    ) {
        self.state = state
        self.identity = identity
        self.transitions = transitions
        self.placement = placement
        self.pendingCloseTracker = pendingCloseTracker
    }

    @discardableResult
    func process(_ observation: SystemObservation) -> ProcessedObservation? {
        let snapshot = state.snapshot
        let identityDecision = identity.identify(observation: observation, snapshot: snapshot)
        guard identityDecision.kind != .ambiguous else { return nil }

        var lifecycleDecision = transitions.transition(identity: identityDecision, observation: observation, snapshot: snapshot)
        if pendingCloseTracker.consumeClosedPending(windowID: identityDecision.windowID, observation: observation) {
            lifecycleDecision = LifecycleDecision(
                windowID: identityDecision.windowID,
                newStatus: .closedPending,
                requests: lifecycleDecision.requests,
                observedAt: lifecycleDecision.observedAt
            )
        }
        let placementResult: PlacementResult
        if shouldRecomputePlacement(
            observation: observation,
            lifecycle: lifecycleDecision,
            snapshot: snapshot
        ) {
            placementResult = placement.place(snapshot: snapshot, lifecycle: lifecycleDecision)
        } else {
            placementResult = PlacementResult(orderedWindowIDs: snapshot.orderedWindowIDs)
        }

        let update = StateUpdate(
            windowID: lifecycleDecision.windowID,
            windowRecord: makeWindowRecord(
                observation: observation,
                identity: identityDecision,
                lifecycle: lifecycleDecision
            ),
            orderedWindowIDs: placementResult.orderedWindowIDs
        )
        state.commit(update)
        if lifecycleDecision.newStatus == .closedPending {
            identity.retire(windowID: lifecycleDecision.windowID)
        }
        return ProcessedObservation(
            observation: observation,
            identity: identityDecision,
            lifecycle: lifecycleDecision
        )
    }

    private func shouldRecomputePlacement(
        observation: SystemObservation,
        lifecycle: LifecycleDecision,
        snapshot: DockSnapshot
    ) -> Bool {
        let wasTracked = snapshot.orderedWindowIDs.contains(lifecycle.windowID)
        let previousStatus = snapshot.windows[lifecycle.windowID]?.status

        if wasTracked == false {
            return true
        }

        if previousStatus != lifecycle.newStatus {
            return true
        }

        switch observation.kind {
        case .appeared, .restored, .unhidden, .minimized, .hidden, .disappeared:
            return true
        case .titleChanged, .unchanged:
            return false
        }
    }

    private func makeWindowRecord(
        observation: SystemObservation,
        identity: IdentityDecision,
        lifecycle: LifecycleDecision
    ) -> WindowRecord? {
        let existing = state.snapshot.windows[lifecycle.windowID]
        if lifecycle.newStatus == .closedPending {
            return nil
        }
        if lifecycle.newStatus == .disappeared, existing == nil {
            return nil
        }

        let title = observation.title ?? existing?.title ?? observation.appName ?? identity.reason
        let appRawValue = observation.bundleIdentifier ?? existing?.appID.rawValue ?? "pid-\(observation.pid)"

        return WindowRecord(
            id: lifecycle.windowID,
            appID: AppID(rawValue: appRawValue),
            pid: observation.pid,
            bundleIdentifier: observation.bundleIdentifier ?? existing?.bundleIdentifier,
            title: title,
            bounds: observation.bounds ?? existing?.bounds,
            status: lifecycle.newStatus
        )
    }
}
