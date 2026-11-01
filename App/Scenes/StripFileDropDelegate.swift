import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// 外部文件拖入任务条的系统拖放收口。路由几何 = 纯函数 `StripDropRouting.route`;
/// 本 delegate 只负责:悬停期间把目标发布给视图做高亮、松手后异步取齐 URL 再回主线程提交。
/// 挂载点必须与 "strip" coordinateSpace 同层（坐标同源,评审拍板）。
///
/// **应用 bundle 与普通文件在这里就分开**：`.app` 只走 `onCommitApplications`（或松在废纸篓上时的
/// `onCommitTrash`），`onCommit`（`handleExternalDrop`）从此不可能拿到应用——那是本文件存在的第二个理由，
/// 也是「拖应用到文件夹格子上会把它从『应用程序』搬走」这个 bug 的两道闸之一。
struct StripFileDropDelegate: DropDelegate {
    /// Geometry is **read when a drop callback runs, never copied at construction**: the strip's
    /// frames live in `StripFrameBox` and the body no longer rebuilds this delegate when they move,
    /// so a value captured here would route a later drop by stale geometry (wrong folder, false
    /// trash). nil = 中转格被用户关掉（不是「帧还没量到」，后者仍传 `.zero`）。
    let shelfFrame: () -> CGRect?
    let trashFrame: () -> CGRect?
    let folderFrames: () -> [String: CGRect]
    let orderedPaths: [String]
    var headSlack: CGFloat = StripDropRouting.defaultHeadSlack
    /// The make-way gap open among the pinned folders right now (nil = none). No default: an
    /// omission compiles into a gap that closes under a pointer resting in it at the zone's ends.
    let openFolderGap: StripDropRouting.OpenFolderGap?
    /// dropEntered = 悬停会话开始;dropUpdated = 会话进行中移动;performDrop/dropExited = 会话结束。
    /// 视图侧据此做「高亮只能由 dropEntered 点亮 + 拖放结束看门狗」（见 externalDropHover*）。
    let onHoverBegan: (StripDropRouting.Target) -> Void
    let onHoverMoved: (StripDropRouting.Target) -> Void
    /// 参数 = 「这一支是落定吗」。只有 `performDrop` 传 `true`（空档留给落定交接）。
    let onHoverEnded: (Bool) -> Void
    let onCommit: (StripDropRouting.Target, [URL]) -> Void
    /// Everything released over the Trash chip, apps and volumes included (`TrashDropPlan` sorts them).
    let onCommitTrash: ([URL]) -> Void
    /// 拖进来的应用 bundle + 落点 x（"strip" 空间）。见 `handleExternalApplicationDrop`。
    let onCommitApplications: ([URL], CGPoint) -> Void
    /// 悬停期的让位空档：(悬停目标, 拖的应用的 bundleID 或 nil, 这次拖放是不是只有文件夹, 落点)。
    /// 视图侧负责把它折成锚点并做变化门控——**这里每 ~50ms 就会调一次**。
    let onGhostMoved: (StripDropRouting.Target, String?, Bool, CGPoint) -> Void
    /// 临时诊断用：此刻空档插在第几位（nil = 没有空档）、冻住的条宽、条的实际屏幕矩形。
    /// 后两个是用来验证「冻宽到底有没有生效」的——查清「加号闪烁」后删。
    let currentGhostIndex: () -> Int?
    let currentFrozenWidth: () -> CGFloat?
    let currentStripRect: () -> CGRect

    /// The target the latest hover callback resolved, read by `StripDropBadgeOverlay` right after it
    /// forwards the same callback. Main thread only. An orphan `dropUpdated` after a drop can leave it
    /// set: harmless, since only a `.copy` answer is rewritten and the next `dropEntered` overwrites it.
    static var hoveredTarget: StripDropRouting.Target?

    /// 悬停期的目标（决定高亮与光标）。应用一律 `.keepApp`。
    private func route(_ info: DropInfo) -> StripDropRouting.Target {
        route(info, isApplicationDrag: DragPasteboardInspector.containsApplication())
    }

    /// 非应用那一半的目标：混合拖拽时应用走保留、其余照旧走文件语义，所以要单独再算一份。
    private func fileRoute(_ info: DropInfo) -> StripDropRouting.Target {
        route(info, isApplicationDrag: false)
    }

    private func route(_ info: DropInfo, isApplicationDrag: Bool) -> StripDropRouting.Target {
        StripDropRouting.route(location: info.location,
                               isApplicationDrag: isApplicationDrag,
                               isTrashItemDrag: DragPasteboardInspector.containsOnlyTrashItems(),
                               shelfFrame: shelfFrame(),
                               trashFrame: trashFrame(),
                               folderFrames: folderFrames(),
                               orderedPaths: orderedPaths,
                               headSlack: headSlack,
                               pinEdgeFraction: DragPasteboardInspector.pinsFolders()
                                   ? StripDropRouting.folderPinEdgeFraction : 0,
                               openGap: openFolderGap)
    }

