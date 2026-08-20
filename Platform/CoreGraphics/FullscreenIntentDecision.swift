import CoreGraphics
import Foundation
import os.lock

enum FullscreenIntentSource: String, Equatable {
    case greenButton
    case keyboardShortcut
}

struct FullscreenIntentSnapshot: Equatable {
    let generation: UInt64
    let pid: pid_t
    let focusedWindowID: CGWindowID
    let buttonFrame: CGRect
    let windowFrame: CGRect
    let screenCGFrame: CGRect
    let panelScreenCGFrame: CGRect?
    let isFullscreen: Bool
    let buttonEnabled: Bool
}

struct FullscreenIntentRequest: Equatable {
    let source: FullscreenIntentSource
    let cacheGeneration: UInt64
    let pid: pid_t
    let focusedWindowID: CGWindowID
    let screenCGFrame: CGRect
}

enum FullscreenIntentDecision {
    static let ansiFKeyCode = CGKeyCode(3)

    private static let intentModifiers: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn, .maskHelp,
        .maskNumericPad
    ]

    static func normalizedModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(intentModifiers)
    }

    static func greenButtonRequest(
        location: CGPoint,
        flags: CGEventFlags,
        snapshot: FullscreenIntentSnapshot?
    ) -> FullscreenIntentRequest? {
        guard let snapshot,
              snapshot.buttonEnabled,
              !snapshot.isFullscreen,
              snapshot.panelScreenCGFrame == snapshot.screenCGFrame,
              normalizedModifiers(flags).isEmpty,
              snapshot.buttonFrame.contains(location) else {
            return nil
        }
        return request(source: .greenButton, snapshot: snapshot)
    }

    static func shortcutRequest(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool,
        snapshot: FullscreenIntentSnapshot?
    ) -> FullscreenIntentRequest? {
        guard let snapshot,
              snapshot.buttonEnabled,
              !snapshot.isFullscreen,
              snapshot.panelScreenCGFrame == snapshot.screenCGFrame,
              !isRepeat,
              keyCode == ansiFKeyCode,
              normalizedModifiers(flags) == [.maskCommand, .maskControl] else {
            return nil
        }
        return request(source: .keyboardShortcut, snapshot: snapshot)
    }

    static func isEnabled(
        settingEnabled: Bool,
        environment: [String: String]
    ) -> Bool {
        settingEnabled && environment["DOCK_FULLSCREEN_INTENT"] != "0"
    }

    private static func request(
        source: FullscreenIntentSource,
        snapshot: FullscreenIntentSnapshot
    ) -> FullscreenIntentRequest {
        FullscreenIntentRequest(
            source: source,
            cacheGeneration: snapshot.generation,
            pid: snapshot.pid,
            focusedWindowID: snapshot.focusedWindowID,
            screenCGFrame: snapshot.screenCGFrame
        )
    }
}

enum SpaceSwitchDirection: String, Equatable {
    case left
    case right
}

/// 一块显示器上的空间布局快照（SkyLight `SLSCopyManagedDisplaySpaces` 的纯数据投影）。
struct SpaceLayoutSnapshot: Equatable {
    /// 按 Mission Control 的左右顺序排列的空间 id。
    let orderedSpaceIDs: [Int]
    /// 全屏空间（`type == 4`）的 id 集合。
    let fullscreenSpaceIDs: Set<Int>
    let currentSpaceID: Int

    static let fullscreenSpaceType = 4

    /// 目标方向的相邻空间是不是全屏空间。**这道闸是整个预测隐藏的前提**：
    /// 没有它，在两个普通桌面之间切换也会把任务条藏一下，而那里本来什么问题都没有。
    func neighborIsFullscreen(_ direction: SpaceSwitchDirection) -> Bool {
        guard let index = orderedSpaceIDs.firstIndex(of: currentSpaceID) else { return false }
        let neighbor = direction == .right ? index + 1 : index - 1
        guard orderedSpaceIDs.indices.contains(neighbor) else { return false }
        return fullscreenSpaceIDs.contains(orderedSpaceIDs[neighbor])
    }

    var hasAnyFullscreenNeighbor: Bool {
        neighborIsFullscreen(.left) || neighborIsFullscreen(.right)
    }
}

