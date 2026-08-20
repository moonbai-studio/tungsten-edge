import AppKit
import QuartzCore
import SwiftUI

/// 把一张 chip 同步渲染成位图，供 `DragController` 当浮动副本用。
///
/// **快照必须画「和卡槽同一个视图」**，否则起拖那一帧的重叠、落地那一帧的交接都会露馅。
/// 保证这一点的办法不是维护一张「哪种来源画哪种视图」的对照表——那是要人工同步的第二份真相，
/// 而这个仓库已经被「调用点漏传参数、编译还过」咬过两次（`ChipView.scale` 静默按中档渲染、
/// 消息区整个没有名字气泡）。办法是：**由渲染卡槽的那个视图自己拍，用的就是它渲染卡槽的
/// 同一个函数**（`DockStripView.stripEntryContent` / `DrawerView.drawerChip`），
/// 只把「悬停」传成 false。于是「同款」是构造上成立的，不会漂。
///
/// 实现走 `NSHostingView` + `cacheDisplay`，**不用 `ImageRenderer`**。三条实测结论
///（2026-08-18 spike，macOS 26.5）：
///
/// 1. `ImageRenderer` 遇到 `NSViewRepresentable` 会把它那块矩形整个涂成不透明的
///    占位黄 `(255, 204, 0)`。而 `ChipView` 自带 `.nativeContextMenu`（= `overlay(NativeMenuHost)`），
///    所以整张卡会变成一块黄砖。四种组合里带 representable 的两种平均 alpha 都是 255。
/// 2. `cacheDisplay` 对 representable 完全免疫（带不带它，非透明像素占比一模一样），
///    透明度保留，而且**在 macOS 12 上就有**——一条路覆盖全部部署目标，不需要版本分支，
///    也不需要给 12 做降级画法。
/// 3. 耗时：中位 0.59ms、P95 0.87ms（预算 8ms）。首次 0.74ms，没有冷启动惩罚。
enum ChipSnapshotter {
    /// 快照四周多留的那一圈。
    ///
    /// 卡片里有东西会**溢出布局帧**：文件夹名的描边光晕（`theme.labelHalo`）、以及各档位的
    /// 抗锯齿边。在条上没关系（旁边就是别的卡，没人裁它），但按布局帧裁快照就会切掉，
    /// 落地那一帧和条上的卡对不上。6pt 足够装下最大档位。
    ///
    /// （原先这里写的是「装图标投影」——图标的外投影 2026-08-19 已按 owner 决定全部去掉，
    /// 但这圈余量仍然要留，理由换成了上面这条。）
    static let bleed: CGFloat = 6

    /// 渲染用的 backing scale：**卡槽所在那块屏的**，不多不少。
    ///
    /// 「取所有屏里最大的」踩过坑（2026-08-19）：2x 拍出来的图在 1.6x 的外接屏上整段拖动都被缩小
    /// 重采样、比条上那张卡糊一点，落地最后一帧换成真卡才突然清晰。位图像素 = 本屏像素，
    /// 加上图层原点对齐到像素格（`DragCarrierGeometry.pixelAligned`），CA 才是 1:1 搬像素。
    ///
    /// 真正用的是**宿主窗口报的** backing scale（见 `hostWindow(forScreenPoint:)`）——那才是图层
    /// 实际光栅化的分辨率，位图必须和它一致；这个函数只负责把窗口摆到对的那块屏上。
    static func renderScale(forScreenPoint point: CGPoint) -> CGFloat {
        screen(forScreenPoint: point)?.backingScaleFactor.clampedToAtLeastOne ?? 2
    }

