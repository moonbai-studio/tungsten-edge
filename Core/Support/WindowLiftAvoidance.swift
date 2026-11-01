import CoreGraphics
import Darwin
import Foundation

struct WindowLiftAvoidanceContext: Equatable {
    /// AppKit global geometry used to calculate the lifted target frame.
    let geometry: WindowLiftAvoidance.Geometry
    /// CG/Quartz global geometry used by the front-to-back window scan.
    let screenCGFrame: CGRect
    let visibleCGFrame: CGRect
    /// Flip reference between CG/AX top-left and AppKit bottom-left coordinates.
    let primaryScreenHeight: CGFloat
}

/// “最大化窗口避让任务栏”的纯几何、节奏和会话决策。
///
/// 几何接口统一使用 AppKit 全局坐标（左下原点）；CGWindow/AX 的窗口 frame 在进入这里前
/// 通过 `appKitFrame(fromQuartz:primaryScreenHeight:)` 转换。
enum WindowLiftAvoidance {
    static let detectionTolerance: CGFloat = 12
    static let verificationTolerance: CGFloat = 2
    static let clearance: CGFloat = 2
    static let animationDuration: TimeInterval = 0.5
    /// The user-zoom-toggle restore (maximized → remembered frame): shorter than the lift, close to
    /// the system's own zoom animation, so the undo reads as one motion after the system's bulge.
    /// An interpolation plan, not a bound — each frame's AX round-trips add on top.
    static let userRestoreAnimationDuration: TimeInterval = 0.25
    static let animationFramesPerSecond: Double = 30
    static let globalDetectionInterval: TimeInterval = 0.2
    static let trackedSessionProbeInterval: TimeInterval = 0.05
    static let maximumReliftCount = 1
    /// 抢顶型应用在 ~450ms 内抢回铺满（Docs/05）；超过这个窗口的铺满重现按用户操作处理。
    /// 这是 L↔M 缩放记忆死锁的解药：缩放记忆被污染后窗口只在 native↔target 间往复、
    /// 永不产生 external 帧，时间尺度是唯一可靠的"应用 vs 用户"区分器。
    /// 取 ~450ms 的 2.2 倍余量；同时也是 abandoned 超时重开的等待——调大会直接放大
    /// "连续缩放后要等几秒才抬"的观感（owner 2026-07-16 反馈）。
    static let appReassertWindow: TimeInterval = 1.0
    /// 连续对峙轮数上限：abandoned 超时重开的次数；达到后这一轮彻底不再抬（owner 2026-09-18）。
    /// 平铺式窗口管理器（AeroSpace 等）会立刻把铺满的窗口摆回去，旧行为是到顶后降为慢频
    /// 重开、抬一下又被摆回，用户看到窗口底边周期性跳动；改成到顶即停手，让窗口安静地被条
    /// 压住底边。不永久锁死整机：external 帧（窗口不再铺满 / 换窗 / 关窗）是万能出口，清会话
    /// 后下一次铺满从零重来。
    static let maximumStandoffRounds = 2
    /// Size floor of a bottom-docked tile, as fractions of the visible frame. System halves and
    /// quarters, and third / quarter columns from snapping tools, all clear it.
    static let tileMinimumWidthFraction: CGFloat = 0.25
    static let tileMinimumHeightFraction: CGFloat = 0.30

    enum PollCadence {
        static let idleInterval: TimeInterval = 1.0

        static func interval(
            hasSessions: Bool,
            hasSuppressedFrames: Bool,
            isRestoring: Bool
        ) -> TimeInterval {
            hasSessions || hasSuppressedFrames || isRestoring
                ? globalDetectionInterval
                : idleInterval
        }
    }

    struct EventPollCoalescer: Equatable {
        enum Action: Equatable {
            case none
            case start
            case schedule(after: TimeInterval)
        }

        private(set) var pending = false
        private(set) var lastStartedAt: TimeInterval?

        mutating func request(at now: TimeInterval, scanInFlight: Bool) -> Action {
            pending = true
            return drain(at: now, scanInFlight: scanInFlight)
        }

        mutating func scanCompleted(at now: TimeInterval) -> Action {
            guard pending else { return .none }
            return drain(at: now, scanInFlight: false)
        }

        mutating func cooldownFired(at now: TimeInterval, scanInFlight: Bool) -> Action {
            guard pending else { return .none }
            return drain(at: now, scanInFlight: scanInFlight)
        }

        mutating func reset() {
            pending = false
            lastStartedAt = nil
        }

        private mutating func drain(at now: TimeInterval, scanInFlight: Bool) -> Action {
            guard !scanInFlight else { return .none }
            if let lastStartedAt {
                let remaining = globalDetectionInterval - (now - lastStartedAt)
                if remaining > 0.000_001 { return .schedule(after: remaining) }
            }
            pending = false
            lastStartedAt = now
            return .start
        }
    }

    /// cgWindowID 只在窗口仍存活的本轮会话内使用；控制器必须按 CG 全表定期 prune。
    struct WindowKey: Hashable {
        let pid: pid_t
        let cgWindowID: CGWindowID
    }

    struct Geometry: Equatable {
        /// AppKit global coordinates (bottom-left origin).
        let screenFrame: CGRect
        let visibleFrame: CGRect
        let taskbarTop: CGFloat

        func fillsVisibleFrame(
            _ frame: CGRect,
            tolerance: CGFloat = WindowLiftAvoidance.detectionTolerance
        ) -> Bool {
            guard mostlyBelongsToScreen(frame) else { return false }
            return WindowLiftAvoidance.fillsVisibleFrame(
                frame,
                visible: visibleFrame,
                tolerance: tolerance
            )
        }

