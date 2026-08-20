import AppKit
import XCTest

final class WindowTitleTooltipTests: XCTestCase {
    func testFontUsesRenderedSizeRules() {
        XCTAssertEqual(WindowTitleTextMetrics.font(scale: 0.5).pointSize, 10)
        XCTAssertEqual(WindowTitleTextMetrics.font(scale: 1).pointSize, 12)
        XCTAssertEqual(WindowTitleTextMetrics.font(scale: 1.5).pointSize, 18)
    }

    func testFontUsesRoundedSystemDesign() {
        XCTAssertTrue(WindowTitleTextMetrics.font(scale: 1).fontName.contains("Rounded"))
    }

    func testIntrinsicWidthTracksScale() {
        let title = "activity-list.vue - project"
        let small = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: 0.5)
        let regular = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: 1)
        let large = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: 1.5)

        XCTAssertLessThan(small, regular)
        XCTAssertLessThan(regular, large)
    }

    func testInStripTitleWidthTracksTheDockScale() {
        // 条内标题宽度随任务条缩放，截断判定必须用同一个宽度——两处各写死 140 就会出现
        // 「看着截断了却不弹 tooltip」（或反之）。这一条只管**条内**那段文字；
        // 气泡自己的缩放锁在 `testMediumTierKeepsTheNativePixelsAndOtherTiersScaleWholesale`。
        for tier in DockSize.allCases {
            XCTAssertEqual(WindowTitleTextMetrics.maximumWidth(for: tier.scale),
                           WindowTitleTextMetrics.maximumWidth * tier.scale, accuracy: 0.001)
        }
        // 中档必须与历史字面值一致。
        XCTAssertEqual(WindowTitleTextMetrics.maximumWidth(for: 1.0), 140)
    }

    // 截断判定（`isTruncated` / `needsTooltip`）连同它的三条测试于 2026-08-17 删除：
    // 那是「标题被截断才弹 tooltip」的门槛，气泡先改成悬停就弹、后又改成只写应用名，
    // 生产代码里已无调用方。别按旧签名把它们恢复回来。
}

/// 悬停时 chip 的几何**恒定不动**——应用名 2026-08-16 改成了原生 Dock 那种「图标正上方的
/// 气泡」，chip 内部不再需要为它腾地方。
///
/// 这里以前锁的是 `ChipSubtitleMetrics` 那套位移公式（对着更早的 `VStack(spacing: 2)` 布局
/// 解方程得来的 `pillHoverShift = 3s - 1 - Hs/2` 之类）。**那个类型和它的整组测试随功能
/// 一起删除了，不要按旧公式恢复。**
final class ChipHoverGeometryTests: XCTestCase {
    private let tiers: [CGFloat] = DockSize.allCases.map(\.scale)

    func testHoverDoesNotMoveAnyGeometry() {
        for scale in tiers {
            let rest = ChipHoverVisual.resolve(progress: 0, scale: scale)
            let hover = ChipHoverVisual.resolve(progress: 1, scale: scale)
            XCTAssertEqual(rest.bareIconSize, hover.bareIconSize, accuracy: 0.001,
                           "悬停不该缩图标（scale=\(scale)）")
            XCTAssertEqual(rest.pillHeight, hover.pillHeight, accuracy: 0.001,
                           "悬停不该缩药丸（scale=\(scale)）")
            XCTAssertEqual(rest.pillIconSize, hover.pillIconSize, accuracy: 0.001,
                           "悬停不该缩药丸内的图标（scale=\(scale)）")
        }
    }

