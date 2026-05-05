import Foundation

enum ObservationKindMergeRule {
    static func preferred(
        _ lhs: SystemObservation.ObservationKind?,
        _ rhs: SystemObservation.ObservationKind
    ) -> SystemObservation.ObservationKind {
        guard let lhs else { return rhs }
        return priority(rhs) < priority(lhs) ? rhs : lhs
    }

    private static func priority(_ kind: SystemObservation.ObservationKind) -> Int {
        switch kind {
        case .hidden:
            return 0
        case .minimized:
            return 1
        case .unhidden:
            return 2
        case .restored:
            return 3
        case .appeared:
            return 4
        case .disappeared:
            return 5
        case .titleChanged:
            return 6
        case .unchanged:
            return 7
        }
    }
}
