import Foundation

/// 旧观测管线（`ObservationPipeline`）的状态容器。**正式 App 不用它**——只有 window-lab
/// 诊断工具实例化这条管线；App 的窗口真值由 `AppTracker.reconcile()` 内联构建并发布
/// `DockSnapshot`（`Core/Model/DockSnapshot.swift`）。
@MainActor
final class DockState {
    private(set) var snapshot: DockSnapshot = .empty

    func commit(_ update: StateUpdate) {
        var next = snapshot
        if let windowRecord = update.windowRecord {
            next.windows[windowRecord.id] = windowRecord
        } else {
            next.windows.removeValue(forKey: update.windowID)
        }
        next.orderedWindowIDs = update.orderedWindowIDs
        guard next != snapshot else { return }
        snapshot = next
    }
}
