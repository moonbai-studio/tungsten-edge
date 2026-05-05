import Foundation

enum DecisionKind: String, Hashable, Codable, Sendable {
    case knownWindow
    case newWindow
    case ambiguous
}

enum Confidence: String, Hashable, Codable, Sendable {
    case high
    case medium
    case low
}

struct IdentityDecision: Hashable, Sendable {
    let kind: DecisionKind
    let windowID: WindowID
    let confidence: Confidence
    let reason: String
}

struct LifecycleDecision: Hashable, Sendable {
    let windowID: WindowID
    let newStatus: WindowStatus
    let requests: [PlatformActionRequest]
    let observedAt: Date
}

struct PlacementResult: Hashable, Sendable {
    let orderedWindowIDs: [WindowID]
}

struct StateUpdate: Hashable, Sendable {
    let windowID: WindowID
    let windowRecord: WindowRecord?
    let orderedWindowIDs: [WindowID]
}
