import AppKit
import ApplicationServices
import Foundation
import OSLog
import os.lock

/// SkyLight 的空间布局读取。`Docs/05` 实测单次 `SLSCopyManagedDisplaySpaces` 约 0.132ms，
/// 可以放在事件路径上；这里只在空间/屏幕变化时读，频率远低于此。
///
/// **显示器必须按 `CGDisplayCreateUUIDFromDisplayID` 的 UUID 匹配，不能按数组顺序**
/// （`Docs/05` 明文，多屏下顺序不稳）。
/// （`PanelCoordinator` 的「常驻所有桌面」成员资格修复是第二个消费者，故不再是 private。）
enum ManagedSpaceLayoutReader {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> CFArray?

    private static let symbols: (cid: Int32, copy: CopySpacesFn)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ),
            let cidSym = dlsym(handle, "SLSMainConnectionID"),
            let copySym = dlsym(handle, "SLSCopyManagedDisplaySpaces")
        else { return nil }
        let cid = unsafeBitCast(cidSym, to: MainConnectionIDFn.self)()
        return (cid, unsafeBitCast(copySym, to: CopySpacesFn.self))
    }()

    // 同样的 NSScreen→UUID 逻辑在 `DisplayIdentity.uuidString(for:)` 还有一份（固定到某屏用）；
    // 本文件细节被规则冻结，刻意不共享实现，改一边记得看另一边。
    static func displayUUIDString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
        else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
    }

    static func layout(forDisplayUUID uuid: String) -> SpaceLayoutSnapshot? {
        guard let symbols,
              let displays = symbols.copy(symbols.cid) as? [[String: Any]] else { return nil }
        for display in displays {
            guard display["Display Identifier"] as? String == uuid,
                  let spaces = display["Spaces"] as? [[String: Any]],
                  let current = display["Current Space"] as? [String: Any],
                  let currentID = spaceID(current) else { continue }
            var ordered: [Int] = []
            var fullscreen: Set<Int> = []
            for space in spaces {
                guard let id = spaceID(space) else { continue }
                ordered.append(id)
                if space["type"] as? Int == SpaceLayoutSnapshot.fullscreenSpaceType {
                    fullscreen.insert(id)
                }
            }
            guard !ordered.isEmpty else { return nil }
            return SpaceLayoutSnapshot(
                orderedSpaceIDs: ordered,
                fullscreenSpaceIDs: fullscreen,
                currentSpaceID: currentID
            )
        }
        return nil
    }

    private static func spaceID(_ dict: [String: Any]) -> Int? {
        (dict["ManagedSpaceID"] as? Int) ?? (dict["id64"] as? Int)
    }
}

/// 「这扇窗现在属于哪些空间」。issue #19 的修复靠它读回验收——只赋一遍
/// `collectionBehavior` 不保证成功，不读回就不知道修没修好。
///
/// selector `0x7` = 取全部空间（与 Dock / WindowServer 内部用法一致）。开销与
/// `SLSCopyManagedDisplaySpaces` 同量级（`Docs/05` 实测 0.132ms/次），只在面板显隐
/// 与空间切换时调，不在事件路径上。
enum WindowSpaceMembershipReader {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?

    private static let symbols: (cid: Int32, copy: CopySpacesForWindowsFn)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ),
            let cidSym = dlsym(handle, "SLSMainConnectionID"),
            let copySym = dlsym(handle, "SLSCopySpacesForWindows")
        else { return nil }
        let cid = unsafeBitCast(cidSym, to: MainConnectionIDFn.self)()
        return (cid, unsafeBitCast(copySym, to: CopySpacesForWindowsFn.self))
    }()

    /// 读不到（符号缺失 / 窗口号无效）返回 nil —— 调用方必须把它当作「不知道」，
    /// 而不是「什么空间都不属于」，否则一次读失败会触发一轮无谓的修复。
    static func spaceIDs(forWindowNumber windowNumber: Int) -> [Int]? {
        guard windowNumber > 0, let symbols else { return nil }
        guard let raw = symbols.copy(
            symbols.cid,
            0x7,
            [NSNumber(value: windowNumber)] as CFArray
        ) as? [NSNumber] else { return nil }
        return raw.map(\.intValue)
    }
}

