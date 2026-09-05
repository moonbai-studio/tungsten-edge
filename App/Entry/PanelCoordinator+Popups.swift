import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · 文件夹 / 中转站弹窗：单面板复用、开合动画、click-away 监视。
// 2026-09-05 从 PanelCoordinator.swift 按 extension 拆出，只搬不改。
/// CAMediaTimingFunction 的数值求解版：CALayer 隐式动画只能按"单一属性"整体插值，
/// 而弹窗切换要按 centerX/bottomY/width/height 四个语义量分别插值再拼回 frame，
/// 只能自己按时间步进算 progress。直接吃调用方已有的 CAMediaTimingFunction，不重复定义
/// 控制点（两个调用点用的曲线不同：PopoverAnimation.curve() 与 .easeInEaseOut）。
/// WebKit UnitBezier 同款：牛顿迭代求解 x(t)=elapsed，再取 y(t) 作为缓动进度，迭代不收敛时二分兜底。
private struct UnitBezierEase {
    private let ax, bx, cx: Double
    private let ay, by, cy: Double

    init(_ timingFunction: CAMediaTimingFunction) {
        var p1 = [Float](repeating: 0, count: 2)
        var p2 = [Float](repeating: 0, count: 2)
        timingFunction.getControlPoint(at: 1, values: &p1)
        timingFunction.getControlPoint(at: 2, values: &p2)
        let (p1x, p1y, p2x, p2y) = (Double(p1[0]), Double(p1[1]), Double(p2[0]), Double(p2[1]))
        cx = 3 * p1x; bx = 3 * (p2x - p1x) - cx; ax = 1 - cx - bx
        cy = 3 * p1y; by = 3 * (p2y - p1y) - cy; ay = 1 - cy - by
    }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func sampleDX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    private func solveX(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let dx = sampleX(t) - x
            if abs(dx) < 1e-6 { return t }
            let d = sampleDX(t)
            if abs(d) < 1e-6 { break }
            t -= dx / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        while lo < hi {
            let cur = sampleX(t)
            if abs(cur - x) < 1e-6 { return t }
            if x > cur { lo = t } else { hi = t }
            t = (hi - lo) / 2 + lo
        }
        return t
    }

    func progress(at t: Double) -> Double { sampleY(solveX(t)) }
}

extension PanelCoordinator {
    // MARK: - 文件夹/废纸篓弹窗（克隆抽屉模板：懒面板 + 普通容器包 hosting + 淡入淡出 + click-away 监视器）

    /// chip 点击入口：同一文件夹再点 = 收起；换文件夹 = 瞬时切换目标。anchorVisibleRect 是 chip 可视矩形（屏幕坐标）。
    func toggleFolderPopup(path: String, anchorVisibleRect: CGRect) {
        if folderPopupWantsOpen, openPopupContent == .folder(path: path) {
            closeFolderPopup()
        } else {
            openFolderPopup(path: path, anchorVisibleRect: anchorVisibleRect)
        }
    }

    /// 中转格点击入口：再点 = 收起；从文件夹弹窗切过来 = 原地切换（同单面板语义）。
    func toggleShelfPopup(anchorVisibleRect: CGRect) {
        if folderPopupWantsOpen, openPopupContent == .shelf {
            closeFolderPopup()
        } else {
            openShelfPopup(anchorVisibleRect: anchorVisibleRect)
        }
    }

    private func openFolderPopup(path: String, anchorVisibleRect: CGRect) {
        let rootURL = URL(fileURLWithPath: path)
        let sortOrder = pinnedFolderStore.sortOrder(for: path)
        // 混合兜底：先查热缓存（0ms，且校验了排序一致性），Miss 则回退到短时 preload（最多阻塞 150ms），确保首帧完整。
        let preloadedEntries = folderCoverStore.cachedEntries(for: path, order: sortOrder)
            ?? FolderContentsLoader.preload(url: rootURL, timeout: 0.15, order: sortOrder)
        // 首帧完整**包含图标**：预热首批可见格（8 列 × 网格高上限 ≈ 40 格,取 48 宽裕值）的图标缓存,
        // 否则格子先出、图标按解析顺序从左上角逐个浮现（owner 2026-07-07 报的"从左上角出现"真因）。
        if let entries = preloadedEntries {
            FolderIconResolver.warm(paths: entries.prefix(48).map(\.url.path), timeout: 0.1)
        }

        presentPopup(content: .folder(path: path), anchorVisibleRect: anchorVisibleRect) { [weak self] maxContentHeight in
            NSHostingView(rootView: FolderGridPopupView(
                rootURL: rootURL,
                initialEntries: preloadedEntries,
                sortOrder: sortOrder,
                maxContentHeight: maxContentHeight,
                usesLiquidGlass: usesLiquidGlass,
                onFileOpened: { [weak self] in self?.closeFolderPopup() },
                onContentResize: { [weak self] in self?.repositionFolderPopup(animated: true) },
                onPinFolder: { [weak self] url in self?.pinnedFolderStore.add(url.path) },
                isFolderPinned: { [weak self] url in self?.pinnedFolderStore.contains(url.path) ?? true }
            ))
        }
    }

