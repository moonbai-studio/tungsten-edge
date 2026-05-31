import AppKit
import SwiftUI

struct DockStripView: View {
    @EnvironmentObject var runtime: AppRuntime

    private var stripItems: [StripItem] {
        StripItem.items(from: runtime.snapshot)
    }

    // Animation key: only id + form-state (zero/single/multi). Title/status changes invisible here.
    private var stripLayoutKeys: [StripLayoutKey] {
        stripItems.map(StripLayoutKey.init)
    }

    var body: some View {
        ZStack {
            DockVisualEffectView()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)
                Spacer(minLength: 0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(stripItems, id: \.id) { item in
                        dockChip(item)
                            .transition(.scale(scale: 0.88).combined(with: .opacity))
                    }
                    // 抽屉区插入点（本期不实现）
                }
                .padding(.horizontal, 16)
                .frame(height: AppDelegate.panelHeight)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: stripLayoutKeys)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chip Dispatch

    @ViewBuilder
    private func dockChip(_ item: StripItem) -> some View {
        let isPending = runtime.feedbackEntriesByWindowID[item.id]?.phase == .pending
        Group {
            if item.isAppLevelFallback {
                // State A: 0 windows — dim icon, no highlight
                bareIconChip(item, isPending: isPending, opacity: 0.45, showActiveHighlight: false)
            } else if !item.showsTitle {
                // State B: 1 window — full icon + active strokeBorder
                bareIconChip(item, isPending: isPending, opacity: 1.0, showActiveHighlight: true)
            } else {
                // State C: 2+ windows — per-window labeled chip
                multiWindowChip(item, isPending: isPending)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: item.showsTitle)
    }

    // MARK: - State A / State B

    private func bareIconChip(
        _ item: StripItem,
        isPending: Bool,
        opacity: Double,
        showActiveHighlight: Bool
    ) -> some View {
        let isActive = showActiveHighlight && item.status == WindowStatus.active.rawValue

        return ZStack {
            appIcon(item, size: 36, opacity: opacity)

            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.88))
                    .frame(width: 20, height: 20)
                    .background(Color.black.opacity(0.36), in: Circle())
                    .offset(x: 14, y: -14)
            }
        }
        .overlay(alignment: .bottom) {
            if isActive {
                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 19, height: 2.5)
                    .offset(y: -3)
            }
        }
        .frame(width: 44, height: 52)
        .contentShape(Rectangle())
        .onTapGesture { guard !isPending else { return }; runtime.toggle(windowID: item.id) }
        .contextMenu { chipContextMenu(item, isDisabled: isPending) }
        .help(displayTitle(item))
    }

    // MARK: - State C

    private func multiWindowChip(_ item: StripItem, isPending: Bool) -> some View {
        let isActive = item.status == WindowStatus.active.rawValue
        let isMinimized = item.status == WindowStatus.minimized.rawValue

        return HStack(spacing: 6) {
            appIcon(item, size: 22, opacity: isMinimized ? 0.55 : 1.0)

            Text(displayTitle(item))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(isMinimized ? .white.opacity(0.42) : .white.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.09))
        )
        .overlay(alignment: .bottom) {
            if isActive {
                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 2.5)
                    .padding(.horizontal, 11)
                    .offset(y: -3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.8))
                    .padding(6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { guard !isPending else { return }; runtime.toggle(windowID: item.id) }
        .contextMenu { chipContextMenu(item, isDisabled: isPending) }
        .help(displayTitle(item))
    }

    // MARK: - Shared Icon

    private func appIcon(_ item: StripItem, size: CGFloat, opacity: Double) -> some View {
        Image(nsImage: AppIconResolver.icon(for: item.bundleIdentifier ?? item.appID))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .opacity(opacity)
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func chipContextMenu(_ item: StripItem, isDisabled: Bool) -> some View {
        Button("激活") { runtime.activate(windowID: item.id) }.disabled(isDisabled)
        if item.canHide {
            Button("隐藏") { runtime.hide(windowID: item.id) }.disabled(isDisabled)
        }
        if item.canMinimize {
            Button("最小化") { runtime.minimize(windowID: item.id) }.disabled(isDisabled)
        }
        if item.canClose {
            Divider()
            Button("关闭") { runtime.close(windowID: item.id) }.disabled(isDisabled)
        }
    }

    // MARK: - Helpers

    private func displayTitle(_ item: StripItem) -> String {
        item.title == "macos-dock-cc-v2" ? "任务条" : item.title
    }
}

// MARK: - Layout Animation Key

private struct StripLayoutKey: Equatable {
    let id: String
    let form: Form

    enum Form: Equatable { case zero, single, multi }

    init(_ item: StripItem) {
        id = item.id
        if item.isAppLevelFallback { form = .zero }
        else if item.showsTitle    { form = .multi }
        else                        { form = .single }
    }
}

// MARK: - Visual Effect Background

private struct DockVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