/// 三指水平滑动的纯状态机。事件流里每个手势事件喂一次，够条件就吐出方向。
///
/// 判据来自 2026-08-09 实测（样本见诊断归档）：**≥3 指 + 水平位移 > 阈值 + 水平位移压过垂直位移**。
/// - 只用「水平 > 阈值」会误命中三指上下滑（10 次里中 1 次）；加上「水平 > 垂直」后 10/10 全部排除。
/// - 阈值取 0.03 / 0.05 / 0.08 结果完全一致 —— 信号本身就分得开，不是调参调出来的。
/// - 日常两指滚动 / 点击 / 移光标（约 45 秒样本）一次都不触发：它们凑不够三根手指。
struct SpaceSwipeTracker: Equatable {
    static let minimumTouches = 3
    static let horizontalThreshold = 0.05
    /// 超过这个间隔没收到有效采样就重新起锚。**必须有它**：手势事件里约三分之一
    /// （magnify 之类）根本不带触控数据，不能把「这一条没数据」当成「手指抬起来了」，
    /// 否则一串滑动会被反复打断、锚点永远重置，判据一次都不会成立。
    static let burstGap: TimeInterval = 0.4

    private var anchorX: Double?
    private var anchorY: Double?
    private var lastSampleAt: TimeInterval?
    private var firedInThisBurst = false

    mutating func reset() {
        anchorX = nil
        anchorY = nil
        lastSampleAt = nil
        firedInThisBurst = false
    }

    /// - Parameter naturalScrolling: 系统「自然滚动」。实测（14/14 一致）：自然滚动下
    ///   **手指向左滑去右边的空间**，方向与位移符号相反；关掉自然滚动则同号。
    mutating func consume(
        touches: Int,
        x: Double,
        y: Double,
        at now: TimeInterval,
        naturalScrolling: Bool
    ) -> SpaceSwitchDirection? {
        if let last = lastSampleAt, now - last > Self.burstGap { reset() }
        guard touches >= Self.minimumTouches else {
            reset()
            return nil
        }
        lastSampleAt = now
        guard let ax = anchorX, let ay = anchorY else {
            anchorX = x
            anchorY = y
            return nil
        }
        guard !firedInThisBurst else { return nil }
        let dx = x - ax
        let dy = y - ay
        guard abs(dx) > Self.horizontalThreshold, abs(dx) > abs(dy) else { return nil }
        firedInThisBurst = true
        let movesRight = naturalScrolling ? (dx < 0) : (dx > 0)
        return movesRight ? .right : .left
    }
}

/// Control+←/→ 切换空间的预测隐藏。**已转正、默认开**，关掉用 `DOCK_SPACE_INTENT=0`
///（判定在 `FullscreenIntentMonitor` 的 `spaceSwitchEnabled`）。
///
/// ⚠️ 本段曾长期写着「实验、`DOCK_SPACE_INTENT_EXPERIMENT=1`、默认关、不判断相邻空间」。
/// 那是 2026-08-09 立项时的描述，**早已作废**：那个环境变量全仓库没有任何代码在读，
/// 相邻空间闸也已经补上并成为硬性条件。2026-08-19 修正——过期成这样的注释会让下一个
/// 来查「全屏切换闪烁」的人直接得出「这功能根本没启用」的错误结论。
///
/// 立项时要回答的问题：方向键按下比空间真正切换早约 `548–575ms`（已实测归档），这个提前量
/// 够不够消掉「普通桌面 → 全屏空间」的闪烁。已实测走死的两条是 managed-space 预测
/// （只早约 30ms）和快速 AX 探测（空间通知后 0.2–1ms），都晚于 WindowServer 的过渡快照。
///
/// **相邻空间闸是硬性条件**：只有目标方向的相邻空间确实是全屏空间才预测，否则两个普通桌面
/// 之间按方向键会白藏一下。这道闸在 `FullscreenIntentMonitor` 里就判掉了
/// （`SLSCopyManagedDisplaySpaces`，按显示器 UUID 匹配，不能按数组顺序）。
enum FullscreenSpaceSwitchDecision {
    static let leftArrowKeyCode = CGKeyCode(123)
    static let rightArrowKeyCode = CGKeyCode(124)

