import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · 窗口标题气泡：专属面板的展示 / 宽限 / 看门狗 / 鼠标监视。
// 2026-09-05 从 PanelCoordinator.swift 按 extension 拆出，只搬不改。
extension PanelCoordinator {
    func handleWindowTitleTooltipEvent(_ event: WindowTitleTooltipEvent) {
        switch event {
        case let .update(request):
            // 这里**不再做归属判定**。请求现在只有一个来源：任务条整条那块跟踪区按指针位置
            // 算出来的（`StripHoverResolution`），发出来时指针必定压在那张卡上。
            // 以前每张卡各自发请求才需要守卫（卡住的 `isHovering` 会抢面板），
            // 理由留在 `WindowTitleTooltipRequest` 的注释里。
            if windowTitleTooltipSuppressedChipID == request.chipID { return }
            windowTitleTooltipSuppressedChipID = nil
            cancelWindowTitleTooltipLinger()

            HoverTrace.hover(chipID: request.chipID, entered: true)
            windowTitleTooltipRequest = request
            installWindowTitleTooltipMouseMonitors()
            // 立刻换文字换位置：不去抖、不淡入（见上面那条常量的注释）。
            presentWindowTitleTooltip(request)

        case let .exit(chipID):
            HoverTrace.hover(chipID: chipID, entered: false)
            if windowTitleTooltipSuppressedChipID == chipID {
                windowTitleTooltipSuppressedChipID = nil
            }
            guard windowTitleTooltipRequest?.chipID == chipID else { return }
            // `.exit` 现在的含义很干脆：**指针没压在任何一张卡上**——分区分隔线那道宽缝、
            // 条两端的留白，或者已经离开任务条。卡与卡之间那 2pt 窄缝不会走到这里：
            // 归属判定把它桥接掉了（`StripHoverResolution`），所以「A → 空 → B」在源头上没了。
            //
            // 还留一个 90ms 宽限：横穿分隔线时别闪一下，隔壁一发 `.update` 就接管。
            // 指针已经不在任务条上就立刻收，不挂一颗过期气泡。
            if isPointInsideTaskbarPanels(NSEvent.mouseLocation) {
                scheduleWindowTitleTooltipLinger()
            } else {
                dismissWindowTitleTooltip()
            }
        }
    }

    /// 延后收气泡；宽限内有别的 chip `.update` 进来就直接接管这块面板（见 `windowTitleTooltipLingerDelay`）。
    private func scheduleWindowTitleTooltipLinger() {
        cancelWindowTitleTooltipLinger()
        let timer = Timer(timeInterval: Self.windowTitleTooltipLingerDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.windowTitleTooltipLingerTimer = nil
                self.dismissWindowTitleTooltip()
            }
        }
        windowTitleTooltipLingerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelWindowTitleTooltipLinger() {
        windowTitleTooltipLingerTimer?.invalidate()
        windowTitleTooltipLingerTimer = nil
    }

