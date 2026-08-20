import AppKit
import SwiftUI

/// 窗口根视图。和权限引导同一个结构：滚动条平时不出现，窗口高度由内容自然高度决定，
/// 只有被屏幕高度截断时才真的需要滚。
struct WelcomeGuideWindowContent: View {
    let onHideDock: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            WelcomeGuideView(onHideDock: onHideDock, onDismiss: onDismiss)
        }
        .frame(width: WelcomeGuideView.contentWidth)
    }
}

/// 首次运行的一次性引导：建议把系统 Dock 收起来。
///
/// 只讲系统 Dock 这一件事（owner 2026-08-20 定）。抽屉空状态的可发现性是另一件事，
/// 有它自己的待办卡，不塞进这一屏——一次只教一件事，第二件就没人看了。
struct WelcomeGuideView: View {
    let onHideDock: () -> Void
    let onDismiss: () -> Void

    /// 宽度固定：窗口高度由 `fittingSize` 决定，宽度不能跟着文案长短抖。
    /// 取值和权限引导一致，两扇引导窗口该长得像一家人。
    static let contentWidth: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Text("Tungsten Edge and the Dock both live along the bottom edge of the screen, so they cover each other up.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            Text("This sets the Dock to hide itself and stay hidden, so it won’t pop up when you move the pointer to the bottom edge. The Dock restarts, so the screen will flash once.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            comeBackBox

            HStack(spacing: 8) {
                Spacer()
                Button("Not Now") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Hide the Dock") { onHideDock() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.bottomthird.inset.filled")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Hide the Dock First")
                    .font(.title3.weight(.semibold))
                Text("Tungsten Edge is ready. One suggestion before you start.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 后路必须写出来（owner 2026-08-20 明确要求）：这一步会让系统 Dock 彻底不出现，
    /// 不告诉用户怎么唤回来，等于让他觉得自己把 Dock 弄丢了。
    ///
    /// ⚠️ `⌥⌘D` 归 macOS 所有，这里**只能当纯文字写**。钨极全局热键用的是 ⌥⇧⌘D；
    /// 把 ⌥⌘D 注册成 `keyEquivalent` 会把系统的快捷键抢过来（见 AGENTS.md 的热键规则）。
    private var comeBackBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Want the Dock back?")
                .font(.callout.weight(.semibold))
            Text("Press ⌥⌘D at any time — that’s macOS’s own shortcut for showing and hiding the Dock. You can also change this later from the Tungsten Edge menu bar item.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
        )
    }
}
