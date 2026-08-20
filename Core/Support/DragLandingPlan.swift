import CoreGraphics
import Foundation

/// 松手后浮动副本「飞回卡槽」的一次飞行。坐标都在**载体面板内**（左上原点、y 向下），
/// 因为载体是唯一会画它的地方。
struct DragLandingFlight: Equatable {
    let from: CGPoint
    let to: CGPoint
    let fromScale: CGFloat
    let toScale: CGFloat
    /// **这一次**飞多久。按距离算出来的，不是全局常量——见 `DragLandingPlan.duration(travel:)`。
    let duration: TimeInterval
    /// **这一次**用哪条曲线。同样按距离算（近缓远快），见 `DragLandingPlan.curve(travel:)`。
    let curve: DragLandingCurve
    /// 落地时的透明度：飞回卡槽 = 1；吸进胶囊 = 0（`DragLandingPlan.stashFlight`）。
    var toOpacity: Float = 1
}

/// 一条定时长的三次贝塞尔曲线（`CAMediaTimingFunction(controlPoints:)` 的四个数）。
struct DragLandingCurve: Equatable {
    let c0x: Double
    let c0y: Double
    let c1x: Double
    let c1y: Double

    /// 归一化时间 `t`（0…1）处的进度（0…1）：解 x(s) = t 再取 y(s)，和 CA / CSS 的 timing function
    /// 同一套算法。**控制器靠它算「飞行中的图标此刻在哪」**（`DragController.landingPose`）——
    /// `CALayer.presentation()` 比屏幕上实际画的落后约两帧，飞行起步段每帧十几 pt，
    /// 按它冻结会往回跳（2026-08-19 抽帧实测 15pt）；按同一条曲线、同一个时钟自己算才和渲染服务器对得上。
    func progress(at t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        var lo = 0.0, hi = 1.0, s = t
        for _ in 0..<48 {
            let x = Self.bezier(s, c0x, c1x)
            if abs(x - t) < 1e-7 { break }
            if x < t { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return Self.bezier(s, c0y, c1y)
    }

    private static func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
    }
}

/// 归位飞行的纯判定（owner 2026-08-18：「放手一瞬间图标归位的动画，做的不如原生 dock 从容优雅」）。
///
/// **改造前根本没有这个阶段**：`endDrag()` 里 `orderOut` 载体和 `draggingPayload = nil` 发生在同一帧，
/// 于是手里的浮动副本瞬间消失、条上那张卡瞬间从 opacity 0 变 1。光标到卡槽中心那段距离、
/// 还有 1.05 → 1.0 的尺寸差，全是**跳**过去的。原生 Dock 是让图标飞回卡槽。
///
/// 判定单独抽出来的理由和 `DragConversionPlan` / `StripHoverResolution` 一样：
/// 坐标换算最容易写岔（屏幕是左下原点、载体面板是左上原点），单测能钉死它。
enum DragLandingPlan {
    /// 飞行时长的两端。**时长按距离取，不是定值**（owner 2026-08-18：「没有原生的动画从容优雅」）。
    ///
    /// 定长的毛病在于：同一个 0.26 秒，20pt 的小归位显得急促、200pt 的长途显得赶。
    /// 原生那种「从容」很大程度来自距离越远走得越久。开根号收敛而不是线性：
    /// 近距离不至于短到看不见，远距离也不会拖沓。
    /// owner 逐轮定的：0.16/0.34 → 0.22/0.46 → 0.30/0.62 → 0.60/0.90（2026-08-18）
    /// → **0.32/0.50**（2026-08-19：「比原生的要慢挺多」）。
    ///
    /// **这不是回归，是前提变了。** 0.60/0.90 是在「载体还是半透明 SwiftUI 副本、曲线还是长途那条
    /// 快出缓停」的时候定的：那条曲线 17% 的时间就走完 61%，后面大半段肉眼几乎看不出在动，
    /// 所以 0.6 秒当时读起来是「从容」。2026-08-19 把短途曲线换成标准 ease-out 之后，同样的时长
    /// 「看得见的位移」变长了一大截，于是显得拖沓。曲线不动、只把时长按比例收回来。
    ///
    /// 调这两个数不用重装：`DOCK_DRAG_FLIGHT_MS=320,500`（见 `DragLandingSwitches.flightDurations`）。
    static let minimumDuration: TimeInterval = DragLandingSwitches.flightDurations?.minimum ?? 0.32
    static let maximumFlightDuration: TimeInterval = DragLandingSwitches.flightDurations?.maximum ?? 0.50
    /// 到这个位移就用满时长；再远也不加了。
    static let referenceTravel: CGFloat = 300