    private func reportGhost(_ target: StripDropRouting.Target, _ info: DropInfo) {
        onGhostMoved(target, DragPasteboardInspector.applicationBundleID(),
                     DragPasteboardInspector.pinsFolders(), info.location)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        let target = route(info)
        Self.hoveredTarget = target
        trace("entered", info, target: target)
        onHoverBegan(target)
        reportGhost(target, info)
    }

    /// Stays `.copy` over the Trash too: the badge-free answer is `StripDropBadgeOverlay`'s.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = route(info)
        Self.hoveredTarget = target
        trace("updated", info, target: target)
        onHoverMoved(target)
        reportGhost(target, info)
        return DropProposal(operation: target == .none ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        Self.hoveredTarget = nil
        trace("exited", info, target: route(info))
        onHoverEnded(false)   // 没有落定要接 → 空档当场收掉
    }

    /// 临时诊断（2026-09-08「加号一直闪」）。查清后连同 `HoverTrace.externalDrop` 一起删。
    private func trace(_ phase: String, _ info: DropInfo, target: StripDropRouting.Target) {
        guard HoverTrace.isEnabled else { return }
        HoverTrace.externalDrop(phase: phase,
                                x: info.location.x,
                                isApp: DragPasteboardInspector.containsApplication(),
                                target: "\(target)",
                                fileTarget: "\(fileRoute(info))",
                                operation: target == .none ? "forbidden" : "copy",
                                ghostIndex: currentGhostIndex(),
                                frozenWidth: currentFrozenWidth(),
                                stripRect: currentStripRect())
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = route(info)
        let fileTarget = fileRoute(info)
        let location = info.location
        Self.hoveredTarget = nil
        trace("perform", info, target: target)
        // 落定即灭高亮,同步清（系统在这之后仍可能补发孤立 dropUpdated,已被门控忽略）。
        // 传 true：空档要留到真图标进投影，由 `keepDroppedApplications` / `handleExternalDrop` 的
        // `.pin` 收（外加兜底 Timer）。A folder dropped *into* a chip fills no gap: close it now.
        let fillsGap: Bool
        switch target {
        case .keepApp:
            fillsGap = true
            // The gap follows the release point, while the session is still live, so the landing
            // takes over exactly the slot the app was let go in.
            reportGhost(target, info)
        case .pin: fillsGap = DragPasteboardInspector.pinsFolders()
        default: fillsGap = false
        }
        onHoverEnded(fillsGap)
        guard target != .none else { return false }
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        // The fallback for an in-process drag (see `StripDropRouting.committedURLs`). The drag
        // pasteboard is readable only while the session lives — snapshot it before this returns.
        let pasteboardURLs = DragPasteboardInspector.draggedURLs()

        // 异步取齐全部 URL,保持 provider 顺序,回主线程一次性提交。
        let group = DispatchGroup()
        let box = ResultBox(count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                box.set(url, at: index)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // Trash items are filtered here, before the app split, so a Trash `.app` cannot reach
            // the keep path either.
            let urls = StripDropRouting.committedURLs(
                loaded: box.urls,
                pasteboard: pasteboardURLs,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
            guard !urls.isEmpty else { return }
            // 落定这一刻按**真实 URL** 再判一次应用身份（悬停期读的是拖放剪贴板，只用来
            // 决定高亮和光标）。分流是硬的：`onCommit` 收到的绝不含应用。
            let split = StripDropRouting.commitSplit(target: target, fileTarget: fileTarget, urls: urls,
                                                     isApplication: DragPasteboardInspector.isApplication)
            if !split.trash.isEmpty {
                onCommitTrash(split.trash)
            }
            let applications = split.keepApplications.compactMap(DragPasteboardInspector.applicationURL)
            if !applications.isEmpty {
                onCommitApplications(applications, location)
            }
            if let files = split.files {
                onCommit(files.target, files.urls)
            }
        }
        return true
    }

    /// 拖放剪贴板速查：悬停期**同步**回答「这次拖的是不是应用」。
    ///
    /// 必须同步：`dropUpdated` 返回 `.forbidden` 时系统根本不会调 `performDrop`，
    /// 而应用的落点覆盖整条（包括窗口区，那里对文件是 `.none`）——用 `itemProviders`
    /// 异步取 URL 就意味着「从访达一把拖到窗口区松手」在 URL 到手之前已经被拒绝了。
    /// `NSPasteboard(name: .drag)` 在拖放会话期间对目标进程同步可读，正好补上这一格。
    ///
    /// `dropUpdated` 每 ~50ms 来一次,所以按 `changeCount` 缓存——一次拖放会话内只读一次盘。
    enum DragPasteboardInspector {
        private struct Session {
            let changeCount: Int
            /// Every dragged URL is inside a Trash: the whole drop is refused.
            let containsOnlyTrashItems: Bool
            let containsApplication: Bool
            /// 第一个应用 bundle 的 id。**解析 Info.plist 是读盘**，所以一次拖放会话只做一次
            /// ——`dropUpdated` 每 ~50ms 一次，逐次读盘会把主线程拖垮。
            let applicationBundleID: String?
            /// Every app bundle's id, deduped, in drag order — the drawer's make-way slot. Read in
            /// the same pass as the first.
            let applicationBundleIDs: [String]
            /// File URLs only, Trash items included (the caller filters them).
            let draggedURLs: [URL]
            /// `StripDropRouting.dragPinsFolders` over the non-app items. Read from disk once per session.
            let pinsFolders: Bool
            /// Every item is a volume root, so the Trash chip shows the eject icon, as on the native Dock.
            let ejectsVolumes: Bool
        }
        private static var session: Session?

        /// 拖放剪贴板里有没有应用 bundle。读不到（剪贴板为空 / 非文件拖放）一律 false:
        /// 保持原有的文件语义，落定时还会按真实 URL 再判一次。
        /// 只在主线程调（DropDelegate 的回调都在主线程），缓存因此不上锁。
        static func containsApplication() -> Bool {
            currentSession().containsApplication
        }

        /// 让位空档要显示给谁。`nil` = 不是应用拖放，或 bundle 坏了读不出 id → 不让位。
        static func applicationBundleID() -> String? {
            currentSession().applicationBundleID
        }

        /// The ids the drawer's make-way slot shows and its drop lands (`DrawerView`).
        static func applicationBundleIDs() -> [String] {
            currentSession().applicationBundleIDs
        }

        static func containsOnlyTrashItems() -> Bool {
            currentSession().containsOnlyTrashItems
        }

        /// Whether the drag is folders only, so the folder zone pins it: that is what opens the
        /// make-way gap, splits a chip into pin edges and a move-into centre, and drops the badge.
        static func pinsFolders() -> Bool {
            currentSession().pinsFolders
        }

        /// Whether the drag is volume roots only (`TrashDropPlan.isVolumeRoot`).
        static func ejectsVolumes() -> Bool {
            currentSession().ejectsVolumes
        }

        /// The dragged file URLs, read synchronously. Readable only while the session is alive.
        static func draggedURLs() -> [URL] {
            currentSession().draggedURLs
        }

        /// Path components only — nothing inside the Trash is read.
        static func isInsideTrash(_ url: URL) -> Bool {
            TrashPath.isInsideTrash(url, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }

        private static func currentSession() -> Session {
            let pasteboard = NSPasteboard(name: .drag)
            let changeCount = pasteboard.changeCount
            if let session, session.changeCount == changeCount { return session }
            let dragged = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            // Trash items are filtered before the app check: a mixed drag keeps only the rest.
            let urls = dragged.filter { !isInsideTrash($0) }
            let apps = urls.compactMap(applicationURL)
            let appIDs = apps.map { Bundle(url: $0)?.bundleIdentifier }
            var seen = Set<String>()
            let next = Session(
                changeCount: changeCount,
                containsOnlyTrashItems: !dragged.isEmpty && urls.isEmpty,
                containsApplication: !apps.isEmpty,
                applicationBundleID: appIDs.first.flatMap { $0 },
                applicationBundleIDs: appIDs.compactMap { $0 }.filter { seen.insert($0).inserted },
                draggedURLs: dragged.filter(\.isFileURL),
                pinsFolders: StripDropRouting.dragPinsFolders(
                    nonApplicationItemsAreDirectories: urls.filter { !isApplication($0) }.map { url in
                        url.isFileURL && ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
                    }),
                ejectsVolumes: !urls.isEmpty && urls.allSatisfy(TrashDropPlan.isVolumeRoot)
            )
            session = next
            return next
        }

        /// 是不是应用 bundle（替身、访达别名按它指向的那个算）。判法见 `DroppedApplication`。
        static func isApplication(_ url: URL) -> Bool {
            applicationURL(url) != nil
        }

        /// The bundle to read for a dragged item — its symlink / alias target when it is one.
        static func applicationURL(_ url: URL) -> URL? {
            DroppedApplication.bundleURL(for: url, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    /// loadObject 回调在后台线程,加锁按位写,保序。
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [URL?]
        init(count: Int) { urls = Array(repeating: nil, count: count) }
        func set(_ url: URL?, at index: Int) {
            lock.lock(); defer { lock.unlock() }
            urls[index] = url
        }
    }
}

/// Removes the cursor badge over the Trash chip, a folder's pin slot and an app drag, and the
/// system drop animation of an app drag; everything else about the drop stays SwiftUI's.
///
/// SwiftUI's `.onDrop` only offers `.copy` (badge) / `.move` / `.forbidden`, and its real AppKit
/// destination is a private subview spanning the strip — `NSWindow`'s dragging methods are never
/// called during a session, so neither the window nor a parent view can rewrite the answer. AppKit
/// hands the drag to the topmost registered view instead, so this view sits **over** that subview
/// with the same frame (`.overlay` right after `.onDrop`), forwards every dragging message to it
/// unchanged, and rewrites only the returned operation. SwiftUI therefore sees exactly the session it
/// saw before — one enter, updates, one exit or perform — so highlight, ghost, frozen width and the
/// watchdog are untouched. A view covering only the Trash chip would split that into exit/enter pairs.
struct StripDropBadgeOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> ForwardingView { ForwardingView() }
    func updateNSView(_ nsView: ForwardingView, context: Context) {}

    final class ForwardingView: NSView {
        private weak var destination: NSView?

        /// Observes drags only; clicks, hover and scrolling go to the content below.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveDestination()
            // SwiftUI may insert its destination view later in the same pass.
            DispatchQueue.main.async { [weak self] in self?.resolveDestination() }
        }

        override func layout() {
            super.layout()
            if destination?.window !== window { resolveDestination() }
        }

        /// Registered only while the SwiftUI destination is known, with its exact types: unregistered,
        /// AppKit targets SwiftUI directly and drops keep working (with the badge).
        private func resolveDestination() {
            let found = window == nil ? nil : Self.nearestDropDestination(from: self)
            destination = found
            let types = found?.registeredDraggedTypes ?? []
            if Set(types) != Set(registeredDraggedTypes) {
                unregisterDraggedTypes()
                if !types.isEmpty { registerForDraggedTypes(types) }
            }
        }

        /// The nearest registered view sharing an ancestor with `view` — the strip's only `.onDrop`.
        /// The ancestor itself counts too, in case a SwiftUI version handles drops in the hosting view.
        private static func nearestDropDestination(from view: NSView) -> NSView? {
            var ancestor = view.superview
            while let current = ancestor {
                if let found = firstRegistered(in: current, excluding: view) { return found }
                if !current.registeredDraggedTypes.isEmpty { return current }
                ancestor = current.superview
            }
            return nil
        }

        private static func firstRegistered(in root: NSView, excluding excluded: NSView) -> NSView? {
            for subview in root.subviews where subview !== excluded && !(subview is ForwardingView) {
                if !subview.registeredDraggedTypes.isEmpty { return subview }
                if let found = firstRegistered(in: subview, excluding: excluded) { return found }
            }
            return nil
        }

        private func liveDestination() -> NSView? {
            if destination?.window == nil { resolveDestination() }
            return destination
        }

        /// Read after forwarding: SwiftUI calls the delegate synchronously inside the forwarded call.
        private func answer(_ proposed: NSDragOperation, _ sender: NSDraggingInfo) -> NSDragOperation {
            let generic = StripDropRouting.usesGenericOperation(
                hoveredTarget: StripFileDropDelegate.hoveredTarget,
                pinsFolder: StripFileDropDelegate.DragPasteboardInspector.pinsFolders(),
                proposedIsCopy: proposed == .copy,
                sourceAllowsGeneric: sender.draggingSourceOperationMask.contains(.generic)
            )
            return generic ? .generic : proposed
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let destination = liveDestination() else { return [] }
            return answer(destination.draggingEntered(sender), sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let destination = liveDestination() else { return [] }
            return answer(destination.draggingUpdated(sender), sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            destination?.draggingExited(sender)
        }

        /// SwiftUI turns `animatesToDestination` on inside this call; switching it off afterwards is
        /// what lets the drag image vanish on release. Setting it after `performDragOperation:` is too late.
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let accepted = destination?.prepareForDragOperation(sender) ?? false
            if StripDropRouting.suppressesSystemDropAnimation(hoveredTarget: StripFileDropDelegate.hoveredTarget) {
                sender.animatesToDestination = false
            }
            return accepted
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            destination?.performDragOperation(sender) ?? false
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            destination?.concludeDragOperation(sender)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            destination?.draggingEnded(sender)
        }
    }
}