private final class FullscreenIntentAtomicState {
    private var lock = os_unfair_lock_s()
    private var snapshot: FullscreenIntentSnapshot?
    private var spaceLayouts: SpaceLayoutDirectory?
    private var naturalScrolling = true
    private var tapEnabled = false

    func currentSnapshot() -> FullscreenIntentSnapshot? {
        withLock { tapEnabled ? snapshot : nil }
    }

    /// 事件线程读：返回 nil 表示「没有一块屏的两侧有全屏空间」，调用方可以直接跳过，
    /// 连 `NSEvent` 转换都不必做——手势事件一秒两百个，这个提前退出是常态路径。
    func currentSpaceContext() -> (layouts: SpaceLayoutDirectory, naturalScrolling: Bool)? {
        withLock {
            guard tapEnabled, let spaceLayouts, spaceLayouts.hasAnyFullscreenNeighbor else {
                return nil
            }
            return (spaceLayouts, naturalScrolling)
        }
    }

    func replaceSpaceLayout(_ value: SpaceLayoutDirectory?, naturalScrolling: Bool) {
        withLock {
            spaceLayouts = value
            self.naturalScrolling = naturalScrolling
        }
    }

    func replaceSnapshot(_ value: FullscreenIntentSnapshot?) {
        withLock { snapshot = value }
    }

    func updatePanelScreens(_ frames: Set<CGRect>) {
        withLock {
            guard let current = snapshot else { return }
            snapshot = FullscreenIntentSnapshot(
                generation: current.generation,
                pid: current.pid,
                focusedWindowID: current.focusedWindowID,
                buttonFrame: current.buttonFrame,
                windowFrame: current.windowFrame,
                screenCGFrame: current.screenCGFrame,
                panelScreenCGFrames: frames,
                isFullscreen: current.isFullscreen,
                buttonEnabled: current.buttonEnabled
            )
        }
    }

    func setTapEnabled(_ enabled: Bool) {
        withLock { tapEnabled = enabled }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}

private final class FullscreenIntentEventBridge {
    private static let handoffTimeout: DispatchTimeInterval = .milliseconds(150)

    /// 手势事件类型的原始值（`CGEventType` 没有具名 case，但 tap 掩码按原始值取位）。
    /// 取自 `NSEvent.EventType`：gesture 29 / magnify 30 / swipe 31 / smartMagnify 32 /
    /// rotate 18 / beginGesture 19 / endGesture 20。
    static let gestureEventRawValues: [UInt32] = [18, 19, 20, 29, 30, 31, 32]
    private static let gestureEventTypes = Set(gestureEventRawValues)

    private let state: FullscreenIntentAtomicState
    private let logger: Logger
    private let onIntent: (FullscreenIntentRequest) -> Void
    private let onSpaceSwitchIntent: (SpaceSwitchDirection, _ displayUUID: String) -> Void
    private let onGestureSample: (CGEvent) -> Void
    private let spaceSwitchEnabled: Bool
    private var gestureHopLock = os_unfair_lock_s()
    private var gestureHopInFlight = false
    /// `DOCK_SPACE_INTENT_TRACE=1` 时的手势诊断：每 60 个手势事件汇报一次去向，
    /// 避免每秒两百条日志把事件线程拖慢。默认关，零成本。
    private static let traceEnabled =
        DebugSwitch.spaceIntentTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private var gestureSeen: UInt64 = 0
    private var traceCounts: [String: Int] = [:]

    private func trace(_ outcome: String) {
        guard Self.traceEnabled else { return }
        traceCounts[outcome, default: 0] += 1
        guard gestureSeen % 60 == 0 else { return }
        let summary = traceCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.notice("[space-trace] seen=\(self.gestureSeen, privacy: .public) \(summary, privacy: .public)")
    }

    init(
        state: FullscreenIntentAtomicState,
        logger: Logger,
        spaceSwitchEnabled: Bool,
        onIntent: @escaping (FullscreenIntentRequest) -> Void,
        onSpaceSwitchIntent: @escaping (SpaceSwitchDirection, _ displayUUID: String) -> Void,
        onGestureSample: @escaping (CGEvent) -> Void
    ) {
        self.state = state
        self.logger = logger
        self.spaceSwitchEnabled = spaceSwitchEnabled
        self.onIntent = onIntent
        self.onSpaceSwitchIntent = onSpaceSwitchIntent
        self.onGestureSample = onGestureSample
    }

