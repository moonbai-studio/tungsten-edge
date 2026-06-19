import Foundation
import CoreGraphics

struct WindowRecord: Hashable, Sendable {
    let id: WindowID
    let appID: AppID
    let pid: Int32
    let bundleIdentifier: String?
    var title: String
    var bounds: CGRect?
    var status: WindowStatus
    var cgWindowID: CGWindowID?
    var isOnDesktop: Bool
    /// 稳定分组身份（标签组根治）。同一物理窗口的所有原生标签座位共享同一个 token，一旦分配就
    /// **不随当前激活标签的 CGWindowID 变化**；普通单窗口是自成一组的 token。任务条据此合并、
    /// 并以它作为卡片的稳定 id（切标签 / 后台标签来去都不换身份证 → 卡片不跳不裂）。
    /// 默认空串 = 退化为按 `id` 各自独立（兼容未赋值路径）。
    var groupID: String

    init(
        id: WindowID,
        appID: AppID,
        pid: Int32,
        bundleIdentifier: String?,
        title: String,
        bounds: CGRect?,
        status: WindowStatus,
        cgWindowID: CGWindowID? = nil,
        isOnDesktop: Bool = false,
        groupID: String = ""
    ) {
        self.id = id
        self.appID = appID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.bounds = bounds
        self.status = status
        self.cgWindowID = cgWindowID
        self.isOnDesktop = isOnDesktop
        self.groupID = groupID.isEmpty ? id.rawValue : groupID
    }
}

enum WindowStatus: String, Hashable, Codable, Sendable {
    case active
    case inactive
    case minimized
    case hidden
    case closedPending
    case disappeared
}

/// 乐观状态 overlay（交互打磨 2026-06-13）：点击发出显隐类动作（activate / minimize /
/// hide）的瞬间，先本地假定窗口已变成目标状态，UI 与下一次 toggle 规划都优先读它，
/// 不等快照 round-trip —— 这就是「可打断 / 连点衔接」的根。真实快照兑现预测或超时
/// 后清除（静默回弹）。close / quit 不写乐观态（窗口要消失，失败回弹会闪）。
struct OptimisticWindowState: Hashable, Sendable {
    let status: WindowStatus
    /// toggle 规划同时读 status 和 frontmost（LifecycleActionPlanner），所以预测态
    /// 必须把两个轴都盖住，否则连点交替会被真实 NSWorkspace 前台值打断。
    let isAppFrontmost: Bool
    let createdAt: Date
}
