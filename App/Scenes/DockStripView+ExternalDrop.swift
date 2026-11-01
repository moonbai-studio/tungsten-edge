import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · 外部文件拖入任务条：高亮、悬停目标、落下分发。
// 2026-09-05 从 DockStripView.swift 按 extension 拆出，只搬不改。
extension DockStripView {
    /// 外部拖入高亮的三个生命周期入口 + 看门狗。`externalDropTarget` 只在这一组里改。
    /// dropEntered：一次悬停会话开始 → 允许点亮。
    func externalDropHoverBegan(_ target: StripDropRouting.Target) {
        externalDropHoverActive = true
        // **必须在第一次插空档之前捕获**，否则冻住的是已经被空档撑宽的那个值，环照样成立。
        // 这里是整条悬停会话唯一的起点，所以捕获点只能在这儿。
        // An app the landing surely adds is the exception: its gap grows and re-centres the bar.
        if !appDropMayWidenOnHover(), frozenStripWidth == nil, stripRootScreenRect != .zero {
            frozenStripWidth = stripRootScreenRect.width
        }
        let trashMinX = settingsStore.showTrash && frames.trashFrame != .zero ? frames.trashFrame.minX : nil
        let measured = stripRootScreenRect == .zero ? nil
            : (frames.folderChipFrames.values.map(\.minX) + [trashMinX].compactMap { $0 }).min()
                .map { stripRootScreenRect.minX + $0 }
        frames.dropRightZoneScreenMinX = StripDropRouting.dropRightZoneBoundary(
            previous: frames.dropRightZoneScreenMinX, inheritsOpenGap: appDropGhost != nil, measured: measured)
        // A gap still waiting for the previous drop's landing now belongs to this session.
        externalDropGhostTimeout?.invalidate()
        externalDropGhostTimeout = nil
        setExternalDropTarget(target)
    }

    /// dropUpdated：只在会话进行中才更新;落定/离开后系统补发的孤立 dropUpdated（hoverActive=false）忽略 → 无回闪。
    func externalDropHoverMoved(_ target: StripDropRouting.Target) {
        guard externalDropHoverActive else { return }
        setExternalDropTarget(target)
    }

    /// performDrop/dropExited：会话结束 → 立即清高亮、作废看门狗、关门控（同步清,落定即灭,不留尾巴）。
    ///
    /// **让位空档不在这里清**：`performDrop` 也走这条，而真图标要等 `actionQueue` 把 bundleID
    /// 解析完才进投影——这中间把空档撤掉就会看到「空档合上 → 图标弹出」闪一下。
    /// 空档由 `keepDroppedApplications` 在真图标就位后清，外加 `armExternalDropGhostTimeout` 兜底。
    /// - Parameter isLanding: `true` 只有 `performDrop` 传——那一支要把空档留给落定交接。
    ///   其余收尾（`dropExited`、中转格开关变化）一律 `false`：没有落定要接，空档必须当场收掉，
    ///   否则条上留一个永远不走的空位。
    func externalDropHoverEnded(isLanding: Bool) {
        externalDropHoverActive = false
        externalDropGeneration &+= 1
        externalDropWatchdog?.invalidate()
        externalDropWatchdog = nil
        externalDropTarget = nil
        if isLanding, externalDropGhost != nil {
            // 交接期的兜底就上在这一处，而不是落定路径深处：`performDrop` 在这之后还有
            // 好几条提前 return（目标是 .none、没有 provider、URL 取空、一个应用都没解析出来），
            // 每一条都不会走到落定。上在这里，任何一条都能在 1s 内自愈。
            armExternalDropGhostTimeout()
        } else {
            // 没有空档要交接（拖的是普通文件，或本来就没让位）→ 立刻收，**包括解冻条宽**。
            // 少了这一支，拖文件落定后条宽会一直冻在悬停那一刻的值。
            clearExternalDropGhost()
        }
    }

