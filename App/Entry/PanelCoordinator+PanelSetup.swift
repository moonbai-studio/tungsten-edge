import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · 面板建立：任务条 / 玻璃底板 / 胶囊三块常驻面板的创建、配置与首帧呈现。
// 2026-09-05 从 PanelCoordinator.swift 按 extension 拆出，只搬不改。
extension PanelCoordinator {
    func setupDockPanel() {
        let screen = resolvedPinnedScreen() ?? NSScreen.main ?? NSScreen.screens[0]
        let s = screen.frame
        let legacyInitialFrame = NSRect(
            x: s.minX,
            y: s.minY + layoutMetrics.bottomGap - Self.shadowPadding,
            width: s.width,
            height: windowHeight
        )

        let glassBackground = makeTaskbarGlassBackground(contentPanelFrame: legacyInitialFrame)
        let usesLiquidGlass = glassBackground != nil

        // 内容窗口**始终**用含 20pt 阴影透明边的 frame，玻璃态也不例外：落地阴影住在那里，
        // 而且投放区/弹簧区/「鼠标还在条上」这些判定全都按「窗口 frame 减 shadowPadding」
        // 换算（`dragDropZones` / `springZone` / `isMouseOutsideInteractivePanels`）。
        // 缩窗口会让这一整批坐标一起错位。
        let panel = makeFloatingPanel(contentRect: legacyInitialFrame, usesLiquidGlass: usesLiquidGlass)
        configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: true)

        let hosting = NSHostingView(rootView: DockStripView(
            usesLiquidGlass: usesLiquidGlass,
            stripSurfaceID: stripSurfaceID,
            displayUUID: fixedUnitDisplayUUID,
            folderPopupPresence: folderPopupPresence,
            onFolderPopupToggle: { [weak self] path, anchorRect, origin in
                self?.toggleFolderPopup(path: path, anchorVisibleRect: anchorRect, origin: origin)
            },
            onFolderDragWillBegin: { [weak self] in self?.closeFolderPopup(immediately: true) },
            onShelfPopupToggle: { [weak self] anchorRect in
                self?.toggleShelfPopup(anchorVisibleRect: anchorRect)
            },
            onTrashPopupToggle: { [weak self] anchorRect in
                self?.toggleTrashPopup(anchorVisibleRect: anchorRect)
            },
            onAddFolder: { [weak self] in self?.onAddFolder() },
            onMoveExternalFiles: { [weak self] urls, path in
                self?.moveExternalFiles(urls, into: path)
            },
            onWindowTitleTooltipEvent: { [weak self] event in
                self?.handleWindowTitleTooltipEvent(event)
            },
            onRequestTaskbarMenu: { [weak self] event, view in
                self?.prepareResizeCursorForMenu()
                self?.onRequestTaskbarMenu?(event, view)
            },
            onInteractiveResize: { [weak self] event in
                switch event {
                case let .pointerEnteredBar(hitTest): self?.assertBarArrowCursor(hitTest: hitTest)
                case let .hover(pointer): self?.gripHoverChanged(pointer)
                case let .began(pointer): self?.beginInteractiveResize(pointer: pointer)
                case let .changed(pointer): self?.updateInteractiveResize(pointer: pointer)
                case .ended: self?.endInteractiveResize()
                }
            },
            resizeGripController: resizeGripController,
            // 标签变长变短：开一段面板逐帧跟随内容宽度的窗口（见 `beginLabelWidthFollow`）。
            onLabelWidthChange: { [weak self] starting in self?.beginLabelWidthFollow(starting: starting) },
            onLabelBoxWidthTick: { [weak self] id, width in self?.labelBoxWidthDidTick(chipID: id, width: width) },
            // Next main-loop turn: mid-update `fittingSize` reads 0 (`Docs/05`), as in `subscribeStripSlotCollapse`.
            onAppGapPresenceChange: { [weak self] in
                DispatchQueue.main.async { self?.relayout(animated: true) }
            }
        ).environmentObject(runtime).environmentObject(drawerStore).environmentObject(messagingStore).environmentObject(badgeStore).environmentObject(stripOrderStore).environmentObject(pinnedFolderStore).environmentObject(folderCoverStore).environmentObject(shelfStore).environmentObject(dragController).environmentObject(keptAppStore).environmentObject(runningApplicationStore).environmentObject(appMembershipController).environmentObject(settingsStore).environmentObject(displayTopologyStore)
            .modifier(PanelHeightResizeModifier(presentation: heightResizePresentation)))
        hosting.autoresizingMask = [.width, .height]
        // Prevent NSHostingView from adding its own opaque background over the blur
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        dockContentHost = ManualPanelHost(contentView: hosting, in: panel)
        dockPanel = panel