    /// 气泡在屏上时的看门狗：指针离开了会弹气泡的那些面板就收掉。
    ///
    /// 改造之后它只剩**兜底**这一个身份：条上谁拥有气泡由整条那块跟踪区实时算
    /// （`StripHoverResolution`），它自己的 `mouseExited` 才是正常的收气泡路径。
    /// 但面板被 `orderOut`（贴边隐藏、进全屏）、或 chip 从指针底下被抽走时，
    /// 跟踪区不保证补一次 exit，那时就靠这条 10Hz 复核，免得气泡永远挂着
    /// （owner 报过「有时候鼠标移走气泡还在」）。
    ///
    /// **判定用整块面板，不用锚点矩形**：条内的归属交给跟踪区，这里再按锚点判一次
    /// 只会和它打架——指针停在分隔线或窄缝上时两边结论不同，气泡会被抢着收掉。
    ///
    /// 刻意用**只在气泡可见期间存活**的定时器，而不是常驻的 `.mouseMoved` 全局监视器：
    /// 后者是事件 tap，我们自己的菜单弹起时会把鼠标事件拖慢（AGENTS《Menus, Panels, And Screens》
    /// 那条 100ms 粘滞就是这么来的），为一颗 tooltip 不值得再开一个。
    func startWindowTitleTooltipWatchdog() {
        guard windowTitleTooltipWatchdog == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.windowTitleTooltipPanel?.isVisible == true,
                      self.windowTitleTooltipRequest != nil else {
                    self.stopWindowTitleTooltipWatchdog()
                    return
                }
                guard !self.isPointInsideTaskbarPanels(NSEvent.mouseLocation) else { return }
                self.dismissWindowTitleTooltip()
            }
        }
        windowTitleTooltipWatchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 指针是否还落在「会弹气泡的那些面板」上（任务条本体 + 胶囊 + 打开着的抽屉）。
    /// 用整窗 frame 就够：多算进去的只有 20pt 透明阴影边，宽限到点自然会收。
    private func isPointInsideTaskbarPanels(_ point: CGPoint) -> Bool {
        if let dock = dockPanel, dock.frame.contains(point) { return true }
        if let capsule = capsulePanel, capsule.frame.contains(point) { return true }
        if drawerWantsOpen, let drawer = drawerPanel, drawer.frame.contains(point) { return true }
        return false
    }

    private func stopWindowTitleTooltipWatchdog() {
        windowTitleTooltipWatchdog?.invalidate()
        windowTitleTooltipWatchdog = nil
    }

    private func presentWindowTitleTooltip(_ request: WindowTitleTooltipRequest) {
        guard request.anchorVisibleRect != .zero else { return }
        onAccessoryWillOpen?(self, .tooltip)
        let traceStart = CACurrentMediaTime()
        let traceCold = windowTitleTooltipPanel?.isVisible != true
        defer { HoverTrace.present(chipID: request.chipID, cold: traceCold,
                                   elapsed: CACurrentMediaTime() - traceStart) }
        let panel: NSPanel
        if let existing = windowTitleTooltipPanel {
            panel = existing
        } else {
            let created = makeFloatingPanel(contentRect: .zero, usesLiquidGlass: usesLiquidGlass)
            configurePanel(created, backgroundColor: .clear, appliesLevelOverride: false)
            created.ignoresMouseEvents = true
            windowTitleTooltipPanel = created
            panel = created
        }

        // 气泡整颗随任务条档位缩放（owner 2026-08-17）。`DockSize.scale` 已经是中档归一的，
        // 中档恒为 1.0 → 中档逐字保持实测的原生像素。档位切换走既有的 `beginDockSizeChange`
        // 事务，它会先收掉气泡，所以这里不需要额外的失效处理。
        let style = WindowTitleTooltipStyle(scale: settingsStore.dockSize.scale)
        let contentHost: ManualPanelHost
        if let hosting = windowTitleTooltipHosting, let existingHost = windowTitleTooltipHost {
            hosting.rootView = WindowTitleTooltipView(title: request.title, style: style,
                                                    usesLiquidGlass: usesLiquidGlass)
            contentHost = existingHost
        } else {
            let hosting = NSHostingView(rootView: WindowTitleTooltipView(title: request.title, style: style,
                                                          usesLiquidGlass: usesLiquidGlass))
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            contentHost = ManualPanelHost(contentView: hosting, in: panel)
            windowTitleTooltipHosting = hosting
            windowTitleTooltipHost = contentHost
        }
        panel.layoutIfNeeded()
        let size = contentHost.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        let anchorPoint = CGPoint(x: request.anchorVisibleRect.midX, y: request.anchorVisibleRect.midY)
        // **锚点必须落在任务条所在的那块屏上。** 弹气泡的 chip 全都住在任务条 / 抽屉里，
        // 两者永远同屏；锚点跑到别的屏上只可能是那张卡缓存的屏幕矩形过期了（面板换过屏）。
        // 此时宁可这一帧不弹——`ScreenRectReader` 现在会在窗口移动时补一次上报，
        // 下一帧就正确。真弹出去就是 owner 报的「气泡跑到没有任务条的那块屏上」。
        let dockScreen = dockPanel.map { panelCurrentScreen(panel: $0) }
        if let dockScreen, !dockScreen.frame.contains(anchorPoint) { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) })
            ?? dockScreen
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let target = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: request.anchorVisibleRect,
            size: size,
            tipGap: style.tipGap,
            on: Self.screenGeometry(screen)
        )
        panel.setFrame(target, display: true)

        // **不淡入。** 实测输入 → 气泡上屏只要 2.9–9.5ms，链路本来就是即时的；
        // owner 说的「没有原生那么干脆」是这 0.1s 淡入带来的**软**，不是慢
        // （原生 Dock 的应用名是直接出现的）。同理离开也是直接收，见 `.exit` 分支。
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
        pinOverlappingPanelIfNeeded(panel)
        startWindowTitleTooltipWatchdog()
    }

    /// **幂等**：每次 `.update` 都会调它（换 chip 不再先 dismiss 后重装），重复装会漏掉旧监视器。
    private func installWindowTitleTooltipMouseMonitors() {
        guard windowTitleTooltipLocalMonitor == nil, windowTitleTooltipGlobalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        windowTitleTooltipLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            return event
        }
        windowTitleTooltipGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        }
    }

    func dismissWindowTitleTooltip(suppressCurrentUntilExit: Bool = false) {
        if suppressCurrentUntilExit, let chipID = windowTitleTooltipRequest?.chipID {
            windowTitleTooltipSuppressedChipID = chipID
        }
        cancelWindowTitleTooltipLinger()
        stopWindowTitleTooltipWatchdog()
        windowTitleTooltipRequest = nil
        if let monitor = windowTitleTooltipLocalMonitor {
            NSEvent.removeMonitor(monitor)
            windowTitleTooltipLocalMonitor = nil
        }
        if let monitor = windowTitleTooltipGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            windowTitleTooltipGlobalMonitor = nil
        }
        windowTitleTooltipPanel?.alphaValue = 0
        windowTitleTooltipPanel?.orderOut(nil)
    }
}
