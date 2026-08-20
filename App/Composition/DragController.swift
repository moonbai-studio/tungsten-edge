import AppKit
import Combine
import SwiftUI

// `DragSource` 定义在 Core/Support/DragConversionPlan.swift（纯决策层，测试 target 本地编译）。

/// 载体面板的容器。一块普通的透明 `NSView`，图层里挂着载体那张位图所在的 `CALayer`。
///
/// 不能拿 `NSHostingView` 直接当 `contentView`（AGENTS 那条护栏），而且载体从 2026-08-18 起
/// 压根不再是 SwiftUI——**非 flipped 视图**，所以子图层坐标是左下原点、y 向上，
/// 和屏幕坐标同向，换算只差一个平移（见 `DragCarrierGeometry`）。
private final class CarrierContainerView: NSView {
    /// **只在归位飞行期间**非 nil：返回图标此刻（presentation）在本视图坐标里的帧。
    /// 面板平时 `ignoresMouseEvents = true`，根本走不到 `hitTest`；飞行期指针压在图标上时
    /// 控制器才把面板切成接事件（`DragController.refreshLandingGrabState`），这里再按图标
    /// 当前帧守一道——点在图标外一律 `nil`。
    var grabRegion: (@MainActor () -> CGRect?)?
    /// 按在飞行中的图标上 → 从它此刻的位置接着拖（`DragController.regrabLanding`）。
    var onGrab: (@MainActor (CGPoint) -> Void)?

    /// 载体面板永远不是 key window，第一下按下也要收（同 `MenuActionButton` 的理由）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let region = grabRegion?(), region.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) { onGrab?(NSEvent.mouseLocation) }
}

/// 载体（飘浮副本）画成什么样。
enum DragVisualKind { case stripChip, drawerIcon, folderChip, keptAppIcon, messagingIcon }

/// 通用拖动载荷。任务条卡片有 `StripItem`；抽屉很多图标（无窗口运行项 / 未运行收纳项 / 纯固定项）
/// 只有 bundleID、没有 `StripItem`，故 `item` 可空，主键统一用 `bundleID`。`id` 给来源面板自己
/// 排序用（strip = chip 身份令牌 `item.id`，drawer = bundleID），免得来源面板从载荷里猜。
struct DragPayload {
    let source: DragSource
    let id: String          // strip = item.id（chip token）；drawer = bundleID
    let bundleID: String
    let item: StripItem?     // 仅任务条窗口卡有
    let visualKind: DragVisualKind
    /// 能否投到「另一面板」触发收纳/移回。strip = `canStash`；drawer = 真收纳项（`drawerStore.contains`）。
    /// 纯固定项 = false：只能抽屉内排序，拖到任务条不高亮、不动作（Codex 二审）。
    let canExternalDrop: Bool
}

/// 跨面板拖动的唯一权威（拖卡进抽屉 路线 C / 抽屉拖回任务条，2026-06-20→21）。
///
/// 对称两向：任务条卡拖到胶囊=收纳；抽屉图标拖到任务条=移回。整屏自绘载体 + local 监视器一套机制
/// 反向复用（机制探针 2026-06-20 已验证：mouse-down 起拖后隐式抓取使 local 监视器全程接事件含松手）。
/// 全部收在这里：载体面板生命周期、监视器、落点判定、幂等收尾。来源面板只 `beginDrag` + 读
/// `draggingPayload`（隐藏原位）/ `isOverDropZone`（停区内排序）。
@MainActor
final class DragController: ObservableObject {
    @Published private(set) var draggingPayload: DragPayload?
    @Published private(set) var isOverDropZone = false

    /// 拖动中的光标位置（屏幕坐标）。**刻意不是 `@Published`。**
    ///
    /// 实测 2026-08-18（`DOCK_HOVER_TRACE`）：它曾经是 `@Published`，而 `DockStripView`
    /// 用 `@EnvironmentObject` 订阅着本对象——于是**每动一下鼠标就把整条任务条打翻重算一次**，
    /// 一秒钟拖动量到 **46 次整条 body 重算**（每次都要重建整份投影：快照转卡、成员投影、顺序对账）。
    /// 主线程被这些占满，载体的位置更新就迟到，快速拖动时甚至丢帧——正是 owner 报的
    /// 「起拖有迟滞」「拖快了图标会短暂消失」。
    ///
    /// 现在改成：值本身是普通属性，变化通过 `pointerMoves` 广播。
    /// - 载体的**位置**根本不再经过 SwiftUI —— `update()` 直接设那张位图所在图层的 `position`
    ///   （见 `moveCarrier`）。
    /// - 需要**每帧跑副作用**的（条内重排、跨面板转换）→ 用 `.onReceive(pointerMoves)`：
    ///   闭包照跑，但不给视图建立依赖，只有副作用真的改了什么才会重画。
    private(set) var globalLocation: CGPoint = .zero
    private let pointerSubject = CurrentValueSubject<CGPoint, Never>(.zero)
    /// 飞行途中「点了一下」那张卡（重抓后松手没挪过 `regrabClickSlop`）。动作由拥有那张卡的面板分发
    ///（`DockStripView` / `DrawerView` 的 `.onReceive`）——控制器不知道每种卡点下去该干什么。
    let carrierClicks: AnyPublisher<DragPayload, Never>
    private let carrierClickSubject = PassthroughSubject<DragPayload, Never>()
    /// **存成 `let`，不要每次调用现 erase**：SwiftUI 的 `onReceive` 换了 publisher 实例就会重订阅，
    /// 而 `CurrentValueSubject` 一订阅就补发当前值，等于每次 body 都白跑一遍副作用。
    let pointerMoves: AnyPublisher<CGPoint, Never>

    private(set) var grabOffset: CGSize = .zero
    private(set) var carrierScreenFrame: CGRect = .zero

    // MARK: - 松手归位飞行

    /// 松手之后、载体真正消失之前的那 0.26 秒：浮动副本从光标飞回卡槽。
    /// 见 `DragLandingPlan`。`nil` = 没有飞行在进行（含被关掉、拿不到落点两种）。
    struct Landing: Equatable {
        /// 飞回卡槽（可纠偏、可重抓、可点击）／吸进胶囊（收纳：定点、定时长，都不可）。
        enum Kind { case returnToSlot, stash }
        /// 每次飞行一个新令牌：收载体的计时器与动画完成回调都按它认领，
        /// 连着两次拖动不会互相收尾。
        let token: Int
        let payload: DragPayload
        let kind: Kind
        /// **飞行途中可以改终点**（`var` 不是 `let`）。松手那一刻卡槽往往还在跑让位动画，
        /// 量到的是插值中的位置；等它落定再纠一次偏，图标才不会在最后一下跳过去。
        var flight: DragLandingFlight

        static func == (lhs: Landing, rhs: Landing) -> Bool {
            lhs.token == rhs.token && lhs.kind == rhs.kind && lhs.flight == rhs.flight
        }
    }
    @Published private(set) var landing: Landing?

    /// **视图判「哪一格要空着」一律用它。** 归位飞行期间原位必须继续空着，
    /// 否则卡先显形、载体还在飞 = 又是两个影子。
    ///
    /// 起拖那一头**不再有门控**：载体是一张位图，`beginDrag` 在同一轮 run loop 里同步把它
    /// 摆在卡槽原位、同尺寸、同像素地压在卡上，所以「卡什么时候藏」怎么都不会露出空档——
    /// 重叠一两帧看不出来。原来那套 `carrierReady` / `onAppear` 回报 / 50ms 兜底计时器
    /// 是在给两个渲染器之间的赛跑当裁判，随位图载体一起删掉了。
    var carriedPayload: DragPayload? { draggingPayload ?? landing?.payload }

    /// **视图判「哪一格要空着」用它，不要用 `carriedPayload`。** 起拖那一头要等 `carrierArmed`
    /// （理由见该属性）；落地那一头一清 `landing` 就该显形，所以两头不对称。
    var hiddenSlotPayload: DragPayload? {
        if draggingPayload != nil { return carrierArmed ? draggingPayload : nil }
        return landing?.payload
    }

    /// 载体已经飞到位、条上那张卡也显形了，但那张位图还要多留一轮 run loop 才撤
    /// （见 `finishLanding`）。这一轮里悬停仍然要压着。
    @Published private(set) var carrierRetiring = false

    /// **条上那格从哪一刻起真的空出来**，以及抬起动画从哪一刻开始。两件事绑在一起。
    ///
    /// 起拖时载体的位图是全新的 `CGImage`，第一帧要等一次纹理上传——实测它**总是**比
    /// SwiftUI 藏卡晚整整一个显示帧（2026-08-19，连续三次拖动录像逐帧比对：46 / 137 / 228 帧
    /// 各露一帧「卡槽已空、载体未上屏」，而且把面板改成常驻不 `orderOut` 也照旧，
    /// 所以不是 `orderFront` 的延迟）。
    ///
    /// 两条路，按有没有**预备好的候选**分（见 `prepareCandidate`）：
    /// - 按下那一刻已经把位图挂上图层、以肉眼不可见的透明度预热过纹理 → 起拖当轮直接放行：
    ///   点亮载体和藏卡在同一轮、同一个提交里，`liftCarrier` 也当轮就跑。
    /// - 没有候选（调用方没预备、或候选对不上）→ 先让载体在卡槽原位、同尺寸、同像素地出现，
    ///   **过两个显示帧**（`DragLandingPlan.pickUpSettle`）再「藏卡 + 抬起」。第一版推迟的是
    ///   「一轮 run loop」——合成拖拽每步 16ms、下一轮恰好落在下一帧，看不出问题；真机鼠标
    ///   1–8ms 就来一个事件，下一轮往往还在同一帧里，卡藏了、位图没上屏 = 一帧空档，
    ///   就是 owner 2026-08-19 报的「有几率消失」。推迟按时间不按轮次，才和显示帧对得上。
    /// 重叠一两帧无害，空档一帧就是可见的闪。
    @Published private(set) var carrierArmed = false

    /// 「手里正拎着东西」（含松手后的归位飞行与最后那一轮交叠）。**要一直 true 到载体真的没了**，
    /// 否则卡在交叠那一帧就已经是悬停态（安静档还要放大 1.10），和载体最后一帧差出一截。
    var isCarrying: Bool { carriedPayload != nil || carrierRetiring }

    /// 悬停判定该**原地冻结**的时段：载体已经压在卡槽原位、卡还没藏。
    ///
    /// 这几帧载体的姿态是按卡槽此刻的「悬停 × 按压」复合形态摆的（`DragCarrierGeometry.pickUpPose`），
    /// 卡要是这时候因为「开始拖了」被清掉悬停、开始 0.12s 的回落，两者就对不上了——
    /// 第一版正是这么露出「上下残影」的。所以起拖那一刻**什么都别动**：`hoveredEntryID` 保持原样。
    var hoverFrozen: Bool { draggingPayload != nil && !carrierArmed }

    /// **整条任务条都不判悬停**的时段：只在「手里真的拎着东西」时。
    ///
    /// 拖动途中指针扫过谁就给谁点亮、还弹名字气泡，本来就不对——原生 Dock 拖动时别的图标也不亮。
    ///
    /// **归位飞行期不在此列**（owner 2026-08-19 报「图标飞行时划到其他图标上没有悬停效果」）：
    /// 松手之后鼠标已经自由了，原生这时候划过别的图标照样出名字。飞行期改成只豁免**正在飞的
    /// 那一张**，见 `hoverExemptPayload`。
    var hoverSuppressed: Bool { draggingPayload != nil && carrierArmed }

