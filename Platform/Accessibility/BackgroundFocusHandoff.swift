import CoreGraphics
import Darwin

struct BackgroundActivationTarget: Equatable {
    let pid: pid_t
    let cgWindowID: CGWindowID
}

struct BackgroundWindowIdentity: Hashable {
    let pid: pid_t
    let cgWindowID: CGWindowID
}

struct BackgroundWindowCandidate: Equatable {
    let pid: pid_t
    let cgWindowID: CGWindowID?
    let layer: Int
    let isRegularApplication: Bool
    let isTrustedWindow: Bool
}

enum BackgroundActivationDecision {
    static func trustedWindowIdentities(in snapshot: DockSnapshot) -> Set<BackgroundWindowIdentity> {
        Set(snapshot.orderedWindowIDs.compactMap { windowID in
            guard let record = snapshot.windows[windowID],
                  record.status != .closedPending,
                  let cgWindowID = record.cgWindowID,
                  cgWindowID != 0 else { return nil }
            return BackgroundWindowIdentity(pid: record.pid, cgWindowID: cgWindowID)
        })
    }

    static func target(
        frontToBack candidates: [BackgroundWindowCandidate],
        excludingPID: pid_t,
        dockPID: pid_t
    ) -> BackgroundActivationTarget? {
        for candidate in candidates {
            guard candidate.layer == 0,
                  candidate.pid != excludingPID,
                  candidate.pid != dockPID,
                  candidate.isRegularApplication,
                  candidate.isTrustedWindow,
                  let cgWindowID = candidate.cgWindowID,
                  cgWindowID != 0 else {
                continue
            }
            return BackgroundActivationTarget(pid: candidate.pid, cgWindowID: cgWindowID)
        }
        return nil
    }

    static func targetWindowIsFocused(
        isTargetAppActive: Bool,
        targetWindowID: CGWindowID?,
        focusedWindowID: CGWindowID?,
        elementsEqual: Bool
    ) -> Bool {
        guard isTargetAppActive else { return false }
        if let targetWindowID, let focusedWindowID {
            return targetWindowID == focusedWindowID
        }
        return elementsEqual
    }
}

enum BackgroundFocusHandoff {
    enum RaiseOutcome: Equatable {
        case notAttempted
        case succeeded
        case failed
        case unavailable
    }

    struct Outcome: Equatable {
        let carbonSubmitted: Bool
        let skyLightPosted: Bool
        let raise: RaiseOutcome

        /// Describes request submission only. The posting process cannot verify focus landing.
        var focusRequestSubmitted: Bool {
            carbonSubmitted || skyLightPosted
        }
    }

    static func perform(
        target: BackgroundActivationTarget,
        skyLightFocus: (pid_t, CGWindowID) -> Bool,
        axRaise: (() -> Bool)?,
        carbonSwitch: (pid_t) -> Bool
    ) -> Outcome {
        // Carbon's frontWindowOnly switch is the live-verified z-order handoff that keeps
        // the minimizing app's sibling windows down. SkyLight then assigns key ownership
        // to the exact candidate window, with AXRaise as a bounded best-effort reinforcement.
        let carbonSubmitted = carbonSwitch(target.pid)
        guard skyLightFocus(target.pid, target.cgWindowID) else {
            return Outcome(
                carbonSubmitted: carbonSubmitted,
                skyLightPosted: false,
                raise: .notAttempted
            )
        }
        guard let axRaise else {
            return Outcome(
                carbonSubmitted: carbonSubmitted,
                skyLightPosted: true,
                raise: .unavailable
            )
        }
        return Outcome(
            carbonSubmitted: carbonSubmitted,
            skyLightPosted: true,
            raise: axRaise() ? .succeeded : .failed
        )
    }
}
