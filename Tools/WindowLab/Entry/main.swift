import Foundation

enum LabMode: String {
    case observe
    case minimizeRestore
    case closeTarget
    case replay
    case placementReplay
    case transitionReplay
}

struct AnalyzedObservation {
    let observation: SystemObservation
    let identity: IdentityDecision
}

struct LabTarget {
    let displayName: String
    let pid: Int32
    let baselineIdentity: WindowID
    let baselineCGWindowID: UInt32?
    let title: String?
    let bounds: CGRect?
}

var cgSource = CoreGraphicsSource()
let axSource = AccessibilitySource()
let finderSource = FinderSource()
let axActionExecutor = AccessibilityWindowActionExecutor()
let identityEngine = WindowIdentityEngine()
let formatter = ISO8601DateFormatter()

let rawArguments = Array(CommandLine.arguments.dropFirst())
let mode = rawArguments.first.flatMap(LabMode.init(rawValue:)) ?? .observe
let modeArguments = Array(rawArguments.dropFirst())

func loadScenarioURL(named scenarioName: String) -> URL {
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let preferred = currentDirectory.appendingPathComponent("Tools/WindowLab/Scenarios/\(scenarioName).json")
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let fallbackRoot = executableURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fallback = fallbackRoot.appendingPathComponent("Tools/WindowLab/Scenarios/\(scenarioName).json")
    return FileManager.default.fileExists(atPath: preferred.path) ? preferred : fallback
}

func analyze(_ observation: SystemObservation) -> AnalyzedObservation {
    AnalyzedObservation(
        observation: observation,
        identity: identityEngine.identify(observation: observation)
    )
}

func analyze(_ observations: [SystemObservation]) -> [AnalyzedObservation] {
    observations.map(analyze)
}

func frameString(for observation: SystemObservation) -> String {
    observation.bounds.map {
        "\(Int($0.origin.x.rounded())):\(Int($0.origin.y.rounded())):\(Int($0.width.rounded())):\(Int($0.height.rounded()))"
    } ?? "<unknown>"
}

func displayName(for analyzed: AnalyzedObservation) -> String {
    analyzed.observation.title ?? analyzed.observation.appName ?? analyzed.identity.windowID.rawValue
}

func printObservation(_ analyzed: AnalyzedObservation, label: String) {
    let observation = analyzed.observation
    let identity = analyzed.identity
    let title = observation.title ?? ""
    let frame = frameString(for: observation)
    print("[\(formatter.string(from: Date()))] [\(label):\(observation.kind.rawValue.uppercased())] identity=\(identity.windowID.rawValue) confidence=\(identity.confidence.rawValue.uppercased())")
    print("  signals: pid=\(observation.pid) cg_id=\(observation.cgWindowID ?? 0) title=\"\(title)\" frame=\(frame)")
    print("  source: \(observation.source.rawValue) minimized=\(observation.isMinimized) focused=\(observation.isFocusedWindow)")
    print("  decision: \(identity.kind.rawValue.uppercased()) (\(identity.reason))")
    print("  prev_state: <unknown> -> new_state: ACTIVE")
}

@discardableResult
func printObservation(_ observation: SystemObservation, label: String) -> IdentityDecision {
    let analyzed = analyze(observation)
    printObservation(analyzed, label: label)
    return analyzed.identity
}

func collectRealObservations() -> [SystemObservation] {
    let cg = cgSource.observe()
    let ax = axSource.observe()
    let finder = finderSource.observe()
    return cg + ax + finder
}

func collectAnalyzedRealObservations() -> [AnalyzedObservation] {
    analyze(collectRealObservations())
}

func baselineCandidates(from analyzed: [AnalyzedObservation]) -> [AnalyzedObservation] {
    analyzed
        .filter { analyzed in
            analyzed.observation.source == .coreGraphics
                && analyzed.observation.kind != .disappeared
                && analyzed.identity.kind != .ambiguous
        }
        .sorted {
            displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending
        }
}