    /// **物理方向键天生携带 `Fn + 小键盘 + nonCoalesced` 三个标志位**（2026-08-09 实测归档），
    /// 用户一个附加键都没按也是如此。所以这里不能复用 `FullscreenIntentDecision` 那套
    /// 归一化（它把 Fn / 小键盘算作用户修饰键）——那样永远匹配不上，得到的是一个
    /// 「什么都不触发」的假阴性，而它极容易被读成「提前量不够，这条路走不通」。
    private static let userModifiers: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskHelp
    ]

    static func normalizedModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(userModifiers)
    }

    static func arrowDirection(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> SpaceSwitchDirection? {
        guard !isRepeat, normalizedModifiers(flags) == [.maskControl] else { return nil }
        switch keyCode {
        case leftArrowKeyCode: return .left
        case rightArrowKeyCode: return .right
        default: return nil
        }
    }

    static func isSpaceSwitchArrow(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> Bool {
        arrowDirection(keyCode: keyCode, flags: flags, isRepeat: isRepeat) != nil
    }
}

struct FullscreenIntentRefreshCoalescer: Equatable {
    enum Completion: Equatable {
        case ignored
        case idle
        case start(UInt64)
    }

    private(set) var activeToken: UInt64?
    private(set) var needsTrailingRefresh = false
    private var nextToken: UInt64 = 0

    mutating func request() -> UInt64? {
        guard activeToken == nil else {
            needsTrailingRefresh = true
            return nil
        }
        return begin()
    }

    mutating func complete(token: UInt64) -> Completion {
        guard activeToken == token else { return .ignored }
        if needsTrailingRefresh {
            needsTrailingRefresh = false
            let trailingToken = begin()
            return .start(trailingToken)
        }
        activeToken = nil
        return .idle
    }

    mutating func reset() {
        activeToken = nil
        needsTrailingRefresh = false
    }

    private mutating func begin() -> UInt64 {
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }
}

enum FullscreenIntentCacheDecision {
    static func shouldApplyRefresh(
        started: Bool,
        expectedObservation: UInt64,
        currentObservation: UInt64,
        expectedCache: UInt64,
        currentCache: UInt64,
        requestedPID: pid_t,
        activePID: pid_t?
    ) -> Bool {
        started
            && expectedObservation == currentObservation
            && expectedCache == currentCache
            && requestedPID == activePID
    }

    static func isCurrentRequest(
        _ request: FullscreenIntentRequest,
        snapshot: FullscreenIntentSnapshot?,
        activePID: pid_t?,
        started: Bool
    ) -> Bool {
        guard started, activePID == request.pid, let snapshot else { return false }
        return snapshot.generation == request.cacheGeneration
            && snapshot.pid == request.pid
            && snapshot.focusedWindowID == request.focusedWindowID
            && snapshot.screenCGFrame == request.screenCGFrame
    }
}

struct FullscreenEventTapRecoveryPolicy: Equatable {
    static let window: TimeInterval = 60
    static let maximumReenables = 3

    private(set) var disableTimes: [TimeInterval] = []
    private(set) var isFused = false

    mutating func recordDisable(at now: TimeInterval) -> Bool {
        guard !isFused else { return false }
        disableTimes.removeAll { now - $0 > Self.window }
        guard disableTimes.count < Self.maximumReenables else {
            isFused = true
            return false
        }
        disableTimes.append(now)
        return true
    }
}

final class FullscreenIntentHandoffGate {
    enum State: Equatable {
        case pending
        case executing
        case completed
        case cancelled
    }

    private var lock = os_unfair_lock_s()
    private var state: State = .pending

    func beginExecution() -> Bool {
        withLock {
            guard state == .pending else { return false }
            state = .executing
            return true
        }
    }

    func complete() {
        withLock {
            guard state == .executing else { return }
            state = .completed
        }
    }

    @discardableResult
    func cancelIfPending() -> Bool {
        withLock {
            guard state == .pending else { return false }
            state = .cancelled
            return true
        }
    }

    var currentState: State { withLock { state } }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}