    /// 唯一还随悬停变化的量：药丸底与描边的提亮。
    func testOnlyEmphasisTracksHover() {
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 0, scale: 1).emphasisProgress, 0)
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 1, scale: 1).emphasisProgress, 1)
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 0.5, scale: 1).emphasisProgress, 0.5)
    }

    func testProgressIsClamped() {
        XCTAssertEqual(ChipHoverVisual.resolve(progress: -3, scale: 1).progress, 0)
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 9, scale: 1).progress, 1)
    }

    func testSizesTrackTheTier() {
        for scale in tiers {
            let v = ChipHoverVisual.resolve(progress: 0, scale: scale)
            XCTAssertEqual(v.bareIconSize, ChipPillMetrics.bareIconSlot * scale, accuracy: 0.001)
            XCTAssertEqual(v.pillHeight, ChipPillMetrics.boxHeight * scale, accuracy: 0.001)
            XCTAssertEqual(v.pillIconSize, ChipPillMetrics.iconSlot * scale, accuracy: 0.001)
        }
    }
}

/// 探针改量卡片矩形之后，tooltip 的锚点契约（pill rect）靠这组常量推出来，
/// 所以推导必须与渲染用的是同一份数值。
final class ChipPillMetricsTests: XCTestCase {
    func testWidthMatchesTheRenderedComposition() {
        let title = "psd-文件"
        let scale: CGFloat = 1
        let titleWidth = min(WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale),
                             WindowTitleTextMetrics.maximumWidth(for: scale))
        let expected = (2 * 10 + 22 + 6) * scale + ceil(titleWidth)
        XCTAssertEqual(ChipPillMetrics.width(title: title, scale: scale), expected, accuracy: 0.001)
    }

    func testWidthIsCappedByTheTitleMaximum() {
        let long = String(repeating: "very-long-window-title-", count: 20)
        let scale: CGFloat = 1
        let expected = (2 * 10 + 22 + 6) * scale + ceil(WindowTitleTextMetrics.maximumWidth(for: scale))
        XCTAssertEqual(ChipPillMetrics.width(title: long, scale: scale), expected, accuracy: 0.001)
    }

    // MARK: - 安静档悬停放大：按卡宽收敛

    /// **主锁**：图标卡的观感一个像素不变。
    ///
    /// 封顶规则在 40pt 卡上算出 1.15，被 `quietHoverScale` 上限截回 1.10 ——
    /// 收敛只该咬到宽到会挤的卡。四种图标卡（窗口卡 / kept / 消息区 / 中转格）都是这个宽度。
    func testIconCardKeepsTheAcceptedFullScale() {
        for tier in DockSize.allCases {
            let width = ChipPillMetrics.cardWidth * tier.scale
            XCTAssertEqual(
                ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: tier.scale),
                ChipPillMetrics.quietHoverScale, accuracy: 0.0001,
                "档位 \(tier) 的图标卡必须仍是 1.10"
            )
        }
    }

    /// 任何卡宽下，每侧向外长出的量都不超预算——这才是「不再挤」的直接判据。
    /// （倍数本身是多少无所谓，用户看见的是边缘位移。）
    func testNoCardGrowsBeyondTheEdgeBudget() {
        for tier in DockSize.allCases {
            let budget = ChipPillMetrics.quietHoverEdgeBudget * tier.scale
            for base in [40, 60, 96, 140, 168.5, 196, 400] as [CGFloat] {
                let width = base * tier.scale
                let s = ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: tier.scale)
                let growthPerSide = width * (s - 1) / 2
                XCTAssertLessThanOrEqual(growthPerSide, budget + 0.0001,
                                         "卡宽 \(base) 档位 \(tier) 每侧外扩 \(growthPerSide) 超预算")
            }
        }
    }

    /// 两张满宽标题卡相邻：放大之后仍要剩得下缝。
    /// 静息可见缝 = `2 * titledCardInset + chipSpacing` = 10pt，预算 3pt → 至少剩 7pt。
    func testTwoWidestTitledCardsStillLeaveAVisibleGap() {
        let scale: CGFloat = 1
        let longTitle = String(repeating: "very-long-window-title-", count: 20)
        let cardWidth = ChipPillMetrics.width(title: longTitle, scale: scale)
            + 2 * ChipPillMetrics.titledCardInset * scale
        let restingGap = 2 * ChipPillMetrics.titledCardInset * scale + 2 /* Style.chipSpacing */
        let s = ChipPillMetrics.quietHoverScale(forCardWidth: cardWidth, scale: scale)
        let remaining = restingGap - cardWidth * (s - 1) / 2

        XCTAssertEqual(restingGap, 10, accuracy: 0.001, "静息缝的构成变了，这条判据要跟着重算")
        XCTAssertGreaterThanOrEqual(remaining, 7 - 0.001,
                                    "放大后只剩 \(remaining)pt，宽卡又会挤到邻居")
    }

    /// 未读角标的尺寸：中档逐字等于历史字面值，其余档位整体跟着 `scale` 走。
    ///
    /// 改成缩放前这四个数是写死的，四个档位一样大——和悬停气泡是同一类漏网。
    func testBadgeMetricsKeepTheMediumLiteralsAndScaleWithTheTier() {
        XCTAssertEqual(ChipPillMetrics.badgeFontSize, 10)
        XCTAssertEqual(ChipPillMetrics.badgeMinimumSize, 16)
        XCTAssertEqual(ChipPillMetrics.badgeHorizontalPadding, 5)
        XCTAssertEqual(ChipPillMetrics.badgeTopOffset, 5)
        // 中档 scale 恒为 1，所以「乘 scale」在中档就是原值——这条同时锁住那个恒等式。
        XCTAssertEqual(DockSize.medium.scale, 1.0, accuracy: 0.0000001)
    }

    /// 宽度为 0（还没量到）不能算出 NaN / 无穷大。
    func testZeroWidthFallsBackToTheCap() {
        XCTAssertEqual(ChipPillMetrics.quietHoverScale(forCardWidth: 0, scale: 1),
                       ChipPillMetrics.quietHoverScale)
    }

    /// 药丸在卡内水平居中 → midX 直接沿用卡片的；竖向全部来自常量。
    func testPillRectIsHorizontallyCenteredOnTheCard() {
        let card = CGRect(x: 100, y: 200, width: 180, height: 52)
        let rect = ChipPillMetrics.pillRect(inCard: card, title: "psd-文件", scale: 1)
        XCTAssertEqual(rect.midX, card.midX, accuracy: 0.001)
    }

    /// 屏幕坐标 y 向上：静息态药丸顶边 = 卡片顶边下方 `boxTopInset`。
    func testRestPillRectSitsBoxTopInsetBelowTheCardTop() {
        let card = CGRect(x: 0, y: 0, width: 180, height: ChipPillMetrics.chipHeight)
        let rect = ChipPillMetrics.pillRect(inCard: card, title: "psd-文件", scale: 1)
        XCTAssertEqual(rect.maxY, card.maxY - ChipPillMetrics.boxTopInset, accuracy: 0.001)
        XCTAssertEqual(rect.height, 34, accuracy: 0.001)
    }

}