    func handle(type: CGEventType, event: CGEvent) {
        let request: FullscreenIntentRequest?
        switch type {
        case .leftMouseDown:
            request = FullscreenIntentDecision.greenButtonRequest(
                location: event.location,
                flags: event.flags,
                snapshot: state.currentSnapshot()
            )
        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // 空间切换先判：它不依赖 AX 快照（切空间时前台窗口能不能全屏无关紧要），
            // 而 shortcutRequest 没有快照就直接返回 nil。
            if spaceSwitchEnabled,
               let direction = FullscreenSpaceSwitchDecision.arrowDirection(
                   keyCode: keyCode,
                   flags: event.flags,
                   isRepeat: isRepeat
               ) {
                handleSpaceSwitch(direction: direction, label: "arrow")
                return
            }
            request = FullscreenIntentDecision.shortcutRequest(
                keyCode: keyCode,
                flags: event.flags,
                isRepeat: isRepeat,
                snapshot: state.currentSnapshot()
            )
        default:
            if spaceSwitchEnabled, Self.gestureEventTypes.contains(type.rawValue) {
                handleGesture(event)
            }
            request = nil
        }
        guard let request else { return }
        performHandoff(label: request.source.rawValue, pid: request.pid) { [weak self] in
            self?.onIntent(request)
        }
    }

    /// 三指水平滑动只做两件事：提前退出，以及把事件**异步**丢给主线程。
    ///
    /// **触控点必须在主线程用 CGEvent 现造 NSEvent 才读得到**（2026-08-09 受控实测：
    /// 事件线程上 `allTouches()` / `touches(matching:)` 都是 780/780 空集，把事件线程造出来的
    /// NSEvent 搬到主线程读同样是空的；只有在主线程重新 `NSEvent(cgEvent:)` 才有数据）。
    ///
    /// 这里可以异步、不必像绿灯那条一样卡住输入：三指滑动领先空间切换约 `950–1130ms`，
    /// 几毫秒的线程跳转无关紧要。同时用 in-flight 标志合并——手指按在触控板上时手势事件
    /// 约每秒 200 个，全部投到主线程既没必要（判据只要几十毫秒的位移）又会压垮主线程。
    private func handleGesture(_ event: CGEvent) {
        gestureSeen &+= 1
        guard state.currentSpaceContext() != nil else {
            trace("no-space-context")
            return
        }
        var shouldHop = false
        os_unfair_lock_lock(&gestureHopLock)
        if !gestureHopInFlight {
            gestureHopInFlight = true
            shouldHop = true
        }
        os_unfair_lock_unlock(&gestureHopLock)
        guard shouldHop else {
            trace("coalesced")
            return
        }
        guard let copy = event.copy() else {
            finishGestureHop()
            return
        }
        trace("hop")
        onGestureSample(copy)
    }

    func finishGestureHop() {
        os_unfair_lock_lock(&gestureHopLock)
        gestureHopInFlight = false
        os_unfair_lock_unlock(&gestureHopLock)
    }

    private func handleSpaceSwitch(direction: SpaceSwitchDirection, label: String) {
        // 事件线程只做并集闸（任一显示器该方向有全屏空间）；落在哪块屏在主线程交接体里定
        //（键盘焦点屏读不到，多块候选时取鼠标所在屏）。
        guard let context = state.currentSpaceContext(),
              !context.layouts.displays(withFullscreenNeighbor: direction).isEmpty else {
            return
        }
        performHandoff(label: label, pid: nil) { [weak self] in
            guard let self else { return }
            let target = self.state.currentSpaceContext()?.layouts
                .arrowTarget(direction, mouseLocation: NSEvent.mouseLocation)
            guard let target else { return }
            self.onSpaceSwitchIntent(direction, target.displayUUID)
        }
    }

