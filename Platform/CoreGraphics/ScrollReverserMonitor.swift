import CoreGraphics
import Foundation
import OSLog
import os.lock

/// 全局鼠标滚轮反转（设置「通用 · 反转鼠标滚轮方向」，默认关）。
///
/// 结构克隆 `FullscreenIntentEventTapThread`：专用线程、`.cgSessionEventTap` +
/// `.headInsertEventTap` + `.defaultTap`、`.commonModes`、同一套熔断重启策略
/// （`FullscreenEventTapRecoveryPolicy`）。那边的规则冻结了这些细节，这里**刻意不抽
/// 公共基类**、接受少量重复——真要抽等两个 tap 都稳定之后再说。
///
/// 这是全项目唯一**改写**输入事件的地方：只翻离散滚轮事件的六个 delta 字段，
/// 不读内容、不分配、不进主线程（panels-and-screens 的 CGEventTap 纪律）。
/// 开关关闭时本对象不存在（`AppDelegate` 只在设置开着时才建），tap 随之不存在。
@MainActor
final class ScrollReverserMonitor {
    private var tapThread: ScrollReverserEventTapThread?

    func start() {
        guard tapThread == nil else { return }
        let thread = ScrollReverserEventTapThread(
            logger: Logger(subsystem: "com.caye.macosdockcc.v2", category: "scroll-reverser")
        )
        tapThread = thread
        thread.start()
    }

    func stop() {
        tapThread?.stop()
        tapThread = nil
    }
}

private final class ScrollReverserEventTapThread {
    private let logger: Logger
    private var lifecycleLock = os_unfair_lock_s()
    private var recoveryLock = os_unfair_lock_s()
    private var recoveryPolicy = FullscreenEventTapRecoveryPolicy()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var stopping = false
    private let finished = DispatchSemaphore(value: 0)

    /// 机制探针（`DOCK_SCROLL_REVERSER_TRACE=1`，默认关）：打前 10 条事件的连续标志与
    /// delta，用来在真机上确认「鼠标滚轮 cont=0、触控板 cont=1」。只在 tap 线程碰它。
    private static let traceEnabled =
        DebugSwitch.scrollReverserTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private var traceRemaining = 10

    init(logger: Logger) {
        self.logger = logger
    }

    func start() {
        withLifecycleLock {
            guard thread == nil else { return }
            stopping = false
            let thread = Thread { [weak self] in self?.run() }
            thread.name = "com.caye.macosdockcc.scroll-reverser-tap"
            thread.qualityOfService = .userInteractive
            self.thread = thread
            thread.start()
        }
    }

    func stop() {
        let loop: CFRunLoop? = withLifecycleLock {
            stopping = true
            return runLoop
        }
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self else { return }
                if let tap = self.withLifecycleLock({ self.tap }) {
                    CGEvent.tapEnable(tap: tap, enable: false)
                    CFMachPortInvalidate(tap)
                }
                CFRunLoopStop(loop)
            }
            CFRunLoopWakeUp(loop)
            _ = finished.wait(timeout: .now() + 1)
        }
        withLifecycleLock {
            thread = nil
            runLoop = nil
            tap = nil
        }
    }

    private func run() {
        autoreleasepool {
            let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                logger.error("scroll-tap-create-failed")
                finished.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let currentLoop = CFRunLoopGetCurrent()
            let shouldStop = withLifecycleLock {
                self.tap = tap
                runLoop = currentLoop
                return stopping
            }
            guard !shouldStop else {
                CFMachPortInvalidate(tap)
                finished.signal()
                return
            }
            CFRunLoopAddSource(currentLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            finished.signal()
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<ScrollReverserEventTapThread>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            owner.handleDisabled(type: type)
        } else if type == .scrollWheel {
            owner.reverseIfNeeded(event)
        }
        return Unmanaged.passUnretained(event)
    }

    /// 热路径：读一个标志、翻六个字段。无分配、无锁、无日志（trace 默认关、只打 10 条）。
    private func reverseIfNeeded(_ event: CGEvent) {
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        if Self.traceEnabled, traceRemaining > 0 {
            traceRemaining -= 1
            print("[scrollrev] cont=\(isContinuous ? 1 : 0)"
                + " axis1=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))"
                + " point1=\(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))"
                + " fixed1=\(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))")
        }
        guard ScrollReverserDecision.shouldReverse(isContinuous: isContinuous) else { return }
        let deltas = ScrollWheelDeltas(
            axis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            axis2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            pointAxis1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            pointAxis2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixedAxis1: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixedAxis2: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )
        let reversed = ScrollReverserDecision.reversed(deltas)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: reversed.axis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: reversed.axis2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: reversed.pointAxis1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: reversed.pointAxis2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: reversed.fixedAxis1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: reversed.fixedAxis2)
    }

    /// 熔断策略与全屏 tap 完全一致：60 秒内最多重启 3 次，超了保持关闭（功能静默失效，
    /// 开关重开一次即重建）。系统在 tap 超时 / 用户输入风暴时会自动禁用 tap。
    private func handleDisabled(type: CGEventType) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReenable: Bool = withRecoveryLock {
            recoveryPolicy.recordDisable(at: now)
        }
        guard shouldReenable, let tap = withLifecycleLock({ self.tap }) else {
            logger.fault("scroll-tap-fused type=\(type.rawValue, privacy: .public)")
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.error("scroll-tap-reenabled type=\(type.rawValue, privacy: .public)")
    }

    private func withLifecycleLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lifecycleLock)
        defer { os_unfair_lock_unlock(&lifecycleLock) }
        return body()
    }

    private func withRecoveryLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&recoveryLock)
        defer { os_unfair_lock_unlock(&recoveryLock) }
        return body()
    }
}
