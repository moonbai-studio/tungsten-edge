import SwiftUI

// MARK: - 纯判定

/// 按压反馈的纯判定层。时间只从参数进来，`ChipPressFeedbackTests` 锁住这里。
///
/// **为什么要有按下这条边**（owner 2026-08-11 报「按下去有粘滞感」）：旧实现把回弹挂在
/// `.onTapGesture` 上，而 SwiftUI 的 TapGesture 是**鼠标抬起**才触发的——按下那一刻屏幕零变化，
/// 松手之后才开始缩放。整个「按压」发生在点击已经结束之后，读起来就是延迟。现在改由
/// `DragGesture(minimumDistance: 0)` 的 `onChanged` 在按下瞬间驱动。
enum ChipPressDecision {
    /// 按下时的缩放。与改动前的 `isTapPressed ? 0.93 : 1.0` 完全一致，刻意不动。
    static let pressedScale: CGFloat = 0.93

    /// 抬起后仍要保持按下态的最短时长。一次极快的点击（按下到抬起只有几毫秒）如果立刻弹回，
    /// 那一下缩放根本看不见——这就是旧实现里那个 90ms 定时器的本意，原样保留。
    static let minimumHold: TimeInterval = 0.09

    /// 兜底上限。SwiftUI 会在重排挪动 chip 时**取消**手势（见 `DockStripView` 消息区重排、
    /// `DrawerView` 抽屉重排两处注释），那种情况下 `onEnded` 可能永远不来。没有这道闸，
    /// chip 会永久停在 0.93。
    static let maximumHold: TimeInterval = 1.0

    /// 抬起时还需要继续保持多久才允许弹回（0 = 立即弹回）。
    ///
    /// - `pressedAt` 为 nil：没记到按下（例如力度触控那种只有脉冲的路径），补足整段。
    /// - 抬起早于按下（时钟异常）：同样补足整段，不返回负数。
    static func holdAfterRelease(pressedAt: TimeInterval?, releasedAt: TimeInterval) -> TimeInterval {
        guard let pressedAt, releasedAt >= pressedAt else { return minimumHold }
        return max(0, minimumHold - (releasedAt - pressedAt))
    }
}

/// 默认按下即反馈。`DOCK_CHIP_PRESS_DOWN=0` 退回旧行为（鼠标抬起才播一次脉冲）。
///
/// 留这个开关的理由：`minimumDistance: 0` 的手势要和已有的 8pt 重排拖拽共存。仓库里
/// `simultaneousGesture` + `onTapGesture` + `nativeContextMenu` 三者共存已有先例
/// （`DockStripView.chipWithReorder`），但万一在实机上影响到拖拽或点击本身，
/// owner 能立刻退回去，不用等重新打包。
enum ChipPressSwitches {
    static let pressDownEnabled = DebugSwitch.chipPressDown.isEnabled(in: ProcessInfo.processInfo.environment)
}

enum ChipPressAnimation {
    /// 按下要「沉得快」。旧实现两条边共用一条 spring（阻尼 0.5），所以按下也会过冲——
    /// 那在抬起后播还看不太出来，按下即时播就很明显了。
    static let down = Animation.easeOut(duration: 0.08)

    /// 回弹沿用旧参数，一个字不改：这是 owner 已经签收过的观感。
    static let up = Animation.spring(response: 0.22, dampingFraction: 0.5)
}

// MARK: - 视图接入

extension View {
    /// 只做视觉：按压缩放 + 两条边各自的曲线。
    ///
    /// 和手势**分成两个修饰器**是刻意的：抽屉胶囊的按压只作用在里面的九宫格上、外框保持静止
    /// （owner 2026-06-21 定），所以缩放和手势必须能挂在不同层级。
    func chipPressScale(_ isPressed: Bool) -> some View {
        scaleEffect(isPressed ? ChipPressDecision.pressedScale : 1.0)
            .animation(isPressed ? ChipPressAnimation.down : ChipPressAnimation.up, value: isPressed)
    }