    /// **位移小于这个数就不飞，直接落定。** 只挡亚像素——落点已按设备像素取整
    /// （`DragCarrierGeometry.pixelAligned`），差不到 1pt 的飞行什么都看不见。
    ///
    /// 原来是 12pt，为「点击时手抖」设的：起拖门槛 8pt，手一抖就是一次微小拖动，而那时
    /// 载体还是半透明的 SwiftUI 副本，0.6s 原地晃回去会留一个可见的影子（owner 2026-08-18
    /// 「点击图标隔壁的图标会有上下的重影」）。载体改位图之后这个理由不存在了：副本不透明、
    /// 逐像素等于卡槽、落地后不重判悬停——飞回去只会比跳过去更好。反过来 12pt 恰恰是条内
    /// 重排最常见的落点（图标间距 42pt，松手时卡槽中心和载体差 0～21pt，一半以上在 12pt
    /// 以内），这些全在瞬间跳到位，正是 owner 2026-08-19 报的「短距离偏快」的一半。
    /// 现在手抖 8–12pt 也照飞，和原生 Dock 一样是滑回去，不是跳回去。
    static let minimumTravel: CGFloat = 1

    /// 兜底/基准时长（纠偏闸与单测用的名义值）。真正每次飞多久看 `duration(travel:)`。
    static let duration: TimeInterval = 0.26

    static func duration(travel: CGFloat) -> TimeInterval {
        minimumDuration + (maximumFlightDuration - minimumDuration) * travelFactor(travel)
    }

    /// 距离 → 0…1 的进度数：`referenceTravel` 处到 1，再远不加；开根号（近距离更慷慨）。
    /// **时长和曲线都用它**，一个数决定「这一次飞行有多长途」。
    static func travelFactor(_ travel: CGFloat) -> Double {
        min(1, max(0, Double(travel) / Double(referenceTravel))).squareRoot()
    }

    /// **曲线也按距离取：近缓、远快，连续过渡**（owner 2026-08-19：「短距离的飞行动画偏快」）。
    ///
    /// 时长本来就有 0.60s 打底，短途看起来还是快，是因为长途那条曲线（`curve`）太靠前：
    /// 17% 的时间走完 61%，31% 的时间走完 84%。300pt 的长途剩下 48pt 在后半段慢慢收，
    /// 读起来是「从容」；30pt 的短途肉眼可见的位移 0.15–0.2s 就走完了，剩下几个 pt 在
    /// 0.4s 里蹭——等于没有动画。所以短途换一条更缓的 ease-out：`shortCurve` 是 Penner 的
    /// easeOutQuad，30% 时间走 53%、50% 时间走 77%，0.6s 里前 0.4s 都在**可见地**滑。
    /// 两端之间按 `travelFactor` 对四个控制点线性插值——不用阈值切换，阈值两侧的两次
    /// 飞行会长得不一样。`referenceTravel` 及以上就是原来那条，owner 认可过的长途一点不变。
    static func curve(travel: CGFloat) -> DragLandingCurve {
        let f = travelFactor(travel)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
        return DragLandingCurve(c0x: mix(shortCurve.c0x, curve.c0x),
                                c0y: mix(shortCurve.c0y, curve.c0y),
                                c1x: mix(shortCurve.c1x, curve.c1x),
                                c1y: mix(shortCurve.c1y, curve.c1y))
    }

    /// 短途那一端的曲线（Penner easeOutQuad）。仍是快出缓停、仍在 `duration` 处准时结束。
    static let shortCurve = DragLandingCurve(c0x: 0.25, c0y: 0.46, c1x: 0.45, c1y: 0.94)

    /// `DOCK_DRAG_FLIGHT_MS` 的解析（纯函数，单测覆盖）。`"320,500"` → 0.32s / 0.50s。
    /// 不合法一律 `nil`：**半套生效比不生效更糟**——只认下界的话，曲线两端会反过来。
    static func parseFlightDurations(_ raw: String) -> (minimum: TimeInterval, maximum: TimeInterval)? {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let lo = parts[0], let hi = parts[1],
              lo > 0, hi > 0, lo <= hi else { return nil }
        return (lo / 1000, hi / 1000)
    }

    /// 载体到点之后再等一小会儿才真的收掉，给最后一帧提交留余量。
    static let settleMargin: TimeInterval = 0.03

    /// 中途纠偏会把收载体的时刻往后推（每纠一次就重新飞一段）。这是整段飞行的硬上限，
    /// 免得卡槽一直在动时载体挂着不放。正常情况根本用不到：松手时不重排，卡槽是静止的。
    static let maximumDuration: TimeInterval = 2.00

