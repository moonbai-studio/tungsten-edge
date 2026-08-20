import Foundation

/// 首次运行要不要弹「建议隐藏系统 Dock」那一屏。
///
/// 纯决策，不碰 I/O，可单测。调用方（`AppDelegate`）负责读系统 Dock 状态、弹窗、写标记。
///
/// ## 为什么不是一个布尔就够
///
/// 只看「有没有看过」会误伤两拨人：
///
/// - **升级上来的老用户**。他们多半早就把系统 Dock 隐藏了（README 的「推荐配置」一节
///   一直这么建议），再弹一次纯属噪音。
/// - **沙箱环境**。写系统 Dock 偏好需要非沙箱（`NativeDockPreferencesService.isAvailable`），
///   弹了也按不动，只会给一个必然失败的按钮。
///
/// 所以再读一次系统 Dock 的真实状态，按四种情况分开处理。这套写法对齐
/// `AutoHideToggleMenuModel.resolvedStoreDelay` 的「四象限」纪律：**读不到**是一种独立状态，
/// 不能和「读到了 false」混为一谈。
enum WelcomeGuideDecision {
    enum Outcome: Equatable {
        /// 弹引导。
        case present
        /// 不弹，并且**记下已看过**——这台机器以后都不用再问了。
        case skipAndMarkSeen
        /// 不弹，但**不记**。只是这一次没读到系统状态，下次启动再判。
        case skipWithoutMarking
    }

    /// - Parameters:
    ///   - hasSeenWelcome: `AppSettingsStore.hasSeenWelcome`
    ///   - canWriteDockPreferences: `NativeDockPreferencesService.isAvailable`（非沙箱）
    ///   - dockAutohideEnabled: 系统 Dock 当前是否自动隐藏；`nil` = **读不到**
    ///     （`currentAutohideState()` 返回 nil），不是「没开」
    static func evaluate(
        hasSeenWelcome: Bool,
        canWriteDockPreferences: Bool,
        dockAutohideEnabled: Bool?
    ) -> Outcome {
        // 看过就是看过。这一条必须排在最前面：它是用户已经表达过的意思
        //（无论他当时点的是「帮我隐藏」还是「以后再说」），后面几条都不该推翻它。
        if hasSeenWelcome { return .skipAndMarkSeen }

        // 按不动的按钮不如不给。沙箱是永久属性，直接销掉这台机器上的引导。
        guard canWriteDockPreferences else { return .skipAndMarkSeen }

        guard let dockAutohideEnabled else {
            // CFPreferences 偶发读不到。**别在这里标记已看过**——那会因为一次瞬时故障
            // 永久吞掉引导；下次启动再读一遍就是了，代价只是每次启动一次静默的异步读。
            return .skipWithoutMarking
        }

        // 已经是自动隐藏了，引导没有意义。顺手标记，免得用户哪天把 Dock 改回常驻时
        // 被一个「首次运行引导」突然拦住——那时他显然是故意要 Dock 回来的。
        if dockAutohideEnabled { return .skipAndMarkSeen }

        return .present
    }
}
