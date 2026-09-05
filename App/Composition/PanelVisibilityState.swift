import ApplicationServices
import CoreGraphics

enum PanelVisibilityReason: Hashable {
    case fullscreen
    case fullscreenTransitionPending
    case edgeAutoHide
}

enum FullscreenSpaceHoldDisposition: Equatable {
    case apply
    case hold
    case stale
}

enum FullscreenSpaceHoldDecision {
    static let postSpaceConfirmationDelay: TimeInterval = 0.12
    static let activationFallbackDelay: TimeInterval = 0.5

    static func shouldBegin(isFullscreen: Bool, hasInputIntent: Bool) -> Bool {
        isFullscreen && !hasInputIntent
    }

    static func disposition(
        isFullscreenVerdict: Bool,
        expectedGeneration: UInt64?,
        activeGeneration: UInt64?,
        isFinalWindowedConfirmation: Bool
    ) -> FullscreenSpaceHoldDisposition {
        guard let activeGeneration else {
            return expectedGeneration == nil ? .apply : .stale
        }
        guard expectedGeneration == activeGeneration else { return .stale }
        // 保持存续期间，**非终审裁决一律不放行**——true 也不行。原来的写法
        // （true 即 .apply）会让退出全屏瞬间 CG 滞后 0.4~0.8s 报出的假 true
        // 把 120ms 确认保持连根销毁，随后正确的 AX false 因保持已亡被判 .stale
        // 静默丢弃，条只能等 5 秒对账兜底——「退全屏 2~3 秒才回归」（2026-08-30
        // 实测，指纹：space-cg true 后无 space-ax 行、揭示行距上条 ax 行 5.098s，
        // `Docs/05`）。保持期间状态本就是 .fullscreen，true 无事可做；忍 120ms
        // 让终审 CG+AX 定夺，全→全切换只是晚 120ms 确认、期间条本来就藏着。
        if isFinalWindowedConfirmation { return .apply }
        return .hold
    }
}

/// 「常驻所有桌面」的成员资格修复（issue #19）。
///
/// macOS 会在**一个全屏空间被销毁的那一刻，把当时处于隐藏状态的 `.canJoinAllSpaces` 窗口
/// 重新只挂到当前那个桌面上**，其余桌面从此看不到它。2026-08-28 用一个 80 行、与本项目
/// 无关的独立实验复现（`scratch/space_membership_lab2.swift`），所以这不是钨极的 bug，
/// 但受害的正是我们「进全屏 orderOut / 退全屏 orderFrontRegardless」这套让位机制。
///
/// 补不回来的做法（都实测过）：`orderFrontRegardless`、把同样的 `collectionBehavior`
/// 再赋一遍、`orderOut` + 重设 + `orderFront`。**有效的唯一形状是：换成别的值 → 让它过一轮
/// runloop → 再赋回**，而且**单次不保证成功**（3 轮实验里有 1 轮要修两次），所以必须
/// 读回验收 + 重试，不能一发了事。
enum AllSpacesMembership {
    static let maxRepairAttempts = 3
    /// 赋回之后等多久再读回验收。实测 120ms 足够 WindowServer 落定。
    static let verifyDelay: TimeInterval = 0.12

    /// 这扇窗还缺哪些普通桌面（全屏空间不算——窗口本来就不该常驻在别人的全屏空间上）。
    /// 空数组 = 健康。`desktopSpaceIDs` 少于 2 个时永远返回空：单桌面谈不上「丢桌面」。
    static func missingSpaceIDs(windowSpaceIDs: [Int], desktopSpaceIDs: [Int]) -> [Int] {
        guard desktopSpaceIDs.count > 1 else { return [] }
        let owned = Set(windowSpaceIDs)
        return desktopSpaceIDs.filter { !owned.contains($0) }.sorted()
    }

    static func shouldRetry(attempt: Int) -> Bool { attempt < maxRepairAttempts }
}

enum EdgeAutoHideInhibitor: Hashable {
    case dragging
    case drawerOpen
    case folderPopupOpen
    /// 钨极菜单（状态栏图标或任务条右键弹出的那一个）正开着。
    /// 不挡的话，自动隐藏档位下空闲计时照跑，任务条会从菜单底下缩掉。
    case taskbarMenuOpen
}

