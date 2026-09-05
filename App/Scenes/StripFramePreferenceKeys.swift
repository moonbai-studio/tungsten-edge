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