        if let (backgroundPanel, backgroundView) = glassBackground {
            dockGlassBackgroundPanel = backgroundPanel
            dockGlassBackgroundView = backgroundView
        }
    }

    private func makeTaskbarGlassBackground(
        contentPanelFrame: NSRect
    ) -> (NonConstrainingPanel, DockTaskbarLiquidGlassBackgroundView)? {
        guard DockGlassPresentation.shouldAttemptTaskbarComposite else { return nil }

        let configuration = DockGlassPresentation.configuration
        let backgroundFrame = DockLiquidGlassPanelGeometry.backgroundFrame(
            for: contentPanelFrame,
            shadowPadding: Self.shadowPadding
        )
        guard backgroundFrame.width > 0, backgroundFrame.height > 0 else { return nil }

        let panel = NonConstrainingPanel(
            contentRect: backgroundFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel(panel, backgroundColor: .clear, appliesLevelOverride: true)
        panel.ignoresMouseEvents = true
        // 下面的失败分支会 close() 一个从未 order in 过的窗口；NSWindow 默认 close 即释放，
        // 而这里还持有着强引用。
        panel.isReleasedWhenClosed = false

        let backgroundView = DockTaskbarLiquidGlassBackgroundView(
            frame: NSRect(origin: .zero, size: backgroundFrame.size),
            cornerRadius: taskbarPlateCornerRadius,
            configuration: configuration
        )
        backgroundView.autoresizingMask = [.width, .height]
        panel.contentView = backgroundView

        // The blur call is tuning only (default radius 0 = no call), and its failure must never
        // decide the render path: this used to be a guard that dropped the whole composite, which
        // is the suspected way macOS 26.x users lost the glass (why the call failed there is unknown).
        if let blurRadius = configuration.requestedWindowBlurRadius,
           !TEDockGlassSetWindowBackgroundBlurRadius(panel.windowNumber, blurRadius) {
            print("[glass] window blur radius \(blurRadius) rejected by WindowServer; continuing without it")
        }
        return (panel, backgroundView)
    }

    func tearDownTaskbarGlassBackground() {
        guard let background = dockGlassBackgroundPanel else { return }
        if DockGlassPresentation.configuration.requestedWindowBlurRadius != nil {
            _ = TEDockGlassSetWindowBackgroundBlurRadius(background.windowNumber, 0)
        }
        background.contentView = nil
        background.orderOut(nil)
        background.close()
        dockGlassBackgroundView = nil
        dockGlassBackgroundPanel = nil
    }

    func orderDockSurfaceFront() {
        let ordering = DockLiquidGlassPanelLifecyclePlan.ordering(
            isCompositeActive: dockGlassBackgroundPanel != nil,
            shouldShow: true
        )
        for role in ordering {
            switch role {
            case .background:
                dockGlassBackgroundPanel?.orderFrontRegardless()
            case .content:
                dockPanel?.orderFrontRegardless()
            }
        }
        if let background = dockGlassBackgroundPanel, let dock = dockPanel {
            background.order(.below, relativeTo: dock.windowNumber)
        }
    }

    func orderDockSurfaceOut() {
        let ordering = DockLiquidGlassPanelLifecyclePlan.ordering(
            isCompositeActive: dockGlassBackgroundPanel != nil,
            shouldShow: false
        )
        for role in ordering {
            switch role {
            case .background:
                dockGlassBackgroundPanel?.orderOut(nil)
            case .content:
                dockPanel?.orderOut(nil)
            }
        }
    }

    private func moveExternalFiles(_ urls: [URL], into path: String) {
        let destination = URL(fileURLWithPath: path, isDirectory: true)
        fileDropQueue.async {
            let eligible = FolderDropPlan.eligibleSources(urls, destination: destination)
            guard !eligible.isEmpty else { return }
            let result = FileMover().move(eligible, into: destination)
            guard result.hasIssues else { return }
            DispatchQueue.main.async { NSSound.beep() }
        }
    }

    /// App bundles dropped from Finder onto the capsule (`.front`) or into the open drawer (where
    /// the pointer was): into the drawer in drag order, with kept turned on — as a drag into the
    /// drawer does (`Docs/27`). An app already on the bar leaves it through the projections, as
    /// when its card is stashed.
    func stashDroppedApplications(_ urls: [URL], placement: DrawerAppDrop.Placement) {
        externalDragDropped()
        let paths = urls.map(\.path)
        // Reading Info.plist is disk I/O: user actions run on `actionQueue`, never the cooperative pool.
        AppRuntime.actionQueue.async {
            let bundleIDs = paths.compactMap { Bundle(url: URL(fileURLWithPath: $0))?.bundleIdentifier }
            DispatchQueue.main.async { [weak self] in
                self?.landDroppedApplications(bundleIDs, placement: placement)
            }
        }
    }

    /// The open drawer's drop when its make-way slot was showing: the ids were read from the drag
    /// pasteboard while hovering, so nothing is read here and the slot's cells become the members
    /// in the drawer's same turn.
    func stashDroppedApplicationIDs(_ ids: [String], placement: DrawerAppDrop.Placement) {
        externalDragDropped()
        landDroppedApplications(ids, placement: placement)
    }

    /// The store half of both drops. Never sends `.dropped`: that belongs to the moment of release.
    private func landDroppedApplications(_ bundleIDs: [String], placement: DrawerAppDrop.Placement) {
        var seen = Set<String>()
        let ids = bundleIDs.filter { KeptAppStore.canKeep($0) && seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        // Order first: `reconciled(members:)` appends a member it has no place for, so a
        // new member added before its place exists shows up last for a frame.
        drawerOrderStore.place(ids, at: placement)
        for id in ids {
            appMembershipController.moveToDrawer(id)
            appMembershipController.setKept(id, enabled: true)
        }
    }

    func setupCapsulePanel() {
        let panel = makeFloatingPanel(
            contentRect: NSRect(origin: .zero,
                                size: CGSize(width: capsuleWidth + Self.shadowPadding * 2,
                                             height: capsuleWidth + Self.shadowPadding * 2)),
            usesLiquidGlass: usesLiquidGlass
        )
        configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: true)
        let hosting = NSHostingView(rootView:
            DrawerCapsuleButton(
                onRequestTaskbarMenu: { [weak self] event, view in
                    self?.onRequestTaskbarMenu?(event, view)
                },
                usesLiquidGlass: usesLiquidGlass,
                action: { [weak self] in self?.toggleDrawer() },
                onPrimaryAction: { [weak self] in self?.closeDrawerAfterAction() },
                onDropApplications: { [weak self] urls in self?.stashDroppedApplications(urls, placement: .front) },
                onExternalDragHover: { [weak self] over in self?.externalDragHover(.capsule, over) }
            )
                .environmentObject(runtime)
                .environmentObject(drawerStore)
                .environmentObject(messagingStore)
                .environmentObject(keptAppStore)
                .environmentObject(runningApplicationStore)
                .environmentObject(drawerOrderStore)
                .environmentObject(dragController)
                .environmentObject(settingsStore)
                .modifier(PanelHeightResizeModifier(presentation: heightResizePresentation))
        )
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        capsuleContentHost = ManualPanelHost(contentView: hosting, in: panel)
        capsulePanel = panel
    }

    /// 两个常驻面板先在隐藏态完成 SwiftUI 布局和目标 frame 提交，再一起显示。
    /// 这样首个可见 frame 已经是业务几何，不给 HostingView 的自然尺寸留下窗口级中间态。
    func presentInitialPanels() {
        guard let dock = dockPanel, let capsule = capsulePanel else { return }
        dock.layoutIfNeeded()
        capsule.layoutIfNeeded()
        relayout(animated: false)
        orderDockSurfaceFront()
        capsule.orderFrontRegardless()
    }

    /// `usesLiquidGlass` 由调用方显式传：`setupDockPanel` 里玻璃底板刚建好、还没赋给
    /// `dockGlassBackgroundPanel`，此时读计算属性会错判成「无玻璃」建出普通面板。
    func makeFloatingPanel(contentRect: NSRect, usesLiquidGlass: Bool) -> NonConstrainingPanel {
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        return usesLiquidGlass
            ? DockLiquidGlassPanel(contentRect: contentRect, styleMask: styleMask,
                                   backing: .buffered, defer: false)
            : NonConstrainingPanel(contentRect: contentRect, styleMask: styleMask,
                                   backing: .buffered, defer: false)
    }

    /// 六块面板共用的窗口配置（2026-09-05 从六处逐字相同的复制收拢）。**顺序承重**：
    /// `isFloatingPanel = true` 会把 `level` 重置回 `.floating`，实验层级覆盖必须排在它之后；
    /// 只有三块常驻面板（任务条 / 玻璃底板 / 胶囊）吃 `DOCK_PANEL_LEVEL` 覆盖，抽屉 / 弹窗 / 气泡不吃。
    /// `PanelCollectionBehavior.standard` 的赋值点就此只剩这里和 issue #19 的修复循环。
    func configurePanel(_ panel: NSPanel, backgroundColor: NSColor, appliesLevelOverride: Bool) {
        panel.level = .floating
        panel.collectionBehavior = PanelCollectionBehavior.standard
        panel.isFloatingPanel = true
        if appliesLevelOverride, let level = Self.panelLevelOverride { panel.level = level }
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = backgroundColor
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
    }
}