    /// 悬停期更新让位空档。应用拖放（`bundleID` 非空）→ live 区空档；带文件夹的拖放 →
    /// 固定文件夹区空档（`StripDropRouting.folderGhostIndex`）；两者都不是 → 收空档。
    ///
    /// **变化门控是这个函数存在的理由**：`dropUpdated` 每 ~50ms 调一次，而写一次 `@State`
    /// 就是整条任务条重算一遍（实测过「1.2 秒拖动 46 次整条重算」）。锚点没变就一个字都不写。
    func updateExternalDropGhost(target: StripDropRouting.Target, bundleID: String?,
                                 pinsFolder: Bool, atX x: CGFloat) {
        // **门控与整条高亮同源，理由也同一条**：成功 drop 之后 ~330ms 系统会补发一次孤立的
        // `dropUpdated`。没有这道闸，那一次会把落定时刚收掉的空档重新开出来，而且顺手作废
        // 兜底 Timer——条上从此留一个永远不走的空位（2026-09-08 owner 实测，拖「查找」进条后
        // 右边多一个空位，把「查找」移除也还在）。会话结束后既不能重开空档，也不能把正在
        // 交接的空档抹掉，所以这里是直接返回，不是清空。
        guard externalDropHoverActive else { return }
        guard let bundleID else {
            let current = externalDropGhost.flatMap { $0.zone == .folder ? $0.insertIndex : nil }
            let index = StripDropRouting.folderGhostIndex(current: current, target: target,
                                                          pinsFolder: pinsFolder)
            setExternalDropGhost(index.map { StripDropGhost(zone: .folder, insertIndex: $0) })
            return
        }
        if StripDropRouting.appGhostCloses(pointerX: stripRootScreenRect.minX + x, target: target,
                                           rightZoneMinX: frames.dropRightZoneScreenMinX) {
            return setExternalDropGhost(nil)
        }
        // 落点判定与抽屉转正共用一份（`StripBlockLanding`）。空档不上报卡帧，所以 `chipFrames`
        // 里只有真卡——但它们的**位置**已经被空档推开了，所以判定结果必须折成插入序号才稳定
        //（理由见 `StripDropGhost`）。显示序按帧的左缘排，与渲染序同源。
        let orderedLiveIDs = chipFrames.sorted { $0.value.minX < $1.value.minX }.map(\.key)
        let target = blockTarget(atX: x, excluding: [])
        let index = StripDropRouting.ghostInsertionIndex(orderedIDs: orderedLiveIDs,
                                                         targetID: target?.id,
                                                         after: target?.after ?? false)
        setExternalDropGhost(StripDropGhost(zone: .live(bundleID: bundleID), insertIndex: index))
    }

    /// The open make-way gap if it is an app's (`.live` zone); a folder's gap is `nil` here.
    var appDropGhost: StripDropGhost? {
        guard let ghost = externalDropGhost, case .live = ghost.zone else { return nil }
        return ghost
    }

    /// Whether this drag is an app the landing will surely add as a new launcher card, so the bar
    /// may grow and re-centre while it hovers (`StripDropRouting.appDropMayWidenOnHover`).
    func appDropMayWidenOnHover() -> Bool {
        guard let bundleID = StripFileDropDelegate.DragPasteboardInspector.applicationBundleID() else {
            return false
        }
        return StripDropRouting.appDropMayWidenOnHover(
            isRunning: runningApplicationStore.isRunning(bundleID),
            isMessaging: messagingStore.contains(bundleID),
            isFinder: FinderTaskbarPolicy.isFinder(bundleID),
            hasEntryOnStrip: !freshProjection().liveEntryIDs(bundleID: bundleID).isEmpty
        )
    }

