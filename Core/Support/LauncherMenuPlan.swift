import Foundation

/// 启动图标（LauncherChip）右键菜单的**纯决策层**：给定「显示区运行态 + 是否有成员项」，
/// 产出应出现的菜单项种类（顺序即渲染顺序）。抽成纯逻辑是为了可单测，构建 NSMenu 的副作用留在 LauncherChip。
///
/// 关键：`isRunning` 传的是**图标所在区的显示态**（`LauncherChip.isRunning`，按区赋值），
/// **不是** `NSWorkspace` 的进程存活态。未运行区里进程可能仍活（关窗不退 / 常驻），
/// 但它按「未运行」显示，菜单也必须按未运行处理——否则会冒出与外观矛盾的「隐藏 / 退出」。

enum LauncherMenuItemKind: Equatable {
    /// 「打开」——仅未运行时出现，严格排在最近文件与成员项之前。运行态用 显示/隐藏/退出 代替。
    case open
    case recentDocuments
    case show
    case hide
    case quit
    /// 成员 / 管理项区（可勾选的在程序坞中保留 / 取消标记消息应用；1 或多项由调用方决定）。
    case membership
}

enum LauncherMenuPlan {
    /// - Parameters:
    ///   - isRunning: 图标所在区的**显示态**（非进程存活态）。
    ///   - isHidden: 显示态下 app 是否隐藏（决定「显示」还是「隐藏」）。
    ///   - hasMembership: 是否有成员/管理项。
    static func itemKinds(isRunning: Bool,
                          isHidden: Bool,
                          hasMembership: Bool) -> [LauncherMenuItemKind] {
        var kinds: [LauncherMenuItemKind] = []
        if !isRunning { kinds.append(.open) }
        if isRunning || hasMembership { kinds.append(.recentDocuments) }
        if isRunning {
            kinds.append(isHidden ? .show : .hide)
            kinds.append(.quit)
        }
        if hasMembership { kinds.append(.membership) }
        return kinds
    }
}