    /// **单独豁免**的那一张卡：正在飞回去的 / 刚落定还没等到指针移动的。别的卡照常悬停。
    ///
    /// 两个理由都只针对这一张，与别的卡无关：
    /// - 飞行中它的卡槽是空的，这时候把悬停判给它，等它落地显形就已经是悬停态（安静档还要
    ///   放大 1.10），而载体最后一帧画的是**非悬停**态，交接那一帧就「啵」地跳一下；
    /// - 落地后指针必然压在它身上，卡刚以 1.0 停稳就重判悬停会当场往上长一截——owner
    ///   2026-08-19 报的「落位抖动」。AppKit 自己对拖放结束后的悬停也是等鼠标动了才发
    ///   mouseEntered（按住期由 `hoverHoldPayload` 管，指针一动就解除）。
    ///
    /// 撤载体那一轮（卡已显形、位图还没撤）不用单独处理：`finishLanding` 与 `teardown` 的不飞分支
    /// 都在 `retireCarrierAfterHandoff()` **之前**先 `beginHoverHold(for:)`，那一轮由 hold 覆盖。
    var hoverExemptPayload: DragPayload? { landing?.payload ?? hoverHoldPayload }

    /// 悬停闸的组合值。视图用它做重判触发——光看 `hoverSuppressed` 的话，
    /// 「豁免对象换人了」不会触发重判（飞行结束那一刻正是换人）。
    var hoverGate: HoverGate {
        HoverGate(suppressed: hoverSuppressed, exemptID: hoverExemptPayload?.id,
                  exemptSource: hoverExemptPayload?.source)
    }
    struct HoverGate: Equatable {
        let suppressed: Bool
        let exemptID: String?
        let exemptSource: DragSource?
    }

    /// 刚落定、指针还没动过的那张卡。非空期间悬停一律压着；指针一动（或 3 秒兜底）就清。
    /// 抽屉侧拿它压住 `LauncherChip` 的悬停反馈，任务条侧走 `hoverSuppressed`。
    @Published private(set) var hoverHoldPayload: DragPayload?
    private var hoverHoldTimer: Timer?
    private var hoverHoldOrigin: CGPoint = .zero
    private var hoverHoldStartedAt: CFTimeInterval = 0

    /// 拎在手里时的缩放。载体和飞行起点共用这一个表达式——分开写过就会漂。
    var carriedScale: CGFloat {
        isOverDropZone && !isConvertedToStrip ? DragLandingPlan.dropZoneScale : DragLandingPlan.carriedScale
    }

    /// 载体这一刻该有的缩放。文件夹 chip 拖出任务条可见范围时再叠一档放大
    /// （`.folder` 永远 `canExternalDrop == false`，`carriedScale` 那支恒为 1.05，两者不冲突）。
    private var carrierVisualScale: CGFloat {
        guard draggingPayload?.source == .folder, folderDragZone == .outsideStrip else { return carriedScale }
        return carriedScale * DragLandingPlan.folderRemovalScale
    }

    /// 载体这一刻该有的透明度。只有「文件夹 chip 拖出任务条可见范围」会淡下去。
    private var carrierVisualOpacity: Float {
        draggingPayload?.source == .folder && folderDragZone == .outsideStrip
            ? DragLandingPlan.folderRemovalOpacity : 1
    }

    /// 落点锚点（屏幕坐标）。**两个视图各写各的、每次光标更新都写**，带 owner 标签：
    /// 任务条侧管 `.strip` / `.messaging` 载荷，抽屉侧管 `.drawer` 载荷。
    /// 不owner 标签的话，抽屉图标转正进任务条之后，抽屉那边写下的旧锚点会留着，
    /// 图标就会往已经关掉的抽屉里飞。
    enum LandingAnchorOwner { case strip, drawer }
    private var landingAnchor: (owner: LandingAnchorOwner, rect: CGRect)?
    private var landingTimer: Timer?
    /// 每次（重新）发出飞行动画 +1。CA 的完成回调在动画被**替换**时也会触发，
    /// 光靠 `landing.token` 认不出来（纠偏不换令牌），所以另记一个代次。
    private var landingAnimation = 0
    private var dragBeganAt: CFTimeInterval = 0
    private var landingToken = 0
    /// 纠偏可以把飞行往后推，但不能无限推。飞行一开始就定死这个上限。
    private var landingDeadline: CFTimeInterval = 0

    func setLandingAnchor(_ rect: CGRect?, owner: LandingAnchorOwner) {
        if let rect {
            landingAnchor = (owner, rect)
        } else if landingAnchor?.owner == owner {
            landingAnchor = nil
        }
        retargetLandingIfNeeded()
    }

    /// 飞行途中的**中途纠偏**。
    ///
    /// 松手那一刻卡槽多半还在跑让位动画（条内 0.28s 的 spring / 抽屉 0.22s 的网格重排），
    /// `GeometryReader` 报的是插值中的中间值——照它飞过去，等载体撤掉时卡已经落到别处，
    /// 差出来的那十几 pt 就是 owner 看到的「归位还在抖」。锚点在飞行期间会继续更新
    /// （视图那边改成按帧变化上报，见 `updateLandingAnchor`），这里跟着改终点，
    /// SwiftUI 会从当前位置平滑地接上去。
    ///
    /// 门槛 0.5pt：亚像素抖动不值得为它重发一次（`DockStripView` 观察着本对象，
    /// 每发一次都要重算整条 body）。
    private func retargetLandingIfNeeded() {
        // 吸进胶囊的飞行不纠偏：收纳后一两帧里任务条还会把那格的旧帧报上来，跟着它就又被拉回条上。
        guard var current = landing, current.kind == .returnToSlot,
              DragLandingPlan.allowsRetarget(
                remainingBeforeDeadline: landingDeadline - CACurrentMediaTime(),
                flightDuration: current.flight.duration),
              let rect = landingAnchor?.rect,
              let updated = DragLandingPlan.flight(from: current.flight.from,
                                                   fromScale: current.flight.fromScale,
                                                   anchorScreenRect: rect,
                                                   carrierScreenFrame: carrierScreenFrame),
              hypot(updated.to.x - current.flight.to.x, updated.to.y - current.flight.to.y) > 0.5
        else { return }
        current.flight = updated
        landing = current
        // 重发同一组动画（位移 / 缩放 / 阴影在一个事务里），CA 会从当前插值位置平滑接到新终点。
        // 改了终点就等于重新起飞一段，**兜底计时器必须跟着往后推**——否则载体在半路被撤掉，
        // 那正是要治的那一下跳。上限 `landingDeadline` 保证卡槽万一一直动也不会挂着不放。
        flyCarrier(along: updated, token: current.token)
    }

    /// 飞到终点。**先让条上那张卡显形，晚一轮 run loop 再撤载体**——两头都是「先新后旧」：
    /// 卡已经在屏上了，载体最后一帧和它像素相同、位置相同，交叠那一帧不可见；
    /// 反过来先撤载体就必然露出一帧空位（owner 2026-08-18 报的「落位重影」的另一面）。幂等。
    func finishLanding(token: Int) {
        guard let current = landing, current.token == token else { return }
        landingTimer?.invalidate(); landingTimer = nil
        landingAnimation &+= 1
        endLandingGrabWatch()
        flightTimeline = nil
        recordLandingDelta()
        beginHoverHold(for: current.payload)   // 先按住悬停，再让卡显形——顺序反了就抖一下
        landing = nil            // ← 条 / 抽屉在本轮 SwiftUI 提交里让卡显形
        retireCarrierAfterHandoff()
    }