    /// `.onChange(of: externalDropGhost)`. The box holds what the last body rendered, so it is
    /// compared before it is overwritten.
    func appDropGhostDidChange() {
        let previous = frames.renderedAppGhost
        let current = appDropGhost
        frames.renderedAppGhost = current
        if (previous == nil) != (current == nil) { onAppGapPresenceChange() }
        // The hand-over just ended. The landed card does not necessarily move any geometry (a card
        // re-dropped in place, a bar at its width limit) and a resting pointer is never re-polled,
        // so re-resolve explicitly once SwiftUI has laid out the new card.
        if previous != nil, current == nil, !externalDropHoverActive {
            DispatchQueue.main.async {
                refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
            }
        }
    }

    static var entryTransition: AnyTransition {
        .scale(scale: 0.88).combined(with: .opacity)
    }

    /// A card an app drop just added enters with no transition of its own: it takes the gap's slot
    /// in the same update, and `DroppedAppLandingGrow` grows its artwork inside the frame readers.
    static var droppedAppLandingTransition: AnyTransition {
        .asymmetric(insertion: .identity, removal: entryTransition)
    }

    /// The change gate. Closing keeps the frozen width: the hover session is still running, and
    /// unfreezing mid-session re-centres the bar under the pointer (see `frozenStripWidth`).
    private func setExternalDropGhost(_ next: StripDropGhost?) {
        guard next != externalDropGhost else { return }
        externalDropGhostTimeout?.invalidate()
        externalDropGhostTimeout = nil
        externalDropGhost = next
    }