    /// 命中后唯一的主线程交接：有上限地**同步**等待，`orderOut` 完成才放行原始输入 ——
    /// 这是唯一被实测证明有效的时序条件，不能改成 `main.async`。超时后迟到的 block 由
    /// `FullscreenIntentHandoffGate` 变成 no-op，输入原样放行（退化成今天的闪烁）。
    private func performHandoff(label: String, pid: pid_t?, _ body: @escaping () -> Void) {
        let gate = FullscreenIntentHandoffGate()
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            guard gate.beginExecution() else {
                completion.signal()
                return
            }
            body()
            gate.complete()
            completion.signal()
        }

        if completion.wait(timeout: .now() + Self.handoffTimeout) == .timedOut {
            let cancelled = gate.cancelIfPending()
            logger.error(
                "handoff-timeout source=\(label, privacy: .public) pid=\(pid ?? -1, privacy: .public) cancelled=\(cancelled, privacy: .public)"
            )
        }
    }
}

private final class FullscreenIntentEventTapThread {
    private let logger: Logger
    private let bridge: FullscreenIntentEventBridge
    private let atomicState: FullscreenIntentAtomicState
    private var lifecycleLock = os_unfair_lock_s()
    private var recoveryLock = os_unfair_lock_s()
    private var recoveryPolicy = FullscreenEventTapRecoveryPolicy()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var stopping = false
    private let finished = DispatchSemaphore(value: 0)

    init(
        logger: Logger,
        bridge: FullscreenIntentEventBridge,
        atomicState: FullscreenIntentAtomicState
    ) {
        self.logger = logger
        self.bridge = bridge
        self.atomicState = atomicState
    }

    func start() {
        withLifecycleLock {
            guard thread == nil else { return }
            stopping = false
            let thread = Thread { [weak self] in self?.run() }
            thread.name = "com.caye.macosdockcc.fullscreen-intent-tap"
            thread.qualityOfService = .userInteractive
            self.thread = thread
            thread.start()
        }
    }