func printPhaseObservations(_ analyzed: [AnalyzedObservation], phase: String) {
    for item in analyzed.prefix(12) {
        let label = item.observation.source == .coreGraphics ? "CG-\(phase)" : "AX-\(phase)"
        printObservation(item, label: label)
    }
}

func printCandidateList(_ candidates: [AnalyzedObservation]) {
    print("# candidate windows:")
    for (index, candidate) in candidates.enumerated() {
        let observation = candidate.observation
        print(
            "  [\(index + 1)] \(displayName(for: candidate)) | identity=\(candidate.identity.windowID.rawValue) pid=\(observation.pid) cg_id=\(observation.cgWindowID ?? 0)"
        )
    }
}

func selectCandidate(from candidates: [AnalyzedObservation], preferredKeyword: String?) -> AnalyzedObservation? {
    if let preferredKeyword {
        let trimmed = preferredKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            if let indexCandidate = candidateByIndexSelector(trimmed, from: candidates) {
                return indexCandidate
            }

            if let cgCandidate = candidateByCGSelector(trimmed, from: candidates) {
                return cgCandidate
            }

            let matches = candidates.filter {
                displayName(for: $0).localizedCaseInsensitiveContains(trimmed)
            }

            if matches.isEmpty {
                fputs("no candidate matched keyword\n", stderr)
                return nil
            }

            if matches.count > 1 {
                print("# keyword matched multiple windows:")
                printCandidateList(matches)
                fputs("ambiguous target keyword\n", stderr)
                return nil
            }

            return matches[0]
        }
    }

    print("# type a candidate index, then press Return")
    guard let raw = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
          let index = Int(raw),
          candidates.indices.contains(index - 1) else {
        fputs("invalid candidate selection\n", stderr)
        return nil
    }

    return candidates[index - 1]
}

func candidateByIndexSelector(_ selector: String, from candidates: [AnalyzedObservation]) -> AnalyzedObservation? {
    guard selector.hasPrefix("index:") else { return nil }
    let raw = String(selector.dropFirst("index:".count))
    guard let index = Int(raw), candidates.indices.contains(index - 1) else {
        fputs("invalid index selector\n", stderr)
        return nil
    }
    return candidates[index - 1]
}

func candidateByCGSelector(_ selector: String, from candidates: [AnalyzedObservation]) -> AnalyzedObservation? {
    guard selector.hasPrefix("cg:") else { return nil }
    let raw = String(selector.dropFirst("cg:".count))
    guard let cgWindowID = UInt32(raw) else {
        fputs("invalid cg selector\n", stderr)
        return nil
    }

    guard let candidate = candidates.first(where: { $0.observation.cgWindowID == cgWindowID }) else {
        fputs("cg selector did not match any candidate\n", stderr)
        return nil
    }

    return candidate
}

func trackedObservation(in analyzed: [AnalyzedObservation], target: LabTarget) -> AnalyzedObservation? {
    if let sameIdentityCurrent = analyzed.first(where: {
        $0.identity.windowID == target.baselineIdentity && $0.observation.kind != .disappeared
    }) {
        return sameIdentityCurrent
    }

    if let sameIdentity = analyzed.first(where: { $0.identity.windowID == target.baselineIdentity }) {
        return sameIdentity
    }

    return analyzed.first {
        $0.observation.pid == target.pid && displayName(for: $0) == target.displayName
    }
}

func targetRelatedObservations(in analyzed: [AnalyzedObservation], target: LabTarget) -> [AnalyzedObservation] {
    analyzed.filter { candidate in
        let observation = candidate.observation

        if candidate.identity.windowID == target.baselineIdentity {
            return true
        }

        guard observation.pid == target.pid else { return false }

        if let baselineCGWindowID = target.baselineCGWindowID,
           observation.cgWindowID == baselineCGWindowID {
            return true
        }

        if let title = target.title,
           observation.title == title {
            return true
        }

        if let targetBounds = target.bounds,
           let bounds = observation.bounds,
           areClose(bounds, targetBounds) {
            return true
        }

        return false
    }
}

