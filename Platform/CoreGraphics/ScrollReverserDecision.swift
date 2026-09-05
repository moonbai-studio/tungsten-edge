import Foundation

/// 一个滚轮事件的六个方向字段（`CGEventField` 的三组 axis1/axis2）。
/// 纯值类型：反转逻辑要可单测，读写 CGEvent 的副作用留在 `ScrollReverserMonitor`。
struct ScrollWheelDeltas: Equatable {
    var axis1: Int64
    var axis2: Int64
    var pointAxis1: Int64
    var pointAxis2: Int64
    var fixedAxis1: Double
    var fixedAxis2: Double
}

/// 「全局反转鼠标滚轮」的纯决策（设置「通用 · 反转鼠标滚轮方向」，默认关）。
enum ScrollReverserDecision {
    static func isEnabled(
        settingEnabled: Bool,
        environment: [String: String]
    ) -> Bool {
        settingEnabled && DebugSwitch.scrollReverser.isEnabled(in: environment)
    }

    /// 只反转离散滚轮（`scrollWheelEventIsContinuous == 0` = 带格子的鼠标滚轮）。
    /// 触控板、妙控鼠标、开了平滑滚动的鼠标发的是连续事件，一律放行——
    /// 它们的方向归系统「自然滚动」管，跟着反会把触控板一起翻过来。
    /// 动量滚动不用单独判：动量只出现在连续事件上，已被这一条覆盖。
    static func shouldReverse(isContinuous: Bool) -> Bool {
        !isContinuous
    }

    static func reversed(_ deltas: ScrollWheelDeltas) -> ScrollWheelDeltas {
        ScrollWheelDeltas(
            axis1: negated(deltas.axis1),
            axis2: negated(deltas.axis2),
            pointAxis1: negated(deltas.pointAxis1),
            pointAxis2: negated(deltas.pointAxis2),
            fixedAxis1: -deltas.fixedAxis1,
            fixedAxis2: -deltas.fixedAxis2
        )
    }

    /// `Int64.min` 取负会溢出崩溃。真实滚轮 delta 是个位数，这纯属防御——
    /// 但这条 tap 收的是**全系统**的滚动事件，防御就得是绝对的。
    private static func negated(_ value: Int64) -> Int64 {
        value == .min ? .max : -value
    }
}