final class ScreenRectReaderTests: XCTestCase {
    private final class Task: ScreenRectDeliveryTask {
        private let action: () -> Void
        private(set) var isCancelled = false

        init(action: @escaping () -> Void) { self.action = action }
        func cancel() { isCancelled = true }
        func run() { if !isCancelled { action() } }
        func forceRun() { action() }
    }

    private final class Scheduler: ScreenRectDeliveryScheduling {
        struct Scheduled {
            let delay: TimeInterval
            let task: Task
        }

        private(set) var scheduled: [Scheduled] = []

        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScreenRectDeliveryTask {
            let task = Task(action: action)
            scheduled.append(Scheduled(delay: delay, task: task))
            return task
        }

        func runAll() {
            let tasks = scheduled
            scheduled.removeAll()
            tasks.forEach { $0.task.run() }
        }
    }

    func testReportsEveryDistinctRectInOrder() {
        let scheduler = Scheduler()
        var reported: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { reported.append($0) }
        )
        let a = CGRect(x: 1, y: 2, width: 3, height: 4)
        let b = CGRect(x: 2, y: 3, width: 4, height: 5)

        view.enqueue(a)
        view.enqueue(a)
        view.enqueue(b)
        view.enqueue(a)
        scheduler.runAll()

        XCTAssertEqual(reported, [a, b, a])
        XCTAssertEqual(scheduler.scheduled.count, 0)
    }



    func testPendingDeliveryUsesTheLatestCallback() {
        let scheduler = Scheduler()
        var old: [CGRect] = []
        var latest: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { old.append($0) }
        )
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)

        view.enqueue(rect)
        view.update(onChange: { latest.append($0) })
        scheduler.runAll()

        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(latest, [rect])
    }

    func testDetachCancellationBlocksPendingCallbacks() {
        let scheduler = Scheduler()
        var reported: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { reported.append($0) }
        )
        view.enqueue(CGRect(x: 1, y: 2, width: 3, height: 4))
        view.cancelPendingDelivery()
        scheduler.runAll()
        XCTAssertTrue(reported.isEmpty, "detach 之后排队的投递必须作废")
    }


    /// 窗口移动 / 换屏必须重新上报。
    ///
    /// `layout()` 只在视图树变化时触发，把面板搬到另一块屏或上下移动都不改视图树——
    /// 于是每张卡缓存的屏幕矩形停在旧位置，气泡会弹到没有任务条的那块屏上
    /// （owner 2026-08-17 报）。这条锁住"装了观察者、而且拆得掉"。
    func testWindowMovementTriggersAFreshReport() {
        let scheduler = Scheduler()
        var reported: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { reported.append($0) }
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        view.frame = CGRect(x: 10, y: 10, width: 50, height: 20)
        scheduler.runAll()
        reported.removeAll()

        window.setFrameOrigin(CGPoint(x: 400, y: 300))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        scheduler.runAll()
        XCTAssertFalse(reported.isEmpty, "窗口移动后必须补一次上报")

        // 拆掉之后不能再响，否则观察者会活过视图。
        view.removeFromSuperview()
        reported.removeAll()
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        scheduler.runAll()
        XCTAssertTrue(reported.isEmpty, "已 detach 的探针不该再上报")
    }

    /// 气泡尺寸是 2026-08-17 从原生 macOS 26 Dock 的截图上逐像素量出来的，不是设计出来的。
    /// 这条锁住那组数——要改先重新截图重新量，别凭手感调。
    func testBubbleMetricsMatchTheMeasuredNativeDockLabel() {
        let native = WindowTitleTooltipStyle.native
        XCTAssertEqual(native.height, 26)
        XCTAssertEqual(native.fontSize, 14)
        XCTAssertEqual(native.horizontalPadding, 13)
        XCTAssertEqual(native.tailWidth, 23)
        XCTAssertEqual(native.tailHeight, 6.5)
        XCTAssertEqual(native.tipGap, 6.5)
        XCTAssertEqual(native.maximumWidth, 360)
        // 中段直边的斜率（半宽/深度）实测 ≈1.17；圆头存在的证据就是它外推不到底。
        let slope = (native.tailShoulderHalfWidth - native.tailTipHalfWidth)
            / (native.tailTipDepth - native.tailShoulderDepth)
        XCTAssertEqual(slope, 1.17, accuracy: 0.05)
        let extrapolated = native.tailTipDepth + native.tailTipHalfWidth / slope
        XCTAssertGreaterThan(extrapolated, native.tailHeight,
                             "直边外推必须落在实际尖端之下——差的那截才是圆头")
        // **胶囊，不是圆角矩形**：圆角必须正好是高的一半。
        XCTAssertEqual(native.cornerRadius, native.height / 2)
    }

    /// 气泡随任务条档位缩放（owner 2026-08-17），但**中档必须一个像素不动**。
    ///
    /// 这条同时是那个分母陷阱的回归锁：系数得用 `DockSize.scale`（已按中档归一），
    /// 中档恒等于 1.0。若谁改成「条高 ÷ 某个字面量」，中档立刻不再是 1，签收过的原生像素就被改掉。
    func testMediumTierKeepsTheNativePixelsAndOtherTiersScaleWholesale() {
        XCTAssertEqual(DockSize.medium.scale, 1.0, accuracy: 0.0000001)
        let medium = WindowTitleTooltipStyle(scale: DockSize.medium.scale)
        XCTAssertEqual(medium, WindowTitleTooltipStyle.native)

        for tier in DockSize.allCases {
            let style = WindowTitleTooltipStyle(scale: tier.scale)
            XCTAssertEqual(style.height, 26 * tier.scale, accuracy: 0.001)
            XCTAssertEqual(style.fontSize, 14 * tier.scale, accuracy: 0.001)
            XCTAssertEqual(style.tipGap, 6.5 * tier.scale, accuracy: 0.001)
            XCTAssertEqual(style.horizontalPadding, 13 * tier.scale, accuracy: 0.001)
            // 缩放后仍是胶囊。
            XCTAssertEqual(style.cornerRadius, style.height / 2, accuracy: 0.001)
        }
    }

    /// 尾巴那顶圆帽在任意档位都还在（直边外推必须过冲真实尖端）。
    func testTailStaysRoundedAtEveryTier() {
        for tier in DockSize.allCases {
            let style = WindowTitleTooltipStyle(scale: tier.scale)
            let slope = (style.tailShoulderHalfWidth - style.tailTipHalfWidth)
                / (style.tailTipDepth - style.tailShoulderDepth)
            let extrapolated = style.tailTipDepth + style.tailTipHalfWidth / slope
            XCTAssertGreaterThan(extrapolated, style.tailHeight, "档位 \(tier) 的尖端不该变尖")
        }
    }

    /// 尖角必须画在同一条闭合路径里：叠一个三角形会在接缝处交叉出一条横线。
    /// 这里验证形状确实向下伸出尖角，且尖端落在水平中心。
    func testShapeExtendsADownwardTailAtTheHorizontalCentre() {
        let style = WindowTitleTooltipStyle.native
        let rect = CGRect(x: 0, y: 0, width: 85, height: style.height + style.tailHeight)
        let box = WindowTitleTooltipShape(style: style).path(in: rect).boundingRect
        XCTAssertEqual(box.maxY, rect.maxY, accuracy: 0.5, "尖端要顶到形状底边")
        XCTAssertEqual(box.width, rect.width, accuracy: 0.5, "主体要占满整宽")

        // 尖端所在那一行只剩很窄一条，且居中。
        let tip = WindowTitleTooltipShape(style: style).path(in: rect)
        let nearTip = tip.boundingRect
        XCTAssertEqual(nearTip.midX, rect.midX, accuracy: 0.5)
        XCTAssertFalse(tip.contains(CGPoint(x: rect.minX + 2, y: rect.maxY - 1)),
                       "尖角两侧必须是空的，不能是一整条底边")
        XCTAssertTrue(tip.contains(CGPoint(x: rect.midX, y: rect.maxY - 1)),
                      "中心那一竖必须还在形状里")
    }
}

/// 图标中心间距：原生实测的 42pt，而且和条内实际用的间距是同一个常量。
///
///（原来这里还有一整套 `WindowTitleTooltipOwnership` 的用例：谁有资格占用那唯一一块气泡面板、
/// 跨缝时要不要留着。2026-08-17 把悬停改成「整条一块跟踪区 + 按位置反查」之后，
/// 气泡只有一个发送方，抢占在结构上不可能发生，那套判定连同用例一起删了；
/// 缝隙与边界现在锁在 `StripHoverResolutionTests` 里。）
final class ChipIconPitchTests: XCTestCase {
    func testIconPitchMatchesTheNativeDock() {
        XCTAssertEqual(ChipPillMetrics.iconPitch, 42)
        XCTAssertEqual(ChipPillMetrics.iconPitch,
                       ChipPillMetrics.cardWidth + ChipPillMetrics.chipSpacing)
    }
}