func currentVisibleCGWindowIDs(in analyzed: [AnalyzedObservation]) -> Set<UInt32> {
    Set(
        analyzed.compactMap { candidate in
            guard candidate.observation.source == .coreGraphics,
                  candidate.observation.kind != .disappeared else {
                return nil
            }
            return candidate.observation.cgWindowID
        }
    )
}

func printTargetDiagnostics(phase: String, analyzed: [AnalyzedObservation], target: LabTarget) {
    let related = targetRelatedObservations(in: analyzed, target: target)
    let cgMatches = related.filter { $0.observation.source == .coreGraphics }
    let axMatches = related.filter { $0.observation.source == .accessibility }

    print("# target diagnostics (\(phase)):")
    if cgMatches.isEmpty {
        print("  CG: <none>")
    } else {
        for match in cgMatches {
            let observation = match.observation
            print(
                "  CG: kind=\(observation.kind.rawValue) identity=\(match.identity.windowID.rawValue) cg_id=\(observation.cgWindowID ?? 0) minimized=\(observation.isMinimized) focused=\(observation.isFocusedWindow) title=\"\(observation.title ?? "")\" frame=\(frameString(for: observation))"
            )
        }
    }

    if axMatches.isEmpty {
        print("  AX: <none>")
    } else {
        for match in axMatches {
            let observation = match.observation
            print(
                "  AX: kind=\(observation.kind.rawValue) identity=\(match.identity.windowID.rawValue) cg_id=\(observation.cgWindowID ?? 0) minimized=\(observation.isMinimized) focused=\(observation.isFocusedWindow) title=\"\(observation.title ?? "")\" frame=\(frameString(for: observation))"
            )
        }
    }
}

func areClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= 4
        && abs(lhs.origin.y - rhs.origin.y) <= 4
        && abs(lhs.width - rhs.width) <= 4
        && abs(lhs.height - rhs.height) <= 4
}

