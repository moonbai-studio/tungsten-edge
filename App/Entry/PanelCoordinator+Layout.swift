import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · 布局：内容宽度订阅、目标 frame 计算与提交、换档、屏幕参数变化。
// 2026-09-05 从 PanelCoordinator.swift 按 extension 拆出，只搬不改。
extension PanelCoordinator {
    // MARK: - Content Width via fittingSize

    func subscribeSnapshotWidth() {
        snapshotWidthSubscription = runtime.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Defer one run-loop cycle so SwiftUI finishes layout before we read fittingSize
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)   // layoutPanels 内含抽屉重定位；转正期间 relayout 内部钳住宽度
                }
            }
    }

    func subscribeDrawerStoreWidth() {
        drawerStoreWidthSubscription = drawerStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.syncDrawerOrder()
                    self?.relayout(animated: true)
                }
            }
    }

    /// 拖出即合拢（owner 2026-09-03）：条上那张卡离开 / 回到任务条时投影层剔掉 / 放回它，面板宽度
    /// 要跟着动画。任务条宽度**不再钳**（2026-06-22 → 08-20 两轮的宽度冻结机制随之删除）：
    /// 条宽任何时候都等于此刻渲染内容的宽度，收纳松手时条已经是窄的，胶囊 / 抽屉不再在飞行途中滑动。
    /// 写法同 store 订阅（先 receive(on:) 再 async 一轮，让 SwiftUI 先按新投影布局，`fittingSize` 才是新宽度）。
    func subscribeStripSlotCollapse() {
        stripSlotCollapseSubscription = dragController.$stripSlotCollapsed
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // 换档事务里 cancelDrag() 也会走到这里排队一次带动画的布局；用代次吞掉它，
                // 否则会先按新 metrics 动画一次、再被事务的无动画布局跳一次。
                let generation = self.dockSizeChangeGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.dockSizeChangeGeneration else { return }
                    self.relayout(animated: true)
                }
            }
    }

    /// 抽屉顺序按完整 placement 集合收敛，不按当前可见项裁。即便抽屉没开也同步，
    /// 让隐藏成员下一次启动时回到原来的相对位置。
    private func syncDrawerOrder() {
        let members = AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
        drawerOrderStore.sync(members: members)
    }

    func subscribeMessagingStoreWidth() {
        messagingStoreWidthSubscription = messagingStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)
                }
            }
    }

    func subscribeKeptAppStore() {
        keptAppStoreSubscription = keptAppStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)
                }
            }
    }

    func subscribeRunningApplicationStore() {
        runningApplicationStoreSubscription = runningApplicationStore.$runningBundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
    }

    func subscribeSettings() {
        edgeDelaySubscription = settingsStore.$edgeAutoHideDelay
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcilePanelVisibility()
                self?.onHoverMonitorsNeedReconcile?()  // 边缘隐藏开关变了：监视器是否还有存在的必要
            }
        // 显示位置变化：dwell 作废；切到固定档立即搬到固定屏；监视器与唤醒武装按新档重估。
        // dropFirst——启动路径 setupDockPanel 已消费过持久化的档位。
        taskbarScreenPlacementSubscription = settingsStore.$taskbarScreenPlacement
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cancelHoverSwitch()
                if let home = self.resolvedPinnedScreen(), let panel = self.dockPanel,
                   self.panelCurrentScreen(panel: panel) != home {
                    self.layoutPanels(contentWidth: self.lastDesiredWidth, on: home, animated: false)
                }
                self.onHoverMonitorsNeedReconcile?()
                self.reconcilePanelVisibility()
                // ③↔④ 不重建单元，只换投影层的过滤集合：SwiftUI 重画后没有别的路径回到这里量宽
                //（owner 2026-09-02 首轮验收：切档后条长不变，要再点一下窗口才适应）。等这一轮布局跑完再量。
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // 屏表变了（拔插 / 换主屏）：④ 下渲染集合会变（别的屏的卡落回主屏），同样要重新量宽。
        displayTopologySubscription = displayTopologyStore.$table
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // 中转格显隐会改变任务条内容宽度：只让 chip 消失不重排，面板会停在旧宽度，
        // 胶囊和打开着的抽屉也跟着停在旧位置。relayout 必须等 SwiftUI 这一轮布局跑完
        // （fittingSize 那时才是新值），所以再推一轮主队列。
        showShelfSubscription = settingsStore.$showShelf
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.folderPopupWantsOpen, self.openPopupContent == .shelf { self.closeFolderPopup() }
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        dockSizeSubscription = settingsStore.$dockSize
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.beginDockSizeChange() }
    }

    /// 换档是一次**事务**，不是普通的内容变化：面板高度、胶囊宽度、条内每个 chip 的尺寸同时变，
    /// 中途任何一次动画布局都会把三个面板摆到半新半旧的几何上。
    ///
    /// 顺序是有讲究的：
    /// 1. 先收掉所有依附在旧几何上的东西——拖动载体（尺寸随档位）、抽屉（`maxContentHeight`
    ///    是开抽屉时一次性传进根视图的，只挪外框会裁掉内容）、弹窗与 tooltip（锚点已作废）。
    /// 2. `cancelDrag()` 会经 `subscribeStripSlotCollapse` 排队一次**带动画**的 relayout，
    ///    用 generation 门控把它吞掉，否则先按新 metrics 动画一次、再瞬时跳一次。
    /// 3. 等 SwiftUI 用新档位跑完一轮布局（`fittingSize` 那时才是新宽度），再一次性无动画提交。
    ///    换档是瞬时的，不做过渡动画。
    ///
    /// 最大化避让不需要在这里做任何事：`taskbarTop` 由 `panelHeight` 算出、在 Equatable 的
    /// `WindowLiftAvoidanceContext` 里，档位一变 `reconcileContext` 就走既有的还原→重抬路径。
    func beginDockSizeChange() {
        dockSizeChangeGeneration &+= 1
        let generation = dockSizeChangeGeneration

        dragController.cancelDrag()
        dismissWindowTitleTooltip()
        closeFolderPopup(immediately: true)
        if drawerWantsOpen { closeDrawer() }

        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.dockSizeChangeGeneration else { return }
            self.relayout(animated: false)
        }
    }

    /// 任务条目标 frame（按内容宽度、居中、限宽）。
    func dockTargetFrame(contentWidth: CGFloat, on screen: NSScreen) -> NSRect {
        PanelGeometry.dockTargetFrame(contentWidth: contentWidth, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// 胶囊目标 frame（贴任务条右边、纵向居中）。只依赖传入的 dock **目标** frame。
    private func capsuleTargetFrame(forDock dockFrame: NSRect, on screen: NSScreen) -> NSRect {
        PanelGeometry.capsuleTargetFrame(forDock: dockFrame, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// 抽屉目标 frame（右边贴胶囊右边、**底边硬锚在胶囊上方、向上长**）。只依赖传入的胶囊 **目标** frame + 抽屉尺寸。
    /// 关键：底边绝不下移——超过上方可用空间就**封顶高度**（内容由 DrawerView 内部滚动），
    /// 绝不靠"把底边往下压"来塞下，否则压到胶囊/任务条（owner 2026-06-21 报图）。
    func drawerTargetFrame(forCapsule capsuleFrame: NSRect, size: CGSize, on screen: NSScreen) -> NSRect {
        // 底部/左右定位使用 screen.frame，切断与原生 Dock visibleFrame 的耦合；
        // 顶部高度仍由 topUsableY 封顶，避免菜单栏和刘海遮挡。
        PanelGeometry.drawerTargetFrame(forCapsule: capsuleFrame, size: size, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// 统一布局入口：算齐三个目标 frame、存好（给 drop zone / 开抽屉读），三面板同组动画到目标。
    /// 开屏/切屏/多屏悬停传 animated:false；内容变化、收纳/移回、抽屉尺寸变化传 animated:true。
    func layoutPanels(contentWidth: CGFloat, on screen: NSScreen, animated: Bool) {
        guard let dock = dockPanel, let capsule = capsulePanel else { return }
        let panelScreenCGFrame = Self.toCGRect(screen)
        if let transaction = fullscreenIntentTransaction,
           transaction.screenCGFrame != panelScreenCGFrame {
            cancelFullscreenIntent(generation: transaction.generation, reason: "panel-screen-changed")
        }
        let anim = animated && didInitialLayout   // 首帧瞬时,别从初始位置滑过来
        didInitialLayout = true
        onPanelScreenChanged?()

        let dockT = dockTargetFrame(contentWidth: contentWidth, on: screen)
        // 胶囊（连同按它定位的抽屉）**永远**贴着此刻的条目标帧，拖动中也一样：拖出即合拢让条对称收缩，
        // 胶囊跟着一起动（原生 Dock 同样整条重新居中）。2026-09-03 曾在拖动期把胶囊钉在旧目标帧上——
        // 多屏下每个单元都被钉住，B 条变宽压到胶囊、A 条变窄留大缝（owner 当天报）。不要再加锚定。
        let capsuleT = capsuleTargetFrame(forDock: dockT, on: screen)
        // 任务条目标帧一变（宽度/切屏）就关弹窗——不追动画中的锚点（与原生 Dock 行为一致,保 target-frame 纯度）。
        if dockT != lastDockTargetFrame {
            if folderPopupWantsOpen { closeFolderPopup() }
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        }
        lastDockTargetFrame = dockT
        lastCapsuleTargetFrame = capsuleT

        var pairs: [(NSPanel, NSRect)] = []
        if let background = dockGlassBackgroundPanel {
            dockGlassBackgroundView?.apply(
                cornerRadius: taskbarPlateCornerRadius,
                configuration: DockGlassPresentation.configuration
            )
            // 背景窗口贴着可视底板（内容窗口减掉 20pt 阴影透明边）。
            pairs.append((
                background,
                DockLiquidGlassPanelGeometry.backgroundFrame(
                    for: dockT,
                    shadowPadding: Self.shadowPadding
                )
            ))
        }
        pairs.append((dock, dockT))
        pairs.append((capsule, capsuleT))
        if let drawer = drawerPanel, drawer.isVisible, let hosting = drawerContentHost {
            let fitting = hosting.fittingSize
            let drawerSize = CGSize(width: max(fitting.width, 60), height: max(fitting.height, 60))
            lastDrawerSize = drawerSize
            let drawerT = drawerTargetFrame(forCapsule: capsuleT, size: drawerSize, on: screen)
            lastDrawerTargetFrame = drawerT
            pairs.append((drawer, drawerT))
        }
        setFrames(pairs, animated: anim)
    }

    /// 量当前内容宽度后布局（内容变化的统一入口）。
    func relayout(animated: Bool) {
        guard let panel = dockPanel, let hosting = dockContentHost else { return }
        // `fittingSize` 是**主线程上把整条任务条同步布局一遍**，不是读一个缓存值。
        // 探针量的就是它 + 宽度到底变没变（没变还跑动画就是纯浪费）。
        let measureStart = CACurrentMediaTime()
        let measured = hosting.fittingSize.width - 2 * Self.shadowPadding
        HoverTrace.relayout(measureMs: CACurrentMediaTime() - measureStart,
                            width: measured,
                            changed: measured != lastDesiredWidth,
                            animated: animated)
        lastDesiredWidth = measured
        // 跨面板转正进行中 → 任务条宽度钳在拖动前的值（窗口卡溢出/留空而非改变面板宽度，owner 2026-06-22）；
        // 松手/还原解钳后，下一次 relayout 用真实测量值把任务条变到最终长度。
        layoutPanels(contentWidth: measured, on: panelCurrentScreen(panel: panel), animated: animated)
    }

    /// 三面板同一个动画组提交,共用一条时间轴（Codex 二审 P2：避免各跑各的时间轴抖动）。
    ///
    /// **目标 frame 和现状完全一样时直接返回，一帧都不跑。**
    /// 2026-08-17 实测（`DOCK_HOVER_TRACE=1`）：启动后 6 秒里 10 次 `relayout`，其中 **8 次**
    /// 宽度根本没变却仍然 `animated: true`，还有连着 6 次挤在 1.1ms 内。每一次都会启动一组
    /// 窗口尺寸动画，把三个面板"动画"到和现在一模一样的尺寸——**而窗口尺寸动画的每一帧都要
    /// 重画玻璃底板和那圈描边**。测量本身很便宜（`fittingSize` 0.2ms），贵的是这个空动画。
    ///
    /// 判据用**最终 frame 全等**而不是「宽度没变」：换屏、改档位、边缘隐藏都会在宽度不变的
    /// 情况下真的挪动面板，只比宽度会把它们一起吃掉。
    func setFrames(_ pairs: [(NSPanel, NSRect)], animated: Bool) {
        // **和上一次的目标比，不和面板的实时 frame 比。**
        // 实时 frame 在动画途中是插值出来的中间值，永远和目标不等——那样这个短路一次都不会命中
        // （实测 0 次）。AGENTS《Menus, Panels, And Screens》早写过同一条：relayout 是目标
        // frame 驱动的，别在动画期间读面板的实时 frame。
        let targets = pairs.map(\.1)
        guard targets != lastCommittedFrames else {
            HoverTrace.framesUnchanged()
            return
        }
        lastCommittedFrames = targets
        guard animated else { for (p, f) in pairs { p.setFrame(f, display: true) }; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.layoutAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (p, f) in pairs { p.animator().setFrame(f, display: true) }
        }
    }

    /// 由编排层在 `didChangeScreenParametersNotification` 时转发（它先按屏集合建 / 拆单元，再转给幸存者）。
    /// 跨面板拖动的取消与监视器重估也由编排层做一次，这里不重复。
    func screenParametersChanged() {
        cancelHoverSwitch()
        closeFolderPopup()             // 屏幕参数变了,旧锚点坐标作废
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        guard dockPanel != nil else { return }
        // 固定到某屏：屏幕集合变了先归位（拔固定屏 → 回落主屏；接回 → 搬回去）。
        // 必须在 relayout 之前——relayout 用 panelCurrentScreen 从面板坐标反推所在屏。
        if let home = resolvedPinnedScreen(), let panel = dockPanel,
           panelCurrentScreen(panel: panel) != home {
            layoutPanels(contentWidth: lastDesiredWidth, on: home, animated: false)
        }
        relayout(animated: false)      // 切屏瞬时,不滑
        cancelFullscreenIntentIfContextChanged()
        reconcilePanelVisibility()
    }

    static func screenGeometry(_ screen: NSScreen) -> PanelScreenGeometry {
        PanelScreenGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top)
    }
}
