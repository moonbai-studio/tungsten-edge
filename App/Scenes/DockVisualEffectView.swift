import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Visual Effect Background

/// 全部悬浮面板（任务条 / 抽屉 / 胶囊 / 两个弹窗）唯一的毛玻璃底。
/// `.behindWindow` 的模糊与提饱和度由 WindowServer 在窗口后面算，材质本身跟随系统外观。
struct DockVisualEffectView: NSViewRepresentable {
    /// 由调用方按当前外观传入（`DockThemeTokens.panelMaterial`）。
    var material: DockPanelMaterial = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material.nsMaterial
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    /// 必须真的应用材质：外观切换时 SwiftUI 只会重跑 update，不会重建 NSView。
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        let resolved = material.nsMaterial
        if nsView.material != resolved { nsView.material = resolved }
    }
}
