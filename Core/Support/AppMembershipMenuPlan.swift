import Foundation

/// 成员菜单的**纯决策层**：给定图标所在面（strip / drawer）+ Finder / kept / messaging
/// 状态，产出应出现的成员项（顺序即渲染顺序，不含 closure）。抽成纯逻辑便于单测；把 `Item`
/// 映射成带动作的菜单项由 `LauncherMembershipItem.items` 完成，四条菜单构造路径统一消费。
///
/// 固定矩阵（消息项标题恒定，以原生勾选态表达成员身份）：
/// - strip 普通/消息：在程序坞中保留 + 固定在 Dock 栏左侧 + 独立的显示未读角标
/// - drawer 普通：仅在程序坞中保留
/// - drawer 消息：在程序坞中保留 + 固定在 Dock 栏左侧（已勾选）
/// - Finder：仅在程序坞中保留（2026-08-20 起访达纳入统一保留勾选，但仍不能进消息区）
enum AppMembershipMenuPlan {
    enum Surface: Equatable { case strip, drawer }

    /// 无 closure 的展示态，供渲染层映射成具体动作。
    enum Item: Equatable {
        case keep(isChecked: Bool)
        case messaging(isChecked: Bool)
        case unreadBadge(isChecked: Bool)
    }

    static func items(surface: Surface,
                      isFinder: Bool,
                      isKept: Bool,
                      isMessaging: Bool,
                      showsUnreadBadge: Bool = false) -> [Item] {
        // 访达只给保留勾选：消息区的图标代表「这个应用的主窗口」，访达没有这种语义。
        if isFinder { return [.keep(isChecked: isKept)] }
        // 保留勾选恒在前，消息命令在后。
        var items: [Item] = [.keep(isChecked: isKept)]
        if isMessaging {
            items.append(.messaging(isChecked: true))
        } else if surface == .strip {
            // 「固定在 Dock 栏左侧」只在 strip 的普通应用出现：抽屉里标记不改 placement（抽屉优先级更高），
            // 没有可见效果，故 drawer 面不提供该命令。
            items.append(.messaging(isChecked: false))
        }
        // 抽屉本来不画角标，只在能看到效果的条上提供开关。
        if surface == .strip {
            items.append(.unreadBadge(isChecked: showsUnreadBadge))
        }
        return items
    }
}