func runObserveMode(rounds: Int = 3) {
    for round in 0..<rounds {
        let cgObservations = cgSource.observe().filter { observation in
            observation.kind != .unchanged || round > 0
        }

        for observation in cgObservations.prefix(10) {
            printObservation(observation, label: "CG")
        }

        if round == 0 {
            for observation in axSource.observe().prefix(10) {
                printObservation(observation, label: "AX")
            }
        }

        if round < rounds - 1 {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

func runMinimizeRestoreMode() {
    let preferredKeyword = modeArguments.first

    print("# minimize-restore acceptance")
    print("# goal: the tracked window must disappear from the CG list after minimize and restore with the same identity")
    print("# step 1: collect baseline windows")
    let baseline = collectAnalyzedRealObservations()
    printPhaseObservations(baseline, phase: "BASE")

    let candidates = baselineCandidates(from: baseline)
    guard candidates.isEmpty == false else {
        fputs("no visible CG candidates found\n", stderr)
        exit(1)
    }

    printCandidateList(candidates)
    if let preferredKeyword, preferredKeyword.isEmpty == false {
        print("# target keyword: \(preferredKeyword)")
    }

    guard let selected = selectCandidate(from: candidates, preferredKeyword: preferredKeyword) else {
        exit(1)
    }

    let target = LabTarget(
        displayName: displayName(for: selected),
        pid: selected.observation.pid,
        baselineIdentity: selected.identity.windowID,
        baselineCGWindowID: selected.observation.cgWindowID,
        title: selected.observation.title,
        bounds: selected.observation.bounds
    )

    print("# selected target: \(target.displayName)")
    print("# baseline identity: \(target.baselineIdentity.rawValue)")
    print("# baseline cg id: \(target.baselineCGWindowID ?? 0)")

    let actionTarget = AccessibilityWindowActionExecutor.WindowTarget(
        pid: target.pid,
        title: selected.observation.title,
        bounds: selected.observation.bounds
    )
    guard let actionHandle = axActionExecutor.captureHandle(for: actionTarget) else {
        fputs("unable to capture AX handle for selected target\n", stderr)
        exit(1)
    }

    print("# step 2: minimize the target window via AX")
    let minimizeExecution = axActionExecutor.minimize(actionHandle)
    print(
        "# minimize action: mechanism=\(minimizeExecution.mechanism) verified_minimized=\(String(describing: minimizeExecution.verifiedMinimized)) success=\(minimizeExecution.success)"
    )
    guard minimizeExecution.success else {
        fputs("failed to minimize selected target via AX\n", stderr)
        exit(1)
    }
    Thread.sleep(forTimeInterval: 0.8)

    print("# step 3: collect minimized-state windows")
    let minimized = collectAnalyzedRealObservations()
    printPhaseObservations(minimized, phase: "MIN")
    printTargetDiagnostics(phase: "minimized", analyzed: minimized, target: target)

    let minimizedCGIDs = currentVisibleCGWindowIDs(in: minimized)
    let disappearedFromCG: Bool
    if let baselineCGWindowID = target.baselineCGWindowID {
        disappearedFromCG = minimizedCGIDs.contains(baselineCGWindowID) == false
    } else {
        disappearedFromCG = true
    }

    let minimizedMatch = trackedObservation(in: minimized, target: target)
    print("# target during minimize:")
    if let minimizedMatch {
        print(
            "  identity=\(minimizedMatch.identity.windowID.rawValue) source=\(minimizedMatch.observation.source.rawValue) cg_id=\(minimizedMatch.observation.cgWindowID ?? 0)"
        )
    } else {
        print("  <not directly observed>")
    }
    print("# baseline cg id disappeared: \(disappearedFromCG)")

    print("# step 4: restore the target window via AX")
    let restoreExecution = axActionExecutor.restore(actionHandle)
    print(
        "# restore action: mechanism=\(restoreExecution.mechanism) verified_minimized=\(String(describing: restoreExecution.verifiedMinimized)) success=\(restoreExecution.success)"
    )
    guard restoreExecution.success else {
        fputs("failed to restore selected target via AX\n", stderr)
        exit(1)
    }
    Thread.sleep(forTimeInterval: 0.8)

    print("# step 5: collect restored-state windows")
    let restored = collectAnalyzedRealObservations()
    printPhaseObservations(restored, phase: "RESTORE")
    printTargetDiagnostics(phase: "restored", analyzed: restored, target: target)

    let restoredMatch = trackedObservation(in: restored, target: target)
    let restoredIdentity = restoredMatch?.identity.windowID.rawValue ?? "<missing>"
    let stableIdentity = restoredMatch?.identity.windowID == target.baselineIdentity
    print("# restored target: \(restoredMatch.map(displayName(for:)) ?? "<missing>")")
    if let restoredMatch {
        print(
            "# restored source: \(restoredMatch.observation.source.rawValue) cg_id=\(restoredMatch.observation.cgWindowID ?? 0) confidence=\(restoredMatch.identity.confidence.rawValue.uppercased())"
        )
    }
    print("# baseline identity: \(target.baselineIdentity.rawValue)")
    print("# restored identity: \(restoredIdentity)")
    print("# stable identity after restore: \(stableIdentity)")

    let accepted = disappearedFromCG && stableIdentity
    print("# acceptance passed: \(accepted)")
    if accepted == false {
        fputs("minimize-restore acceptance failed\n", stderr)
        exit(1)
    }
}

func runCloseTargetMode() {
    let preferredKeyword = modeArguments.first

    print("# close-target acceptance")
    print("# goal: the tracked window should disappear from live observations after close")
    print("# step 1: collect baseline windows")
    let baseline = collectAnalyzedRealObservations()
    printPhaseObservations(baseline, phase: "BASE")

    let candidates = baselineCandidates(from: baseline)
        .filter { $0.observation.pid != ProcessInfo.processInfo.processIdentifier }
    guard candidates.isEmpty == false else {
        fputs("no visible CG candidates found\n", stderr)
        exit(1)
    }

    printCandidateList(candidates)
    if let preferredKeyword, preferredKeyword.isEmpty == false {
        print("# target keyword: \(preferredKeyword)")
    }

    guard let selected = selectCandidate(from: candidates, preferredKeyword: preferredKeyword) else {
        exit(1)
    }

    let target = LabTarget(
        displayName: displayName(for: selected),
        pid: selected.observation.pid,
        baselineIdentity: selected.identity.windowID,
        baselineCGWindowID: selected.observation.cgWindowID,
        title: selected.observation.title,
        bounds: selected.observation.bounds
    )

    print("# selected target: \(target.displayName)")
    print("# baseline identity: \(target.baselineIdentity.rawValue)")
    print("# baseline cg id: \(target.baselineCGWindowID ?? 0)")

    let actionTarget = AccessibilityWindowActionExecutor.WindowTarget(
        pid: target.pid,
        title: selected.observation.title,
        bounds: selected.observation.bounds
    )
    guard let actionHandle = axActionExecutor.captureHandle(for: actionTarget) else {
        fputs("unable to capture AX handle for selected target\n", stderr)
        exit(1)
    }

    print("# step 2: close the target window via AX")
    let closeSucceeded = axActionExecutor.close(actionHandle)
    print("# close action: success=\(closeSucceeded)")
    guard closeSucceeded else {
        fputs("failed to close selected target via AX\n", stderr)
        exit(1)
    }
    Thread.sleep(forTimeInterval: 1.2)

    print("# step 3: collect post-close windows")
    let afterClose = collectAnalyzedRealObservations()
    printPhaseObservations(afterClose, phase: "CLOSE")
    printTargetDiagnostics(phase: "closed", analyzed: afterClose, target: target)

    let stillVisible = afterClose.contains { candidate in
        guard candidate.observation.kind != .disappeared else { return false }
        if candidate.identity.windowID == target.baselineIdentity {
            return true
        }
        return candidate.observation.pid == target.pid
            && displayName(for: candidate) == target.displayName
    }
    print("# still visible after close: \(stillVisible)")

    if stillVisible {
        fputs("close-target acceptance failed\n", stderr)
        exit(1)
    }
}

struct ReplayScenario: Decodable {
    struct Step: Decodable {
        let label: String
        let observations: [ReplayObservation]
    }

    struct ReplayObservation: Decodable {
        let kind: String
        let source: String
        let pid: Int32
        let bundleIdentifier: String?
        let cgWindowID: UInt32?
        let title: String?
        let appName: String?
        let bounds: String?
        let isMinimized: Bool
        let isFocusedWindow: Bool?
        let track: Bool?
        let atSeconds: Double?
        let expectedDecision: String?
        let expectedReason: String?
        let expectedConfidence: String?
    }

    let name: String
    let expectedStableIdentity: Bool
    let steps: [Step]
}

struct PlacementReplayScenario: Decodable {
    struct Step: Decodable {
        let label: String
        let windowID: String
        let newStatus: String
        let atSeconds: Double
        let expectedOrder: [String]
    }

    let name: String
    let initialOrderedWindowIDs: [String]
    let steps: [Step]
}

struct TransitionReplayScenario: Decodable {
    struct Step: Decodable {
        let label: String
        let observation: ReplayScenario.ReplayObservation
        let expectedStatus: String
        let trackCloseAtSeconds: Double?
    }

    let name: String
    let steps: [Step]
}

func parseBounds(_ raw: String?) -> CGRect? {
    guard let raw else { return nil }
    let parts = raw.split(separator: ":").compactMap { Double($0) }
    guard parts.count == 4 else { return nil }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}

func systemObservation(from replay: ReplayScenario.ReplayObservation) -> SystemObservation {
    let timestamp = Date(timeIntervalSince1970: replay.atSeconds ?? 0)
    return SystemObservation(
        timestamp: timestamp,
        kind: SystemObservation.ObservationKind(rawValue: replay.kind)!,
        source: SystemObservation.ObservationSource(rawValue: replay.source)!,
        pid: replay.pid,
        bundleIdentifier: replay.bundleIdentifier,
        cgWindowID: replay.cgWindowID,
        title: replay.title,
        appName: replay.appName,
        bounds: parseBounds(replay.bounds),
        isMinimized: replay.isMinimized,
        isFocusedWindow: replay.isFocusedWindow ?? false
    )
}

func runReplayMode() {
    let replayScenarioName = modeArguments.first ?? "minimize-restore-replay"
    let root = loadScenarioURL(named: replayScenarioName)
    let data = try! Data(contentsOf: root)
    let scenario = try! JSONDecoder().decode(ReplayScenario.self, from: data)
    print("# replay scenario: \(scenario.name)")

    var trackedKey = ""
    var beforeIdentity = ""
    var finalIdentity = ""

    for (stepIndex, step) in scenario.steps.enumerated() {
        print("# step: \(step.label)")
        for replayObservation in step.observations {
            let observation = systemObservation(from: replayObservation)
            let identity = printObservation(observation, label: "REPLAY")
            if let expectedDecision = replayObservation.expectedDecision,
               identity.kind.rawValue != expectedDecision {
                fputs("unexpected decision kind\\n", stderr)
                exit(1)
            }
            if let expectedReason = replayObservation.expectedReason,
               identity.reason != expectedReason {
                fputs("unexpected decision reason\\n", stderr)
                exit(1)
            }
            if let expectedConfidence = replayObservation.expectedConfidence,
               identity.confidence.rawValue != expectedConfidence {
                fputs("unexpected decision confidence\\n", stderr)
                exit(1)
            }
            let key = observation.title ?? observation.appName ?? "untitled"
            let isTracked = replayObservation.track ?? (step.observations.count == 1)
            if isTracked {
                trackedKey = key
                if stepIndex == 0 && beforeIdentity.isEmpty {
                    beforeIdentity = identity.windowID.rawValue
                }
                if stepIndex == scenario.steps.count - 1 {
                    finalIdentity = identity.windowID.rawValue
                }
            }
        }
    }

    let stable = beforeIdentity == finalIdentity && !beforeIdentity.isEmpty
    print("# tracked key: \(trackedKey)")
    print("# before identity: \(beforeIdentity)")
    print("# final identity: \(finalIdentity)")
    print("# stable identity: \(stable)")
    if stable != scenario.expectedStableIdentity {
        fputs("replay scenario failed\\n", stderr)
        exit(1)
    }
}

func runPlacementReplayMode() {
    let placementScenarioName = modeArguments.first ?? "placement-permanent-hold-replay"
    let root = loadScenarioURL(named: placementScenarioName)
    let data = try! Data(contentsOf: root)
    let scenario = try! JSONDecoder().decode(PlacementReplayScenario.self, from: data)
    let engine = PlacementEngine()

    var snapshot = DockSnapshot(
        windows: Dictionary(
            uniqueKeysWithValues: scenario.initialOrderedWindowIDs.map { rawID in
                let id = WindowID(rawValue: rawID)
                return (
                    id,
                    WindowRecord(
                        id: id,
                        appID: AppID(rawValue: "placement-lab"),
                        pid: 0,
                        bundleIdentifier: nil,
                        title: rawID,
                        bounds: nil,
                        status: .inactive
                    )
                )
            }
        ),
        orderedWindowIDs: scenario.initialOrderedWindowIDs.map { WindowID(rawValue: $0) }
    )

    print("# placement replay scenario: \(scenario.name)")
    print("# initial order: \(scenario.initialOrderedWindowIDs.joined(separator: ","))")

    for step in scenario.steps {
        let lifecycle = LifecycleDecision(
            windowID: WindowID(rawValue: step.windowID),
            newStatus: WindowStatus(rawValue: step.newStatus)!,
            requests: [],
            observedAt: Date(timeIntervalSince1970: step.atSeconds)
        )
        let result = engine.place(snapshot: snapshot, lifecycle: lifecycle)
        let actualOrder = result.orderedWindowIDs.map { $0.rawValue }
        print("# step: \(step.label)")
        print("  lifecycle: window=\(step.windowID) status=\(step.newStatus) at=\(step.atSeconds)")
        print("  order: \(actualOrder.joined(separator: ","))")

        if actualOrder != step.expectedOrder {
            fputs("unexpected placement order\\n", stderr)
            exit(1)
        }

        snapshot = nextSnapshot(from: snapshot, lifecycle: lifecycle, orderedWindowIDs: result.orderedWindowIDs)
    }
}

@MainActor
func runTransitionReplayMode() {
    let scenarioName = modeArguments.first ?? "focused-active-replay"
    let root = loadScenarioURL(named: scenarioName)
    let data = try! Data(contentsOf: root)
    let scenario = try! JSONDecoder().decode(TransitionReplayScenario.self, from: data)

    let state = DockState()
    let identity = WindowIdentityEngine()
    let transitions = LifecycleTransitionEngine()
    let placement = PlacementEngine()
    let pendingCloseTracker = PendingCloseTracker()
    let pipeline = ObservationPipeline(
        state: state,
        identity: identity,
        transitions: transitions,
        placement: placement,
        pendingCloseTracker: pendingCloseTracker
    )

    print("# transition replay scenario: \(scenario.name)")
    for step in scenario.steps {
        let observation = systemObservation(from: step.observation)
        let decision = identity.identify(observation: observation)
        if let trackCloseAtSeconds = step.trackCloseAtSeconds {
            pendingCloseTracker.track(
                windowID: decision.windowID,
                at: Date(timeIntervalSince1970: trackCloseAtSeconds)
            )
        }

        pipeline.process(observation)
        let actualStatus = state.snapshot.windows[decision.windowID]?.status.rawValue ?? "closedPending"
        print("# step: \(step.label)")
        print("  identity: \(decision.windowID.rawValue)")
        print("  status: \(actualStatus)")

        if actualStatus != step.expectedStatus {
            fputs("unexpected lifecycle status\\n", stderr)
            exit(1)
        }
    }
}

func nextSnapshot(
    from snapshot: DockSnapshot,
    lifecycle: LifecycleDecision,
    orderedWindowIDs: [WindowID]
) -> DockSnapshot {
    var windows = snapshot.windows
    switch lifecycle.newStatus {
    case .disappeared, .closedPending:
        windows.removeValue(forKey: lifecycle.windowID)
    default:
        let existing = windows[lifecycle.windowID]
        windows[lifecycle.windowID] = WindowRecord(
            id: lifecycle.windowID,
            appID: existing?.appID ?? AppID(rawValue: "placement-lab"),
            pid: existing?.pid ?? 0,
            bundleIdentifier: existing?.bundleIdentifier,
            title: existing?.title ?? lifecycle.windowID.rawValue,
            bounds: existing?.bounds,
            status: lifecycle.newStatus
        )
    }

    return DockSnapshot(
        windows: windows,
        orderedWindowIDs: orderedWindowIDs
    )
}

switch mode {
case .observe:
    runObserveMode()
case .minimizeRestore:
    runMinimizeRestoreMode()
case .closeTarget:
    runCloseTargetMode()
case .replay:
    runReplayMode()
case .placementReplay:
    runPlacementReplayMode()
case .transitionReplay:
    MainActor.assumeIsolated { runTransitionReplayMode() }
}
