import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · 悬停归属与名字气泡请求（整条一块跟踪区）。
// 2026-09-05 从 DockStripView.swift 按 extension 拆出，只搬不改。
extension DockStripView {
    // MARK: - 悬停归属（整条一块跟踪区）

    /// 重新判一次「指针压在谁身上」，**只有结论变了才写 `@State`**。
    /// 判定是纯函数 `StripHoverResolution`：缝隙里按到卡边的距离取近，边界与来向无关。
    ///
    /// 帧和原点显式传进来而不是读 `self`：它俩自己也是 `@State`，在 `onChange` /
    /// `onPreferenceChange` 闭包里读到的是旧值。
    func refreshHoveredEntry(frames: [String: CGRect], origin: CGRect) {
        // 起拖那一两帧**原地冻结**：载体正按卡槽此刻的「悬停 × 按压」姿态压在卡上，
        // 这时候把悬停清掉、卡开始回落，两者就对不上了（owner 2026-08-19「上下残影」）。
        guard !dragController.hoverFrozen else { return }
        let resolved: String? = {
            // 手里拎着东西时不判悬停，落地之后也**先按住、等指针真动了再判**。三个理由：
            // ① 拖动途中指针扫过谁就给谁点亮、还弹名字气泡，本来就不对；
            // ② 松手位置必然压在刚落定的那张卡上——载体画的是**非悬停**态，
            //    卡一显形却已经是悬停态（安静档还要放大 1.10），两者尺寸不一样，
            //    交接那一帧就"啵"地跳一下；
            // ③ 卡以 1.0 停稳后立刻重判悬停，安静档会当场往上长 1.10——图标刚停稳又动一下，
            //    就是 owner 2026-08-19 报的「落位抖动」。AppKit 自己对拖放结束后的悬停也是
            //    等鼠标动了才发 mouseEntered。按住期由 `DragController.hoverHoldPayload` 管。
            guard !dragController.hoverSuppressed else { return nil }
            guard let pointer = pointerBox.value, origin != .zero else { return nil }
            let point = CGPoint(x: pointer.x - origin.minX, y: origin.maxY - pointer.y)
            let hit = StripHoverResolution.chip(
                at: point,
                frames: frames,
                gapBridge: StripHoverResolution.defaultGapBridge * dockScale
            )
            // 正在飞回去的 / 刚落定还没等到指针移动的那**一张**不给悬停，别的卡照常
            //（owner 2026-08-19：「图标飞行时鼠标划到其他图标上没有悬停效果」）。理由见
            // `DragController.hoverExemptPayload`。
            if let exempt = dragController.hoverExemptPayload,
               carriedStripEntryID(for: exempt) == hit { return nil }
            return hit
        }()
        if resolved != hoveredEntryID { hoveredEntryID = resolved }
    }

    /// 该 entry 的气泡文案。`nil` = 这类 chip 不弹气泡。
    ///
    /// **弹的是应用名，不是窗口标题**（owner 2026-08-17，原生 Dock 的标签永远只写应用名）。
    /// 固定文件夹不弹——它的名字常驻在封面下方；分隔线不是 chip。
    private func bubbleTitle(for entry: StripEntry) -> String? {
        switch entry {
        case let .window(item):
            return appBubbleName(bundleID: item.bundleIdentifier, fallback: item.appID)
        case let .messagingApp(bid, _):
            return appBubbleName(bundleID: bid, fallback: bid)
        case let .keptApp(bid):
            return appBubbleName(bundleID: bid, fallback: bid)
        case .shelf:
            let count = shelfStore.itemPaths.count
            return count > 0
                ? String(format: String(localized: "Shelf · %d"), count)
                : String(localized: "Shelf")
        case .pinnedFolder, .divider:
            return nil
        }
    }

    private func appBubbleName(bundleID: String?, fallback: String) -> String {
        let name = bundleID.map(AppDisplayNameResolver.displayName(for:)) ?? fallback
        return WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: name)
    }

    /// 这一帧该给气泡面板什么。`nil` = 收气泡。
    ///
    /// 由「指针位置 + 卡片几何 + 档位」整体推出来，所以锚点漂移、应用名变化、档位切换
    /// 全都自动跟上，不需要每张卡各自补发 `.refresh`——那套「内容驱动的重发」连同它的
    /// 归属守卫一起没了，因为现在**只有一个人**能占用这块面板。
    ///
    /// 安静档不弹气泡（`hoverStyle.isExpressive`），与改造前的 `showsHover` 门槛一致。
    func bubbleRequest(projection: StripProjection) -> WindowTitleTooltipRequest? {
        guard hoverStyle.isExpressive,
              let id = hoveredEntryID,
              let frame = stripHoverFrames[id],
              stripRootScreenRect != .zero,
              let entry = projection.entries.first(where: { $0.id == id }),
              let title = bubbleTitle(for: entry) else { return nil }
        return WindowTitleTooltipRequest(chipID: id,
                                         title: title,
                                         anchorVisibleRect: stripFrameToScreen(frame))
    }

    /// 右键任务条底板时该不该弹钨极菜单。判定本身在纯 `StripContextMenuZone` 里，
    /// 这里只负责换算坐标、把四个区的帧凑齐（消息区 / 固定文件夹 / 中转格的帧各有独立的
    /// PreferenceKey，从来不合并进 `chipFrames`）。
    func taskbarMenuZoneClaims(atScreen global: CGPoint) -> Bool {
        guard let point = stripPoint(from: global) else { return false }
        var frames = Array(chipFrames.values)
        frames.append(contentsOf: folderChipFrames.values)
        frames.append(contentsOf: messagingChipFrames.values)
        if shelfFrame != .zero { frames.append(shelfFrame) }
        return StripContextMenuZone.claims(
            point: point,
            chipFrames: frames,
            bounds: CGRect(origin: .zero, size: stripRootScreenRect.size),
            minimumGapWidth: StripContextMenuZone.defaultMinimumGapWidth * dockScale
        )
    }
}
