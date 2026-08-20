import CoreGraphics

/// 指针位置 → 该由哪张 chip 拥有悬停。
///
/// **为什么任务条不再让每张卡各自挂 `.onHover`。** 那样等于每张卡各占一块 `NSTrackingArea`，
/// 悬停靠系统成对派发的「进入 / 离开」。指针快起来之后 macOS 会合并鼠标移动事件，中间那些卡的
/// 进入/离开整对丢掉——卡片根本不知道指针来过。实测（2026-08-17，固定 120Hz 合成事件横扫
/// 一排 10 张卡）：800pt/s 命中 9 张、1600pt/s 命中 6 张、2400pt/s 只剩 3 张，而且同一速度
/// 重跑会从 9 掉到 5。同一轮对照实验里把液态玻璃关掉（摆一次气泡的成本差一倍）命中数没有
/// 任何规律性变化，所以**瓶颈不在渲染，在事件**。owner 报的「原生快速划过气泡照样跟得上，
/// 钨极不行」就是这个。
///
/// 顺带同一个根因还解释了「边界不固定」：两张卡的命中矩形之间隔着 `chipSpacing` 的死区，
/// 必须**完全走进**下一张卡才换手，于是切换点带方向——向右比几何中点偏右、向左偏左，
/// 实测迟滞 3.5pt（owner 2026-08-17）。
///
/// **原生 Dock 不是这么做的**：整条是一块，每个鼠标事件都按位置反查落在哪个磁贴上。
/// 这个类型就是那个反查。纯函数，边界只由几何决定，与来向无关；调用它的那块跟踪区盖住
/// 整条任务条，所以指针每动一次都会重算，不依赖成对事件。
///
/// 注意这**不是** AGENTS《Menus, Panels, And Screens》禁掉的常驻 `.mouseMoved` 全局监视器：
/// 那条禁的是 `NSEvent.addGlobalMonitorForEvents`（事件 tap，全系统鼠标事件先过我们进程，
/// 我们自己弹菜单时会把它拖慢 100ms）。这里是**我们自己窗口内**的普通跟踪区，性质不同。
enum StripHoverResolution {
    /// 卡与卡之间的缝里，最多把命中区向外扩这么多（pt，未乘档位）。
    ///
    /// 取 2pt 的理由：卡间距本身就是 `ChipPillMetrics.chipSpacing`（2pt），两侧各扩 2pt
    /// 会在缝隙正中重叠，于是缝里没有死区、边界正好落在**两卡的中点**，且与来向无关。
    /// 而分区分隔线那道 9pt 宽的缝，两侧各扩 2 之后中间仍空着 5pt，所以悬停分隔线依然
    /// 什么都不弹（原生也是这样）；任务条两端的留白同理。
    static let defaultGapBridge: CGFloat = 2

    /// 归属判定。
    ///
    /// - Parameters:
    ///   - point: 指针，与 `frames` 同一坐标系（条内用 `"strip"` 空间）。
    ///   - frames: 参与判定的所有 chip 帧（四个区都收进来），键即 chip 身份。
    ///   - gapBridge: 缝隙桥接量，已乘过档位。
    /// - Returns: 命中的 chip 身份；落在分隔线宽缝 / 条两端留白 / 条外 → `nil`。
    ///
    /// 缝里的裁决按**到卡边的距离**取近，不是按到卡心的距离：宽窄不一的卡并排时，
    /// 按卡心会让窄卡多吃一块，按卡边才是那道缝的正中。
    static func chip(at point: CGPoint,
                     frames: [String: CGRect],
                     gapBridge: CGFloat = defaultGapBridge) -> String? {
        var best: (id: String, distance: CGFloat)?
        for (id, frame) in frames {
            guard frame.width > 0, frame.height > 0 else { continue }
            guard frame.insetBy(dx: -gapBridge, dy: 0).contains(point) else { continue }
            let distance = max(frame.minX - point.x, point.x - frame.maxX, 0)
            guard let current = best else {
                best = (id, distance)
                continue
            }
            // 并列时按 id 定序，免得字典遍历顺序让结果在两帧之间跳。
            if distance < current.distance || (distance == current.distance && id < current.id) {
                best = (id, distance)
            }
        }
        return best?.id
    }
}

/// chip 的悬停状态从哪来。**故意不给默认值**，理由同 `scale` / `hoverStyle`：
/// 漏传必须是编译错误。
enum ChipHoverInput: Equatable {
    /// 由外部算好的悬停状态。任务条走这条——整条一块跟踪区 + `StripHoverResolution`。
    case resolved(Bool)
    /// 视图自己挂 `.onHover` 跟踪。抽屉那块面板没有跟踪区，走这条。
    case selfTracked
}