    private func openShelfPopup(anchorVisibleRect: CGRect) {
        shelfStore.prune()   // 打开即剔除已失效的引用（文件被移走/删除）
        // 同 openFolderPopup：首帧图标全亮,不逐个浮现。
        FolderIconResolver.warm(paths: Array(shelfStore.itemPaths.prefix(48)), timeout: 0.1)

        presentPopup(content: .shelf, anchorVisibleRect: anchorVisibleRect) { [weak self, shelfStore] maxContentHeight in
            NSHostingView(rootView: ShelfGridPopupView(
                shelfStore: shelfStore,
                maxContentHeight: maxContentHeight,
                usesLiquidGlass: usesLiquidGlass,
                onClosePopup: { [weak self] in self?.closeFolderPopup() },
                onContentResize: { [weak self] in self?.repositionFolderPopup(animated: true) },
                onPinFolder: { [weak self] url in self?.pinnedFolderStore.add(url.path) },
                isFolderPinned: { [weak self] url in self?.pinnedFolderStore.contains(url.path) ?? true }
            ))
        }
    }

    /// 共享的弹窗呈现路径（文件夹/中转同一面板同一套动画与监视器）。内容构建交给 makeHosting
    /// （入参 = 网格可用高度上限）；调用方负责先做好各自的预载（首帧完整,AGENTS 护栏）。
    private func presentPopup(content: PopupContent, anchorVisibleRect: CGRect, makeHosting: (CGFloat) -> NSView) {
        guard let mainPanel = dockPanel else { return }
        onAccessoryWillOpen?(self, .popup)
        // 可打断：面板可见时换内容**原地切换**——不 orderOut（根除黑一下的 blink），
        // 只撤旧监视器（随后重装），内容瞬换、帧滑向新目标。仅淡出中/未开时才走关闭路径。
        let isSwitching = folderPopupWantsOpen && (folderPopupPanel?.isVisible ?? false)
        if folderPopupWantsOpen {
            if isSwitching {
                if let m = popupLocalMonitor  { NSEvent.removeMonitor(m); popupLocalMonitor  = nil }
                if let m = popupGlobalMonitor { NSEvent.removeMonitor(m); popupGlobalMonitor = nil }
            } else {
                closeFolderPopup(immediately: true)
            }
        }

        if folderPopupPanel == nil {
            let panel = makeFloatingPanel(
                contentRect: NSRect(origin: .zero, size: lastPopupSize),
                usesLiquidGlass: usesLiquidGlass
            )
            configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: false)
            folderPopupPanel = panel
        }
        guard let panel = folderPopupPanel else { return }

        let screen = panelCurrentScreen(panel: mainPanel)
        let screenGeometry = Self.screenGeometry(screen)
        let maxContentHeight = PanelGeometry.maxFolderPopupContentHeight(
            anchorVisibleRect: anchorVisibleRect, on: screenGeometry, metrics: layoutMetrics)

        let hosting = makeHosting(maxContentHeight)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor

        popupAnchorVisibleRect = anchorVisibleRect
        openPopupContent = content
        folderPopupWantsOpen = true
        setAutoHideInhibitor(.folderPopupOpen, active: true)

        // 同抽屉：普通 NSView 容器 + hosting 钉入,防 NSHostingView 当 contentView 时顶边锚定向下撑（AGENTS 护栏）。
        let container = NSView(frame: NSRect(origin: .zero, size: lastPopupSize))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        folderPopupContentHost = hosting