        /// A window the system (or the user) parked against the bottom of the visible frame without
        /// filling it: a left / right half, a bottom half or quarter, a full-height column. Its
        /// bottom edge sits under the taskbar exactly like a maximized window's.
        ///
        /// Bottom edge flush, at least one more edge flush (top / left / right), nothing outside the
        /// visible frame, and no smaller than `tileMinimumWidthFraction` × `tileMinimumHeightFraction`
        /// of it — the floor keeps a small window resting in a corner from being squashed.
        /// `detectionTolerance` already covers the 8pt "tiled windows have margins" inset.
        func isBottomDockedTile(
            _ frame: CGRect,
            tolerance: CGFloat = WindowLiftAvoidance.detectionTolerance
        ) -> Bool {
            guard mostlyBelongsToScreen(frame),
                  WindowLiftAvoidance.isValid(frame: visibleFrame),
                  tolerance.isFinite,
                  tolerance >= 0 else {
                return false
            }
            let visible = visibleFrame
            guard abs(frame.minY - visible.minY) <= tolerance,
                  frame.minX >= visible.minX - tolerance,
                  frame.maxX <= visible.maxX + tolerance,
                  frame.maxY <= visible.maxY + tolerance,
                  frame.width >= visible.width * WindowLiftAvoidance.tileMinimumWidthFraction - tolerance,
                  frame.height >= visible.height * WindowLiftAvoidance.tileMinimumHeightFraction else {
                return false
            }
            return abs(frame.maxY - visible.maxY) <= tolerance
                || abs(frame.minX - visible.minX) <= tolerance
                || abs(frame.maxX - visible.maxX) <= tolerance
        }

        /// What the scan may lift: a frame filling the visible frame, plus bottom-docked tiles when
        /// `includesTiles` (`DOCK_WINDOW_LIFT_TILES`). No default on purpose — the controller's
        /// kill switch must reach every call.
        func isLiftEligible(_ frame: CGRect, includesTiles: Bool) -> Bool {
            fillsVisibleFrame(frame) || (includesTiles && isBottomDockedTile(frame))
        }

        /// `adjustedFrame(for:)` widened to bottom-docked tiles: same target bottom, same fixed
        /// top / left / width.
        func liftTargetFrame(
            for frame: CGRect,
            includesTiles: Bool,
            clearance: CGFloat = WindowLiftAvoidance.clearance
        ) -> CGRect? {
            guard isLiftEligible(frame, includesTiles: includesTiles),
                  clearance.isFinite,
                  clearance >= 0,
                  taskbarTop.isFinite else {
                return nil
            }
            return WindowLiftAvoidance.adjustedFrame(
                for: frame,
                targetBottom: max(frame.minY, visibleFrame.minY, taskbarTop + clearance)
            )
        }

        /// A suppressed window shows a frame that is not its old native one: may it start a fresh
        /// lift? A tile's native frame is not unique (left half → right half, a margin toggle), so
        /// "wait for the exact native frame" alone would leave a re-tiled window under the taskbar
        /// for good. Released only when the external frame that cleared the session was the user's
        /// (`externalFrameIsUserEra`), the new frame is eligible, and it is not maximized → maximized
        /// (that pair keeps the exact-native rule it always had).
        func suppressionReleasesOnNewFrame(
            _ frame: CGRect,
            suppressedNative: CGRect,
            userEra: Bool,
            includesTiles: Bool
        ) -> Bool {
            guard includesTiles, userEra, isLiftEligible(frame, includesTiles: true) else {
                return false
            }
            return !(fillsVisibleFrame(suppressedNative) && fillsVisibleFrame(frame))
        }

        /// 保持窗口顶、左、宽不变，只把底边收至系统保留区和钨极任务栏之上。
        func adjustedFrame(
            for maximizedFrame: CGRect,
            clearance: CGFloat = WindowLiftAvoidance.clearance
        ) -> CGRect? {
            guard fillsVisibleFrame(maximizedFrame),
                  clearance.isFinite,
                  clearance >= 0,
                  taskbarTop.isFinite else {
                return nil
            }

            let targetBottom = max(
                maximizedFrame.minY,
                visibleFrame.minY,
                taskbarTop + clearance
            )
            return WindowLiftAvoidance.adjustedFrame(
                for: maximizedFrame,
                targetBottom: targetBottom
            )
        }

        private func mostlyBelongsToScreen(_ frame: CGRect) -> Bool {
            guard WindowLiftAvoidance.isValid(frame: frame),
                  WindowLiftAvoidance.isValid(frame: screenFrame) else {
                return false
            }
            let overlap = frame.intersection(screenFrame)
            guard !overlap.isNull, !overlap.isEmpty else { return false }
            return overlap.width * overlap.height >= frame.width * frame.height * 0.5
        }
    }

    static func fillsVisibleFrame(
        _ frame: CGRect,
        visible: CGRect,
        tolerance: CGFloat = detectionTolerance
    ) -> Bool {
        guard isValid(frame: frame),
              isValid(frame: visible),
              tolerance.isFinite,
              tolerance >= 0 else {
            return false
        }
        return abs(frame.minX - visible.minX) <= tolerance
            && abs(frame.maxX - visible.maxX) <= tolerance
            && abs(frame.minY - visible.minY) <= tolerance
            && abs(frame.maxY - visible.maxY) <= tolerance
    }

    /// 低层几何 helper；调用方负责先做最大化判定。
    static func adjustedFrame(
        for frame: CGRect,
        taskbarTopY: CGFloat,
        clearance: CGFloat = clearance
    ) -> CGRect? {
        guard taskbarTopY.isFinite,
              clearance.isFinite,
              clearance >= 0 else {
            return nil
        }
        return adjustedFrame(
            for: frame,
            targetBottom: max(frame.minY, taskbarTopY + clearance)
        )
    }

