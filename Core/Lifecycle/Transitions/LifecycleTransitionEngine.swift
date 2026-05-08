import Foundation

final class LifecycleTransitionEngine {
    func transition(identity: IdentityDecision, observation: SystemObservation, snapshot: DockSnapshot) -> LifecycleDecision {
        let existingStatus = snapshot.windows[identity.windowID]?.status
        let status: WindowStatus
        switch observation.kind {
        case .appeared, .restored, .unhidden:
            status = observation.isFocusedWindow ? .active : .inactive
        case .titleChanged, .unchanged:
            if (observation.source == .accessibility || observation.source == .appWindowInventory),
               observation.isMinimized == false {
                status = observation.isFocusedWindow ? .active : .inactive
            } else {
                status = existingStatus ?? .inactive
            }
        case .minimized:
            status = .minimized
        case .hidden:
            status = .hidden
        case .disappeared:
            status = .disappeared
        }
        return LifecycleDecision(
            windowID: identity.windowID,
            newStatus: status,
            requests: [],
            observedAt: observation.timestamp
        )
    }
}