        // 首帧就位（owner 2026-07-06「不丝滑」主因之一）：orderFront **前**同步量真实尺寸,
        // 首帧即最终大小,不再「旧尺寸弹出→瞬间校正」。量不到合理值退回 lastPopupSize,
        // 后面的 double-defer 复测仍在,作兜底校正。
        panel.layoutIfNeeded()
        let sync = hosting.fittingSize
        if sync.width >= 160, sync.height >= 100 {
            lastPopupSize = sync
        }
        let initialFrame = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: anchorVisibleRect, size: lastPopupSize, on: screenGeometry, metrics: layoutMetrics)
        lastPopupTargetFrame = initialFrame

        if isSwitching {
            // 原地切换：alpha 保持 1,帧从当前位置滑向新目标,内容已瞬换。随时可再切（可打断）。
            animateFolderPopupFrame(
                panel: panel, to: initialFrame,
                duration: PopoverAnimation.openDuration, timingFunction: PopoverAnimation.curve())
        } else {
            // 首帧就位后整体淡入：panel.alphaValue 0→1 把背景/网格/阴影当一块淡进来
            // （内容层不再另做缩放/透明度,见 FolderGridPopupView）。
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                panel.setFrame(initialFrame, display: false)
            }
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            pinOverlappingPanelIfNeeded(panel)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PopoverAnimation.openDuration
                ctx.timingFunction = PopoverAnimation.curve()
                panel.animator().alphaValue = 1
            }
        }
        popupOpenedAt = Date()
        // 弹出后复测 fittingSize（双重 defer 等 SwiftUI 布局完成）——同步量偏差时的兜底校正,瞬时。
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.repositionFolderPopup(animated: false)
            }
        }

        popupLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.dismissFolderPopupIfOutside()
            return event
        }
        popupGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dismissFolderPopupIfOutside()
        }
    }

    /// 内容尺寸变化（首测/下钻/实时刷新）→ 按锚点重算目标帧。宽高都由内容推导（列数确定宽）。
    private func repositionFolderPopup(animated: Bool) {
        guard folderPopupWantsOpen,
              let panel = folderPopupPanel,
              let hosting = folderPopupContentHost,
              let dock = dockPanel else { return }
        // 入场窗口期内一律瞬时校正,不与入场淡入叠加出晃动（散装感修复）。
        let animated = animated && Date().timeIntervalSince(popupOpenedAt) > 0.25
        let fitting = hosting.fittingSize
        let size = CGSize(width: max(fitting.width, 160), height: max(fitting.height, 120))
        lastPopupSize = size
        let screen = panelCurrentScreen(panel: dock)
        let target = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: popupAnchorVisibleRect, size: size, on: Self.screenGeometry(screen), metrics: layoutMetrics)
        lastPopupTargetFrame = target

        if folderPopupFrameTimer != nil {
            // 正有一个手搓 tween 在飞（多半是刚触发的切换动画）——双重 defer 的兜底校正不能瞬时打断它,
            // 只把它的终点纠正到最新测量值,继续飞（不然切换动画刚起步就被这里焊死到终点）。
            animateFolderPopupFrame(
                panel: panel, to: target,
                duration: PopoverAnimation.openDuration, timingFunction: PopoverAnimation.curve())
        } else if animated {
            animateFolderPopupFrame(
                panel: panel, to: target,
                duration: Self.layoutAnimationDuration, timingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// 弹窗切换/重定位 tween 的统一取消入口：invalidate 挡不住"已经 fire、Task 还没跑到"的那一次
    /// 回调,靠 token 递增让过期的排队任务在 tick 里自己变成 no-op。
    private func cancelFolderPopupFrameTween() {
        folderPopupFrameTimer?.invalidate()
        folderPopupFrameTimer = nil
        folderPopupTweenTarget = nil
        folderPopupTweenToken &+= 1
    }

    /// 弹窗切换/重定位 tween 的每帧 frame 计算：不直接插值两个已经各自算好、各自钳位过的端点位置
    /// （那样会把"要不要钳位"这件事当成两点间的直线搬移，忽略了钳位只在宽度够大时才触发的
    /// 非线性——宽内容贴边、窄内容不贴边，直线插值会在中途出现方向不自然的滑动）。
    /// 改成插值"期望中心点"（未钳位的锚点中心）+ 宽高，每帧重新走一遍居中+钳位公式，
    /// 与 `PanelGeometry.folderPopupTargetFrame` 同一套规则，保证任何中间尺寸都表现得
    /// 像"用这个尺寸真的锚定在这个 chip 上"。
    /// 首帧起点用 `start.midX`/`start.minY` 而不是"旧锚点"——start 本身永远是当前合法、
    /// 已经在屏幕内的 frame，用它自己的中心反推永远精确等于 start，天然保证 p=0 时不瞬移；
    /// 终点用 `popupAnchorVisibleRect`（当前/新锚点的原始位置）配合插值到 target 的宽度，
    /// 同样保证 p=1 精确落回 target（AGENTS「只向上生长」的设计意图）。
    private func animateFolderPopupFrame(
        panel: NSPanel, to target: NSRect, duration: TimeInterval, timingFunction: CAMediaTimingFunction
    ) {
        // 已经在飞向同一目标 → 别重启,让它按原时钟走完（双重 defer 兜底校正的常见情形,
        // 重启会打断刚起步的动画、重置进度时钟,凭空制造速度突变+更长时长）。
        if folderPopupFrameTimer != nil, folderPopupTweenTarget == target { return }
        cancelFolderPopupFrameTween()
        let token = folderPopupTweenToken

        let start = panel.frame
        guard start != target, duration > 0, let dock = dockPanel else {
            panel.setFrame(target, display: true)
            return
        }
        let screen = Self.screenGeometry(panelCurrentScreen(panel: dock))

        let ease = UnitBezierEase(timingFunction)
        let (w0, w1) = (start.width, target.width)
        let (h0, h1) = (start.height, target.height)
        let startCenterX = start.midX
        let endCenterX = popupAnchorVisibleRect.midX
        let startBottomY = start.minY
        let endBottomY = popupAnchorVisibleRect.maxY + 8
        let clockStart = CACurrentMediaTime()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self, self.folderPopupTweenToken == token, let panel = self.folderPopupPanel else {
                    t.invalidate()
                    return
                }
                let raw = min(max((CACurrentMediaTime() - clockStart) / duration, 0), 1)
                if raw >= 1 {
                    panel.setFrame(target, display: true)   // 落到精确目标值,不依赖浮点误差刚好踩中 1.0
                    self.folderPopupFrameTimer = nil
                    self.folderPopupTweenTarget = nil
                    t.invalidate()
                } else {
                    let p = ease.progress(at: raw)
                    let width = w0 + (w1 - w0) * p
                    let height = h0 + (h1 - h0) * p
                    // 每帧用当前尺寸重走 PanelGeometry 的居中+钳位公式（与首帧/重定位同一真相）。
                    let origin = PanelGeometry.folderPopupClampedOrigin(
                        desiredCenterX: startCenterX + (endCenterX - startCenterX) * p,
                        desiredBottomY: startBottomY + (endBottomY - startBottomY) * p,
                        size: CGSize(width: width, height: height), on: screen)
                    panel.setFrame(NSRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
                }
            }
        }
        folderPopupFrameTimer = timer
        folderPopupTweenTarget = target
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 可打断淡出关闭（同 closeDrawer）。immediately=true 用于换目标瞬切。
    func closeFolderPopup(immediately: Bool = false) {
        guard folderPopupWantsOpen else { return }
        folderPopupWantsOpen = false
        openPopupContent = nil
        setAutoHideInhibitor(.folderPopupOpen, active: false)
        if let m = popupLocalMonitor  { NSEvent.removeMonitor(m); popupLocalMonitor  = nil }
        if let m = popupGlobalMonitor { NSEvent.removeMonitor(m); popupGlobalMonitor = nil }
        cancelFolderPopupFrameTween()   // 关闭时任何在飞的 tween 都要停,免得 orderOut 之后还偷偷挪 frame
        guard let panel = folderPopupPanel else { return }

        if immediately {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PopoverAnimation.closeDuration
            ctx.timingFunction = PopoverAnimation.curve()
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.folderPopupWantsOpen else { return }   // 淡出中又开了 → 别 orderOut
                panel.orderOut(nil)
            }
        })
    }

    /// click-away：弹窗内不关；**锚点 chip（+4pt 容差）内也不关**——监视器在 mouseDown 关、chip 的
    /// onTapGesture 在 mouseUp 又开,不排除锚点则同 chip 点击永远开↔关抖动（评审确认的竞态,勿删）。
    private func dismissFolderPopupIfOutside() {
        guard folderPopupWantsOpen, let panel = folderPopupPanel else { return }
        let mouse = NSEvent.mouseLocation
        guard !panel.frame.contains(mouse),
              !popupAnchorVisibleRect.insetBy(dx: -4, dy: -4).contains(mouse) else { return }
        closeFolderPopup()
    }

    /// 固定文件夹名单变化：同步封面 watcher、被移除文件夹的弹窗要关、任务条宽度重排。
    func subscribePinnedFolderStore() {
        pinnedFolderStoreSubscription = pinnedFolderStore.$folderPaths
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paths in
                guard let self else { return }
                self.folderCoverStore.sync(paths: paths)
                if let openPath = self.openPopupPath, !paths.contains(openPath) {
                    self.closeFolderPopup()
                }
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // 某文件夹排序方式变化：封面要换成新排序的第一个文件;该文件夹弹窗开着 → 走原地切换
        // 路径按新排序重开（面板不灭,内容瞬换;下钻状态重置为接受的边缘,原生 Stacks 同款）。
        pinnedFolderSortSubscription = pinnedFolderStore.$sortOrders
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.folderCoverStore.sync(paths: self.pinnedFolderStore.folderPaths)
                if let openPath = self.openPopupPath {
                    self.openFolderPopup(path: openPath, anchorVisibleRect: self.popupAnchorVisibleRect)
                }
            }
    }
}
