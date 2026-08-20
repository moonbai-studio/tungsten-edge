import AppKit
import Combine
import XCTest

/// 跨面板转换状态机的转换/回滚/落定/取消全矩阵（Codex 评审 2026-07-11 P2-6）。
/// 用真 store（临时 UserDefaults）+ 固定投放区 stub 驱动 DragController 本体（本地编译进测试
/// target,同 store 一致）；几何触发（何时进/出区）归视图层,这里只验证每个转换动作前后的成员关系与载荷。
@MainActor
final class DragControllerConversionTests: XCTestCase {

    private var drawer: DrawerStore!
    private var kept: KeptAppStore!
    private var messaging: MessagingAppStore!
    private var controller: DragController!
    /// 固定投放区：命中判定只看 beginDrag 的起点坐标。
    private let dropZone = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let insideZone = CGPoint(x: 50, y: 50)
    private let outsideZone = CGPoint(x: 500, y: 500)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared   // 无宿主 app 的测试 bundle 里创建 NSPanel 前先起 AppKit
        let suite = "test-dragconv-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        drawer = DrawerStore(defaults: defaults)
        kept = KeptAppStore(defaults: defaults)
        messaging = MessagingAppStore(defaults: defaults)
        controller = DragController(
            drawerStore: drawer,
            messagingStore: messaging,
            keptAppStore: kept,
            dropZonesProvider: { [dropZone] _ in [dropZone] },
            screensProvider: { NSScreen.screens }
        )
    }

    override func tearDown() {
        controller.cancelDrag()   // 幂等收尾，防面板/监视器泄漏到下个用例
        super.tearDown()
    }

    private func payload(_ source: DragSource, _ bid: String) -> DragPayload {
        DragPayload(source: source, id: bid, bundleID: bid, item: nil,
                    visualKind: .drawerIcon, canExternalDrop: true)
    }

    /// 起拖必须带一张载体位图（拍不出来就不起拖，见 `DragController.beginDrag`）。
    /// 这些用例验的是成员关系与载荷，位图画什么无所谓，给一张 1×1 的就行。
    private func stubSnapshot(side: Int = 1) -> CarrierSnapshot {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 4 * side,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CarrierSnapshot(image: context.makeImage()!,
                               size: CGSize(width: side, height: side),
                               contentSize: CGSize(width: side, height: side),
                               scale: 1)
    }

    private func begin(_ source: DragSource, _ bid: String, at point: CGPoint) {
        controller.beginDrag(payload: payload(source, bid), startScreenLocation: point,
                             grabOffset: .zero, sourceScreenRect: .zero, pose: .resting,
                             snapshot: stubSnapshot())
    }

    /// 等一小段真实时间（跑 run loop），给 `DragLandingPlan.pickUpSettle` 那种按时间的推迟用。
    private func settle(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// 跑 run loop 直到条件成立（最多 `timeout`）。按时间推迟的那几步用它，别赌一个固定的等待时长。
    private func waitUntil(_ timeout: TimeInterval = 1, _ condition: () -> Bool) {
        let until = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < until {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    // MARK: - 起拖 / 落地的交接顺序（两头都必须「先新后旧」）

    /// **起拖那一帧，条上那张卡不能先藏（没有预备候选时）。**
    ///
    /// 载体是一张新拍的位图，它的第一帧要等一次纹理上传，实测总是比 SwiftUI 藏卡晚一个显示帧
    /// （2026-08-19 录像逐帧：连续三次拖动，每次都在同一相位露一帧「卡槽已空、载体没上屏」）。
    /// 所以没预热过时 `beginDrag` 当轮只把载体摆到卡槽原位，**过两个显示帧**（按时间，不按
    /// run loop 轮次——真机 1ms 一个鼠标事件，下一轮往往还在同一帧里）才同时藏卡 + 抬起。
    func testSlotStaysFilledUntilTheCarrierHasHadAFrame() {
        begin(.strip, "app", at: outsideZone)
        XCTAssertNotNil(controller.draggingPayload, "拖动本身立刻开始")
        XCTAssertNil(controller.hiddenSlotPayload, "但这一轮条上那格还不能空")
        XCTAssertTrue(controller.hoverFrozen, "这几帧悬停原地冻结，卡不能变形")

        // 下一轮 run loop 还不够——那正是第一版露一帧空档的原因。
        let nextTurn = expectation(description: "下一轮 run loop")
        DispatchQueue.main.async { nextTurn.fulfill() }
        wait(for: [nextTurn], timeout: 1)
        XCTAssertNil(controller.hiddenSlotPayload, "下一轮 run loop 仍不放行")

        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "两个显示帧后才空出来")
        XCTAssertFalse(controller.hoverFrozen)
        XCTAssertTrue(controller.hoverSuppressed, "藏卡之后悬停改为压制")
    }

    /// **按下时预备了候选 → 起拖当轮就放行**：纹理早已上传，点亮载体和藏卡同一个提交。
    func testPreparedCandidateArmsImmediately() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "app", sourceScreenRect: slot, snapshot: stubSnapshot())
        controller.beginDrag(payload: payload(.strip, "app"), startScreenLocation: outsideZone,
                             grabOffset: .zero, sourceScreenRect: slot, pose: .resting,
                             snapshot: nil)   // 有候选就不该再拍：这里传 nil 也必须能起拖
        XCTAssertNotNil(controller.draggingPayload)
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "当轮就藏卡")
        XCTAssertFalse(controller.hoverFrozen)
        XCTAssertTrue(controller.hoverSuppressed)
    }

    /// 候选对不上（按的是别的卡）→ 不能拿它冒充，走没有候选那条路。
    func testMismatchedCandidateIsIgnored() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "other", sourceScreenRect: slot, snapshot: stubSnapshot())
        begin(.strip, "app", at: outsideZone)
        XCTAssertNotNil(controller.draggingPayload)
        XCTAssertNil(controller.hiddenSlotPayload, "没有匹配的候选 → 仍要先压着卡")
    }

    /// 松手没起拖 → 候选撤掉，之后起拖不会误用。
    func testClearedCandidateDoesNotArmImmediately() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "app", sourceScreenRect: slot, snapshot: stubSnapshot())
        controller.clearCandidate(payloadID: "app")
        begin(.strip, "app", at: outsideZone)
        XCTAssertNil(controller.hiddenSlotPayload)
    }

    /// 落地那一头**反过来**：`landing` 一清就该让卡显形，载体晚一轮再撤。
    /// 两头不对称，所以 `hiddenSlotPayload` 不能简单等于 `carriedPayload`。
    func testLandingSideIsNotGatedTheSameWay() {
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertNotNil(controller.hiddenSlotPayload)

        controller.endDrag()
        // 没有落点锚点 → 不飞 → landing 为 nil → 卡当轮就该显形
        XCTAssertNil(controller.landing)
        XCTAssertNil(controller.hiddenSlotPayload, "不飞的收尾也要立刻让卡显形")
        XCTAssertTrue(controller.isCarrying, "但载体还没撤，悬停仍要压着")
    }

    /// **落地之后那一张卡的悬停要按住**，直到指针真的动了：卡刚以 1.0 停稳就重判悬停，
    /// 安静档会当场往上长 1.10（owner 2026-08-19「落位抖动」）。这里指针不动，按住期就一直在。
    ///
    /// 按住的是**它一张**，不是整条任务条——见下一条用例。
    func testHoverStaysHeldAfterLandingUntilThePointerMoves() {
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        controller.endDrag()
        XCTAssertEqual(controller.hoverHoldPayload?.bundleID, "app")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app")
        // 载体撤掉那一轮之后仍然按着（`carrierRetiring` 已经 false，靠的是 hold）。
        waitUntil { !controller.isCarrying }
        XCTAssertFalse(controller.isCarrying, "载体已经撤了")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app", "但指针没动，它自己仍按住")
        // 兜底上限一到就放开（测试里没法真动指针）。
        waitUntil(DragLandingPlan.hoverHoldMaximum + 1) { controller.hoverHoldPayload == nil }
        XCTAssertNil(controller.hoverHoldPayload)
        XCTAssertNil(controller.hoverExemptPayload)
    }

    /// **整条压制只在「手里真拎着东西」时**；松手之后的归位飞行期，别的卡照常悬停
    ///（owner 2026-08-19：「图标飞行时鼠标划到其他图标上没有悬停效果，要完全落地才有」）。
    func testOnlyTheFlyingCardIsExemptDuringTheReturnFlight() {
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertTrue(controller.hoverSuppressed, "拎着的时候整条不判悬停")

        controller.setLandingAnchor(CGRect(x: outsideZone.x + 200, y: outsideZone.y, width: 40, height: 54),
                                    owner: .strip)
        controller.endDrag()
        XCTAssertNotNil(controller.landing, "起飞了")
        XCTAssertFalse(controller.hoverSuppressed, "飞行期不再整条压制——别的卡要能悬停")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app", "只豁免正在飞的那一张")
    }

    // MARK: - 归位飞行可打断（owner 2026-08-19：「原生和 bestdock 都能打断」）

    private func flyBack(from point: CGPoint) {
        begin(.strip, "app", at: point)
        waitUntil { controller.hiddenSlotPayload != nil }
        // 锚点离指针够远 → 松手起飞。
        controller.setLandingAnchor(CGRect(x: point.x + 200, y: point.y, width: 40, height: 54), owner: .strip)
        controller.endDrag()
    }

    /// 飞行途中重新抓住：飞行结束、变成新拖动、**卡槽连续空着**（`hiddenSlotPayload` 不闪 nil）。
    func testRegrabDuringLandingContinuesTheDragWithoutAGap() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing, "有锚点、位移够 → 起飞")
        XCTAssertNil(controller.draggingPayload)
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "飞行中卡槽空着")

        // 点在图标外 → 抓不住，飞行继续。
        XCTAssertFalse(controller.regrabLanding(at: CGPoint(x: outsideZone.x - 900, y: outsideZone.y - 900)))
        XCTAssertNotNil(controller.landing)

        // 同一张卡的卡槽被按住（不要求命中图标）→ 从图标此刻的位置接着拖。
        XCTAssertTrue(controller.regrabLanding(at: outsideZone, requireHit: false))
        XCTAssertNil(controller.landing, "飞行结束")
        XCTAssertEqual(controller.draggingPayload?.bundleID, "app", "变成新拖动")
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "卡槽连续空着")
        XCTAssertTrue(controller.isCarrying)
        XCTAssertFalse(controller.hoverFrozen, "重抓的载体早就抬起了，不需要起拖那几帧的冻结")
        XCTAssertTrue(controller.hoverSuppressed)
        XCTAssertNil(controller.hoverHoldPayload)

        // 再次松手照常收尾。
        controller.endDrag()
        XCTAssertNil(controller.draggingPayload)
    }

    /// 按在空卡槽上（SwiftUI 手势起拖了同一载荷）也走重抓：不再「瞬收 + 从卡槽重新抬起」。
    func testBeginDragOfTheSameCardDuringLandingRegrabs() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing)
        begin(.strip, "app", at: CGPoint(x: outsideZone.x + 30, y: outsideZone.y))
        XCTAssertNil(controller.landing)
        XCTAssertEqual(controller.draggingPayload?.bundleID, "app")
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "当轮就空着，没有起拖那两帧的门控")
        XCTAssertTrue(controller.carrierArmed)
    }

    /// 别的卡在飞行中被拎起 → 照旧收掉飞行（那是另一张卡，不是重抓）。
    func testBeginDragOfAnotherCardDuringLandingAbortsTheFlight() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing)
        begin(.strip, "other", at: outsideZone)
        XCTAssertNil(controller.landing)
        XCTAssertEqual(controller.draggingPayload?.bundleID, "other")
    }

    /// 重抓后松手没挪 = **点了一下这张卡**：发出点击、图标接着飞回卡槽、成员关系一个都不动。
    func testRegrabThenReleaseWithoutMovingIsAClick() {
        var clicks: [DragPayload] = []
        let sub = controller.carrierClicks.sink { clicks.append($0) }
        defer { sub.cancel() }
        flyBack(from: outsideZone)
        XCTAssertTrue(controller.regrabLanding(at: outsideZone, requireHit: false))
        // 真机上重抓那一下 `pointerMoves` 一发，任务条就把卡槽帧重新报上来；这里替它报。
        controller.setLandingAnchor(CGRect(x: outsideZone.x + 200, y: outsideZone.y, width: 40, height: 54), owner: .strip)
        controller.endDrag()
        XCTAssertEqual(clicks.map(\.bundleID), ["app"])
        XCTAssertNotNil(controller.landing, "点完图标接着飞回卡槽")
        XCTAssertEqual(controller.landing?.kind, .returnToSlot)
        XCTAssertNil(controller.draggingPayload)
        XCTAssertFalse(drawer.contains("app"), "点一下不收纳")
    }

    /// 没有重抓的普通松手不是点击。
    func testOrdinaryReleaseIsNotAClick() {
        var clicks: [DragPayload] = []
        let sub = controller.carrierClicks.sink { clicks.append($0) }
        defer { sub.cancel() }
        flyBack(from: outsideZone)
        XCTAssertTrue(clicks.isEmpty)
    }

    /// 飞完之后就没什么可抓的了。
    func testRegrabAfterTheFlightIsRefused() {
        flyBack(from: outsideZone)
        waitUntil(DragLandingPlan.maximumDuration + 1) { controller.landing == nil }
        XCTAssertNil(controller.landing)
        XCTAssertFalse(controller.regrabLanding(at: outsideZone, requireHit: false))
        XCTAssertNil(controller.draggingPayload)
    }

    // MARK: - 松在胶囊上收纳 = 吸进胶囊（owner 2026-08-19：收纳后图标往任务条那头飘一段再消失）

    private func makeStashingController() -> DragController {
        DragController(drawerStore: drawer, messagingStore: messaging, keptAppStore: kept,
                       dropZonesProvider: { [dropZone] _ in [dropZone] },
                       screensProvider: { NSScreen.screens },
                       stashTargetProvider: { CGRect(x: 40, y: 40, width: 20, height: 20) })
    }

    func testStripDropOnCapsuleFliesIntoTheCapsuleAndNeverRetargets() {
        let stashing = makeStashingController()
        defer { stashing.cancelDrag() }
        stashing.beginDrag(payload: payload(.strip, "app"), startScreenLocation: insideZone,
                           grabOffset: .zero, sourceScreenRect: .zero, pose: .resting, snapshot: stubSnapshot())
        waitUntil { stashing.hiddenSlotPayload != nil }
        XCTAssertTrue(stashing.isOverDropZone)
        stashing.endDrag()
        XCTAssertTrue(drawer.contains("app"), "照常收纳")
        guard let landing = stashing.landing else { return XCTFail("要有吸进胶囊的飞行") }
        XCTAssertEqual(landing.kind, .stash)
        XCTAssertEqual(landing.flight.toOpacity, 0)
        XCTAssertEqual(landing.flight.toScale, DragLandingPlan.stashScale)
        let destination = landing.flight.to
        // 收纳后一两帧任务条还会把那格的旧帧报上来——吸进胶囊的飞行不许被拉回去。
        stashing.setLandingAnchor(CGRect(x: 500, y: 8, width: 40, height: 54), owner: .strip)
        XCTAssertEqual(stashing.landing?.flight.to, destination)
        // 也抓不住、点不了：那张卡已经不在条上了。
        XCTAssertFalse(stashing.regrabLanding(at: insideZone, requireHit: false))
    }

    /// 不知道胶囊在哪（默认 provider）→ 不飞、瞬时收尾，**不能**退回飞向已经不存在的卡槽。
    func testStashWithoutACapsuleFrameDoesNotFlyBackToTheSlot() {
        begin(.strip, "app", at: insideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        controller.setLandingAnchor(CGRect(x: 500, y: 8, width: 40, height: 54), owner: .strip)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertNil(controller.landing)
    }

    // MARK: - 进抽屉体换位图 + 重新锚定（owner 2026-08-19：进抽屉后大卡压在抽屉边上）

    /// `reanchor: true`：抓取偏移按新旧位图尺寸比例缩放，指针停在图标上同一个相对位置。
    func testReanchoredSnapshotScalesTheGrabOffset() {
        controller.beginDrag(payload: payload(.strip, "app"), startScreenLocation: outsideZone,
                             grabOffset: CGSize(width: 10, height: -6), sourceScreenRect: .zero,
                             pose: .resting, snapshot: stubSnapshot(side: 4))
        waitUntil { controller.hiddenSlotPayload != nil }
        waitUntil { controller.carrierLifted }       // 抬起之后才允许重锚
        XCTAssertTrue(controller.carrierLifted)
        controller.setCarrierSnapshot(stubSnapshot(side: 2), reanchor: true)
        XCTAssertEqual(controller.grabOffset.width, 5, accuracy: 0.0001)
        XCTAssertEqual(controller.grabOffset.height, -3, accuracy: 0.0001)
        // 换回起拖那张（nil）也按比例还原。
        controller.setCarrierSnapshot(nil, reanchor: true)
        XCTAssertEqual(controller.grabOffset.width, 10, accuracy: 0.0001)
        XCTAssertEqual(controller.grabOffset.height, -6, accuracy: 0.0001)
        // 不重锚的换图不动偏移（抽屉图标转正进任务条那个方向）。
        controller.setCarrierSnapshot(stubSnapshot(side: 8))
        XCTAssertEqual(controller.grabOffset.width, 10, accuracy: 0.0001)
    }

    // MARK: - 消息区 chip → 抽屉（收纳预览）

    func testMessagingToDrawerConvertFlipsPayloadAndAddsMember() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .drawer)
        XCTAssertTrue(controller.isConvertedFromMessaging)
        XCTAssertTrue(messaging.contains("chat"), "收纳不清消息 flag")
    }

    func testMessagingToDrawerRevertRestoresOriginal() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.revertMessagingFromDrawer()
        XCTAssertFalse(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .messaging)
        XCTAssertFalse(controller.isConvertedFromMessaging)
    }

    func testMessagingToDrawerDropInsideDrawerCommits() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.endDrag()   // 抽屉体内松手（不在外部投放区）
        XCTAssertTrue(drawer.contains("chat"), "落定后仍是抽屉成员")
        XCTAssertNil(controller.draggingPayload)
        XCTAssertFalse(controller.isConvertedFromMessaging, "commit 清转换态")
    }

    func testMessagingToDrawerCancelRollsBack() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.cancelDrag()
        XCTAssertFalse(drawer.contains("chat"), "取消恢复原成员关系")
        XCTAssertNil(controller.draggingPayload)
    }

    /// 未进抽屉体、在胶囊投放区松手 → 收纳（等同任务条卡胶囊落点）。
    func testMessagingChipDropOnCapsuleStashes() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
    }

    /// 桌面/文件夹区/live 区（非投放区）松手 → 原地不动。
    func testMessagingChipDropOutsideDoesNothing() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.endDrag()
        XCTAssertFalse(drawer.contains("chat"))
        XCTAssertTrue(messaging.contains("chat"))
    }

    // MARK: - 抽屉里的消息应用 → 消息区（临时释放）

    func testDrawerToMessagingReleaseRemovesMemberAndFlipsPayload() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        XCTAssertFalse(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .messaging)
        XCTAssertTrue(controller.isReleasedToMessaging)
    }

    func testDrawerToMessagingRevertRestoresDrawer() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        controller.revertDrawerToMessaging()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .drawer)
        XCTAssertFalse(controller.isReleasedToMessaging)
    }

    func testDrawerToMessagingDropCommits() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        controller.endDrag()   // 消息区内松手（非投放区）
        XCTAssertFalse(drawer.contains("chat"), "落定：已离开抽屉")
        XCTAssertTrue(messaging.contains("chat"), "消息 flag 原样")
        XCTAssertNil(controller.draggingPayload)
    }

    func testDrawerToMessagingCancelRollsBack() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        controller.cancelDrag()
        XCTAssertTrue(drawer.contains("chat"), "取消回到抽屉")
    }

    /// 消息成员的抽屉图标在任务条（消息区范围外）松手 → 不走降级 unstash,留在抽屉（评审 P1-3）。
    func testMessagingMemberDrawerDragNeverFallbackUnstashes() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: insideZone)   // 投放区内（任务条面板）
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
    }

    /// 非消息成员保持既有降级路径：任务条上松手 → 移出抽屉。
    func testNonMessagingDrawerDragFallbackUnstashes() {
        drawer.add("plain")
        begin(.drawer, "plain", at: insideZone)
        controller.endDrag()
        XCTAssertFalse(drawer.contains("plain"))
    }

    // MARK: - 既有两向的回归（转换态收敛进 CrossPanelConversion 后行为不变）

    func testStripToDrawerConvertRevertPreservesKept() {
        kept.add("app")
        begin(.strip, "app", at: outsideZone)
        controller.convertStripToDrawer()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"))
        XCTAssertTrue(controller.isConvertedFromStrip)
        controller.revertStripFromDrawer()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"), "转换和撤销都不修改 kept")
        XCTAssertEqual(controller.draggingPayload?.source, .strip)
    }

    func testDrawerToStripConvertAndRevertPreservesKept() {
        drawer.add("app"); kept.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertEqual(controller.convertedDrawerBundleID, "app")
        XCTAssertTrue(kept.contains("app"))
        controller.revertDrawerToStrip()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"), "placement 回滚不修改 kept")
        XCTAssertNil(controller.convertedDrawerBundleID)
    }

    func testUncheckedPlacementConversionsRemainUnchecked() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        XCTAssertFalse(kept.contains("app"))
        controller.revertDrawerToStrip()
        XCTAssertFalse(kept.contains("app"))
    }

    func testCancelFromDrawerToStripFiresCancelCallback() {
        drawer.add("app")
        var cancelled = false
        controller.onDrawerToStripCancelled = { cancelled = true }
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.cancelDrag()
        XCTAssertTrue(cancelled)
        XCTAssertTrue(drawer.contains("app"))
    }

    // MARK: - 拖入抽屉落定 → 自动打开 kept（owner 2026-08-06）

    /// 入口 1/4：任务条卡拖进抽屉体，抽屉里松手。
    func testStripCardDroppedInsideDrawerEnablesKept() {
        begin(.strip, "app", at: outsideZone)
        controller.convertStripToDrawer()
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"))
    }

    /// 入口 2/4：任务条卡没进抽屉体，直接落在胶囊上。
    func testStripCardDroppedOnCapsuleEnablesKept() {
        begin(.strip, "app", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"))
    }

    /// 入口 3/4：消息区 chip 拖进抽屉体。消息身份不受影响。
    func testMessagingChipDroppedInsideDrawerEnablesKept() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertTrue(kept.contains("chat"))
        XCTAssertTrue(messaging.contains("chat"))
    }

    /// 入口 4/4：消息区 chip 落在胶囊上。
    func testMessagingChipDroppedOnCapsuleEnablesKept() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertTrue(kept.contains("chat"))
    }

    /// 负样本：抽屉内重排落定 —— 没有新成员加入，不该打开 kept。
    func testDrawerInternalReorderDoesNotEnableKept() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"), "抽屉内重排不是「拖入」")
    }

    /// 负样本：拖进抽屉体又拖出来（撤销）→ 落定时已不在抽屉，不该打开 kept。
    func testStripCardRevertedOutOfDrawerDoesNotEnableKept() {
        begin(.strip, "app", at: outsideZone)
        controller.convertStripToDrawer()
        controller.revertStripFromDrawer()
        controller.endDrag()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"))
    }

    /// 负样本：抽屉图标转正进任务条后又撤回 —— 起拖来源是 `.drawer`，它本来就在抽屉里，
    /// 不是这次拖动带进来的，所以不该打开 kept。
    func testDrawerToStripRevertedDoesNotEnableKept() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.revertDrawerToStrip()
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"))
    }

    /// 负样本：转正进任务条并落定 —— 落定后已不在抽屉。
    func testCommittedDrawerToStripDoesNotEnableKept() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.endDrag()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"))
    }

    /// **语义锁**（owner 2026-08-06）：手动取消勾选后再拖进来会**重新**勾上。
    /// 这不是 bug —— 每次拖入都算重新表达「我要它长期放这里」。要改这条得先问 owner。
    func testDraggingInAgainReEnablesKeptAfterManualUncheck() {
        begin(.strip, "app", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(kept.contains("app"))

        // 拖回任务条（kept 不动），再手动取消勾选。
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.endDrag()
        XCTAssertTrue(kept.contains("app"), "拖出抽屉不关 kept")
        kept.remove("app")

        begin(.strip, "app", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(kept.contains("app"), "再次拖入重新打开 kept")
    }

    /// Finder 永不进 kept —— `KeptAppStore.add` 自带拒收，这里锁住拖拽路径也不例外。
    func testFinderNeverEntersKeptThroughDrop() {
        begin(.strip, "com.apple.finder", at: insideZone)
        controller.endDrag()
        XCTAssertFalse(kept.contains("com.apple.finder"))
    }
}