    private static func screen(forScreenPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// 快照专用的离屏宿主窗口。**没有窗口就一定糊**。
    ///
    /// SwiftUI 在 `NSHostingView` 里建的子图层，`contentsScale` 是从**窗口**拿的；视图不在窗口里时
    /// 它恒为 `1.0`，于是 `cacheDisplay` 走 `CALayer.render(in:)` 按 1x 光栅化再放大到 2x 的 rep 里——
    /// 整段拖动的副本都比条上那张卡糊一点，落地换成真卡才清晰（owner 2026-08-19：「拖动图标时
    /// 图标会有一个微弱的模糊效果，落地后模糊效果才消失」）。
    ///
    /// 2026-08-19 spike 逐个量过（同一张日历图标，锐度 = 拉普拉斯方差）：
    /// - 直接 `NSImage.draw` 进 2x 上下文（理论上限）：**5430**
    /// - 现在这样裸 `NSHostingView` + `cacheDisplay`：**2274**（≈ 被 σ 0.5px 糊过一道）
    /// - 抓完再补 `contentsScale = 2`：还是 2274 —— **内容早就以 1x 光栅化好了，改标记没用**
    /// - 补 `contentsScale` 再 `setNeedsDisplay` + `displayIfNeeded`：**0**（整张空图，更糟）
    /// - 挂进窗口再抓：**5430**，与上限逐字节相同
    ///
    /// 窗口**从不 order 上屏**（实测不上屏也照样给出 2.0 的 backing scale 与 5430 的锐度），
    /// 所以不存在闪一下的风险；它的唯一作用就是给图层一个 backing scale 的来源。复用同一个窗口，
    /// 免得每次快照都建一个。
    @MainActor
    private static func hostWindow(forScreenPoint point: CGPoint, fitting: CGSize) -> NSWindow {
        let window = sharedHostWindow ?? {
            let made = NSWindow(contentRect: CGRect(origin: .zero, size: defaultHostSize),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            made.isOpaque = false
            made.backgroundColor = .clear
            made.hasShadow = false
            made.ignoresMouseEvents = true
            made.isExcludedFromWindowsMenu = true
            made.alphaValue = 0            // 双保险：即使哪天被误 order，也是全透明
            made.contentView = NSView(frame: CGRect(origin: .zero, size: defaultHostSize))
            sharedHostWindow = made
            return made
        }()
        // **只在装不下时才扩，别每次都 resize。** 改窗口尺寸要往 WindowServer 跑一趟：
        // 实测每次快照都 `setContentSize` 会把耗时从 0.6ms 推到 4.4ms（最大 11.7ms，超 8ms 预算），
        // 而这条路是**鼠标按下**时跑的（`prepareCandidate`）。开一块够大的画布重复用就没这笔钱。
        let current = window.contentView?.bounds.size ?? .zero
        if fitting.width > current.width || fitting.height > current.height {
            let grown = CGSize(width: max(fitting.width, current.width),
                               height: max(fitting.height, current.height))
            window.setContentSize(grown)
            window.contentView?.frame = CGRect(origin: .zero, size: grown)
        }
        // 摆到目标屏：backing scale 跟着窗口所在的屏走，多屏异分辨率下不能省这一步。
        if let screen = screen(forScreenPoint: point), window.frame.origin != screen.frame.origin {
            window.setFrameOrigin(screen.frame.origin)
        }
        return window
    }
    @MainActor private static var sharedHostWindow: NSWindow?
    /// 画布初始尺寸：装得下最大档位的标题卡（约 200×70）还有富余，一般一次都不用扩。
    private static let defaultHostSize = CGSize(width: 400, height: 160)

    /// - Parameter screenPoint: 卡槽在屏幕上的位置（取哪块屏的 backing scale 就看它）。
    @MainActor
    static func snapshot<Content: View>(of content: Content, screenPoint: CGPoint) -> CarrierSnapshot? {
        let started = CACurrentMediaTime()
        let result = render(content, screenPoint: screenPoint)
        HoverTrace.carrierSnapshot(ms: (CACurrentMediaTime() - started) * 1000,
                                   width: result?.size.width ?? 0,
                                   height: result?.size.height ?? 0,
                                   ok: result != nil)
        return result
    }

    @MainActor
    private static func render<Content: View>(_ content: Content, screenPoint: CGPoint) -> CarrierSnapshot? {
        let host = NSHostingView(rootView: SnapshotRoot(content: AnyView(content)))
        // `fittingSize` 会**同步**逼出 SwiftUI 的布局（启动首帧事务早就靠这个），
        // 所以这里拿到的就是这张卡在条上占的尺寸，不需要等下一轮 run loop。
        let fitting = host.fittingSize
        guard fitting.width > 0, fitting.height > 0 else {
            dismantle(host)
            return nil
        }
        let logical = CGSize(width: fitting.width + 2 * bleed, height: fitting.height + 2 * bleed)
        // **先进窗口再布局**：子图层的 `contentsScale` 是挂上窗口那一刻定的，顺序反了就白搭
        //（理由与实测数见 `hostWindow(forScreenPoint:)`）。窗口尺寸跟着卡走——`contentView`
        // 会被窗口拉成内容尺寸，不先设窗口大小的话 `host.frame` 会被覆盖掉。
        let window = hostWindow(forScreenPoint: screenPoint, fitting: logical)
        // 挂成**子视图**而不是 `contentView`：后者会被窗口拉成内容尺寸，于是每张卡都要 resize 窗口。
        host.frame = CGRect(origin: .zero, size: fitting)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        defer { host.removeFromSuperview() }      // 松开这棵树，别让它跨次留在窗口上
        // **位图分辨率取窗口报的**，不取屏幕：图层就是按窗口这个 scale 光栅化的，两者必须一致，
        // 否则又回到「位图和图层不是 1:1」的重采样。
        let scale = window.backingScaleFactor.clampedToAtLeastOne
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((logical.width * scale).rounded()),
            pixelsHigh: Int((logical.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            dismantle(host)
            return nil
        }
        // **不能用 `bitmapImageRepForCachingDisplay(in:)`**：它按视图当前所在屏（不在窗口里时是主屏）
        // 定分辨率，多屏异分辨率下就会取错。手工建 rep 再把 `size` 设成逻辑尺寸，scale 才是我们说了算。
        rep.size = logical
        host.cacheDisplay(in: CGRect(x: -bleed, y: -bleed,
                                     width: logical.width, height: logical.height),
                          to: rep)
        dismantle(host)
        guard let drawn = rep.cgImage, let image = detached(drawn) else { return nil }
        // 图层逻辑尺寸取「像素数 / scale」而不是 `logical`：1.6x 屏上 52pt 是 83.2px，位图只能是 83px，
        // 再按 52pt 摆就要重采样；按 83/1.6 = 51.875pt 摆才是 1:1。
        let exact = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return CarrierSnapshot(image: image, size: exact, contentSize: fitting, scale: scale)
    }

    /// **必须把位图拷成一张自己拥有后备存储的图。**
    ///
    /// `NSBitmapImageRep.cgImage` 返回的 `CGImage` 与那个 rep **共享像素缓冲**。rep 是这里的
    /// 局部变量，一出作用域就释放，于是 `CALayer.contents` 拿到的是一张指向已释放内存的图——
    /// 表现极其误导：`contents != nil`、`bounds` / `position` / `opacity` / 层级全部正确、
    /// 自检一条不报，**屏幕上就是什么都没有**（2026-08-19 实测：起拖后载体全程不可见，
    /// 而 spike 里同样的代码是好的，因为那边 rep 还活着就把图写盘了）。
    ///
    /// `CGContext.makeImage()` 返回的是当前位图的**快照**，自带后备存储，与上下文再无关系。
    private static func detached(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// **拍完必须显式拆掉这棵树。**
    ///
    /// 实测：没有窗口的 `NSHostingView` 照样会触发 `onAppear`，但**永远不会**触发 `onDisappear`。
    /// `LauncherChip` 的启动弹跳正是在 `onAppear` 里挂一个 `repeats: true` 的计时器、
    /// 靠 `onDisappear` 收掉——于是每拍一次正在启动的图标就留下一个永不停的计时器
    ///（spike 里 5 次快照 0.4 秒滴答 40 下）。把根视图的内容置 nil 再逼一次布局，
    /// SwiftUI 就会同步跑掉 `onDisappear`，已经捕获的位图不受影响。
    @MainActor
    private static func dismantle(_ host: NSHostingView<SnapshotRoot>) {
        host.rootView = SnapshotRoot(content: nil)
        host.layoutSubtreeIfNeeded()
    }
}

private extension CGFloat {
    /// backing scale 兜底：拿到 0 / 负数（理论上不该有）时按 1 算，别让位图尺寸算成 0。
    var clampedToAtLeastOne: CGFloat { self < 1 ? 1 : self }
}

/// 可清空的宿主根视图。内容置 nil 就是「这棵子树没了」，`onDisappear` 因此有机会跑。
struct SnapshotRoot: View {
    var content: AnyView?

    var body: some View {
        ZStack { if let content { content } }
            // **拖动副本的开关只在这一处置位。** 四个快照调用点分别经由
            // `stripEntryContent` / `drawerChipContent`，而那两个 helper 同时也在渲染真正的卡；
            // 要是靠传参，就得给它们加带默认值的形参——「漏传照样编译」正是这仓库栽过两次的地方
            //（`ChipView.scale` 静默按中档、消息区整个没有名字气泡）。放在这里，现有四处和将来
            // 任何新增的快照都自动覆盖，忘不掉。
            //
            // AGENTS 里「环境值刷不动长命 hosting root」那条不适用：快照宿主每次现建现拆。
            .environment(\.isDragCarrierSnapshot, true)
    }
}
