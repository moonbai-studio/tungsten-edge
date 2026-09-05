import Foundation

/// 任务条读到的窗口清单快照：`AppTracker` 发布、`AppRuntime` 消费，全应用的窗口真值。
/// 2026-09-05 从 `DockState.swift` 拆出——那个文件的另一半（`DockState` 容器）只有诊断工具
/// window-lab 的旧观测管线在用，已随管线搬到 `Tools/WindowLab/Pipeline/`。
struct DockSnapshot: Equatable, Sendable {
    var windows: [WindowID: WindowRecord]
    var orderedWindowIDs: [WindowID]

    static let empty = DockSnapshot(windows: [:], orderedWindowIDs: [])
}