    func stop() {
        atomicState.setTapEnabled(false)
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
            var mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            // 三指滑动切空间要看手势事件；掩码按事件原始值取位，CGEventType 没有具名 case。
            for raw in FullscreenIntentEventBridge.gestureEventRawValues {
                mask |= (CGEventMask(1) << CGEventMask(raw))
            }
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                logger.error("event-tap-create-failed")
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
            atomicState.setTapEnabled(true)
            CFRunLoopRun()
            atomicState.setTapEnabled(false)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            finished.signal()
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<FullscreenIntentEventTapThread>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            owner.handleDisabled(type: type)
        } else {
            owner.bridge.handle(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleDisabled(type: CGEventType) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReenable: Bool = withRecoveryLock {
            recoveryPolicy.recordDisable(at: now)
        }
        guard shouldReenable, let tap = withLifecycleLock({ self.tap }) else {
            atomicState.setTapEnabled(false)
            logger.fault("event-tap-fused type=\(type.rawValue, privacy: .public)")
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        atomicState.setTapEnabled(true)
        logger.error("event-tap-reenabled type=\(type.rawValue, privacy: .public)")
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

@MainActor
final class FullscreenIntentMonitor {
    enum ContextChange {
        case activeApplication(pid_t?)
        case focusedWindow
        case windowDestroyed(CGWindowID?)
    }

    /// `AXUIElement` 是不可变的 CF 句柄，跨线程传递安全；`@unchecked` 只是替 ApplicationServices 补上它没标的 Sendable。
    private struct AXReadResult: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        let windowID: CGWindowID
        let buttonFrame: CGRect
        let windowFrame: CGRect
        let screenCGFrame: CGRect
        let isFullscreen: Bool
        let buttonEnabled: Bool
    }

    private let logger = Logger(
        subsystem: "com.caye.macosdockcc.v2",
        category: "FullscreenIntent"
    )
    private let atomicState = FullscreenIntentAtomicState()
    private let onIntent: (FullscreenIntentRequest) -> Void
    /// 方向 + 要预测隐藏的那块显示器的 UUID（空间切换按显示器发生）。
    private let onSpaceSwitchIntent: (SpaceSwitchDirection, _ displayUUID: String) -> Void
    private let onContextChange: (ContextChange) -> Void
    private let spaceSwitchEnabled: Bool
    private lazy var bridge = FullscreenIntentEventBridge(
        state: atomicState,
        logger: logger,
        spaceSwitchEnabled: spaceSwitchEnabled,
        onIntent: { [weak self] request in self?.accept(request) },
        onSpaceSwitchIntent: { [weak self] direction, displayUUID in
            guard let self, self.started else { return }
            self.onSpaceSwitchIntent(direction, displayUUID)
        },
        onGestureSample: { [weak self] event in
            // 触控点只有在主线程现造 NSEvent 才读得到（见 handleGesture 的注释）。
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.processGestureSample(event) }
            }
        }
    )
    private lazy var tapThread = FullscreenIntentEventTapThread(
        logger: logger,
        bridge: bridge,
        atomicState: atomicState
    )

    private var workspaceActivationObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var appElement: AXUIElement?
    private var focusedElement: AXUIElement?
    private var focusedWindowID: CGWindowID?
    private var activePID: pid_t?
    /// 有任务条的屏的 CG frame 集合（③④ 下多块）。
    private var panelScreenCGFrames: Set<CGRect> = []
    private var observationGeneration: UInt64 = 0
    private var cacheGeneration: UInt64 = 0
    private var refreshCoalescer = FullscreenIntentRefreshCoalescer()
    /// 只在主线程读写（`processGestureSample`）。
    private var swipeTracker = SpaceSwipeTracker()
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var started = false

    init(
        spaceSwitchEnabled: Bool = DebugSwitch.spaceIntent.isEnabled(in: ProcessInfo.processInfo.environment),
        onIntent: @escaping (FullscreenIntentRequest) -> Void,
        onSpaceSwitchIntent: @escaping (SpaceSwitchDirection, _ displayUUID: String) -> Void,
        onContextChange: @escaping (ContextChange) -> Void
    ) {
        self.spaceSwitchEnabled = spaceSwitchEnabled
        self.onIntent = onIntent
        self.onSpaceSwitchIntent = onSpaceSwitchIntent
        self.onContextChange = onContextChange
    }

    /// 空间布局快照：只在空间切换 / 屏幕参数变化时重读（每块屏约 0.132ms）。
    /// 事件线程只读缓存，永远不在 tap 回调里调 SkyLight。
    /// **对所有显示器读**（不只有任务条的那些）：空间切换按显示器发生，预测先要定位到那块屏；
    /// 按 UUID 匹配，不按数组顺序。
    func refreshSpaceLayout() {
        guard started, spaceSwitchEnabled else { return }
        let natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection")
            .map { ($0 as? Bool) ?? true } ?? true
        let entries: [SpaceLayoutDirectory.Entry] = NSScreen.screens.compactMap { screen in
            guard let uuid = ManagedSpaceLayoutReader.displayUUIDString(for: screen),
                  let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else { return nil }
            return SpaceLayoutDirectory.Entry(displayUUID: uuid, appKitFrame: screen.frame, layout: layout)
        }
        atomicState.replaceSpaceLayout(
            entries.isEmpty ? nil : SpaceLayoutDirectory(entries: entries),
            naturalScrolling: natural
        )
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceActivationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor [weak self] in self?.activate(pid: pid) }
        }
        spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 空间刚切完：同一次滑动的减速尾巴还在继续投递手势事件，
                // 清掉状态机，别让余波凑成新的一串。
                self.swipeTracker.reset()
                self.refreshSpaceLayout()
                // 全屏空间在空间序里的排位要 ~420ms 才落定（实测 [1 3 4 F]→[1 F 3 4]），
                // 切换瞬间读到的布局可能把两个方向的闸都关死——高速连滑时表现为
                // 「一对失败（进闪 + 出迟到）然后自愈」（2026-08-31 实测）。0.6s 后再刷一次，
                // 脏快照赶在下一次滑动前自愈。多刷无害（单次 0.132ms、幂等）。
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    self?.refreshSpaceLayout()
                }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSpaceLayout() }
        }
        tapThread.start()
        let initialPID = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?.processIdentifier
        activate(pid: initialPID)
        refreshSpaceLayout()
    }

    func stop() {
        guard started else { return }
        started = false
        observationGeneration &+= 1
        cacheGeneration &+= 1
        refreshCoalescer.reset()
        atomicState.replaceSnapshot(nil)
        atomicState.replaceSpaceLayout(nil, naturalScrolling: true)
        let center = NSWorkspace.shared.notificationCenter
        if let observer = workspaceActivationObserver {
            center.removeObserver(observer)
            workspaceActivationObserver = nil
        }
        if let observer = spaceObserver {
            center.removeObserver(observer)
            spaceObserver = nil
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        stopAXObservation()
        tapThread.stop()
    }

    /// 编排层在任一单元换屏 / 建拆单元后喂进全部有任务条的屏。集合没变时是空操作。
    func updatePanelScreens(_ frames: Set<CGRect>) {
        guard frames != panelScreenCGFrames else { return }
        panelScreenCGFrames = frames
        atomicState.updatePanelScreens(frames)
    }

    private static let mainTraceEnabled =
        DebugSwitch.spaceIntentTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private var mainTraceSeen: UInt64 = 0
    private var mainTraceCounts: [String: Int] = [:]

    private func mainTrace(_ outcome: String) {
        guard Self.mainTraceEnabled else { return }
        mainTraceSeen &+= 1
        mainTraceCounts[outcome, default: 0] += 1
        guard mainTraceSeen % 60 == 0 else { return }
        let summary = mainTraceCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.notice("[space-main] seen=\(self.mainTraceSeen, privacy: .public) \(summary, privacy: .public)")
    }

    /// 主线程侧的三指判定：现造 NSEvent → 读触控点 → 喂纯状态机 → 过相邻空间闸。
    /// 必须在主线程；事件线程造出来的 NSEvent 读不到触控点（受控实测）。
    private func processGestureSample(_ event: CGEvent) {
        defer { bridge.finishGestureHop() }
        guard started, spaceSwitchEnabled else { return mainTrace("not-started") }
        guard let context = atomicState.currentSpaceContext() else {
            return mainTrace("no-context")
        }
        guard let ns = NSEvent(cgEvent: event) else { return mainTrace("nsevent-nil") }
        // **`NSTouch.Phase.touching` 是组合值（began|moved|stationary），必须用交集判断。**
        // 写成 `phase.contains(.touching)` 要求单个触点同时具备三种状态，永远不成立——
        // 2026-08-09 实测：`allTouches()` 明明给出 3 个触点，过滤后恒为 0，功能完全不触发。
        // 独立探针里用的是 `touches(matching:)`，那个 API 内部就是取交集，所以没暴露这个错。
        let all = ns.allTouches()
        let touching = all.filter { !$0.phase.intersection(.touching).isEmpty }
        mainTrace("all=\(all.count) touching=\(touching.count)")
        // 手势事件里约三分之一不带触控数据（magnify 之类）：跳过即可，**不要当作
        // 「手指抬起」去重置状态机**，否则一串滑动会被反复打断。串的结束交给
        // `SpaceSwipeTracker` 的时间间隔判定。
        guard !touching.isEmpty else { return }
        let xs = touching.map { $0.normalizedPosition.x }
        let ys = touching.map { $0.normalizedPosition.y }
        guard let direction = swipeTracker.consume(
            touches: touching.count,
            x: xs.reduce(0, +) / Double(xs.count),
            y: ys.reduce(0, +) / Double(ys.count),
            at: ProcessInfo.processInfo.systemUptime,
            naturalScrolling: context.naturalScrolling
        ) else { return }
        // 三指滑动作用于光标所在的显示器：先定位到那块屏的布局，再判相邻空间。
        let mouse = NSEvent.mouseLocation
        guard let entry = context.layouts.entry(containing: mouse) else {
            return mainTrace("no-display-under-mouse")
        }
        var open = entry.layout.neighborIsFullscreen(direction)
        if !open {
            // 闸关着可能只是缓存脏：空间切换后 ~420ms 内 SkyLight 的空间序还在重排，
            // 切换瞬间刷进缓存的布局会把闸误关（2026-08-31 实测）。当场重读一次真值
            // 再判——0.132ms、主线程、每串手势最多一次。仍关才是真的没得预测。
            // 已试过并回退：再挂 250ms 复判补发——噪声手势的迟到预测也会被补发出去，
            // 桌面上凭空藏一下条，闪烁不降反升。起滑落在脏窗口内的手势漏预测是
            // 已接受的边界（正常节奏碰不到）。
            refreshSpaceLayout()
            open = atomicState.currentSpaceContext()?.layouts
                .entry(forDisplayUUID: entry.displayUUID)?.layout
                .neighborIsFullscreen(direction) ?? false
        }
        guard open else {
            mainTrace("gate-closed-\(direction.rawValue)")
            return
        }
        logger.notice("space-swipe direction=\(direction.rawValue, privacy: .public)")
        onSpaceSwitchIntent(direction, entry.displayUUID)
    }

    private func accept(_ request: FullscreenIntentRequest) {
        guard FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: atomicState.currentSnapshot(),
            activePID: activePID,
            started: started
        ) else {
            return
        }
        onIntent(request)
    }

    private func activate(pid: pid_t?) {
        guard activePID != pid || axObserver == nil else { return }
        activePID = pid
        observationGeneration &+= 1
        cacheGeneration &+= 1
        atomicState.replaceSnapshot(nil)
        stopAXObservation()
        onContextChange(.activeApplication(pid))
        guard let pid else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &observer) == .success,
              let observer else {
            return
        }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.1)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        appElement = app
        refreshCache()
    }

    private func stopAXObservation() {
        if let observer = axObserver {
            unregisterFocusedElement(observer: observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        appElement = nil
        focusedElement = nil
        focusedWindowID = nil
    }

    private func refreshCache() {
        guard let pid = activePID else { return }
        guard let token = refreshCoalescer.request() else { return }
        startCacheRefresh(token: token, pid: pid)
    }

    private func startCacheRefresh(token: UInt64, pid: pid_t) {
        let expectedCache = cacheGeneration
        let expectedObservation = observationGeneration
        let screens = Self.screenFrames()
        Task.detached(priority: .userInitiated) {
            let result = Self.readAXState(pid: pid, screenFrames: screens)
            await MainActor.run { [weak self] in
                self?.finishCacheRefresh(
                    token: token,
                    result: result,
                    pid: pid,
                    expectedCache: expectedCache,
                    expectedObservation: expectedObservation
                )
            }
        }
    }

    private func finishCacheRefresh(
        token: UInt64,
        result: AXReadResult?,
        pid: pid_t,
        expectedCache: UInt64,
        expectedObservation: UInt64
    ) {
        let completion = refreshCoalescer.complete(token: token)
        guard completion != .ignored else { return }

        if FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: started,
            expectedObservation: expectedObservation,
            currentObservation: observationGeneration,
            expectedCache: expectedCache,
            currentCache: cacheGeneration,
            requestedPID: pid,
            activePID: activePID
        ) {
            if let result {
                registerFocusedElement(result.element, windowID: result.windowID)
                atomicState.replaceSnapshot(FullscreenIntentSnapshot(
                    generation: expectedCache,
                    pid: result.pid,
                    focusedWindowID: result.windowID,
                    buttonFrame: result.buttonFrame,
                    windowFrame: result.windowFrame,
                    screenCGFrame: result.screenCGFrame,
                    panelScreenCGFrames: panelScreenCGFrames,
                    isFullscreen: result.isFullscreen,
                    buttonEnabled: result.buttonEnabled
                ))
            } else {
                atomicState.replaceSnapshot(nil)
                unregisterFocusedElement(observer: axObserver)
            }
        }

        if case let .start(nextToken) = completion {
            guard started, let nextPID = activePID else {
                refreshCoalescer.reset()
                return
            }
            startCacheRefresh(token: nextToken, pid: nextPID)
        }
    }

    private func invalidateCache() {
        cacheGeneration &+= 1
        atomicState.replaceSnapshot(nil)
    }

    private func registerFocusedElement(_ element: AXUIElement, windowID: CGWindowID) {
        guard let observer = axObserver else { return }
        if focusedWindowID == windowID { return }
        unregisterFocusedElement(observer: observer)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, element, kAXWindowMovedNotification as CFString, refcon)
        AXObserverAddNotification(observer, element, kAXWindowResizedNotification as CFString, refcon)
        AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
        focusedElement = element
        focusedWindowID = windowID
    }

    private func unregisterFocusedElement(observer: AXObserver?) {
        guard let observer, let element = focusedElement else {
            focusedElement = nil
            focusedWindowID = nil
            return
        }
        AXObserverRemoveNotification(observer, element, kAXWindowMovedNotification as CFString)
        AXObserverRemoveNotification(observer, element, kAXWindowResizedNotification as CFString)
        AXObserverRemoveNotification(observer, element, kAXUIElementDestroyedNotification as CFString)
        focusedElement = nil
        focusedWindowID = nil
    }

    private func handleAXNotification(_ notification: CFString) {
        let name = notification as String
        if name == (kAXFocusedWindowChangedNotification as String) {
            invalidateCache()
            onContextChange(.focusedWindow)
            refreshCache()
        } else if name == (kAXWindowCreatedNotification as String) {
            // 原生全屏转场本身会创建临时 AX 元素；这不是焦点离开原窗口的证据。
            invalidateCache()
            refreshCache()
        } else if name == (kAXWindowMovedNotification as String)
            || name == (kAXWindowResizedNotification as String) {
            invalidateCache()
            refreshCache()
        } else if name == (kAXUIElementDestroyedNotification as String) {
            let windowID = focusedWindowID
            invalidateCache()
            onContextChange(.windowDestroyed(windowID))
            unregisterFocusedElement(observer: axObserver)
            refreshCache()
        }
    }

    private static let axCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<FullscreenIntentMonitor>.fromOpaque(refcon).takeUnretainedValue()
        // The observer source is installed on CFRunLoopGetMain(), so invalidate during the
        // notification turn instead of adding a second main-queue hop.
        MainActor.assumeIsolated {
            monitor.handleAXNotification(notification)
        }
    }

    nonisolated private static func readAXState(
        pid: pid_t,
        screenFrames: [CGRect]
    ) -> AXReadResult? {
        let reader = AXWindowReader()
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.1)
        guard let focused = reader.elementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: app,
            maxAttempts: 1
        ) else { return nil }
        _ = AXUIElementSetMessagingTimeout(focused, 0.1)
        guard reader.stringAttribute(kAXRoleAttribute as CFString, from: focused, maxAttempts: 1) == kAXWindowRole,
              let windowID = reader.cgWindowID(for: focused, maxAttempts: 1),
              let windowFrame = reader.frame(of: focused, maxAttempts: 1),
              let screenFrame = screenFrames.max(by: {
                  $0.intersection(windowFrame).area < $1.intersection(windowFrame).area
              }),
              screenFrame.intersects(windowFrame),
              let button = reader.elementAttribute(
                  "AXFullScreenButton" as CFString,
                  from: focused,
                  maxAttempts: 1
              ) else { return nil }
        _ = AXUIElementSetMessagingTimeout(button, 0.1)
        guard let buttonFrame = reader.frame(of: button, maxAttempts: 1) else { return nil }
        let isAXFullscreen = reader.boolAttribute(
            "AXFullScreen" as CFString,
            from: focused,
            maxAttempts: 1
        ) ?? false
        let isFullscreen = FullscreenWindowClassifier.isFullscreen(
            role: kAXWindowRole,
            isAXFullscreen: isAXFullscreen,
            windowFrame: windowFrame,
            screenCGFrame: screenFrame
        )
        return AXReadResult(
            element: focused,
            pid: pid,
            windowID: windowID,
            buttonFrame: buttonFrame,
            windowFrame: windowFrame,
            screenCGFrame: screenFrame,
            isFullscreen: isFullscreen,
            buttonEnabled: reader.boolAttribute(
                kAXEnabledAttribute as CFString,
                from: button,
                maxAttempts: 1
            ) ?? false
        )
    }

    private static func screenFrames() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        return NSScreen.screens.map { screen in
            let frame = screen.frame
            return CGRect(
                x: frame.minX,
                y: primaryHeight - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