    /// 离飞行上限不足一整段时长时就别再纠偏了：那时候重新起飞一段必然会被上限截断，
    /// 反而制造出要治的那一下跳。
    static func allowsRetarget(remainingBeforeDeadline: TimeInterval,
                               flightDuration: TimeInterval = duration) -> Bool {
        remainingBeforeDeadline > flightDuration + settleMargin
    }

    /// **必须是定时长曲线，不能用 spring**（owner 2026-08-18 一眼看出「归位还是会抖」）。
    ///
    /// `spring(response: 0.26)` 在 0.26 秒时**根本没停**——response 只是它的固有周期，
    /// 真正静止要 2~3 倍时长。而收载体的计时器是按 `duration` 掐的，于是图标飞到一半被
    /// 硬切掉，剩下那段距离由「载体消失、条上卡显形」一步跳完，看着就是抖一下。
    ///
    /// 控制点取仓库里既有的那条「快出缓停」（`PopoverAnimation.curve()` 同款）：
    /// 起步快、收尾缓，正是原生 Dock 归位的读感，而且**在 `duration` 处确实结束**。
    /// 这是**长途**那一端；实际每次飞行用 `curve(travel:)` 按距离在它和 `shortCurve` 之间取。
    static let curve = DragLandingCurve(c0x: 0.2, c0y: 0.9, c1x: 0.3, c1y: 1.0)

    /// **抬起**：起拖时载体从卡槽原位滑到指针下用多久。
    ///
    /// 起拖门槛是 `DragGesture(minimumDistance: 8)`，所以载体一出现就直接摆在指针下的话，
    /// 图标是**跳**过去的——owner 2026-08-18 报的「选中图标拖动的第一帧有卡顿」有一半是这个跳。
    /// 位移动画用叠加式（`isAdditive`），抬起途中鼠标继续动也不打架：model 值每帧照改，
    /// 叠加的那段偏移自己衰减到 0。
    static let liftDuration: TimeInterval = 0.12

    /// 藏卡之后、抬起之前，载体在卡槽原位按卡槽姿态压着不动的那一小段（两个显示帧）。
    /// 载体的改动是显式事务、当场提交；卡的「藏」要等 SwiftUI/AppKit 的 display 周期。
    /// 主线程一忙两者能差一两帧，载体这时若已离开卡槽就是双影——所以让它先等一等，
    /// 重叠那两帧两者逐像素相同（`DragController.armCarrier`）。
    static let liftDelay: TimeInterval = 0.034

    /// **没有预备候选**时，载体在卡槽原位压着卡等多久再「藏卡 + 抬起」。
    ///
    /// 位图第一帧比 SwiftUI 藏卡晚一个显示帧（纹理上传，实测）。第一版等的是「一轮 run loop」，
    /// 真机鼠标 1–8ms 一个事件，下一轮往往还在同一帧里 → 一帧空档 = 「有几率消失」。
    /// 按时间等两个显示帧（60Hz 下 33ms）才和显示对得上；ProMotion 120Hz 下等于四帧，
    /// 多等只是多重叠几帧，看不出来。**常规路径不走这里**：按下即预备（`prepareCandidate`）
    /// 之后纹理早就上传了，起拖当轮就放行。
    static let pickUpSettle: TimeInterval = 0.034

    /// 按下预备时载体图层用的透明度。**不是 0**：全透明的图层会被渲染树剔除、纹理不上传，
    /// 预热就白做了；0.01 肉眼不可见，但真的会走一遍上传。
    static let candidateOpacity: Float = 0.01

    /// 飞行途中重抓之后，松手前指针挪动不到这个数 = **点击**（唤醒 / 最小化那张卡），挪过 = 拖动。
    /// 和 chip 起拖门槛 `DragGesture(minimumDistance: 8)` 同一个数。
    static let regrabClickSlop: CGFloat = 8

    /// 落地后悬停按住期的上限。正常情况指针一动就结束；这是「用户松手后一动不动」时的兜底，
    /// 免得那 60Hz 的轮询一直挂着。
    static let hoverHoldMaximum: TimeInterval = 3.0

    /// 拖动途中状态切换（进/出投放区、文件夹拖出条外）的时长。
    static let stateChangeDuration: TimeInterval = 0.12

    /// 文件夹 chip 拖离任务条可见范围时的样子：淡下去 + 略放大，给「松手即移除固定」
    /// 一个实时反馈（owner 2026-07-06）。原来写死在载体视图里，载体改位图后搬到这儿。
    static let folderRemovalScale: CGFloat = 1.1
    static let folderRemovalOpacity: Float = 0.35

