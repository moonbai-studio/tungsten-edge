import Foundation

/// 两条自动隐藏设置（系统 Dock + 钨极）的纯展示/去重决策（单测覆盖）。
///
/// 住在 `App/Composition` 而不是 `Core/Support`：它讲的是**菜单**怎么呈现（组标题的措辞、
/// 确认行什么时候浮出），属于应用层的表达约定，而不是 Core 那种与界面无关的判定。
/// 2026-08-03 删掉 `keyEquivalentPresentation` 之后它已经不带 AppKit 类型了，
/// 但归属理由不变——别为了"看起来更纯"再把它搬一次家。
@MainActor
enum AutoHideToggleMenuModel {
    /// 系统 Dock 这一组的分组标题（不可点）。两条滑块长得一模一样，没有标题分不清谁管谁。
    ///
    /// ⌥⌘D 以**纯文字**写进标题，不设 `keyEquivalent`：这一行本就不可点，设了会被菜单捕获，
    /// 也会让禁用行看起来能点。这个键归 macOS 持有、恒生效，我们只是告诉用户它在——
    /// 删掉显隐命令之后，它就是「把 Dock 临时叫回来」的一键入口。
    static let nativeDockSectionTitle = String(localized: "The Dock (⌥⌘D to show/hide)")

    /// 钨极这一组的分组标题（不可点），与上面那条**对称**。
    ///
    /// 两组从前不对称——系统 Dock 有帽子、钨极没有，整个菜单只有一顶帽子在上面，于是
    /// 「打开系统 Dock 设置…」和它下面的钨极命令看起来像一伙的（owner 2026-08-03 反馈）。
    /// 补上这顶帽子的同时，那条可点的显隐命令被删掉了：切常驻改为拖滑块或按 ⌥⇧⌘D。
    ///
    /// 快捷键同样只以**纯文字**写进标题、不设 `keyEquivalent`（理由同上）；
    /// 而且只在 Carbon 注册成功时才提，注册失败时按不出来，写上去就是骗人。
    static func edgeSectionTitle(isHotKeyRegistered: Bool) -> String {
        isHotKeyRegistered
            ? String(localized: "Tungsten Edge (⌥⇧⌘D to show/hide)")
            : String(localized: "Tungsten Edge")
    }

    /// 滑块档位的显示名。滑块本体与确认行必须共用这一份口径，
    /// 否则确认行说的档位和滑块上显示的不是一回事。
    static func delayDisplayName(sliderIndex index: Int) -> String {
        switch index {
        case 0:
            return String(localized: "Always Visible")
        case AppSettingsStore.sliderIndexMax:
            return String(localized: "Never Wake")
        default:
            return String(format: "%.1fs", AppSettingsStore.delayFromSliderIndex(index))
        }
    }

    /// 系统 Dock 的每次写入都以 `killall Dock` 收尾，屏幕必然闪一下——这一下消除不了
    /// （改 `autohide-delay` 在 macOS 上只有这条生效路径），只能让它发生在用户主动确认**之后**，
    /// 预期之中的闪不觉得怪。所以滑块不自动提交，草稿与已生效值不同时才浮出确认。
    ///
    /// 比**整数档位**而不是浮点值：滑块本来就只能停在档位上，比浮点会被表示误差咬到。
    static func shouldShowNativeApply(draft: Double, applied: Double) -> Bool {
        AppSettingsStore.sliderIndexFromDelay(draft) != AppSettingsStore.sliderIndexFromDelay(applied)
    }

    /// 标题带上目标档位是有意的：它同时在提醒「你拖到的这一档现在还没生效」。
    static func nativeApplyTitle(draft: Double) -> String {
        let name = delayDisplayName(sliderIndex: AppSettingsStore.sliderIndexFromDelay(draft))
        // 显式 %@ + String(format:)，不用 String(localized:) 的插值语法：后者的 key 由编译器
        // 按插值类型推导（String → %@），key 长什么样不在眼前，写错了要到运行时才发现。
        // 手写占位符则 key 就是这行字面量，可以被脚本逐条核对。
        return String(format: String(localized: "Apply “%@” (the Dock will restart)"), name)
    }

    /// autohide-delay 键不存在时系统 Dock 的实际默认延迟。
    static let systemDefaultAutohideDelay = 0.5

    /// 系统真值 → 本地镜像应有的档位值。
    static func storeDelay(systemEnabled: Bool, systemDelay: Double?) -> Double {
        guard systemEnabled else { return AppSettingsStore.neverHideDelay }
        let rawDelay = systemDelay ?? systemDefaultAutohideDelay
        // 系统开关已经明确为开；负 delay 只能视为外部自定义的极短延迟，
        // 不能穿透 snapDelay 被误解释成本 App 的「常驻」哨兵 -1。
        let enabledDelay = rawDelay.isFinite
            ? max(rawDelay, AppSettingsStore.finiteDelayMin)
            : AppSettingsStore.defaultNativeDockAutoHideDelay
        return AppSettingsStore.snapDelay(
            enabledDelay,
            fallbackForNonFinite: AppSettingsStore.defaultNativeDockAutoHideDelay
        )
    }

    /// 把系统实际状态回灌进本地镜像，让滑块、标题、点击方向从同一真值出发。
    /// 返回 nil = 已一致，无需改动（`setNativeDockAutoHideDelay` 自己也去重，
    /// 但这里先判一次能省掉一次无谓的 `@Published` 通知）。
    static func reconciledStoreDelay(
        systemEnabled: Bool,
        systemDelay: Double?,
        currentStoreDelay: Double
    ) -> Double? {
        let target = storeDelay(systemEnabled: systemEnabled, systemDelay: systemDelay)
        return currentStoreDelay == target ? nil : target
    }

    /// 写系统之后本地镜像该落什么值。四象限，**不能一律「失败就回 previous」**：
    /// 写成功但读不回来时回滚，会让 UI 显示得和已经生效的系统设置相反。
    ///
    /// |            | 系统可读     | 系统不可读   |
    /// |------------|--------------|--------------|
    /// | **写成功** | 按读到的值   | 保留 target  |
    /// | **写失败** | 按读到的值（可能是部分写入的结果） | 保留 previous |
    static func resolvedStoreDelay(
        writeSucceeded: Bool,
        systemState: NativeDockAutohideState?,
        target: Double,
        previous: Double
    ) -> Double {
        if let systemState {
            return storeDelay(systemEnabled: systemState.enabled, systemDelay: systemState.delay)
        }
        return writeSucceeded ? target : previous
    }

}