    /// 落定后给空档上一条有界兜底：真图标该进投影了却没进（bundle 坏了 / canKeep 不过 /
    /// 解析失败）时，空档也必须自己走掉。
    func armExternalDropGhostTimeout() {
        guard externalDropGhost != nil else { return }
        externalDropGhostTimeout?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
            clearExternalDropGhost()
        }
        RunLoop.main.add(timer, forMode: .common)
        externalDropGhostTimeout = timer
    }

    /// 空档撤掉的同时解冻条宽——两者同寿：落定那一支要等真图标进了投影才解冻，
    /// 条才会一次干净地长到最终长度，而不是先弹回旧宽再变长。
    func clearExternalDropGhost() {
        externalDropGhostTimeout?.invalidate()
        externalDropGhostTimeout = nil
        externalDropGhost = nil
        frozenStripWidth = nil
    }

    /// 设落点目标 + 重置拖放结束看门狗。`dropUpdated` 悬停期每 ~50ms 来一次会不断把 0.35s Timer 推后
    /// → 移动/静止悬停都不会误清;一旦拖放结束却没给收尾回调（dropUpdated 停），Timer 到点即清遗留高亮。
    /// generation 仍匹配才清,避免已入队的旧 Timer 误清新拖放。只动 `externalDropTarget`,不碰抽屉 unstash 高亮。
    func setExternalDropTarget(_ target: StripDropRouting.Target) {
        externalDropTarget = target
        externalDropGeneration &+= 1
        externalDropWatchdog?.invalidate()
        let gen = externalDropGeneration
        let timer = Timer(timeInterval: 0.35, repeats: false) { _ in
            guard externalDropGeneration == gen else { return }
            externalDropHoverActive = false
            externalDropTarget = nil
            externalDropWatchdog = nil
            // 这是「拖放结束却一个收尾回调都没给」那条路径。会话已经死了，
            // 空档和冻住的条宽都得跟着走，否则条会一直卡在悬停时那个宽度。
            clearExternalDropGhost()
        }
        RunLoop.main.add(timer, forMode: .common)
        externalDropWatchdog = timer
    }

    /// 外部拖放落定（DropDelegate 异步取齐 URL 后回到主线程调）。
    /// 中转收一切；命中 chip 移入；间隙/尾部固定只收目录。
    ///
    /// **`urls` 里绝不会有应用 bundle**——`StripFileDropDelegate` 已经把它们分流到
    /// `handleExternalApplicationDrop`，`.keepApp` 也不会走到这里来。A drop on the Trash arrives
    /// through `handleTrashDrop` instead.
    func handleExternalDrop(_ target: StripDropRouting.Target, urls: [URL]) {
        switch target {
        case .stash:
            shelfStore.stash(paths: urls.map(\.path))
        case .moveInto(let path):
            // 第二道闸也守这一支：这里是真实的文件移动（同卷移动、跨卷复制），漏进一个
            // 应用就等于把它从「应用程序」里搬走。分流那道闸在 `StripFileDropDelegate`。
            let files = urls.filter { !StripFileDropDelegate.DragPasteboardInspector.isApplication($0) }
            guard !files.isEmpty else { break }
            onMoveExternalFiles(files, path)
        case .pin(let insertIndex):
            var index = insertIndex
            for url in urls where isPinnableDirectory(url) {
                pinnedFolderStore.insert(url.path, at: index)
                index += 1
            }
            // The gap leaves in the same update that brings the chips in, so the neighbours do not
            // move. An app's gap (mixed drag) is not ours to close — `keepDroppedApplications` does —
            // and neither is the gap of a drag that began hovering before this commit arrived.
            if externalDropGhost?.zone == .folder, !externalDropHoverActive { clearExternalDropGhost() }
        case .trash, .keepApp, .none:
            break
        }
    }

    /// Everything released over the Trash chip. Volumes are ejected; apps are moved to the Trash
    /// unless running, and the ones that went leave the bar and the drawer too — a kept icon would
    /// otherwise stay behind, opening nothing; other items are moved as before.
    func handleTrashDrop(_ urls: [URL]) {
        let runningBundleURLs = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Reads the disk (resource values, symlinks, Info.plist): a user action, so `actionQueue`.
        AppRuntime.actionQueue.async {
            let runningBundlePaths = Set(runningBundleURLs.map(TrashDropPlan.canonicalPath))
            let plan = TrashDropPlan.build(
                urls: urls,
                applicationURL: { DroppedApplication.bundleURL(for: $0, homeDirectory: home) },
                isVolumeRoot: TrashDropPlan.isVolumeRoot,
                runningBundlePaths: runningBundlePaths)
            // Only a bundle that is itself the dragged item leaves the bar: trashing an alias or a
            // symlink removes the link, and the app it opens is still installed.
            var bundleIDs: [String: String] = [:]
            for url in plan.trashesApplications
            where DroppedApplication.bundleURL(for: url, homeDirectory: home)?.standardizedFileURL == url.standardizedFileURL {
                bundleIDs[url.path] = Bundle(url: url)?.bundleIdentifier
            }
            DispatchQueue.main.async {
                trashStore.eject(plan.ejects)
                trashStore.noteApplicationsInUse(plan.refusesRunningApplications)
                trashStore.trashApplications(plan.trashesApplications) { moved in
                    for url in moved {
                        guard let bundleID = bundleIDs[url.path] else { continue }
                        appMembershipController.setKept(bundleID, enabled: false)
                        appMembershipController.moveOutOfDrawer(bundleID)
                    }
                }
                trashStore.trash(plan.trashesFiles)
            }
        }
    }

    /// 从访达把应用拖进任务条：勾「在程序坞中保留」+ 落到光标那个位置（owner 2026-09-07）。
    /// 语义与「拖进抽屉会顺手勾上保留」并列（`Docs/27`）：只管进、不管出，每次拖入都重新勾上，
    /// 所以已经保留的应用再拖一次 = 换个位置，不是错误。
    /// An app placed in the drawer (hidden ones included) is moved out first, as when its drawer cell
    /// is dragged onto the bar: a kept app shows only in the drawer, so the drop would add nothing here.
    ///
    /// - Parameter x: 落点 x（"strip" 空间），落位判定与抽屉转正共用 `StripBlockLanding`。
    func handleExternalApplicationDrop(_ urls: [URL], atX x: CGFloat) {
        let paths = urls.map(\.path)
        // 读 Info.plist 是读盘：铁律——用户动作走 `actionQueue`，既不用 `Task.detached`，
        // 也不占 Swift 协作池（那里跑着 AppTracker 的阻塞式 AX 读）。
        AppRuntime.actionQueue.async {
            let bundleIDs = paths.compactMap { path in
                Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
            }
            DispatchQueue.main.async {
                // 坏 bundle / 没有 Info.plist → 静默忽略，但空档得立刻收掉（兜底 Timer 之前）。
                guard !bundleIDs.isEmpty else { return clearExternalDropGhost() }
                keepDroppedApplications(bundleIDs, atX: x)
            }
        }
    }

    /// 逐个勾保留 + 落位。第二个及以后的应用落在前一个右边，保持拖进来的顺序。
    private func keepDroppedApplications(_ bundleIDs: [String], atX x: CGFloat) {
        // 空档在最后一句才撤——落点是拿它当锚点算的，撤早了 `blockTarget` 会把它让出来的
        // 那段宽度算回去，图标落到隔壁。
        defer { clearExternalDropGhost() }
        var previousAnchor: (id: String, after: Bool)?
        var addedIDs = Set<String>()
        defer { markLandingEntries(addedIDs) }
        for bundleID in bundleIDs where keptAppStore.canKeep(bundleID) {
            // 落点：拖的是它自己已有的卡时要排除自己，否则整块会以自己为锚、原地不动。
            let ownIDs = Set(freshProjection().liveEntryIDs(bundleID: bundleID))
            let target = previousAnchor ?? blockTarget(atX: x, excluding: ownIDs)
            stripOrderStore.stageExternalBlock(bundleID: bundleID,
                                               relativeTo: target?.id,
                                               after: target?.after ?? false)
            appMembershipController.moveOutOfDrawer(bundleID)
            appMembershipController.setKept(bundleID, enabled: true)
            // **同步**跑一次 sync 把刚暂存的落点块消费掉。不能等 `onChange(of: keptAppStore.bundleIDs)`：
            // 那一趟什么时候跑不确定，先 commit 会把暂存丢掉（图标落到末尾），不 commit 则以后每次
            // sync 都重复搬运这一块，把用户后来的手动重排顶回去。
            reconcileLiveOrder(freshProjection())
            stripOrderStore.commitExternalBlock()
            // 一次拖多个应用：下一个落在这一个右边，保持拖进来的顺序。锚点从落定后的投影里取
            // （运行中的应用没有 `app-<bid>` 占位卡，只有窗口卡，硬拼占位 id 会锚到一个不存在的 chip）。
            let landedIDs = freshProjection().liveEntryIDs(bundleID: bundleID)
            // Only cards that were not on this strip get the grow-in; a re-dropped one slides over.
            addedIDs.formUnion(Set(landedIDs).subtracting(ownIDs))
            let landed = landedIDs.last
            previousAnchor = (landed ?? "app-\(bundleID)", true)
        }
    }

    /// Marks freshly landed cards for `droppedAppLandingTransition`, in the same turn as the gap
    /// clears, and unmarks only these once the entrance is over (a later drop keeps its own marks).
    private func markLandingEntries(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        landingEntryIDs.formUnion(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            landingEntryIDs.subtract(ids)
        }
    }

    /// 能不能固定成文件夹格子。**应用 bundle 在文件系统里就是目录**，所以光判 `isDirectoryKey`
    /// 会把应用固定成一个展开 `.app` 内部结构的格子——这是 2026-09-07 之前的真实 bug。
    /// 分流那一道闸在 `StripFileDropDelegate`，这里是第二道：`.moveInto` 是真实的文件移动
    /// （同卷移动、跨卷复制），一旦漏进来就会把用户的应用从「应用程序」里搬走。
    private func isPinnableDirectory(_ url: URL) -> Bool {
        guard !StripFileDropDelegate.DragPasteboardInspector.isApplication(url) else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }
}
