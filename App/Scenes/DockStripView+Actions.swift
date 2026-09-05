import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · 点击 / 手势动作：文件夹、中转站、内容预览、消息应用兜底。
// 2026-09-05 从 DockStripView.swift 按 extension 拆出，只搬不改。
extension DockStripView {
    /// Kept launcher uses the same shared membership projection (strip surface).
    func keptAppMembershipItems(bundleID: String) -> [LauncherMembershipItem] {
        LauncherMembershipItem.items(
            surface: .strip,
            bundleID: bundleID,
            isKept: keptAppStore.contains(bundleID),
            isMessaging: messagingStore.contains(bundleID),
            controller: appMembershipController
        )
    }

    /// 固定文件夹左键唯一入口：按 `FolderInteraction.primaryAction` 分派（现固定 = 内容预览）。
    /// A/B「左键预览 vs 左键开 Finder」只改策略枚举，不动这里的调用点。
    func folderPrimaryTap(_ path: String) {
        switch FolderInteraction.primaryAction {
        case .openFinderWindow: openFolderInFinder(path)
        case .preview: folderShowPreview(path)
        }
    }

    /// 打开该路径的访达窗口（best-effort；左键与右键「在访达中打开」共用此入口）。
    func openFolderInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 固定文件夹内容预览唯一入口（左键 A/B 的 preview 分支、右键「预览内容」、以后中键/重击都走它）。
    /// 把 "strip" 空间帧（top-left,y-down）换算成屏幕坐标（bottom-left）传给弹窗。
    /// 镜像 stripPoint(from:) 的逆映射。帧未就绪（首帧）就不弹,下次触发再说。
    func folderShowPreview(_ path: String) {
        let entryID = StripEntry.pinnedFolder(path: path).id
        guard let frame = folderChipFrames[entryID], stripRootScreenRect != .zero else { return }
        let screenRect = CGRect(
            x: stripRootScreenRect.minX + frame.minX,
            y: stripRootScreenRect.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        onFolderPopupToggle(path, screenRect)
    }

    /// strip 空间帧 → 屏幕矩形（stripPoint(from:) 的逆；弹窗锚点用）。
    func stripFrameToScreen(_ frame: CGRect) -> CGRect {
        CGRect(x: stripRootScreenRect.minX + frame.minX,
               y: stripRootScreenRect.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    /// 手势（重击/中键）命中回调：全局屏幕坐标 → strip 空间 → 命中固定文件夹 / 具体访达窗口 → 预览。
    /// 命中不到任何可预览 chip 就静默忽略。
    func handleGesturePreview(atScreen global: CGPoint) {
        guard let p = stripPoint(from: global) else { return }
        for path in pinnedFolderStore.folderPaths {
            let entryID = StripEntry.pinnedFolder(path: path).id
            if let frame = folderChipFrames[entryID], frame.contains(p) {
                onFolderPopupToggle(path, stripFrameToScreen(frame))
                return
            }
        }
        for (cid, frame) in chipFrames where frame.contains(p) {
            guard let item = StripItem.items(from: runtime.snapshot).first(where: { $0.id == cid }),
                  FinderTaskbarPolicy.isFinder(item.bundleIdentifier), item.isAppLevelFallback == false else { return }
            chipPulseNonces[cid, default: 0] += 1   // 立刻"点到了"反馈，兜住反查那 ~200ms
            previewFinderWindow(item, anchor: stripFrameToScreen(frame))
            return
        }
    }

    /// 具体访达窗口 → 反查路径 → 预览。AX 定位 + 权限流在主线程，AppleEvents 枚举放后台，
    /// 成功回主线程开预览；拒授权 / 无唯一匹配 / 超时 → beep + log，不弹空窗（spike#2 已验证）。
    private func previewFinderWindow(_ item: StripItem, anchor: CGRect) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.caye.macosdockcc.v2", category: "FinderWindowPreview")
        let ref = FinderWindowReference(pid: item.pid, cgWindowID: item.cgWindowID, title: item.title, bounds: item.bounds)
        let reader = FinderWindowContentsReader()
        let onToggle = onFolderPopupToggle

        func resolveViaAppleEvents(_ aeTarget: FinderWindowAppleEventsTarget) {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = try FinderWindowContentsReader.folderURLViaAppleEvents(for: aeTarget)
                    DispatchQueue.main.async { onToggle(url.path, anchor) }
                } catch {
                    logger.error("finder-window-preview AppleEvents failed: \(String(describing: error), privacy: .public)")
                    DispatchQueue.main.async { NSSound.beep() }
                }
            }
        }
        // 最小化窗口在 AX 里按 cgWindowID 定位不到（缺失/对不上）→ 用 StripItem 自带的 title+frame
        // 直接走 AppleEvents 唯一匹配（AppleScript 的 `Finder windows` 含最小化窗口，报还原态 bounds）。
        func resolveFromItem() {
            guard let bounds = item.bounds else { NSSound.beep(); return }
            resolveViaAppleEvents(FinderWindowAppleEventsTarget(title: item.title, cocoaFrame: bounds))
        }

        do {
            switch try reader.target(for: ref) {
            case .folderURL(let url):
                onToggle(url.path, anchor)
            case .appleEvents(let aeTarget):
                resolveViaAppleEvents(aeTarget)
            }
        } catch FinderWindowContentsError.windowNotFound {
            resolveFromItem()
        } catch FinderWindowContentsError.missingWindowID {
            resolveFromItem()
        } catch FinderWindowContentsError.automationPermissionRequired {
            if FinderWindowContentsReader.requestFinderAutomationPermission() { resolveFromItem() } else { NSSound.beep() }
        } catch {
            logger.error("finder-window-preview target failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    /// 中转格点击：同 folderShowPreview 的坐标换算,锚点用独立的 shelfFrame。
    func shelfChipTapped() {
        guard shelfFrame != .zero, stripRootScreenRect != .zero else { return }
        let screenRect = CGRect(
            x: stripRootScreenRect.minX + shelfFrame.minX,
            y: stripRootScreenRect.maxY - shelfFrame.maxY,
            width: shelfFrame.width,
            height: shelfFrame.height
        )
        onShelfPopupToggle(screenRect)
    }

    /// Dock-icon-click equivalent: unhide + reopen. The app recreates its main window
    /// even when other windows are visible (verified with WeChat, 2026-06-12).
    /// 消息区图标**认不出主窗口**时的左键（第 3 条兜底，2026-08-23）：
    /// - app 没有任何真窗口 → 叫回主窗口（owner 每天「关主窗 → 点图标叫回来」的流程，不能变）；
    /// - 有窗口但认不出哪扇是主 → **整个 app 的开关**：在前台就收起、否则唤到前台。图标永远
    ///   有反应，代价是独立聊天窗一起收——比改前「只能叫不能收」强。逻辑复用抽屉图标那份
    ///   `LauncherChip.performDefaultTap`，不另抄一遍「前台就收起、否则唤出」。
    static func messagingFallbackTap(bundleID: String, hasRealWindow: Bool) {
        guard hasRealWindow else {
            reopenMainWindow(bundleID: bundleID)
            return
        }
        LauncherChip.performDefaultTap(bundleID: bundleID, isRunning: true,
                                       finderHasRealWindow: false,   // 访达进不了消息区
                                       launch: {}, onOpen: nil)
    }

    static func reopenMainWindow(bundleID: String) {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter {
                $0.activationPolicy == .regular
                    && ProcessLiveness.isAlive(pid: $0.processIdentifier)
            }
        for app in runningApps { _ = app.unhide() }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }
}
