import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// 悬停命中帧（`StripEntry.id` → "strip" 空间帧）。**四个区的卡全收进这一本**——它回答的是
/// 「指针压在谁身上」，那本来就不分区。同样独立于其余三本：那三本各自喂重排 / 弹窗锚点 /
/// 释放判定，语义不同，合并会互相污染（评审 P1 的老教训）。
struct StripHoverFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 文件夹 chip 帧（弹窗锚点 + 外部拖入 pin 路由）。独立于 ChipFramePreferenceKey——后者是
/// live 窗口区拖拽重排/落点命中的输入,文件夹 id 混进去会被当成落点目标（评审 P1）。
struct FolderChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 消息区 chip 帧（bundleID → frame）。独立于 ChipFramePreferenceKey——理由同文件夹 chip：
/// 混进 live 重排/落点命中的输入会让窗口拖动命中消息区、落点 no-op。
struct MessagingChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 中转格 frame（单值）。独立于 FolderChipFramePreferenceKey（评审：文件夹帧字典不混 sentinel）。
struct ShelfFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct TrashFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Where the reported geometry lives

/// Every frame the strip reports about itself — the four per-zone chip-frame tables, the shelf and
/// trash frames and the content area's screen rect — lives here, in one reference box held by
/// `DockStripView` as `@State var frames`, **never as `@State` values of its own**.
///
/// The reason is the write frequency: during a make-way spring, a slot collapse / reopen or the
/// panel re-centering, every one of these changes on **every animation frame**, and a `@State`
/// write re-evaluates the whole strip (`makeProjection`, order reconcile, twenty chips). Writing a
/// property of a class held in `@State` invalidates nothing, so the geometry can update at frame
/// rate while the body only re-runs for model changes. Everything that reads geometry does so at
/// event time (reorder hit-tests, landing anchors, hover resolution, drop routing, popup anchors)
/// and reads the box directly — always the latest value, never a copy captured by an earlier body.
/// The one rendering input derived from geometry, the hover bubble's anchor, is written separately
/// as `DockStripView.hoveredAnchor` only when the hovered card's screen frame actually moves.
@MainActor
final class StripFrameBox {
    /// Live chip frames by id in the `"strip"` space — the drag-reorder hit-test and landing input.
    var chipFrames: [String: CGRect] = [:]
    /// Hover hit frames for every zone's cards (`StripEntry.id` → frame): "who is under the pointer".
    var stripHoverFrames: [String: CGRect] = [:]
    /// Pinned-folder chip frames — popup anchors, external pin routing, in-zone reorder. Never merged
    /// into `chipFrames` (a folder id there becomes a landing target).
    var folderChipFrames: [String: CGRect] = [:]
    /// Messaging chip frames by bundle id — in-zone reorder and the drawer→messaging release range.
    var messagingChipFrames: [String: CGRect] = [:]
    var shelfFrame: CGRect = .zero
    var trashFrame: CGRect = .zero
    /// The content area's frame in screen coordinates (bottom-left); `.zero` until first reported.
    var stripRootScreenRect: CGRect = .zero
    /// The `stripSlotCollapsed` value the last committed body rendered. Written from
    /// `.onChange(of: stripSlotCollapsed)` — the same moment the old `@State` copy was written, so the
    /// body that first sees the flip still picks the collapse curve — but as a box field the write
    /// itself no longer re-evaluates the strip (that echo body rendered nothing new).
    var renderedCollapsed = false
    /// The app make-way gap (`.live` zone only) the last committed body rendered, written in
    /// `.onChange(of: externalDropGhost)` after it is compared — the old value that picks the
    /// panel-matched curve and tells the panel to re-measure. Folder gaps are never stored here.
    var renderedAppGhost: StripDropGhost?
    /// Screen x where the pinned folders (else the Trash) start, taken when an external drop begins
    /// hovering — before any make-way gap moves them. `StripDropRouting.appGhostCloses` reads it.
    var dropRightZoneScreenMinX: CGFloat?
}

// MARK: - Drag-reorder preference (任务条拖动重排 路线 A 自绘拖动)

/// Collects live chip frames by id in the `"strip"` space — feeds the floating drag copy's
/// position and the left/right-half landing decision (replaces the old width-only key + the
/// SwiftUI DropDelegates, now that the drag is a self-rendered in-app gesture).
struct ChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