    /// 拎在手里时的放大倍数（`DragCarrierView` 的常驻状态）。
    /// **1.0，不放大**（2026-08-19，原来是 1.05）：原生 Dock 和 BestDock 拎起来都不放大
    ///（BestDock 的预览窗口就叫 `dragPreviewLockedSize`）；不缩放 = 位图全程不重采样，
    /// 从起拖到落地和条上那张卡一样清晰，落地最后一帧也就没有「突然变清晰」。
    static let carriedScale: CGFloat = 1.0
    /// 悬在投放区（胶囊 / 任务条）时缩到的倍数。
    static let dropZoneScale: CGFloat = 0.82
    /// 落地即与条上那张卡同尺寸。
    static let landedScale: CGFloat = 1.0

    /// **松在胶囊上收纳 = 吸进胶囊**（owner 2026-08-19 截图：收纳后图标往任务条那头飘一段再消失）。
    /// 收纳一提交，条上那格就没了；飞回一个已经不存在的位置只会凭空消失。改成飞向胶囊中心、
    /// 缩到 `stashScale`、淡到 0。时长定值：这不是「回到原位」的从容归位，是「被吸进去」。
    static let stashScale: CGFloat = 0.3
    static let stashDuration: TimeInterval = 0.35

    /// 吸进胶囊的飞行。`targetScreenRect` = 胶囊可视帧；`nil` = 不知道胶囊在哪 → 不飞（瞬时收尾）。
    static func stashFlight(from: CGPoint,
                            fromScale: CGFloat,
                            targetScreenRect: CGRect?,
                            carrierScreenFrame: CGRect) -> DragLandingFlight? {
        guard let rect = targetScreenRect,
              rect.width > 0, rect.height > 0,
              carrierScreenFrame.width > 0, carrierScreenFrame.height > 0 else { return nil }
        let to = CGPoint(x: rect.midX - carrierScreenFrame.minX,
                         y: carrierScreenFrame.maxY - rect.midY)
        return DragLandingFlight(from: from, to: to,
                                 fromScale: fromScale, toScale: stashScale,
                                 duration: stashDuration, curve: shortCurve, toOpacity: 0)
    }

    /// 屏幕矩形（左下原点）→ 载体面板内的中心点（左上原点）。
    ///
    /// - Parameter anchorScreenRect: 这一项最终会落在屏幕上的哪一格。`nil` = 不知道 → 不飞，
    ///   走改造前的瞬时收尾（零风险的退路）。转正进任务条那一支就是这种：松手会解冻任务条宽度、
    ///   整条重新居中，落点在飞行途中还会漂。
    static func flight(from: CGPoint,
                       fromScale: CGFloat,
                       anchorScreenRect: CGRect?,
                       carrierScreenFrame: CGRect) -> DragLandingFlight? {
        guard let rect = anchorScreenRect,
              rect.width > 0, rect.height > 0,
              carrierScreenFrame.width > 0, carrierScreenFrame.height > 0 else { return nil }
        let to = CGPoint(x: rect.midX - carrierScreenFrame.minX,
                         y: carrierScreenFrame.maxY - rect.midY)
        // 亚像素 → 不飞（理由见 `minimumTravel`）。
        let travel = hypot(to.x - from.x, to.y - from.y)
        guard travel >= minimumTravel else { return nil }
        return DragLandingFlight(from: from, to: to,
                                 fromScale: fromScale, toScale: landedScale,
                                 duration: duration(travel: travel),
                                 curve: curve(travel: travel))
    }
}

/// 归位飞行的开关。新手感一律带退路（同 `ChipPressSwitches`）：万一在实机上和重排、
/// 跨面板收纳打架，owner 能立刻退回瞬时收尾，不用等重新打包。
enum DragLandingSwitches {
    static let enabled = ProcessInfo.processInfo.environment["DOCK_DRAG_LANDING"] != "0"

    /// 归位飞行时长的现场调速旋钮：`DOCK_DRAG_FLIGHT_MS=<最短>,<最长>`（毫秒，例 `320,500`）。
    ///
    /// 存在的理由很实在：这两个数 owner 已经来回定过五轮，每轮都要「改常量 → 重新构建 → 重装 →
    /// 再体感一次」，一轮两分多钟。有了它改环境变量重启就行，秒级收敛（同 `DOCK_PANEL_MATERIAL`
    /// 的先例）。**默认值仍写在 `DragLandingPlan` 里**，不设这个变量时行为与写死常量完全一致。
    ///
    /// 解析不合法（缺一半、非数、非正、最短 > 最长）一律当没设，绝不半套生效。
    static let flightDurations: (minimum: TimeInterval, maximum: TimeInterval)? =
        ProcessInfo.processInfo.environment["DOCK_DRAG_FLIGHT_MS"]
            .flatMap(DragLandingPlan.parseFlightDurations)
}