    /// 晚一轮 run loop 收载体，并在这一轮里继续压着悬停（`carrierRetiring`）。
    private func retireCarrierAfterHandoff() {
        carrierRetiring = true
        let generation = carrierGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 代次对不上 = 下一轮已经开始了新拖动，载体归它管；但这个标志是本轮挂的，
            // 得由本轮清掉——留着就把新拖动的悬停一起压死（第一版靠 `beginDrag` 里的
            // `abortLanding()` 顺手清了才没暴露）。
            defer { self.carrierRetiring = false }
            guard self.carrierGeneration == generation else { return }
            self.retireCarrier()
        }
    }

    // MARK: - 归位飞行可打断（owner 2026-08-19：「原生和 bestdock 都能打断，现在有点难选中」）

    /// 飞行途中按住图标 → 从它**此刻**的位置接着拖，卡槽全程空着不闪。
    ///
    /// 载体是另一块面板上的位图，平时不吃事件；不做这个的话，按在飞行中的图标上事件穿到底下：
    /// 要么是它空着的卡槽（`beginDrag` → `abortLanding` → 图标从半空跳回卡槽再抬起），
    /// 要么是邻居（拎起邻居），要么是桌面。原生 Dock 飞的就是图标本身，按哪儿都是它。
    ///
    /// - Parameter requireHit: `true` = 点必须落在图标当前帧内（载体面板自己收到的按下）；
    ///   `false` = 同一张卡的卡槽被按住（SwiftUI 手势起拖了同一载荷），图标离指针再远也接着走，
    ///   抓取偏移就是它此刻和指针的相对位置——和原生一样，图标不会跳到指针下。
    @discardableResult
    func regrabLanding(at screenPoint: CGPoint, requireHit: Bool = true) -> Bool {
        guard let current = landing, current.kind == .returnToSlot,
              let layer = carrierLayer, carrierScreenFrame.width > 0 else { return false }
        if requireHit {
            guard let iconFrame = landingIconScreenFrame(), iconFrame.contains(screenPoint) else { return false }
        }
        // 冻结在**时间线算出的**此刻位置（不是 `presentation()`，理由见 `FlightTimeline`）。
        let elapsedMs = flightTimeline.map { (CACurrentMediaTime() - $0.beganAt) * 1000 } ?? 0
        // 略往前估（`grabFreezeLead`）：两次抽帧实测冻结点比屏幕最后一帧落后 2–3pt（约 0.25 帧）。
        // 往前多走一两 pt 看着是「又动了一下停住」，往回退才是肉眼可见的抖。
        let pose = landingPose(at: CACurrentMediaTime() + Self.grabFreezeLead)
            ?? LayerPose(position: layer.position, scale: Self.scale(of: layer.transform))
        landingTimer?.invalidate(); landingTimer = nil
        landingAnimation &+= 1          // CA 完成回调按代次丢弃
        endLandingGrabWatch()
        Self.instantly {
            layer.removeAllAnimations()
            layer.position = self.alignedCenter(pose.position, on: layer)
            layer.transform = Self.scaleTransform(pose.scale)
            layer.opacity = 1
        }
        grabOffset = DragCarrierGeometry.grabOffset(pointer: screenPoint, carriedCenter: pose.position,
                                                    panelFrame: carrierScreenFrame)
        // 点 / 拖二选一要等松手才知道：记下按下点；按下期间载体微缩（同 chip 的按压反馈），
        // 挪过 `regrabClickSlop` 就回到拎着的样子（`update`），没挪就是点击（`endDrag`）。
        regrabOrigin = screenPoint
        regrabPressed = ChipPressSwitches.pressDownEnabled
        // **同一个同步块里切状态**：`hiddenSlotPayload` 先后两个分支指向同一张卡，卡槽连续空着。
        let payload = current.payload
        draggingPayload = payload
        carrierArmed = true
        carrierLifted = true
        landing = nil
        carrierRetiring = false
        endHoverHold()
        dragBeganAt = CACurrentMediaTime()
        globalLocation = screenPoint
        pointerSubject.send(screenPoint)
        refreshDropZone()
        installMonitors()
        startPoll()
        flightTimeline = nil
        applyCarrierVisualState(animated: true)   // 按住期缩放 0.93
        HoverTrace.dragHandoff("regrab", msSinceBegin: elapsedMs)
        return true
    }
    /// 重抓那一下按在哪、还在不在「按住没挪」的状态。
    private var regrabOrigin: CGPoint?
    private var regrabPressed = false

    /// 飞行中的图标的命中区（载体面板坐标）：**此刻的帧 ∪ 两帧前的帧**；不在飞行就 nil。
    ///
    /// 人是照着一两帧前看到的位置按的，按下事件到我们手里又有 10–20ms；飞行起步段一帧十几 pt，
    /// 只认此刻的帧会正好擦边错过（2026-08-19 合成实测：松手 46ms 后原点按下，图标已走 28pt、
    /// 半高 27pt，差 1pt 没命中）。按速度自适应：飞得快时多留一段尾巴，飞到慢的尾段几乎不扩。
    private func landingIconPanelFrame() -> CGRect? {
        guard let layer = carrierLayer else { return nil }
        let now = CACurrentMediaTime()
        guard let current = landingPose(at: now), let trailing = landingPose(at: now - Self.grabTrail) else { return nil }
        func frame(_ pose: LayerPose) -> CGRect {
            let size = CGSize(width: layer.bounds.width * pose.scale, height: layer.bounds.height * pose.scale)
            return CGRect(x: pose.position.x - size.width / 2, y: pose.position.y - size.height / 2,
                          width: size.width, height: size.height)
        }
        return frame(current).union(frame(trailing))
    }
    /// 命中区往回追溯多久（约两个显示帧）。
    private static let grabTrail: CFTimeInterval = 0.034
    /// 重抓冻结点的前置量（约四分之一帧，理由见 `regrabLanding`）。
    private static let grabFreezeLead: CFTimeInterval = 0.005

    /// 同上，屏幕坐标。
    private func landingIconScreenFrame() -> CGRect? {
        guard carrierScreenFrame.width > 0, let frame = landingIconPanelFrame() else { return nil }
        return frame.offsetBy(dx: carrierScreenFrame.minX, dy: carrierScreenFrame.minY)
    }

    /// 飞行期 60Hz 看指针在不在图标上：在 → 载体面板接事件（按下就是重抓）；不在 → 照旧不吃事件。
    ///
    /// **为什么不能整段飞行都接事件**：透明面板 `ignoresMouseEvents = false` 时，透明区域的点击
    /// **不会**穿到下面的窗口（2026-08-19 spike 实测：`hitTest` 返回 nil 的区域点击被吞掉，
    /// 下面的窗口收不到）——那等于落地后 0.9s 内点别的图标全部失灵。所以只在指针压着图标
    /// 的那些帧接。轮询与落地悬停按住期同款（`.common`、指针一动就有结果，最长一段飞行）。
    private func beginLandingGrabWatch() {
        landingGrabTimer?.invalidate()
        refreshLandingGrabState()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                guard self.landing != nil else { timer.invalidate(); return }
                self.refreshLandingGrabState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        landingGrabTimer = timer
    }

    private func endLandingGrabWatch() {
        landingGrabTimer?.invalidate(); landingGrabTimer = nil
        setCarrierAcceptsMouse(false)
    }

    private func refreshLandingGrabState() {
        let inside = landingIconScreenFrame()?.contains(NSEvent.mouseLocation) == true
        setCarrierAcceptsMouse(inside)
    }

    /// 只有当前那一套面板可能接事件；其余永远不吃。写前比一下，别每帧都往 WindowServer 发。
    private func setCarrierAcceptsMouse(_ accepts: Bool) {
        for surface in surfaces {
            let ignores = !(accepts && surface.panel === carrierPanel)
            if surface.panel.ignoresMouseEvents != ignores { surface.panel.ignoresMouseEvents = ignores }
        }
    }
    private var landingGrabTimer: Timer?

    // MARK: - 落地后的悬停按住期

    /// 落定那一刻起按住悬停，直到指针真的动了（或 3 秒兜底）。
    ///
    /// 用 60Hz 轮询 `NSEvent.mouseLocation` 而不是事件监视器：本应用的面板都不是 key window，
    /// `.mouseMoved` 能不能送到本地监视器没有保证（任务条那块跟踪区就是因此改成轮询的，见
    /// `StripPointerTracker`），而全局 `.mouseMoved` 监视器是被 AGENTS 点名禁的常驻事件 tap。
    /// 轮询是瞬时的：指针一动就停，最长 3 秒。
    private func beginHoverHold(for payload: DragPayload) {
        hoverHoldTimer?.invalidate()
        hoverHoldPayload = payload
        hoverHoldOrigin = NSEvent.mouseLocation
        hoverHoldStartedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                // 控制器没了就把自己停掉：`repeats: true` 的计时器不会因为 self 释放而停。
                guard let self else { timer.invalidate(); return }
                guard self.hoverHoldPayload != nil else { timer.invalidate(); return }
                let now = NSEvent.mouseLocation
                let moved = hypot(now.x - self.hoverHoldOrigin.x, now.y - self.hoverHoldOrigin.y) > 0.5
                let expired = CACurrentMediaTime() - self.hoverHoldStartedAt > DragLandingPlan.hoverHoldMaximum
                if moved || expired { self.endHoverHold() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverHoldTimer = timer
    }

    private func endHoverHold() {
        hoverHoldTimer?.invalidate(); hoverHoldTimer = nil
        if hoverHoldPayload != nil { hoverHoldPayload = nil }
    }

    /// 立刻收掉载体位图与面板。**只在「卡已经显形」或「压根没有卡可显形」时调**。
    private func retireCarrier() {
        if let layer = carrierLayer {
            Self.instantly {
                layer.removeAllAnimations()
                layer.contents = nil
            }
        }
        carrierSnapshot = nil
        originSnapshot = nil
        // **面板常驻，不 orderOut。** 它全透明、不吃鼠标、比我们自己的面板高一级；每次拖动
        // 再 orderOut / orderFront 一趟，换来的只是「刚 order 上来的窗口内容晚几帧才上屏」
        // 这一类时序坑（实测 2026-08-19：同一份代码，常驻时 6/6 次起拖无空档、载体必现，
        // 反复 order 时有几次载体整段拖动都不上屏）。
    }

    /// 立刻结束飞行、不做交接（新拖动打断、异常取消、面板拆除）。
    /// 这些路径下卡槽可能压根不存在了，所以不延后收载体。
    func abortLanding() {
        landingTimer?.invalidate(); landingTimer = nil
        landingAnimation &+= 1
        endLandingGrabWatch()
        flightTimeline = nil
        carrierRetiring = false
        guard landing != nil else { return }
        landing = nil
        retireCarrier()
    }

    /// 胶囊高亮只在「任务条卡/消息 chip 正悬在收纳区」时亮；任务条移回高亮只在「抽屉图标正悬在任务条」时亮。
    var isOverStashZone: Bool {
        guard isOverDropZone, let s = draggingPayload?.source else { return false }
        return s == .strip || s == .messaging
    }
    var isOverUnstashZone: Bool { isOverDropZone && draggingPayload?.source == .drawer }

    /// 跨面板**临时转换**状态——显式"原始来源 + 回滚快照"，同一时刻至多一个转换在进行
    /// （Codex 评审 2026-07-11：不再叠布尔标志）。commit = `teardown()` 清状态不回滚；
    /// rollback = 各 revert 方法按快照还原；`cancelDrag()` 按当前 case 回滚后收尾。
    /// `@Published`：载体切换、任务条宽度冻结、成员监听豁免都要能驱动刷新。
    enum CrossPanelConversion {
        /// 任务条卡已临时收进抽屉。回滚 = drawer.remove + 还原载荷；kept 不变。
        case stripToDrawer(original: DragPayload)
        /// 抽屉图标已临时转正进任务条（unstash / keepPlacement）。回滚 = drawer.add。
        case drawerToStrip(bundleID: String)
        /// 消息区 chip 已临时收进抽屉。回滚 = drawer.remove + 还原 `.messaging` 载荷。
        case messagingToDrawer(original: DragPayload)
        /// 抽屉里运行中的消息应用已临时释放回消息区。回滚 = drawer.add + 还原 `.drawer` 载荷。
        case drawerToMessaging(original: DragPayload)
    }
    @Published private(set) var conversion: CrossPanelConversion?

    /// 兼容视图层现有调用点的投影（读 `conversion`，@Published 保证驱动刷新）。
    var convertedDrawerBundleID: String? {
        if case let .drawerToStrip(bid) = conversion { return bid }
        return nil
    }
    var isConvertedToStrip: Bool { convertedDrawerBundleID != nil }
    var isConvertedFromStrip: Bool {
        if case .stripToDrawer = conversion { return true }
        return false
    }
    var isConvertedFromMessaging: Bool {
        if case .messagingToDrawer = conversion { return true }
        return false
    }
    var isReleasedToMessaging: Bool {
        if case .drawerToMessaging = conversion { return true }
        return false
    }

    /// 转正后载体改画的**唯一代表卡**。由 DockStripView 在窗口卡实体化后写入（显示序里该 app 第一张
    /// 已实体化的**真窗口卡**），未实体化前为 nil（载体仍画抽屉小图标）。`revert`/`teardown` 清空。
    @Published private(set) var convertedRepresentative: StripItem?

    /// 转正后**条上要隐藏哪张卡**（让出空位）。和上面那个刻意分开成两个字段：
    ///
    /// 载体只能画 `StripItem`，而条上物化出来的可能是 `.keptApp` 占位或 `isAppLevelFallback`
    /// 的兜底卡——两者都不是"能画成一张窗口卡"的东西，`liveChipIDs` 也把它们排除在外。
    /// 早先两件事共用 `convertedRepresentative` 一个字段，于是 `keepPlacement` 路径
    /// （未运行的保留应用、只有 app 级兜底卡的运行应用）它永远是 nil，**条上那张卡全不透明地
    /// 画着、手里还拎着同一个图标 = 两个影子**（owner 2026-08-18 报）。
    /// 所以这里存的是 chip id，不是卡本身。
    @Published private(set) var convertedChipID: String?

    func setConvertedRepresentative(_ item: StripItem?, chipID: String?) {
        if convertedRepresentative != item { convertedRepresentative = item }
        if convertedChipID != chipID {
            convertedChipID = chipID
            HoverTrace.carrierRepresentative(rep: item?.id, hidden: chipID)
        }
    }
    /// 成功松手落定（converted 态）时回调，组合层接到后 `stripOrderStore.commitExternalBlock()`。
    /// 唯一收到 mouseUp 的是 `endDrag`，commit 必须由它触发，不靠 DockStripView 推断 payload 变 nil。
    var onDrawerToStripCommitted: ((String) -> Void)?
    /// 抽屉拖回任务条·异常取消（cancelDrag）时回调，组合层接到后 `stripOrderStore.cancelExternalBlock()`。
    /// 与 onDrawerToStripCommitted 对称：commit = 落定清暂存；cancel = 撤销清暂存+boundIDs。
    var onDrawerToStripCancelled: (() -> Void)?
    /// 抽屉图标松手落进任务条时回调（精确落点路径 + 降级路径都会触发）。
    /// PanelCoordinator 用它关闭抽屉；与 onDrawerToStripCommitted 独立，互不替代。
    var onDrawerToStripCompleted: ((String) -> Void)?
    /// 文件夹 chip 拖动的实时落点分类——**DockStripView 算好写入**（它才有 folderChipFrames/
    /// shelfFrame/stripRootScreenRect），载体视图（DragCarrierView）只读它决定要不要淡出。
    /// 最终 mouseUp 仍由 `endDrag()` 触发，并用 `folderDropGeometry` 重新分类一次。
    @Published private(set) var folderDragZone: FolderChipDropZone?
    func setFolderDragZone(_ zone: FolderChipDropZone?) {
        guard folderDragZone != zone else { return }
        folderDragZone = zone
        applyCarrierVisualState(animated: true)   // 拖出条外 → 淡下去 + 略放大
    }
    private var folderDropGeometry: FolderChipDropGeometry?
    func setFolderDropGeometry(_ geometry: FolderChipDropGeometry?) {
        if folderDropGeometry != geometry { folderDropGeometry = geometry }
    }
    /// 固定文件夹拖拽松手落定。PanelCoordinator 执行 store / Finder 副作用；controller 只负责可靠收尾。
    var onFolderDragEnded: ((String, FolderChipDropZone) -> Void)?

    /// 本次拖动的**原始来源**。转换会翻 `draggingPayload.source`（进抽屉体后变 `.drawer`），
    /// 所以判「这次拖动是不是把它从抽屉外带进来的」只能看这个。唯一权威是 `conversion` 里的
    /// 回滚快照——**不另设并行字段**（见 `CrossPanelConversion` 的注释：不再叠布尔标志）。
    private var originSource: DragSource? {
        guard let payload = draggingPayload else { return nil }
        switch conversion {
        case let .stripToDrawer(original),
             let .messagingToDrawer(original),
             let .drawerToMessaging(original):
            return original.source
        case .drawerToStrip:
            return .drawer
        case nil:
            return payload.source
        }
    }

    private let drawerStore: DrawerStore
    private let messagingStore: MessagingAppStore
    private let keptAppStore: KeptAppStore
    /// 按来源给投放候选区（屏幕坐标，已 inset+容错）：strip/messaging→胶囊(+抽屉)；drawer→任务条 dock 面板。
    private let dropZonesProvider: (DragSource) -> [CGRect]
    /// **全部**屏幕。一块屏一套载体面板（见 `CarrierSurface`），按指针所在屏切换。
    private let screensProvider: () -> [NSScreen]
    /// 胶囊可视帧（屏幕坐标）：任务条卡 / 消息 chip 松在胶囊上收纳时，图标吸进这里。`nil` = 不飞。
    private let stashTargetProvider: () -> CGRect?

    /// 一块屏一套（面板 + 容器视图 + 位图图层）。**为什么不是一块面板跟着指针挪**：把窗口 `setFrame`
    /// 到另一块显示器上，WindowServer 要一两帧才把它在新屏上重新建起来，那一两帧里刚点亮的载体
    /// 是看不见的（实测 2026-08-19：面板上一次停在别的屏，这次起拖露 2 帧空档）。每块屏常驻一套、
    /// 按指针所在屏切换，就没有迁移这一说。
    private struct CarrierSurface {
        let panel: NSPanel
        let container: CarrierContainerView
        let layer: CALayer
        let frame: CGRect
    }
    private var surfaces: [CarrierSurface] = []
    private var activeSurface: CarrierSurface?
    private var carrierPanel: NSPanel? { activeSurface?.panel }
    private var carrierContainer: CarrierContainerView? { activeSurface?.container }
    /// 载体那张位图所在的图层。**位置 / 缩放 / 阴影 / 透明度全是它的 CA 属性**，
    /// 由本控制器在收到鼠标事件的同一轮 run loop 里同步决定——不经过 SwiftUI，也就没有交接赛跑。
    private var carrierLayer: CALayer? { activeSurface?.layer }
    /// 当前这张位图。落地前若卡的样子变了要重拍（见 `setCarrierSnapshot`）。
    private var carrierSnapshot: CarrierSnapshot?
    /// 起拖那一刻拍的那张。抽屉图标转正进任务条会临时换成代表卡的图，回滚时换回它。
    private var originSnapshot: CarrierSnapshot?
    /// 每次载体上屏 +1。「晚一轮再撤」那个 async 认它——否则万一下一轮已经开始了新拖动，
    /// 它会把新载体的位图一起抹掉。
    private var carrierGeneration = 0

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pollTimer: Timer?

    init(drawerStore: DrawerStore,
         messagingStore: MessagingAppStore,
         keptAppStore: KeptAppStore,
         dropZonesProvider: @escaping (DragSource) -> [CGRect],
         screensProvider: @escaping () -> [NSScreen],
         stashTargetProvider: @escaping () -> CGRect? = { nil }) {
        self.pointerMoves = pointerSubject.eraseToAnyPublisher()
        self.carrierClicks = carrierClickSubject.eraseToAnyPublisher()
        self.drawerStore = drawerStore
        self.messagingStore = messagingStore
        self.keptAppStore = keptAppStore
        self.dropZonesProvider = dropZonesProvider
        self.screensProvider = screensProvider
        self.stashTargetProvider = stashTargetProvider
    }

    // MARK: - 起拖

    /// 按下那一刻预备好的载体：位图已挂上图层、纹理已经上传过（见 `prepareCandidate`）。
    private struct Candidate {
        let payloadID: String
        let snapshot: CarrierSnapshot
        let sourceScreenRect: CGRect
        let preparedAt: CFTimeInterval
    }
    /// 候选多久之内算新鲜：手势被 SwiftUI 取消时 `clearCandidate` 收不到，候选会留到下一次
    /// 按下；同一张卡再按下时若还新鲜就复用（省一次快照），否则重拍——卡的样子可能已经变了。
    private static let candidateFreshness: CFTimeInterval = 2
    private var candidate: Candidate?
    /// 没有候选时「过两个显示帧再藏卡 + 抬起」的那一下。
    private var armTask: DispatchWorkItem?

    /// **按下即预备**：mouse-down 那一刻就把这张卡的位图挂到载体图层上、以肉眼看不见的透明度
    /// 上屏一次，把纹理上传这笔钱提前付掉。之后真的起拖（≥ 8pt）时，`beginDrag` 只需把它点亮 +
    /// 摆位——和 `draggingPayload = payload`（藏卡）在**同一轮、同一个提交**里，两者同帧，
    /// 起拖当轮就能抬起，不再需要「先摆着等一轮」。
    ///
    /// 透明度取 0.01 而不是 0：完全透明的图层会被渲染树剔除、纹理根本不上传，等于白预热；
    /// 0.01 肉眼不可见（深色底板上不到 3/255 的亮度），但会真的走一遍上传。
    /// 一次点击付 ~0.6ms 的快照 + 一次透明面板 order front，可以接受。
    /// 松手没起拖 → `clearCandidate`。候选按 `payloadID` 认领，对不上就退回没有候选那条路。
    func prepareCandidate(payloadID: String, sourceScreenRect: CGRect,
                          snapshot: @autoclosure () -> CarrierSnapshot?) {
        guard draggingPayload == nil, landing == nil,
              sourceScreenRect.width > 0, sourceScreenRect.height > 0 else { return }
        // 幂等：`minimumDistance: 0` 的手势按住不放会一直 `onChanged`，同一次按下只预备一次。
        if let current = candidate, current.payloadID == payloadID,
           CACurrentMediaTime() - current.preparedAt < Self.candidateFreshness {
            return
        }
        guard let snapshot = snapshot() else { return }
        candidate = Candidate(payloadID: payloadID, snapshot: snapshot,
                              sourceScreenRect: sourceScreenRect, preparedAt: CACurrentMediaTime())
        let frame = ensureCarrierPanel(for: CGPoint(x: sourceScreenRect.midX, y: sourceScreenRect.midY))
        guard let layer = carrierLayer, let panel = carrierPanel else { return }
        carrierGeneration &+= 1
        Self.instantly {
            layer.removeAllAnimations()
            self.apply(snapshot, to: layer)
            layer.position = self.alignedCenter(
                DragCarrierGeometry.panelCenter(ofScreenRect: sourceScreenRect, panelFrame: frame), on: layer)
            layer.transform = CATransform3DIdentity
            layer.opacity = DragLandingPlan.candidateOpacity
        }
        orderCarrierFrontIfNeeded(panel)
        HoverTrace.dragHandoff("candidatePrepared", msSinceBegin: 0)
    }

    /// 按下没变成拖动（松手 / 手势被取消）→ 撤掉候选。**拖动进行中不动**：那时候候选已经被
    /// `beginDrag` 认领、载体正在手里。
    func clearCandidate(payloadID: String) {
        guard draggingPayload == nil, landing == nil, !carrierRetiring,
              candidate?.payloadID == payloadID else { return }
        candidate = nil
        retireCarrier()
    }

    /// - Parameters:
    ///   - sourceScreenRect: 这张卡**此刻在屏幕上占的那一格**（屏幕坐标）。载体先在这儿以卡槽
    ///     原尺寸出现，再抬到指针下。**不能从 `grabOffset` 反推**：`grabOffset` 是相对手势起点
    ///     `value.startLocation` 量的，而 `startScreenLocation` 是 `minimumDistance: 8` 触发那一刻
    ///     的位置，两者天然差 8pt 以上——那 8pt 正是 owner 报的「第一帧有卡顿」里的跳。
    ///   - pose: 卡槽**此刻**的形态（悬停 × 按压的复合缩放与上移）。载体第一帧按它摆，
    ///     才和卡槽逐像素重合——见 `DragCarrierGeometry.pickUpPose`。
    ///   - snapshot: 卡槽同款视图的位图（由渲染卡槽的那个视图自己拍，见 `ChipSnapshotter`）。
    ///     **是 autoclosure**：按下时已经预备了候选的话（`prepareCandidate`），这里不会再拍一张。
    ///     两边都拍不出来就不起拖：没有位图就没有能拎的东西，硬起拖只会让图标凭空消失。
    func beginDrag(payload: DragPayload,
                   startScreenLocation: CGPoint,
                   grabOffset: CGSize,
                   sourceScreenRect: CGRect,
                   pose: DragCarrierGeometry.PickUpPose,
                   snapshot: @autoclosure () -> CarrierSnapshot?) {
        guard draggingPayload == nil else { return }
        // 同一张卡还在归位飞行 → 从图标此刻的位置接着拖，不走「瞬收 + 从卡槽重新抬起」那一下跳
        //（见 `regrabLanding`）。任务条上这条路平时到不了——空卡槽是 opacity 0，SwiftUI 不给它
        // 命中（合成实测）——留着是护栏：哪个面板 / 哪个系统版本要是给了，也得是接着拖而不是跳。
        if let current = landing, current.payload.id == payload.id,
           regrabLanding(at: startScreenLocation, requireHit: false) {
            return
        }
        let prepared = candidate.flatMap { $0.payloadID == payload.id ? $0 : nil }
        candidate = nil
        guard let image = prepared?.snapshot ?? snapshot() else {
            HoverTrace.dragHandoff("noSnapshot", msSinceBegin: 0)
            retireCarrier()
            return
        }
        // 上一次的归位还在飞就立刻收掉（**不走延后交接**：那是给正常落地用的）。
        abortLanding()
        endHoverHold()
        let started = CACurrentMediaTime()
        dragBeganAt = started
        let hadCarrier = carrierPanel != nil
        carrierArmed = false
        carrierLifted = false
        liftTimer?.invalidate(); liftTimer = nil
        armTask?.cancel(); armTask = nil
        self.grabOffset = grabOffset
        globalLocation = startScreenLocation
        pointerSubject.send(startScreenLocation)
        // **先把载体摆到卡槽原位、再发布载荷**：此刻位图正以卡槽此刻的姿态压在那张卡上，
        // 所以卡下一帧才藏也看不出来，空档不可能出现。
        let beforeCarrier = CACurrentMediaTime()
        // 卡槽帧以起拖这一刻量到的为准（按下到起拖之间条可能重排过）；量不到才用预备时的。
        let slotRect = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? sourceScreenRect : (prepared?.sourceScreenRect ?? sourceScreenRect)
        presentCarrier(snapshot: image, at: slotRect, pose: pose)
        let afterCarrier = CACurrentMediaTime()
        draggingPayload = payload
        refreshDropZone()
        installMonitors()
        startPoll()
        if prepared != nil {
            // 纹理早就在 GPU 上了：点亮和藏卡同一个提交，当轮就抬起。
            armCarrier()
        } else {
            // 没预热过：先压着卡等两个显示帧（理由见 `carrierArmed`），再藏卡 + 抬起。
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.draggingPayload != nil, !self.carrierArmed else { return }
                self.armCarrier()
            }
            armTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + DragLandingPlan.pickUpSettle, execute: task)
        }
        HoverTrace.dragStart(totalMs: (CACurrentMediaTime() - started) * 1000,
                             carrierMs: (afterCarrier - beforeCarrier) * 1000,
                             carrierCreated: !hadCarrier,
                             prepared: prepared != nil)
    }

    /// 藏卡（当轮）+ 抬起（晚 `DragLandingPlan.liftDelay`）。幂等。
    ///
    /// **抬起为什么要再等一小段**：载体的改动走显式事务、`commit` 当场就送到 WindowServer；
    /// 而条上那张卡的「藏」是 SwiftUI 的更新，要等 AppKit 这一轮 display 周期才提交。主线程一忙
    /// （高频鼠标事件、重排），两者能差出一两个显示帧——这段时间里载体若已经离开卡槽往指针
    /// 走，屏幕上就是「卡还在、副本已经飞出去一截」两份图标（1000Hz 合成拖动录屏实测：
    /// 抬起当轮就走，先出现 2 帧上下错开的双影，然后卡才藏）。载体先在卡槽原位、按卡槽此刻的
    /// 姿态压着不动等两帧，藏卡这一提交就一定先到；重叠那两帧两者逐像素相同，看不出来。
    private func armCarrier() {
        guard draggingPayload != nil, !carrierArmed else { return }
        armTask?.cancel(); armTask = nil
        carrierArmed = true
        HoverTrace.dragHandoff("slotHidden", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
        liftTimer?.invalidate()
        let timer = Timer(timeInterval: DragLandingPlan.liftDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.draggingPayload != nil, self.carrierArmed, !self.carrierLifted else { return }
                self.liftCarrier()
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // 拖动中的计时器必须 .common（AGENTS）
        liftTimer = timer
    }
    private var liftTimer: Timer?
    /// 抬起已经开始（跟手从这一刻起）。
    private(set) var carrierLifted = false

    // MARK: - 任务条卡进抽屉体 → 转成抽屉内拖动（统一手感，owner 2026-06-22）

    /// 任务条卡拖进**打开的抽屉体** → 即时"转正"成抽屉成员、把来源改成 `.drawer`。之后完全走抽屉内
    /// 重排路径（全局鼠标驱动、无占位空格、无面板反复缩放）——彻底绕开旧的"占位+面板缩放"机制。
    /// **可逆**：转正只是临时插入(挤开别人=预览);卡拖出抽屉体 → `revertStripFromDrawer` 撤销还原;
    /// 真正松手落在抽屉里那刻才算落定（owner 2026-06-22：再开抽屉要是最初的样子,不是被挤过的）。
    /// `guard source==.strip && conversion==nil` 保证幂等（转一次后不再触发）。
    func convertStripToDrawer() {
        guard let p = draggingPayload, p.source == .strip, p.canExternalDrop, conversion == nil else { return }
        conversion = .stripToDrawer(original: p)  // 先置（同步触发宽度冻结），再动 store
        draggingPayload = DragPayload(source: .drawer, id: p.bundleID, bundleID: p.bundleID,
                                      item: p.item, visualKind: p.visualKind, canExternalDrop: true)
        drawerStore.add(p.bundleID)
        refreshDropZone()   // 投放区集合随来源变,重算
    }

    /// 撤销转正：卡拖出抽屉体 → 从抽屉成员里移除（抽屉缩回原样、其他图标归位）、来源还原成任务条卡。
    /// 之后再次拖进抽屉体会重新 `convertStripToDrawer`。让"再开抽屉=最初的样子"。
    /// 先清转换态、先还原载荷，**再**动 store——成员监听按新载荷来源豁免，无取消竞态（评审 P1-2）。
    func revertStripFromDrawer() {
        guard case let .stripToDrawer(original) = conversion, draggingPayload?.source == .drawer else { return }
        conversion = nil    // 解冻 + 触发 relayout（拖出抽屉还原 → 任务条恢复原宽）
        draggingPayload = original
        drawerStore.remove(original.bundleID)
        refreshDropZone()
    }

    // MARK: - 消息区 chip 进抽屉体 → 收纳预览 / 拖出还原（与任务条卡同一套手感）

    /// 消息区 chip 拖进**打开的抽屉体** → 临时收纳成抽屉成员、来源翻成 `.drawer`（此后抽屉内重排
    /// 全套复用）。**不动消息 flag**——收进抽屉只是投影隐藏，与既有收纳语义一致。
    /// 先置转换态、先翻载荷再 `drawer.add`：消息区监听按来源豁免，不误判"chip 从区里消失"（评审 P1-2/P2-5）。
    func convertMessagingToDrawer() {
        guard let p = draggingPayload, p.source == .messaging, p.canExternalDrop, conversion == nil else { return }
        conversion = .messagingToDrawer(original: p)
        draggingPayload = DragPayload(source: .drawer, id: p.bundleID, bundleID: p.bundleID,
                                      item: nil, visualKind: .drawerIcon, canExternalDrop: true)
        drawerStore.add(p.bundleID)
        refreshDropZone()
    }

    /// 撤销收纳预览：拖出抽屉体 → 移出抽屉成员、载荷还原 `.messaging`（chip 回消息区原位）。
    func revertMessagingFromDrawer() {
        guard case let .messagingToDrawer(original) = conversion, draggingPayload?.source == .drawer else { return }
        conversion = nil
        draggingPayload = original
        drawerStore.remove(original.bundleID)
        refreshDropZone()
    }

    // MARK: - 抽屉图标拖进任务条区 → 转正成任务条窗口卡 / 拖出还原（抽屉拖回任务条·精确落点，2026-06-22）

    /// 抽屉图标拖进**任务条面板区** → 即时"转正"：`drawerStore.remove(bid)`，该 app 的窗口卡随即进 live 区。
    /// 落点排序（暂存 + sync 内落子）归 DockStripView，本方法只管成员变更 + 记 bundleID。**不翻 source**——保
    /// `.drawer` 让 `isOverUnstashZone` 高亮与 `endDrag` 的 `.drawer` 分支继续成立。`guard` 保幂等。
    func convertDrawerToStrip() {
        guard let p = draggingPayload, p.source == .drawer, p.canExternalDrop, conversion == nil else { return }
        conversion = .drawerToStrip(bundleID: p.bundleID)  // 先置（宽度冻结），再动 drawerStore
        drawerStore.remove(p.bundleID)
        applyCarrierVisualState(animated: true)   // 转正后不再缩到 0.82，保持拎着的 1.05
    }

    /// 撤销转正：拖出任务条区 → `drawerStore.add(bid)` 还原 placement；kept 始终不变。
    /// 顺序层的撤销（删 boundIDs + 清 absentSince）由 DockStripView 在调本方法**之前** `cancelExternalBlock`。
    func revertDrawerToStrip() {
        guard case let .drawerToStrip(bid) = conversion else { return }
        drawerStore.add(bid)
        conversion = nil
        convertedRepresentative = nil   // 载体恢复抽屉小图标
        convertedChipID = nil           // 条上不再有卡需要让位
        applyCarrierVisualState(animated: true)
    }

    // MARK: - 抽屉里的消息应用拖进消息区范围 → 临时释放回消息区 / 离区还原（评审 P1-3）

    /// 抽屉起拖的**运行中消息应用**进入消息区范围 → 临时释放：载荷翻成 `.messaging`（区内重排、
    /// 再进抽屉的收纳预览全部复用通用逻辑），再 `drawer.remove`（投影立即让 chip 回到消息区原顺序位）。
    /// 触发范围由 DockStripView 按消息区帧判定——**不是**"离开抽屉体就释放"。
    func convertDrawerToMessaging() {
        guard let p = draggingPayload, p.source == .drawer, p.canExternalDrop, conversion == nil else { return }
        conversion = .drawerToMessaging(original: p)
        draggingPayload = DragPayload(source: .messaging, id: p.bundleID, bundleID: p.bundleID,
                                      item: nil, visualKind: .messagingIcon, canExternalDrop: true)
        drawerStore.remove(p.bundleID)
        refreshDropZone()
    }

    /// 撤销释放：离开消息区范围（或进投放区）→ 收回抽屉、载荷还原 `.drawer`。
    func revertDrawerToMessaging() {
        guard case let .drawerToMessaging(original) = conversion, draggingPayload?.source == .messaging else { return }
        conversion = nil
        draggingPayload = original
        drawerStore.add(original.bundleID)
        refreshDropZone()
    }

    // MARK: - 跟手 / 落点

    private func update(_ loc: CGPoint) {
        globalLocation = loc
        // **同步摆位，第一件事就做**：这是跟手性的全部。走 SwiftUI 的老路子每帧要过一遍渲染管线，
        // 拖快了副本会落在光标后面一百多 pt（owner 2026-08-18 连拍实证）。
        followScreenIfNeeded(loc)
        moveCarrier()
        if regrabPressed, let origin = regrabOrigin,
           hypot(loc.x - origin.x, loc.y - origin.y) > DragLandingPlan.regrabClickSlop {
            regrabPressed = false                    // 挪过门槛 = 拖动：回到拎着的样子（等于抬起）
            applyCarrierVisualState(animated: true)
        }
        refreshDropZone()
        pointerSubject.send(loc)    // 副作用订阅方（条 / 抽屉），不建立视图依赖
        auditCarrierVisibility()
    }

    /// 每次光标更新自检一次：**条上那格已经空了，副本是不是真的在屏幕上？**
    /// 两者只要不同时成立，用户看到的就是「图标不见了」。owner 连着三轮报「偶尔会消失」，
    /// 靠截图只能猜；这条把它变成日志里可以数的事实。
    ///
    /// 反向那条（副本在屏上、条上那格还占着 = 重影）**不用再查了**：起拖不再有门控，
    /// 两者的时序由同一轮 run loop 保证，不存在"谁先谁后"这个自由度。
    private func auditCarrierVisibility() {
        guard HoverTrace.isEnabled, carriedPayload != nil,
              let panel = carrierPanel, let layer = carrierLayer else { return }
        let onScreen = panel.isVisible && panel.alphaValue > 0.99
        let drawn = layer.contents != nil && layer.opacity > 0.01
        // 位图中心必须真的落在面板（= 所有屏的并集）里，多留 24pt 容错。
        let inFrame = CGRect(origin: .zero, size: carrierScreenFrame.size)
            .insetBy(dx: -24, dy: -24).contains(layer.position)
        guard !onScreen || !drawn || !inFrame else { return }
        let reason = !panel.isVisible ? "panelHidden"
            : (panel.alphaValue <= 0.99 ? "panelFaded"
               : (!drawn ? "emptyContent" : "iconOffscreen"))
        HoverTrace.carrierGap(reason: reason, alpha: panel.alphaValue,
                              hostX: layer.position.x, hostY: layer.position.y)
    }

    /// **只在结论真的变了才写**：`@Published` 是每次赋值都发通知，不比较旧值。
    /// 每动一下鼠标写一次，就等于每动一下鼠标打翻一次整条任务条（同 `globalLocation` 那条）。
    private func refreshDropZone() {
        let next: Bool = {
            guard let p = draggingPayload, p.canExternalDrop else { return false }
            return dropZonesProvider(p.source).contains { $0.contains(globalLocation) }
        }()
        guard isOverDropZone != next else { return }
        isOverDropZone = next
        applyCarrierVisualState(animated: true)   // 进/出投放区 → 0.82 ↔ 1.05
    }

    // MARK: - 收尾（幂等，先清后提交）

    /// 正常松手：在投放区 → 按来源收纳/移回；否则什么都不做（区内排序已在拖动中实时提交）。
    /// `.messaging`/`.drawer` 的收尾决策走纯逻辑 `DragConversionPlan.endAction`（单测覆盖）。
    func endDrag() {
        guard let p = draggingPayload else { return }
        // 飞行途中重抓、松手没挪 = **点了一下这张卡**：图标照常接着飞回卡槽（不收纳、不落定什么），
        // 然后把「被点了」交给拥有它的面板去做唤醒 / 最小化（owner 2026-08-19：落地前点它没反应）。
        if let origin = regrabOrigin,
           hypot(globalLocation.x - origin.x, globalLocation.y - origin.y) < DragLandingPlan.regrabClickSlop {
            let folderZone = folderDropGeometry?.classify(screenPoint: globalLocation) ?? .folderZone
            teardown(landing: plannedLanding(for: p, folderZone: folderZone, allowStash: false))
            HoverTrace.dragHandoff("click", msSinceBegin: 0)
            carrierClickSubject.send(p)
            return
        }
        let external = isOverDropZone
        let converted = isConvertedToStrip
        let convertedBid = convertedDrawerBundleID
        let origin = originSource ?? p.source   // 必须赶在 teardown() 清 conversion 之前取
        let finalLocation = globalLocation
        let folderZone = folderDropGeometry?.classify(screenPoint: finalLocation) ?? .folderZone
        let action = DragConversionPlan.endAction(source: p.source,
                                                  isConvertedToStrip: converted,
                                                  isOverDropZone: external,
                                                  isMessagingMember: messagingStore.contains(p.bundleID))
        teardown(landing: plannedLanding(for: p, folderZone: folderZone))
        switch p.source {
        case .folder:
            onFolderDragEnded?(p.id, folderZone)
        case .strip:
            // 进过抽屉体的卡已被 convertStripToDrawer 转成 .drawer（落在里面 = 已是成员、不走这里）。
            // 走到这支 = 没进抽屉体的卡：在投放区(胶囊)松手 → 改 drawer placement。
            // kept 不在这里动——四条入口共用 switch 之后那段统一判据。
            if external {
                drawerStore.add(p.bundleID)
            }
        case .messaging:
            // 消息区起拖未转换（转换后来源已是 .drawer），或抽屉起拖已释放回消息区（drawer.remove
            // 已发生，松手即落定）。投放区（胶囊）→ 收纳；其余任意位置 → 原地不动（区内重排已实时提交）。
            if action == .stashMessagingChip {
                drawerStore.add(p.bundleID)
            }
        case .drawer:
            switch action {
            case .commitDrawerToStrip:
                // 已转正进任务条（成员已 remove、窗口卡已落子）→ 视为落定，不再据 external 动成员。
                // 撤销已在实时离区时发生；这里只通知顺序层 commit（清暂存追踪）。
                let bid = convertedBid ?? p.bundleID
                onDrawerToStripCommitted?(bid)
                onDrawerToStripCompleted?(bid)
            case .fallbackUnstash:
                // 没转正（没运行 / app-fallback）：落任务条 → 移回。消息成员永不走这支——
                // 它回任务条的唯一路径是消息区范围的临时释放（评审 P1-3），其他位置松手留在抽屉。
                drawerStore.remove(p.bundleID)
                onDrawerToStripCompleted?(p.bundleID)
            case .none, .stashMessagingChip:
                break
            }
        }

        // 收纳落定 → 打开「在程序坞中保留」（owner 2026-08-06）。放在 switch **之后**：
        // 此刻 drawerStore 已是最终成员关系，四条入口路径（任务条/消息 chip × 抽屉体/胶囊）
        // 共用一个判据，也天然排除了抽屉内重排、转正进任务条、降级移出这些不该开启的情形。
        // 语义（只进不出、每次拖入都重新打开）见 DragConversionPlan.enablesKeptOnDrop。
        if DragConversionPlan.enablesKeptOnDrop(originSource: origin,
                                                endedInDrawer: drawerStore.contains(p.bundleID)) {
            keptAppStore.add(p.bundleID)
        }
    }

    /// 取消：拖动中目标消失、切屏等异常路径。先按当前转换态回滚已发生的 store 变更
    /// （与各"拖出还原"同路径），再收尾——每个临时态都恢复原成员关系。
    func cancelDrag() {
        // 归位飞行期间 `draggingPayload` 已经是 nil，但载体面板还开着——切屏 / 面板拆除
        // 这些路径都走这里，不先收掉的话会把一个半透明的全屏载体留在屏幕上。
        abortLanding()
        guard draggingPayload != nil else { return }
        switch conversion {
        case .stripToDrawer:
            revertStripFromDrawer()
        case .drawerToStrip:
            onDrawerToStripCancelled?()
            revertDrawerToStrip()
        case .messagingToDrawer:
            revertMessagingFromDrawer()
        case .drawerToMessaging:
            revertDrawerToMessaging()
        case nil:
            break
        }
        // 异常取消（目标消失/切屏）不飞：那不是"落到某一格"，飞回一个已经不存在的位置只会更怪。
        teardown(landing: nil)
    }

    /// 这次松手该不该飞、飞到哪。拿不到落点锚点（或被 `DOCK_DRAG_LANDING=0` 关掉）→ nil → 瞬时收尾。
    private func plannedLanding(for payload: DragPayload, folderZone: FolderChipDropZone,
                                allowStash: Bool = true) -> Landing? {
        guard DragLandingSwitches.enabled else { return nil }
        // 文件夹 chip 拖出任务条（松手 = 取消固定 / 打开）→ 那一格马上就没了，
        // 飞回一个正在消失的位置只会更怪。载体保持淡出的样子直接收掉。
        guard payload.source != .folder || folderZone == .folderZone else { return nil }
        // 松在胶囊上收纳 → 吸进胶囊（`DragLandingPlan.stashFlight`）。判据和 `endDrag` 里真的会
        // `drawerStore.add` 的那两支一致。**不能飞回卡槽**：收纳一提交那格就没了（owner 2026-08-19 截图：
        // 图标往任务条那头飘一段再凭空消失）。拿不到胶囊帧就瞬时收尾。
        if allowStash, willStash(payload) {
            let from = DragCarrierGeometry.topLeftCarriedCenter(pointer: globalLocation,
                                                                grabOffset: grabOffset,
                                                                panelFrame: carrierScreenFrame)
            guard let flight = DragLandingPlan.stashFlight(from: from, fromScale: carriedScale,
                                                           targetScreenRect: stashTargetProvider(),
                                                           carrierScreenFrame: carrierScreenFrame) else {
                HoverTrace.landing(from: from, to: nil, source: "stash:\(payload.source)")
                return nil
            }
            HoverTrace.landing(from: from, to: flight.to, source: "stash:\(payload.source)")
            landingToken &+= 1
            return Landing(token: landingToken, payload: payload, kind: .stash, flight: flight)
        }
        // 卡槽在另一块屏上（跨屏拖回）：面板先挪到卡槽那块屏，飞行才在同一块面板里算。
        if let rect = landingAnchor?.rect {
            followScreenIfNeeded(CGPoint(x: rect.midX, y: rect.midY))
            moveCarrier()   // 载体在新面板坐标里的当前位置 = 起点
        }
        let from = DragCarrierGeometry.topLeftCarriedCenter(pointer: globalLocation,
                                                            grabOffset: grabOffset,
                                                            panelFrame: carrierScreenFrame)
        let flight = DragLandingPlan.flight(from: from,
                                            fromScale: carriedScale,
                                            anchorScreenRect: landingAnchor?.rect,
                                            carrierScreenFrame: carrierScreenFrame)
        HoverTrace.landing(from: from, to: flight?.to, source: "\(payload.source)")
        guard let flight else { return nil }
        landingToken &+= 1
        return Landing(token: landingToken, payload: payload, kind: .returnToSlot, flight: flight)
    }

    /// 这次松手会不会收进抽屉（= `endDrag` 里 `.strip` 的 `external` 支 / `.messaging` 的 `.stashMessagingChip` 支）。
    private func willStash(_ payload: DragPayload) -> Bool {
        switch payload.source {
        case .strip:
            return isOverDropZone
        case .messaging:
            return DragConversionPlan.endAction(source: .messaging,
                                                isConvertedToStrip: isConvertedToStrip,
                                                isOverDropZone: isOverDropZone,
                                                isMessagingMember: messagingStore.contains(payload.bundleID))
                == .stashMessagingChip
        case .drawer, .folder:
            return false
        }
    }

    /// 收尾。`landing` 非空时**不收载体**——它还要飞一段；到点由 `finishLanding()` 收。
    private func teardown(landing flight: Landing?) {
        let released = draggingPayload
        conversion = nil                  // 落定路径：清转换态不回滚（commit）；解冻任务条宽度
        convertedRepresentative = nil
        convertedChipID = nil
        folderDragZone = nil
        folderDropGeometry = nil
        draggingPayload = nil
        carrierArmed = false
        carrierLifted = false
        regrabOrigin = nil
        regrabPressed = false
        liftTimer?.invalidate(); liftTimer = nil
        armTask?.cancel(); armTask = nil
        candidate = nil
        isOverDropZone = false
        landingAnchor = nil
        removeMonitors()
        pollTimer?.invalidate(); pollTimer = nil
        landingTimer?.invalidate(); landingTimer = nil
        landing = flight
        guard let flight else {
            // **不飞也要「先显后撤」。** `draggingPayload` 刚清空，条上那张卡要等 SwiftUI
            // 下一次提交才显形；这里当场 `orderOut` 就必然露出一帧空位——亚像素落点
            // （位移不够 `minimumTravel`，不飞）、没有锚点、文件夹拖出条外这些不飞的路
            // 每次都会闪一下，正是 owner 报的「点击图标隔壁的图标会有上下的重影」在快速点击下的形态。
            // 悬停同样按住到指针再动：这条路的指针也压在刚显形的卡上。
            if let released { beginHoverHold(for: released) }
            retireCarrierAfterHandoff()
            return
        }
        landingDeadline = CACurrentMediaTime() + DragLandingPlan.maximumDuration
        flyCarrier(along: flight.flight, token: flight.token)
        if flight.kind == .returnToSlot { beginLandingGrabWatch() }
    }

    /// 排（或重排）「飞完了就收载体」那一下。
    /// `.common`：松手瞬间主 run loop 可能还在事件跟踪模式，default 模式的计时器不会触发，
    /// 载体就会永远停在半空（同 `armSpringOpenTimer` 的理由）。
    private func scheduleLandingFinish(token: Int) {
        landingTimer?.invalidate()
        let flightDuration = landing?.flight.duration ?? DragLandingPlan.duration
        let remaining = max(0.05, min(flightDuration + DragLandingPlan.settleMargin,
                                      landingDeadline - CACurrentMediaTime()))
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.finishLanding(token: token)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        landingTimer = timer
    }

    /// 任务条卡能否收纳：只拦无 bundleID 与 Finder（Finder 永远保留任务条入口）。
    /// 不拦 app-level fallback —— 抽屉运行区本就显示应用级图标。
    static func canStash(_ item: StripItem) -> Bool {
        guard let bid = item.bundleIdentifier, !bid.isEmpty else { return false }
        if bid == "com.apple.finder" { return false }
        return true
    }

    // MARK: - 载体面板（位图图层）

    /// 提前把载体面板建好，别让用户的**第一次拖动**替我们付这笔钱。
    ///
    /// 载体改成位图之后这笔钱小多了（不再需要 order front 一次去逼一棵 SwiftUI 宿主树布局），
    /// 但建 `NSPanel` 本身仍有成本，而且首次拖动正是 owner 说「第一帧有卡顿」的那一次。
    func prewarmCarrier() {
        guard surfaces.isEmpty else { return }
        // 每块屏一套、现在就 order front（图层里什么都没有，屏幕上看不见）。理由见 `retireCarrier`。
        for frame in screensProvider().map(\.frame) { _ = surface(for: frame) }
        activeSurface = surfaces.first
        carrierScreenFrame = activeSurface?.frame ?? .zero
    }

    /// 面板拆除（权限丢失挂起等）：常驻的几套面板要显式收掉，`NSWindow` 在屏上时不会随控制器一起走。
    func closeCarrierSurfaces() {
        abortLanding()
        for surface in surfaces { surface.panel.orderOut(nil); surface.panel.close() }
        surfaces.removeAll()
        activeSurface = nil
        carrierScreenFrame = .zero
    }

    /// 铺 `frame` 那块屏的那一套；没有就建一套并 order front。
    private func surface(for frame: CGRect) -> CarrierSurface {
        if let existing = surfaces.first(where: { $0.frame == frame }) { return existing }
        let made = makeCarrierSurface(frame: frame)
        surfaces.append(made)
        made.panel.orderFrontRegardless()
        return made
    }

    /// 让「当前那一套」是包含 `point` 的那块屏的；返回该屏 frame。
    /// 换屏时旧那一套的图层清空，新那一套由调用方紧接着 `apply(snapshot)` 填上。
    @discardableResult
    private func ensureCarrierPanel(for point: CGPoint) -> CGRect {
        let frames = screensProvider().map(\.frame)
        // 屏幕排列变了：不再存在的屏那一套收掉（它们本来就是空的、看不见）。
        for stale in surfaces where !frames.contains(stale.frame) {
            stale.panel.orderOut(nil); stale.panel.close()
            if activeSurface?.panel === stale.panel { activeSurface = nil }
        }
        surfaces.removeAll { !frames.contains($0.frame) }
        let frame = DragCarrierGeometry.screenFrame(containing: point, in: frames)
        guard frame.width > 0 else { return .zero }
        let next = surface(for: frame)
        if activeSurface?.panel !== next.panel {
            if let old = activeSurface {
                Self.instantly { old.layer.removeAllAnimations(); old.layer.contents = nil }
            }
            activeSurface = next
        }
        carrierScreenFrame = frame
        return frame
    }

    /// 指针跨到另一块屏 → 切到那块屏那一套，把当前位图 / 缩放 / 投影原样搬过去，再按屏幕坐标摆位
    ///（几何全是「屏幕坐标 − 面板原点」，原点换了照算就是）。同一块屏内什么都不做。
    private func followScreenIfNeeded(_ point: CGPoint) {
        guard carrierScreenFrame.width > 0, !carrierScreenFrame.contains(point) else { return }
        let frames = screensProvider().map(\.frame)
        guard frames.contains(where: { $0.contains(point) }) else { return }   // 屏与屏之间的缝，先不动
        ensureCarrierPanel(for: point)
        if let layer = carrierLayer, let snapshot = carrierSnapshot {
            Self.instantly { self.apply(snapshot, to: layer); layer.opacity = 1 }
            applyCarrierVisualState(animated: false)
        }
        HoverTrace.dragHandoff("screenSwitch", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
    }

    /// 把位图摆到卡槽原位、按卡槽此刻的姿态出现（还没抬起）。整段同步、无隐式动画。
    private func presentCarrier(snapshot: CarrierSnapshot, at sourceScreenRect: CGRect,
                                pose: DragCarrierGeometry.PickUpPose) {
        let anchor = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? CGPoint(x: sourceScreenRect.midX, y: sourceScreenRect.midY) : globalLocation
        let frame = ensureCarrierPanel(for: anchor)
        guard let layer = carrierLayer, let panel = carrierPanel else { return }
        carrierGeneration &+= 1
        carrierSnapshot = snapshot
        originSnapshot = snapshot
        // 帧还没量到（`.zero`）就退回「直接摆在指针下」——总比摆到屏幕左下角强。
        var center = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? DragCarrierGeometry.panelCenter(ofScreenRect: sourceScreenRect, panelFrame: frame)
            : DragCarrierGeometry.carriedCenter(pointer: globalLocation, grabOffset: grabOffset, panelFrame: frame)
        // 卡槽此刻若正被安静档悬停底锚顶着、又被按压缩着，视觉中心不在卡槽中心：按姿态补上。
        center.y += pose.dy
        Self.instantly {
            layer.removeAllAnimations()
            self.apply(snapshot, to: layer)          // 先换图：`alignedCenter` 要用新 bounds
            layer.position = self.alignedCenter(center, on: layer)
            layer.transform = Self.scaleTransform(pose.scale)
            layer.opacity = 1
        }
        orderCarrierFrontIfNeeded(panel)
    }

    /// **载体图层的每一次改动都必须包在显式 `CATransaction` 里，哪怕是瞬时赋值。**
    ///
    /// 实测（2026-08-19，逐项 A/B）：这块面板里的子图层**裸赋值不会送到 WindowServer**——
    /// `presentation()` 读回来是新值（那是本地算的），屏幕上却纹丝不动：位置不跟手、透明度停在
    /// 预备时的 0.01，看起来就是「载体整个不见了」；同一份代码只要包上 `begin/commit` 就正常。
    /// 成因没有追到底（这块面板没有 AppKit 的 display 周期来替它冲提交），但规则很硬：
    /// **裸赋值 = 静默失效**。瞬时改动走这里（顺带关掉隐式动画），要动的走 `animate` 且同样包在事务里。
    private static func instantly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// **已经在最前面就别再 order 一次。**
    ///
    /// 实测（2026-08-19，1000Hz 合成拖动录屏逐帧，其余条件相同）：起拖时对一块**已经**
    /// order front 的载体面板再调一次 `orderFrontRegardless()`，它的内容要晚 2–3 个显示帧才上屏
    /// ——卡槽这边已经藏了，副本还没出来，就是那 3 帧空档；去掉这一下重复 ordering，空档归零。
    /// 面板在按下预备（`prepareCandidate`）那一刻已经 order front，起拖当轮只该改图层，不该动窗口。
    private func orderCarrierFrontIfNeeded(_ panel: NSPanel) {
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    /// 抬起：从卡槽滑到指针下，同时长到 1.05、渐出投影。
    private func liftCarrier() {
        guard let layer = carrierLayer else { return }
        carrierLifted = true
        HoverTrace.dragHandoff("lift", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
        let rawTarget = DragCarrierGeometry.carriedCenter(pointer: globalLocation,
                                                       grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        let target = alignedCenter(rawTarget, on: layer)
        let from = layer.position
        // model 值直接到位（跟手每帧改的就是它），位移用**叠加式**动画补上那段差。
        // 不这样的话，抬起途中每一次跟手写位置都会和一条绝对值动画打架，副本会先飞向旧目标再瞬移。
        // 动画的 add 也在事务里：**任何裸的图层改动（含加动画）都可能开一个永远不提交的隐式事务**
        // （见 `instantly`）。
        Self.instantly {
            layer.position = target
            if hypot(target.x - from.x, target.y - from.y) > 0.5 {
                let slide = CABasicAnimation(keyPath: "position")
                slide.isAdditive = true
                slide.fromValue = NSValue(point: NSPoint(x: from.x - target.x, y: from.y - target.y))
                slide.toValue = NSValue(point: .zero)
                slide.duration = DragLandingPlan.liftDuration
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                slide.isRemovedOnCompletion = true
                layer.add(slide, forKey: "lift")
            }
        }
        applyCarrierVisualState(animated: true)
    }

    /// 跟手：每个鼠标事件同步摆位。**必须关掉隐式动画**——`CALayer.position` 默认带 0.25s 的
    /// 隐式动画，不关的话每一帧都在往上一帧的目标插值，副本会永远软绵绵地落在光标后面。
    private func moveCarrier() {
        // **抬起之前不跟手**：那一轮载体必须待在卡槽原位压着卡（见 `carrierArmed`）。
        // 少了这个 guard，起拖当轮先到的一个 dragged 事件就会把载体瞬移到指针下，
        // `liftCarrier` 随后量到的起点已经是终点，那段滑行就静默地没有了。
        guard carrierLifted, let layer = carrierLayer, carrierScreenFrame.width > 0 else { return }
        let center = DragCarrierGeometry.carriedCenter(pointer: globalLocation,
                                                       grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        let aligned = alignedCenter(center, on: layer)   // 不对齐就是整段拖动都糊，见 `alignedCenter`
        Self.instantly { layer.position = aligned }
    }

    /// 缩放 + 透明度（进/出投放区、转正、文件夹拖出条外）统一走这一个出口，
    /// 免得几处各写各的、状态叠在一起时互相覆盖。
    private func applyCarrierVisualState(animated: Bool) {
        // 同 `moveCarrier`：抬起之前载体保持「卡槽原样」（0.93），
        // 否则起拖当轮一次投放区判定就能把它提前放大到 1.05，抬起动画就成了半截。
        guard carrierLifted, let layer = carrierLayer, draggingPayload != nil else { return }
        let scale = regrabPressed ? ChipPressDecision.pressedScale : carrierVisualScale
        let opacity = carrierVisualOpacity
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(DragLandingPlan.stateChangeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.transform = Self.scaleTransform(scale)
        layer.opacity = opacity
        CATransaction.commit()
    }

    /// 给一个图层属性做一段显式动画：model 值立刻到位，动画从**当前呈现值**接到新值。
    /// `duration == 0` 就是瞬时。图层的隐式动作全关了（见 `makeCarrierPanel`），
    /// 所以想动就只能走这里；反过来，不想动的地方直接赋值就是瞬时的，不用再包事务。
    private static func animate(_ layer: CALayer, _ keyPath: String, to value: Any,
                                duration: TimeInterval,
                                timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut)) {
        let from = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        layer.setValue(value, forKeyPath: keyPath)
        guard duration > 0 else { layer.removeAnimation(forKey: keyPath); return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: keyPath)
    }

    /// 换一张位图（抽屉图标转正成任务条卡 / 回滚；任务条卡收进抽屉体 / 拖出还原；落地前卡的样子变了）。
    /// **传 `nil` = 换回起拖时那张**（回滚路径）。
    ///
    /// - Parameter reanchor: `true` = 新旧位图尺寸差很多（168pt 的标题卡 ↔ 30.8pt 的抽屉小图标），
    ///   抓取偏移按尺寸比例缩放——指针停在图标上**同一个相对位置**，否则标题卡抓在右端、换成小图标后
    ///   会浮在指针几十 pt 以外（owner 2026-08-19 截图：进抽屉后图标压在抽屉边上）；位置滑过去、
    ///   bounds 与 contents 用同一段 0.12s 动画过渡（大卡缩成小图标、同时贴到指针边上）。
    ///   `false` = 瞬时换图、偏移不动（抽屉图标转正进任务条那个方向现在的样子，owner 已验收，不动）。
    func setCarrierSnapshot(_ snapshot: CarrierSnapshot?, reanchor: Bool = false) {
        guard let layer = carrierLayer, draggingPayload != nil,
              let next = snapshot ?? originSnapshot else { return }
        let previousSize = carrierSnapshot?.size ?? layer.bounds.size
        carrierSnapshot = next
        guard reanchor, carrierLifted, previousSize.width > 0, previousSize.height > 0 else {
            Self.instantly { self.apply(next, to: layer) }
            return
        }
        grabOffset = CGSize(width: grabOffset.width * next.size.width / previousSize.width,
                            height: grabOffset.height * next.size.height / previousSize.height)
        let from = layer.position
        let rawTarget = DragCarrierGeometry.carriedCenter(pointer: globalLocation, grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        // bounds 隐式动画 + contents 交叉淡：位图在同一段时间里换样子、换尺寸。
        CATransaction.begin()
        CATransaction.setAnimationDuration(DragLandingPlan.stateChangeDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        apply(next, to: layer)
        CATransaction.commit()
        // 位置：model 直接到位 + 叠加式滑动（同 `liftCarrier`），跟手照常、不和绝对值动画打架。
        let target = alignedCenter(rawTarget, on: layer)
        Self.instantly {
            layer.position = target
            if hypot(target.x - from.x, target.y - from.y) > 0.5 {
                let slide = CABasicAnimation(keyPath: "position")
                slide.isAdditive = true
                slide.fromValue = NSValue(point: NSPoint(x: from.x - target.x, y: from.y - target.y))
                slide.toValue = NSValue(point: .zero)
                slide.duration = DragLandingPlan.stateChangeDuration
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                slide.isRemovedOnCompletion = true
                layer.add(slide, forKey: "reanchor")
            }
        }
    }

    private func apply(_ snapshot: CarrierSnapshot, to layer: CALayer) {
        layer.contents = snapshot.image
        layer.contentsScale = snapshot.scale
        layer.bounds = CGRect(origin: .zero, size: snapshot.size)
    }

    /// 归位飞行：位移、缩放、投影**在同一个事务里**，所以不存在「淡出计时器没跟着纠偏一起重排」
    /// 那种漏排（上一版正是这么把载体在半路淡到 0 的）。
    private func flyCarrier(along flight: DragLandingFlight, token: Int) {
        guard let layer = carrierLayer else { return }
        // 起点：还在飞（纠偏重发）就用时间线算出的此刻位置，否则就是拎着时的 model 值。
        let now = CACurrentMediaTime()
        let start = landingPose(at: now)
            ?? LayerPose(position: layer.position, scale: Self.scale(of: layer.transform))
        landingAnimation &+= 1
        let generation = landingAnimation
        let c = flight.curve   // 每次飞行自带曲线（近缓远快），和 duration 一样不许分开算
        let timing = CAMediaTimingFunction(controlPoints: Float(c.c0x), Float(c.c0y), Float(c.c1x), Float(c.c1y))
        let destination = alignedCenter(
            DragCarrierGeometry.panelPoint(fromTopLeft: flight.to, panelFrame: carrierScreenFrame), on: layer)
        CATransaction.begin()
        CATransaction.setAnimationDuration(flight.duration)
        CATransaction.setAnimationTimingFunction(timing)
        // CA 的完成回调在动画被**替换**时也会触发（纠偏就是替换），所以要认代次：
        // 光认 `token` 会让纠偏那一下当场把飞行结束掉。
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.landingAnimation == generation else { return }
                self.finishLanding(token: token)
            }
        }
        // 终点对齐到设备像素：位图 1:1 落格，落地一帧和条上那张卡一样清晰
        //（`DragCarrierGeometry.pixelAligned`；owner 2026-08-19 报「落位前一帧糊、最后一帧突然清晰」）。
        layer.position = destination
        layer.transform = Self.scaleTransform(flight.toScale)
        layer.opacity = flight.toOpacity        // 飞回卡槽 = 1（文件夹拖出条外的淡出要还原）；吸进胶囊 = 0
        CATransaction.commit()
        // 时间线：起飞时刻取事务开始前那一刻（`now`）。commit 本身是一次到 WindowServer 的往返，
        // 取 commit 之后会比屏幕慢几 ms（抽帧实测重抓时往回退 3pt）；宁可估得略靠前——
        // 冻结点比屏幕多走一两 pt 看着就是「又动了一下停住」，往回退才是跳。
        flightTimeline = FlightTimeline(beganAt: now, start: start,
                                        destination: LayerPose(position: destination, scale: flight.toScale),
                                        duration: flight.duration, curve: flight.curve)
        scheduleLandingFinish(token: token)
    }

    /// 图层的一组呈现值：位置（面板坐标）+ 缩放。载体不带投影，所以这里没有投影项。
    private struct LayerPose {
        var position: CGPoint
        var scale: CGFloat
    }

    /// 这一段飞行的时间线。**「图标此刻在哪」按它算，不读 `presentation()`**：后者比屏幕落后约两帧
    ///（飞行起步段每帧十几 pt），按它冻结会往回跳（2026-08-19 抽帧实测 15pt）；渲染服务器和这里
    /// 用同一条曲线、同一个时钟、同一个 beginTime，自己算才对得上。纠偏重发时起点取当时的估值。
    private struct FlightTimeline {
        let beganAt: CFTimeInterval
        let start: LayerPose
        let destination: LayerPose
        let duration: TimeInterval
        let curve: DragLandingCurve
        func pose(at time: CFTimeInterval) -> LayerPose {
            let p = CGFloat(curve.progress(at: (time - beganAt) / duration))
            return LayerPose(position: CGPoint(x: start.position.x + (destination.position.x - start.position.x) * p,
                                               y: start.position.y + (destination.position.y - start.position.y) * p),
                             scale: start.scale + (destination.scale - start.scale) * p)
        }
    }
    private var flightTimeline: FlightTimeline?

    /// 飞行中的图标此刻的呈现值；不在飞行就 nil。
    private func landingPose(at time: CFTimeInterval) -> LayerPose? {
        guard let landing, let timeline = flightTimeline else { return nil }
        // 吸进胶囊的图标不接受重抓 / 点击：它代表的那张卡已经不在条上了。
        guard landing.kind == .returnToSlot else { return nil }
        return timeline.pose(at: time)
    }

    private static func scale(of transform: CATransform3D) -> CGFloat { transform.m11 }

    /// 落地精度自检：载体最后停在哪、和卡槽差多少。> 0.5pt 就说明落地会看见一下跳。
    private func recordLandingDelta() {
        guard HoverTrace.isEnabled, let layer = carrierLayer, let flight = landing?.flight else { return }
        let want = DragCarrierGeometry.panelPoint(fromTopLeft: flight.to, panelFrame: carrierScreenFrame)
        let got = layer.presentation()?.position ?? layer.position
        HoverTrace.landingDelta(dx: got.x - want.x, dy: got.y - want.y)
    }

    private static func scaleTransform(_ scale: CGFloat) -> CATransform3D {
        CATransform3DMakeScale(scale, scale, 1)
    }

    /// **载体停在哪儿，都要落在设备像素格上。**
    ///
    /// 位图落在半个像素上会被系统重采样，看起来就是「图标比条上那张卡糊一点」
    ///（owner 2026-08-19：「拖动图标时图标有一个微弱的模糊，落地后才消失」）。
    /// 之前只有归位飞行的**终点**对齐过，所以整段跟手都是糊的、一落地就清晰——同一个病的两半。
    ///
    /// 量化步长是一个设备像素（2x 屏 0.5pt），肉眼看不出来，而这正是原生拖动清晰的原因。
    /// 缩放态（悬在投放区的 0.82、起拖姿态的 1.023）本来就要重采样，对齐它无害也无益，
    /// 但统一走这里省得两份算法漂移。
    private func alignedCenter(_ center: CGPoint, on layer: CALayer) -> CGPoint {
        DragCarrierGeometry.pixelAligned(center: center,
                                         size: layer.bounds.size,
                                         scale: carrierSnapshot?.scale ?? 2)
    }

    private func makeCarrierSurface(frame: CGRect) -> CarrierSurface {
        // NonConstrainingPanel: 载体铺满**一块屏**（不是并集，见 `DragCarrierGeometry.screenFrame`），
        // 被系统约束到可用区会错位，同 dock/胶囊。
        let panel = NonConstrainingPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        // **层级必须在 `isFloatingPanel` 之后设，而且要比任务条/抽屉/胶囊（都是 `.floating`）高一级。**
        // 原来写在前面的 `.popUpMenu` 被 `isFloatingPanel = true` 静默改回了 `.floating`（AppKit 语义：
        // 浮动面板就是 floating 层）——载体和任务条同层，谁后 order front 谁在上。任务条在几处会
        // 重新 order front（显隐周期、换屏、初始布局），实测 2026-08-19：松手后约 0.5s 任务条跳到
        // 载体之上，正在飞回卡槽的副本一进任务条面板的矩形（含 20pt 投影边距）就被整个遮住，
        // 卡显形前有 250ms 什么都看不见——owner 报的「落位消失/重影」；拖动中指针离开又回到条上
        // 也会同样被遮，就是「拖快了图标消失」。高一级之后与 ordering 无关，永远压在我们自己
        // 的面板之上，又不越过系统菜单。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 1.0, alpha: 0.0)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true          // 纯绘制，不抢事件；唯一例外见 `refreshLandingGrabState`
        panel.alphaValue = 1                     // 恒 1：再没有任何面板级 alpha 动画
        // 面板的 contentView 是一块普通全屏 NSView（AGENTS「面板不得拿 hosting 当 contentView」），
        // 载体是挂在它图层里的一个子图层。非 flipped 视图 → 子图层坐标是左下原点、y 向上。
        let container = CarrierContainerView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        container.autoresizingMask = [.width, .height]
        let layer = CALayer()
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.isOpaque = false
        layer.allowsEdgeAntialiasing = true
        // **不要在这里 `layer.actions = […NSNull]` 一刀切关掉隐式动作**：归位飞行与进出投放区的缩放
        // 走的正是「事务里设时长 + 直接赋值」的隐式动画，全关掉它们就变成瞬移（2026-08-19 踩过一次：
        // 松手后图标一帧跳回卡槽，飞行没了）。瞬时赋值统一包在 `instantly` 里关动画即可。
        // **载体一路都不带投影**（owner 2026-08-19：条上的图标不投影，拎起来的这份也不投影）。
        // `CALayer` 默认就不画，所以这里一个 shadow 属性都不设——一旦有人设了半个，
        // 落位交接就又会出现「位图的投影比卡的淡」那种台阶（那正是上一轮 +2.85 的成因）。
        container.layer?.addSublayer(layer)
        // 飞行可打断：图标当前帧就是命中区，按下 = 从此刻位置接着拖（见 `regrabLanding`）。
        container.grabRegion = { [weak self] in self?.landingIconPanelFrame() }
        container.onGrab = { [weak self] point in self?.regrabLanding(at: point) }
        panel.contentView = container
        return CarrierSurface(panel: panel, container: container, layer: layer, frame: frame)
    }

    /// 弹簧开抽屉后把载体重新提到最前——新开的抽屉 orderFront 后可能盖住先于它创建的载体（owner 2026-06-21
    /// 报告"拖进弹簧开的抽屉时浮动图标消失"）。仅拖动进行中才动。
    func bringCarrierToFront() {
        guard draggingPayload != nil, let c = carrierPanel else { return }
        c.orderFrontRegardless()
    }

    // MARK: - 监视器 + 轮询兜底

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self else { return ev }
            let loc = NSEvent.mouseLocation
            if ev.type == .leftMouseUp { self.update(loc); self.endDrag() }
            else { self.update(loc) }
            return ev
        }
        // global 实测全程 0 次（隐式抓取锁给本 app），留作廉价兜底。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            if ev.type == .leftMouseUp { self.update(loc); self.endDrag() }
            else { self.update(loc) }
        }
    }

    private func removeMonitors() {
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    private func startPoll() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.draggingPayload != nil else { return }
                if NSEvent.pressedMouseButtons == 0 { self.endDrag() }
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}

// 载体视图（DragCarrierView / DrawerDragIconView）在 App/Composition/DragCarrierView.swift——
// 它牵 ChipView/PinnedFolderChip 等 UI 依赖,拆出去让本控制器可被测试 target 本地编译。
