import Foundation

final class PlacementEngine {
    func place(snapshot: DockSnapshot, lifecycle: LifecycleDecision) -> PlacementResult {
        let existingIDs = snapshot.orderedWindowIDs
        let alreadyTracked = existingIDs.contains(lifecycle.windowID)

        switch lifecycle.newStatus {
        case .closedPending:
            return PlacementResult(
                orderedWindowIDs: existingIDs.filter { $0 != lifecycle.windowID }
            )
        default:
            if alreadyTracked {
                return PlacementResult(orderedWindowIDs: existingIDs)
            }

            return PlacementResult(
                orderedWindowIDs: existingIDs + [lifecycle.windowID]
            )
        }
    }
}