    /// 只驱动状态，不改任何几何。放在 `.contentShape(...)` **之后**，让按压的命中区域
    /// 和点击完全一致。
    ///
    /// - Parameters:
    ///   - isPressed: 由调用方持有的 `@State`（沿用旧的 `isTapPressed` 位置）。
    ///   - pulseNonce: 力度触控 / 中键预览的外部脉冲。那条路径没有 mouse-up，需要自动 down+up 一次。
    ///   - isEnabled: 关掉时既不装手势也不响应脉冲（`LauncherChip` 在启动会话期间用它——
    ///     那时候点击本来就是 no-op，给按压反馈等于骗人）。
    ///   - onEvent: 纯诊断出口（`ChipAnimationTrace`）。**永不喂 planner / frontmost 轴**（AGENTS）。
    func chipPressGesture(
        isPressed: Binding<Bool>,
        pulseNonce: Int = 0,
        isEnabled: Bool = true,
        onEvent: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        modifier(ChipPressGestureModifier(
            isPressed: isPressed,
            pulseNonce: pulseNonce,
            isEnabled: isEnabled,
            onEvent: onEvent
        ))
    }
}

private struct ChipPressGestureModifier: ViewModifier {
    @Binding var isPressed: Bool
    let pulseNonce: Int
    let isEnabled: Bool
    let onEvent: (Bool) -> Void

    @State private var pressedAt: TimeInterval?
    @State private var releaseWork: DispatchWorkItem?
    @State private var watchdogWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, ChipPressSwitches.pressDownEnabled else { return }
                        beginPress()
                    }
                    .onEnded { _ in
                        guard isEnabled else { return }
                        if ChipPressSwitches.pressDownEnabled {
                            endPress()
                        } else {
                            // 旧行为：抬起才播一次完整的 down + up。
                            firePulse()
                        }
                    }
            )
            .onChange(of: pulseNonce) { _ in
                guard isEnabled else { return }
                firePulse()
            }
            .onDisappear {
                cancelPending()
                setPressed(false)
            }
    }

    private func beginPress() {
        guard !isPressed else { return }
        cancelPending()
        pressedAt = ProcessInfo.processInfo.systemUptime
        setPressed(true)
        scheduleWatchdog()
    }

    private func endPress() {
        guard isPressed else { return }
        let hold = ChipPressDecision.holdAfterRelease(
            pressedAt: pressedAt,
            releasedAt: ProcessInfo.processInfo.systemUptime
        )
        if hold <= 0 {
            cancelPending()
            setPressed(false)
        } else {
            scheduleRelease(after: hold)
        }
    }

    /// 没有 mouse-up 的路径（力度触控 / 中键预览 / 关掉按下档时的兼容行为）。
    private func firePulse() {
        cancelPending()
        pressedAt = ProcessInfo.processInfo.systemUptime
        setPressed(true)
        scheduleRelease(after: ChipPressDecision.minimumHold)
    }

    private func scheduleRelease(after delay: TimeInterval) {
        // 已经进入释放倒计时，看门狗就没有意义了（它只防「onEnded 永远不来」）。
        watchdogWork?.cancel()
        watchdogWork = nil
        releaseWork?.cancel()
        let work = DispatchWorkItem {
            releaseWork = nil
            setPressed(false)
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleWatchdog() {
        watchdogWork?.cancel()
        let work = DispatchWorkItem {
            watchdogWork = nil
            setPressed(false)
        }
        watchdogWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ChipPressDecision.maximumHold,
            execute: work
        )
    }

    private func cancelPending() {
        releaseWork?.cancel()
        releaseWork = nil
        watchdogWork?.cancel()
        watchdogWork = nil
    }

    private func setPressed(_ value: Bool) {
        guard isPressed != value else { return }
        isPressed = value
        onEvent(value)
    }
}