struct PanelVisibilityState: Equatable {
    var hideReasons: Set<PanelVisibilityReason> = []
    var autoHideInhibitors: Set<EdgeAutoHideInhibitor> = []
    private(set) var fullscreenTransitionGeneration: UInt64?

    var isVisible: Bool { hideReasons.isEmpty }

    mutating func setFullscreen(_ active: Bool) {
        setReason(.fullscreen, active: active)
    }

    mutating func beginFullscreenTransition(generation: UInt64) {
        fullscreenTransitionGeneration = generation
        hideReasons.insert(.fullscreenTransitionPending)
    }

    @discardableResult
    mutating func confirmFullscreenTransition(generation: UInt64) -> Bool {
        guard fullscreenTransitionGeneration == generation else { return false }
        fullscreenTransitionGeneration = nil
        hideReasons.remove(.fullscreenTransitionPending)
        hideReasons.insert(.fullscreen)
        return true
    }

    @discardableResult
    mutating func timeoutFullscreenTransition(generation: UInt64) -> Bool {
        guard fullscreenTransitionGeneration == generation else { return false }
        fullscreenTransitionGeneration = nil
        hideReasons.remove(.fullscreenTransitionPending)
        return true
    }

    mutating func setEdgeAutoHidden(_ active: Bool) {
        setReason(.edgeAutoHide, active: active)
    }

    mutating func setInhibitor(_ inhibitor: EdgeAutoHideInhibitor, active: Bool) {
        if active {
            autoHideInhibitors.insert(inhibitor)
        } else {
            autoHideInhibitors.remove(inhibitor)
        }
    }

    mutating func reconcileEdgeAutoHide(isEnabled: Bool) {
        if !isEnabled || !autoHideInhibitors.isEmpty {
            hideReasons.remove(.edgeAutoHide)
        }
    }

    private mutating func setReason(_ reason: PanelVisibilityReason, active: Bool) {
        if active {
            hideReasons.insert(reason)
        } else {
            hideReasons.remove(reason)
        }
    }
}

@MainActor
enum EdgeAutoHideRuntimeRules {
    static let fixedIdleHideDelay: Double = 0.2

    static func canArmWake(state: PanelVisibilityState, delay: Double) -> Bool {
        state.hideReasons.contains(.edgeAutoHide)
            && !state.hideReasons.contains(.fullscreen)
            && !state.hideReasons.contains(.fullscreenTransitionPending)
            && state.autoHideInhibitors.isEmpty
            && delay != AppSettingsStore.neverHideDelay
            && delay < AppSettingsStore.neverWakeDelay
    }

    static func canArmIdleHide(state: PanelVisibilityState, delay: Double) -> Bool {
        !state.hideReasons.contains(.edgeAutoHide)
            && !state.hideReasons.contains(.fullscreen)
            && !state.hideReasons.contains(.fullscreenTransitionPending)
            && state.autoHideInhibitors.isEmpty
            && delay != AppSettingsStore.neverHideDelay
    }

    static func idleHideInterval(for delay: Double) -> Double? {
        guard delay > AppSettingsStore.neverHideDelay else { return nil }
        return fixedIdleHideDelay
    }

    /// 底边唤醒热区（贯穿整条屏幕底边）是否应该压住 idle-hide、阻止武装隐藏计时器。
    /// 只在"有限唤醒延迟"（0.1–3.0s）时成立：这个区间唤醒和 idle-hide 都在跑，鼠标停在热区内、
    /// 但任务条矩形外时，两者会互相打架（唤醒→隐藏→唤醒…），必须让热区本身也算"没离开"。
    /// 999（`neverWakeDelay`，自动隐藏但不唤醒）没有唤醒动作，不存在这种打架，隐藏应照常进行；
    /// -1（`neverHideDelay`，常驻显示）本来就不会隐藏，压不压都一样。
    static func bottomHotZoneSuppressesIdleHide(delay: Double) -> Bool {
        delay != AppSettingsStore.neverHideDelay && delay < AppSettingsStore.neverWakeDelay
    }
}