    static func framesMatch(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = verificationTolerance
    ) -> Bool {
        guard isValid(frame: lhs),
              isValid(frame: rhs),
              tolerance.isFinite,
              tolerance >= 0 else {
            return false
        }
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    enum FrameClassification: Equatable {
        case target
        case native
        case managedTrajectory
        case external
    }

    /// Classifies an observed frame in fixed priority order. The order matters near either endpoint.
    static func frameClassification(
        of frame: CGRect,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        tolerance: CGFloat = verificationTolerance
    ) -> FrameClassification {
        guard isValid(frame: frame),
              isValid(frame: nativeFrame),
              isValid(frame: targetFrame),
              tolerance.isFinite,
              tolerance >= 0 else {
            return .external
        }
        if framesMatch(frame, targetFrame, tolerance: tolerance) { return .target }
        if framesMatch(frame, nativeFrame, tolerance: tolerance) { return .native }

        let lowerBottom = min(nativeFrame.minY, targetFrame.minY)
        let upperBottom = max(nativeFrame.minY, targetFrame.minY)
        let followsFixedEdges = abs(frame.minX - nativeFrame.minX) <= tolerance
            && abs(frame.width - nativeFrame.width) <= tolerance
            && abs(frame.maxY - nativeFrame.maxY) <= tolerance
        if followsFixedEdges,
           frame.minY >= lowerBottom,
           frame.minY <= upperBottom {
            return .managedTrajectory
        }
        return .external
    }

    /// Used by the bounded 0/100/250ms confirmation pass before an AX write begins.
    static func samplesAreStable(
        _ sample: CGRect,
        comparedTo reference: CGRect,
        tolerance: CGFloat = verificationTolerance
    ) -> Bool {
        framesMatch(sample, reference, tolerance: tolerance)
    }

    /// Requires the detected CG frame, the delayed CG confirmation, and AX's frame to agree
    /// without allowing pairwise drift to accumulate beyond the verification tolerance.
    static func samplesAreStable(
        initialCGFrame: CGRect,
        confirmedCGFrame: CGRect,
        confirmedAXFrame: CGRect,
        tolerance: CGFloat = verificationTolerance
    ) -> Bool {
        framesMatch(initialCGFrame, confirmedCGFrame, tolerance: tolerance)
            && framesMatch(initialCGFrame, confirmedAXFrame, tolerance: tolerance)
            && framesMatch(confirmedCGFrame, confirmedAXFrame, tolerance: tolerance)
    }

    // MARK: - AX synchronization retry schedule

    struct PollSchedule: Equatable {
        /// Absolute deadlines relative to CG detection; zero means the first AX attempt is immediate.
        let deadlines: [TimeInterval]

        static let standard = PollSchedule(deadlines: [0, 0.1, 0.25])

        var incrementalDelays: [TimeInterval] {
            var previous: TimeInterval = 0
            return deadlines.map { deadline in
                defer { previous = deadline }
                return max(0, deadline - previous)
            }
        }

        func remainingDelay(for index: Int, elapsed: TimeInterval) -> TimeInterval? {
            guard deadlines.indices.contains(index), elapsed.isFinite else { return nil }
            return max(0, deadlines[index] - max(0, elapsed))
        }
    }

    // MARK: - Lift session

    struct WriteAttempt: Equatable {
        /// Detached AX operation generation; write completion must match this value exactly.
        let generation: UInt64
        /// Newest CG observation consumed while the detached writer is still active.
        let latestObservationGeneration: UInt64
        let nativeFrame: CGRect
        let targetFrame: CGRect
        /// Number of application frame takeovers already answered in this maximize session.
        let reliftCount: Int
        /// abandoned 超时重开的累计轮数，随会话透传（external 清会话时随状态一起归零）。
        let standoffRounds: Int

        var isRelift: Bool { reliftCount > 0 }
    }

    struct LiftedSession: Equatable {
        /// Latest accepted observation generation, not a persistent window identity.
        let generation: UInt64
        let nativeFrame: CGRect
        /// 意图写入目标（非实际落点）：实际落点在 ±2pt 容差内浮动，若存实际值，
        /// 超时重开的新会话会以上一轮落点为目标，误差逐轮复利、底边越抬越高。
        let adjustedFrame: CGRect
        let reliftCount: Int
        /// 抬起写完成时刻（writeFinished 的 at）；铺满重现与它比对区分抢顶 vs 用户操作。
        let settledAt: TimeInterval
        let standoffRounds: Int
    }

    enum AbandonReason: Equatable {
        case reliftLimitReached
        case writeFailed
    }

    struct AbandonedSession: Equatable {
        let generation: UInt64
        let nativeFrame: CGRect
        let adjustedFrame: CGRect
        let reliftCount: Int
        let reason: AbandonReason
        /// 进入放弃态的时刻。后续观察不得刷新它，否则放弃态永不过期。
        let abandonedAt: TimeInterval
        let standoffRounds: Int
    }

    enum SessionState: Equatable {
        case idle
        case writing(WriteAttempt)
        case lifted(LiftedSession)
        case abandoned(AbandonedSession)
    }

    /// `at` 一律用 `ProcessInfo.systemUptime` 时间轴；reduce 保持纯函数，时间只从事件进来。
    enum Event: Equatable {
        case maximizedDetected(generation: UInt64, at: TimeInterval, nativeFrame: CGRect, targetFrame: CGRect)
        case writeFinished(generation: UInt64, at: TimeInterval, actualFrame: CGRect, reliftCount: Int)
        case writeFailed(generation: UInt64, at: TimeInterval, reliftCount: Int)
        case reliftLimitReached(generation: UInt64, at: TimeInterval, reliftCount: Int)
        /// The controller sends this only for a live frame that no longer fills visibleFrame.
        case nonMaximizedObserved(generation: UInt64, at: TimeInterval, frame: CGRect)
        case windowUnavailable(generation: UInt64)
        /// A window whose session an app-era external frame cleared is back on its native frame
        /// within `appReassertWindow` of that clear (`isDetourReturn`): the app answered our lift
        /// through a detour frame instead of snapping straight back. `standoffRounds` is what the
        /// cleared session carried; this return counts one more round, never a fresh session —
        /// otherwise the detour hands every bounce a fresh standoff budget and the window jitters
        /// for good.
        case detourReturnObserved(
            generation: UInt64,
            at: TimeInterval,
            nativeFrame: CGRect,
            targetFrame: CGRect,
            standoffRounds: Int
        )
    }

    enum Action: Equatable {
        case none
        case write(targetFrame: CGRect, rollbackFrame: CGRect, generation: UInt64, isRelift: Bool)
        case abandon(AbandonReason)
        case clear
    }

    struct Transition: Equatable {
        let state: SessionState
        let action: Action
    }

    /// 首次铺满写一次；应用抢回铺满后只补写一次；再次抢回则放弃。
    /// 时间尺度判定：铺满在写完/放弃后 `appReassertWindow` 内重现 = 应用抢顶（补抬/放弃）；
    /// 之后重现 = 用户操作（全新会话）。缩放记忆被污染的窗口只在 native↔target 间往复、
    /// 永不产生 external 帧，超时重开是它唯一的出口；`maximumStandoffRounds` 封顶防慢动作拉锯。
    static func reduce(state: SessionState, event: Event) -> Transition {
        switch event {
        case let .maximizedDetected(generation, at, nativeFrame, targetFrame):
            guard isValid(frame: nativeFrame), isValid(frame: targetFrame) else {
                return Transition(state: state, action: .none)
            }

            switch state {
            case .idle:
                return beginWrite(
                    generation: generation,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: 0,
                    standoffRounds: 0
                )

            case let .writing(attempt):
                // The detached writer owns trajectory recovery and relift while this attempt is active.
                guard generation > attempt.latestObservationGeneration else {
                    return Transition(state: state, action: .none)
                }
                return Transition(
                    state: writingAttempt(attempt, observing: generation),
                    action: .none
                )

            case let .lifted(session):
                guard generation > session.generation else {
                    return Transition(state: state, action: .none)
                }
                guard at - session.settledAt <= appReassertWindow else {
                    // 用户在写完许久后重新最大化：全新会话，补抬额度与对峙轮数归零。
                    return beginWrite(
                        generation: generation,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: 0,
                        standoffRounds: 0
                    )
                }
                return beginReliftOrAbandon(
                    generation: generation,
                    at: at,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: session.reliftCount,
                    standoffRounds: session.standoffRounds
                )

            case let .abandoned(session):
                guard generation >= session.generation else {
                    return Transition(state: state, action: .none)
                }
                if shouldReopenAbandoned(session, at: at) {
                    // 对峙窗口已过、未到顶：按用户操作超时重开，记一轮对峙；到顶后停手。
                    return beginWrite(
                        generation: generation,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: 0,
                        standoffRounds: min(session.standoffRounds + 1, maximumStandoffRounds)
                    )
                }
                return Transition(
                    state: .abandoned(AbandonedSession(
                        generation: generation,
                        nativeFrame: nativeFrame,
                        adjustedFrame: targetFrame,
                        reliftCount: session.reliftCount,
                        reason: session.reason,
                        abandonedAt: session.abandonedAt,
                        standoffRounds: session.standoffRounds
                    )),
                    action: .none
                )
            }

        case let .writeFinished(generation, at, actualFrame, reliftCount):
            guard case let .writing(attempt) = state,
                  attempt.generation == generation else {
                return Transition(state: state, action: .none)
            }
            guard reliftCount >= attempt.reliftCount,
                  reliftCount <= maximumReliftCount,
                  framesMatch(actualFrame, attempt.targetFrame) else {
                let abandoned = AbandonedSession(
                    generation: max(generation, attempt.latestObservationGeneration),
                    nativeFrame: attempt.nativeFrame,
                    adjustedFrame: attempt.targetFrame,
                    reliftCount: max(attempt.reliftCount, reliftCount),
                    reason: .writeFailed,
                    abandonedAt: at,
                    standoffRounds: attempt.standoffRounds
                )
                return Transition(state: .abandoned(abandoned), action: .abandon(.writeFailed))
            }
            return Transition(
                state: .lifted(LiftedSession(
                    generation: max(generation, attempt.latestObservationGeneration),
                    nativeFrame: attempt.nativeFrame,
                    adjustedFrame: attempt.targetFrame,
                    reliftCount: reliftCount,
                    settledAt: at,
                    standoffRounds: attempt.standoffRounds
                )),
                action: .none
            )

        case let .writeFailed(generation, at, reliftCount):
            return abandonWritingAttempt(
                state: state,
                generation: generation,
                at: at,
                reliftCount: reliftCount,
                reason: .writeFailed
            )

        case let .reliftLimitReached(generation, at, reliftCount):
            return abandonWritingAttempt(
                state: state,
                generation: generation,
                at: at,
                reliftCount: reliftCount,
                reason: .reliftLimitReached
            )

        case let .nonMaximizedObserved(generation, at, frame):
            guard isValid(frame: frame) else {
                return Transition(state: state, action: .none)
            }
            switch state {
            case .idle:
                return Transition(state: state, action: .none)

            case let .writing(attempt):
                guard generation >= attempt.latestObservationGeneration else {
                    return Transition(state: state, action: .none)
                }
                switch frameClassification(
                    of: frame,
                    nativeFrame: attempt.nativeFrame,
                    targetFrame: attempt.targetFrame
                ) {
                case .target, .managedTrajectory:
                    return Transition(
                        state: writingAttempt(attempt, observing: generation),
                        action: .none
                    )
                case .native:
                    // The detached writer classifies and consumes a native snap serially.
                    return Transition(
                        state: writingAttempt(attempt, observing: generation),
                        action: .none
                    )
                case .external:
                    return Transition(state: .idle, action: .clear)
                }

            case let .lifted(session):
                guard generation >= session.generation else {
                    return Transition(state: state, action: .none)
                }
                switch frameClassification(
                    of: frame,
                    nativeFrame: session.nativeFrame,
                    targetFrame: session.adjustedFrame
                ) {
                case .external:
                    return Transition(state: .idle, action: .clear)
                case .native:
                    guard generation > session.generation else {
                        return Transition(state: state, action: .none)
                    }
                    guard at - session.settledAt <= appReassertWindow else {
                        // 用户把窗口重新缩放回铺满（缩放记忆污染时不经过 external）：全新会话。
                        return beginWrite(
                            generation: generation,
                            nativeFrame: session.nativeFrame,
                            targetFrame: session.adjustedFrame,
                            reliftCount: 0,
                            standoffRounds: 0
                        )
                    }
                    return beginReliftOrAbandon(
                        generation: generation,
                        at: at,
                        nativeFrame: session.nativeFrame,
                        targetFrame: session.adjustedFrame,
                        reliftCount: session.reliftCount,
                        standoffRounds: session.standoffRounds
                    )
                case .target, .managedTrajectory:
                    // 抬起后安稳超过对峙窗口 = 这一轮拉锯结束，对峙轮数痊愈归零。
                    let healedRounds = at - session.settledAt > appReassertWindow
                        ? 0 : session.standoffRounds
                    return Transition(
                        state: .lifted(LiftedSession(
                            generation: generation,
                            nativeFrame: session.nativeFrame,
                            adjustedFrame: session.adjustedFrame,
                            reliftCount: session.reliftCount,
                            settledAt: session.settledAt,
                            standoffRounds: healedRounds
                        )),
                        action: .none
                    )
                }

            case let .abandoned(session):
                guard generation >= session.generation else {
                    return Transition(state: state, action: .none)
                }
                switch frameClassification(
                    of: frame,
                    nativeFrame: session.nativeFrame,
                    targetFrame: session.adjustedFrame
                ) {
                case .external:
                    return Transition(state: .idle, action: .clear)
                case .native:
                    if shouldReopenAbandoned(session, at: at) {
                        return beginWrite(
                            generation: generation,
                            nativeFrame: session.nativeFrame,
                            targetFrame: session.adjustedFrame,
                            reliftCount: 0,
                            standoffRounds: min(session.standoffRounds + 1, maximumStandoffRounds)
                        )
                    }
                    return Transition(
                        state: .abandoned(refreshedAbandoned(session, observing: generation)),
                        action: .none
                    )
                case .target, .managedTrajectory:
                    return Transition(
                        state: .abandoned(refreshedAbandoned(session, observing: generation)),
                        action: .none
                    )
                }
            }

        case let .windowUnavailable(generation):
            guard let stateGeneration = stateGeneration(of: state), generation >= stateGeneration else {
                return Transition(state: state, action: .none)
            }
            return Transition(state: .idle, action: .clear)

        case let .detourReturnObserved(generation, at, nativeFrame, targetFrame, standoffRounds):
            guard case .idle = state,
                  isValid(frame: nativeFrame),
                  isValid(frame: targetFrame),
                  standoffRounds >= 0 else {
                return Transition(state: state, action: .none)
            }
            let rounds = min(standoffRounds + 1, maximumStandoffRounds)
            guard rounds < maximumStandoffRounds else {
                let abandoned = AbandonedSession(
                    generation: generation,
                    nativeFrame: nativeFrame,
                    adjustedFrame: targetFrame,
                    reliftCount: maximumReliftCount,
                    reason: .reliftLimitReached,
                    abandonedAt: at,
                    standoffRounds: rounds
                )
                return Transition(state: .abandoned(abandoned), action: .abandon(.reliftLimitReached))
            }
            return beginWrite(
                generation: generation,
                nativeFrame: nativeFrame,
                targetFrame: targetFrame,
                reliftCount: 0,
                standoffRounds: rounds
            )
        }
    }

    /// Whether a suppressed window seen back on its native frame is the app's answer to our lift
    /// (same time-scale rule as the reducer: within `appReassertWindow` of the app-era clear) rather
    /// than the user maximizing it again.
    static func isDetourReturn(clearedAt: TimeInterval, at: TimeInterval) -> Bool {
        at - clearedAt <= appReassertWindow
    }

    /// Whether the external frame that is about to clear `state` counts as the user's own action.
    /// Same time-scale rule as the reducer: an app or a window manager answers our lift within
    /// `appReassertWindow` of the settle; anything later is the user. A write still in flight never
    /// qualifies.
    static func externalFrameIsUserEra(state: SessionState, at: TimeInterval) -> Bool {
        switch state {
        case let .lifted(session):
            return at - session.settledAt > appReassertWindow
        case let .abandoned(session):
            return at - session.abandonedAt > appReassertWindow
        case .writing, .idle:
            return false
        }
    }

    /// The CG scan's per-window gate for lift candidates. `frontmostLargeWindow` (the fullscreen
    /// probe) keeps its own 0.7-only filter; with `includesTiles == false` this is that same filter.
    ///
    /// A tracked window must stay a candidate: a lifted tile is no longer bottom-docked nor wide,
    /// and without this the next scan would walk past it and lift whatever sits behind it.
    static func isLiftCandidate(
        quartzFrame: CGRect,
        isTracked: Bool,
        context: WindowLiftAvoidanceContext,
        includesTiles: Bool
    ) -> Bool {
        if quartzFrame.width > context.screenCGFrame.width * 0.7 { return true }
        guard includesTiles else { return false }
        if isTracked { return true }
        return context.geometry.isBottomDockedTile(
            appKitFrame(fromQuartz: quartzFrame, primaryScreenHeight: context.primaryScreenHeight)
        )
    }

    // MARK: - User zoom toggle (double-click on a lifted window's title bar)

    /// A frame must sit still this long before it counts as the window's remembered user frame;
    /// the system zoom animates through intermediate frames that must never be remembered.
    static let userFrameConfirmationInterval: TimeInterval = 0.5
    /// How long after a double-click a maximized reappearance still counts as the system zoom
    /// answering that click (zoom animation + our own detection latency).
    static let zoomToggleClickWindow: TimeInterval = 1.5
    /// Height of the strip under a window's top edge where a double-click zooms it: the title bar,
    /// Chrome's tab strip, Safari's unified toolbar.
    static let zoomToggleRegionHeight: CGFloat = 100

    /// The frame a window had before it was maximized, as the system zoom's own undo memory would
    /// have kept it — except that our lift poisons that memory (the lifted frame is "not zoomed",
    /// so the next zoom saves *it*), which is why we keep our own copy.
    struct UserFrameMemory: Equatable {
        private(set) var confirmed: CGRect?
        private(set) var candidate: CGRect
        private(set) var candidateSince: TimeInterval

        init(frame: CGRect, at now: TimeInterval) {
            candidate = frame
            candidateSince = now
        }

        /// Seeded right after a user restore with the frame we *asked* for. An app may land a point
        /// off (Chrome answers 800 with 801); remembering the landing instead would move the target
        /// by that point on every toggle. Later observations within tolerance keep this frame.
        init(confirmed frame: CGRect, at now: TimeInterval) {
            confirmed = frame
            candidate = frame
            candidateSince = now
        }

        mutating func observe(_ frame: CGRect, at now: TimeInterval) {
            if framesMatch(frame, candidate) {
                if now - candidateSince >= userFrameConfirmationInterval {
                    confirmed = candidate
                }
            } else {
                // A new candidate within tolerance of the confirmed frame snaps onto it: the
                // window server reports a restore's frames a beat late, so the first scan after
                // a pin still sees the previous animation frame and would otherwise reseat the
                // candidate on the landing (801 for a requested 800), drifting the target a point
                // per toggle.
                candidate = confirmed.map { framesMatch(frame, $0) ? $0 : frame } ?? frame
                candidateSince = now
            }
        }
    }

    struct DoubleClick: Equatable {
        /// AppKit global coordinates.
        let location: CGPoint
        let at: TimeInterval
    }

    /// Turns samples of the session-wide left-mouse-down counter into double-clicks. Sampling
    /// (50ms, with the tracked-window probe) instead of a resident global event monitor keeps the
    /// system's event stream out of this process (`menus.md`: a resident tap lags our own menus).
    struct ClickCounterSampler: Equatable {
        private(set) var lastCount: UInt32?
        private(set) var pendingClick: DoubleClick?

        /// Returns the double-click when this sample completes one.
        mutating func sample(
            count: UInt32,
            location: CGPoint,
            at now: TimeInterval,
            doubleClickInterval: TimeInterval
        ) -> DoubleClick? {
            defer { lastCount = count }
            guard let lastCount else { return nil }
            let delta = count &- lastCount
            guard delta > 0 else { return nil }
            let click = DoubleClick(location: location, at: now)
            if delta >= 2 {
                pendingClick = nil
                return click
            }
            if let pendingClick, now - pendingClick.at <= doubleClickInterval {
                self.pendingClick = nil
                return click
            }
            pendingClick = click
            return nil
        }

        /// Forget the baseline: clicks made while sampling was paused must not pile up into one.
        mutating func reset() {
            lastCount = nil
            pendingClick = nil
        }
    }

    /// Did the user just double-click the title region of a window we hold at `liftedFrame`?
    /// The system zoom then re-maximizes it (our lifted frame is "not zoomed") instead of undoing
    /// the zoom; the caller answers by restoring the remembered user frame.
    ///
    /// `settledAt` is the lift's own settle time: the double-click that maximized the window in
    /// the first place lands in the same title region and must not read as its own undo.
    static func isUserZoomToggle(
        _ doubleClick: DoubleClick?,
        liftedFrame: CGRect,
        settledAt: TimeInterval,
        at now: TimeInterval
    ) -> Bool {
        guard let doubleClick,
              isValid(frame: liftedFrame),
              doubleClick.at > settledAt,
              now - doubleClick.at >= 0,
              now - doubleClick.at <= zoomToggleClickWindow,
              liftedFrame.contains(doubleClick.location) else {
            return false
        }
        return doubleClick.location.y >= liftedFrame.maxY - zoomToggleRegionHeight
    }

    // MARK: - Animation

    static func easeInOutCubic(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        let t = min(1, max(0, progress))
        if t < 0.5 {
            return 4 * t * t * t
        }
        let inverse = -2 * t + 2
        return 1 - inverse * inverse * inverse / 2
    }

    static func interpolatedFrame(from start: CGRect, to end: CGRect, progress: Double) -> CGRect {
        let amount = CGFloat(easeInOutCubic(progress))
        func interpolate(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
            lhs + (rhs - lhs) * amount
        }
        return CGRect(
            x: interpolate(start.minX, end.minX),
            y: interpolate(start.minY, end.minY),
            width: interpolate(start.width, end.width),
            height: interpolate(start.height, end.height)
        )
    }

    /// One frame of the user-zoom-toggle restore: all four components move, every value integral
    /// (1x displays round or drop fractional requests, which then trips the verification tolerance).
    static func userRestoreFrame(from start: CGRect, to end: CGRect, progress: Double) -> CGRect {
        let frame = interpolatedFrame(from: start, to: end, progress: progress)
        return CGRect(
            x: frame.minX.rounded(),
            y: frame.minY.rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
    }

    enum UserRestoreObservation: Equatable {
        case reached
        case late
        case takeover
    }

    /// What a frame observed during the user restore means. `reached` wins even when the write's
    /// precondition failed: a late app can land on the end frame before our next write. `late` is
    /// a coarse envelope test — every component inside the start→end interval (±tolerance) — so a
    /// drag or relayout that stays inside the envelope reads as late and gets overwritten; only a
    /// frame outside the envelope is a takeover. The precondition read and the two attribute writes
    /// are not atomic either, so this is "stop on what we can see", not a guarantee.
    static func userRestoreObservation(
        _ frame: CGRect,
        from start: CGRect,
        to end: CGRect,
        tolerance: CGFloat = verificationTolerance
    ) -> UserRestoreObservation {
        guard isValid(frame: frame), isValid(frame: start), isValid(frame: end),
              tolerance.isFinite, tolerance >= 0 else {
            return .takeover
        }
        if framesMatch(frame, end, tolerance: tolerance) { return .reached }
        func within(_ value: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool {
            value >= min(a, b) - tolerance && value <= max(a, b) + tolerance
        }
        let inside = within(frame.minX, start.minX, end.minX)
            && within(frame.minY, start.minY, end.minY)
            && within(frame.width, start.width, end.width)
            && within(frame.height, start.height, end.height)
        return inside ? .late : .takeover
    }

    /// Maps the remaining portion of one hard-deadline animation back onto 0...1 after a rebase.
    static func rebasedAnimationProgress(
        _ overallProgress: Double,
        startingAt segmentStart: Double
    ) -> Double {
        guard overallProgress.isFinite, segmentStart.isFinite else { return 0 }
        let overall = min(1, max(0, overallProgress))
        let start = min(1, max(0, segmentStart))
        guard start < 1 else { return 1 }
        return min(1, max(0, (overall - start) / (1 - start)))
    }

    // MARK: - Failure recovery and dead-window pruning

    enum RollbackDecision: Equatable {
        case notNeeded
        case restore(CGRect)
        /// Frame disappeared or no longer matches our attempted write; preserve possible user input.
        case preserveCurrent
    }

    static func rollbackDecision(
        originalFrame: CGRect,
        attemptedFrame: CGRect,
        currentFrame: CGRect?
    ) -> RollbackDecision {
        guard let currentFrame else { return .preserveCurrent }
        if framesMatch(currentFrame, originalFrame) { return .notNeeded }
        if framesMatch(currentFrame, attemptedFrame) { return .restore(originalFrame) }
        return .preserveCurrent
    }

    /// AX-specific failure values are mapped into these two pure categories by the controller.
    enum AnimationWriteFailure: Equatable {
        case initialFrameMismatch(actualFrame: CGRect)
        case terminalWriteFailure
    }

    enum AnimationWriteFailureDecision: Equatable {
        case complete(actualFrame: CGRect)
        case continueFromActual(actualFrame: CGRect)
        case clearSession(preservingFrame: CGRect)
        case restartFromNative(nativeFrame: CGRect, nextReliftCount: Int)
        case reliftLimitReached(actualFrame: CGRect, reliftCount: Int)
        case abandonWriteFailed
    }

    /// Decides whether an interrupted serial animation still owns the observed frame.
    /// The actual frame remains attached to every recoverable decision so MainActor never has
    /// to reconstruct information discarded by the detached AX writer.
    ///
    /// `lastAcknowledgedFrame`：写循环最近一次确认到的窗口位置。回读值仍等于它 = 窗口
    /// 尚未跟上本帧写入（慢应用屏 / 1x 外接屏的迟到应用），按"继续"处理而不是放弃或
    /// 补抬——第一帧缓动步长只有 ~2pt，任何取整/延迟都会撞上 2pt 验证容差。
    static func animationWriteFailureDecision(
        _ failure: AnimationWriteFailure,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        lastAcknowledgedFrame: CGRect? = nil
    ) -> AnimationWriteFailureDecision {
        guard reliftCount >= 0 else { return .abandonWriteFailed }

        switch failure {
        case .terminalWriteFailure:
            return .abandonWriteFailed

        case let .initialFrameMismatch(actualFrame):
            guard isValid(frame: actualFrame),
                  isValid(frame: nativeFrame),
                  isValid(frame: targetFrame) else {
                return .abandonWriteFailed
            }
            if framesMatch(actualFrame, targetFrame) {
                return .complete(actualFrame: actualFrame)
            }
            // 停滞判定必须先于 native：第一帧 lastAcknowledged == native，窗口未动时
            // 若按 native 分类会白白烧掉补抬额度。
            if let lastAcknowledgedFrame,
               isValid(frame: lastAcknowledgedFrame),
               framesMatch(actualFrame, lastAcknowledgedFrame) {
                return .continueFromActual(actualFrame: actualFrame)
            }
            switch frameClassification(
                of: actualFrame,
                nativeFrame: nativeFrame,
                targetFrame: targetFrame
            ) {
            case .target:
                return .complete(actualFrame: actualFrame)
            case .native:
                guard reliftCount < maximumReliftCount else {
                    return .reliftLimitReached(
                        actualFrame: actualFrame,
                        reliftCount: reliftCount
                    )
                }
                return .restartFromNative(
                    nativeFrame: actualFrame,
                    nextReliftCount: reliftCount + 1
                )
            case .managedTrajectory:
                return .continueFromActual(actualFrame: actualFrame)
            case .external:
                return .clearSession(preservingFrame: actualFrame)
            }
        }
    }

    static func deadWindowKeys(
        tracked: Set<WindowKey>,
        live: Set<WindowKey>
    ) -> Set<WindowKey> {
        tracked.subtracting(live)
    }

    /// A slower full-list snapshot must not erase a session already confirmed alive by a newer
    /// tracked-window observation. A later global pass can still prune it if it remains absent.
    static func prunableDeadWindowKeys(
        tracked: Set<WindowKey>,
        live: Set<WindowKey>,
        observationGeneration: UInt64,
        observationWatermarks: [WindowKey: UInt64]
    ) -> Set<WindowKey> {
        deadWindowKeys(tracked: tracked, live: live).filter {
            observationGeneration > (observationWatermarks[$0] ?? 0)
        }
    }

    static func prunedStates<Value>(
        _ states: [WindowKey: Value],
        liveWindowKeys: Set<WindowKey>
    ) -> [WindowKey: Value] {
        states.filter { liveWindowKeys.contains($0.key) }
    }

    // MARK: - Coordinate conversion

    static func appKitFrame(fromQuartz frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func quartzFrame(fromAppKit frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private static func adjustedFrame(for frame: CGRect, targetBottom: CGFloat) -> CGRect? {
        guard isValid(frame: frame), targetBottom.isFinite,
              targetBottom > frame.minY + verificationTolerance,
              targetBottom < frame.maxY - verificationTolerance else {
            return nil
        }
        return CGRect(
            x: frame.minX,
            y: targetBottom,
            width: frame.width,
            height: frame.maxY - targetBottom
        )
    }

    private static func beginWrite(
        generation: UInt64,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        standoffRounds: Int
    ) -> Transition {
        let attempt = WriteAttempt(
            generation: generation,
            latestObservationGeneration: generation,
            nativeFrame: nativeFrame,
            targetFrame: targetFrame,
            reliftCount: reliftCount,
            standoffRounds: standoffRounds
        )
        return Transition(
            state: .writing(attempt),
            action: .write(
                targetFrame: targetFrame,
                rollbackFrame: nativeFrame,
                generation: generation,
                isRelift: attempt.isRelift
            )
        )
    }

    private static func beginReliftOrAbandon(
        generation: UInt64,
        at: TimeInterval,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        standoffRounds: Int
    ) -> Transition {
        guard reliftCount < maximumReliftCount else {
            let abandoned = AbandonedSession(
                generation: generation,
                nativeFrame: nativeFrame,
                adjustedFrame: targetFrame,
                reliftCount: reliftCount,
                reason: .reliftLimitReached,
                abandonedAt: at,
                standoffRounds: standoffRounds
            )
            return Transition(
                state: .abandoned(abandoned),
                action: .abandon(.reliftLimitReached)
            )
        }
        return beginWrite(
            generation: generation,
            nativeFrame: nativeFrame,
            targetFrame: targetFrame,
            reliftCount: reliftCount + 1,
            standoffRounds: standoffRounds
        )
    }

    private static func abandonWritingAttempt(
        state: SessionState,
        generation: UInt64,
        at: TimeInterval,
        reliftCount: Int,
        reason: AbandonReason
    ) -> Transition {
        guard case let .writing(attempt) = state,
              attempt.generation == generation else {
            return Transition(state: state, action: .none)
        }
        let finalReliftCount = max(attempt.reliftCount, reliftCount)
        let abandoned = AbandonedSession(
            generation: max(generation, attempt.latestObservationGeneration),
            nativeFrame: attempt.nativeFrame,
            adjustedFrame: attempt.targetFrame,
            reliftCount: finalReliftCount,
            reason: reason,
            abandonedAt: at,
            standoffRounds: attempt.standoffRounds
        )
        return Transition(state: .abandoned(abandoned), action: .abandon(reason))
    }

    /// 未达对峙上限走正常重开窗口；达到上限降为慢频（不永久锁死）。
    /// 对峙轮数未到顶、且已过对峙窗口 → 超时重开记一轮；到顶后一律不再重开，这一轮只有
    /// external 帧能清会话（见 `maximumStandoffRounds`）。
    private static func shouldReopenAbandoned(_ session: AbandonedSession, at: TimeInterval) -> Bool {
        session.standoffRounds < maximumStandoffRounds && at - session.abandonedAt > appReassertWindow
    }

    /// 只刷新观察 generation；abandonedAt/rounds/reason/frames 原样保留，保证放弃态能按时过期。
    private static func refreshedAbandoned(
        _ session: AbandonedSession,
        observing generation: UInt64
    ) -> AbandonedSession {
        AbandonedSession(
            generation: generation,
            nativeFrame: session.nativeFrame,
            adjustedFrame: session.adjustedFrame,
            reliftCount: session.reliftCount,
            reason: session.reason,
            abandonedAt: session.abandonedAt,
            standoffRounds: session.standoffRounds
        )
    }

    private static func stateGeneration(of state: SessionState) -> UInt64? {
        switch state {
        case .idle:
            return nil
        case let .writing(attempt):
            return attempt.latestObservationGeneration
        case let .lifted(session):
            return session.generation
        case let .abandoned(session):
            return session.generation
        }
    }

    /// 多屏（③④）下候选窗口归哪块屏：面积过半的那块；没有过半就取重叠最大的；一点不沾 → nil。
    /// 跨屏窗口因此只属于一块屏，不会被两块屏的避让同时抬。**与 `Geometry.mostlyBelongsToScreen`
    /// 同一面积法、刻意不共享**（那份是本类型的私有判据；`PanelVisibilityState` 里还有第三份，各归各的规则文件）。
    static func owningContextIndex(for quartzFrame: CGRect, screenCGFrames: [CGRect]) -> Int? {
        guard isValid(frame: quartzFrame) else { return nil }
        let area = quartzFrame.width * quartzFrame.height
        var best: (index: Int, overlap: CGFloat)?
        for (index, screen) in screenCGFrames.enumerated() {
            guard isValid(frame: screen) else { continue }
            let overlap = quartzFrame.intersection(screen)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let overlapArea = overlap.width * overlap.height
            if overlapArea >= area * 0.5 { return index }
            if best == nil || overlapArea > best!.overlap { best = (index, overlapArea) }
        }
        return best?.index
    }

    private static func isValid(frame: CGRect) -> Bool {
        frame.minX.isFinite
            && frame.minY.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    private static func writingAttempt(
        _ attempt: WriteAttempt,
        observing generation: UInt64
    ) -> SessionState {
        .writing(WriteAttempt(
            generation: attempt.generation,
            latestObservationGeneration: max(generation, attempt.latestObservationGeneration),
            nativeFrame: attempt.nativeFrame,
            targetFrame: attempt.targetFrame,
            reliftCount: attempt.reliftCount,
            standoffRounds: attempt.standoffRounds
        ))
    }
}
