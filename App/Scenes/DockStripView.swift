import AppKit
import SwiftUI

struct DockStripView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore

    private var stripItems: [StripItem] {
        StripItem.items(from: runtime.snapshot)
            .filter { !drawerStore.contains($0.bundleIdentifier ?? "") }
    }

    private var stripLayoutKeys: [StripLayoutKey] {
        stripItems.map(StripLayoutKey.init)
    }

    var body: some View {
        ZStack {
            DockVisualEffectView()
                .ignoresSafeArea()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(stripItems, id: \.id) { item in
                        ChipView(item: item)
                            .transition(.scale(scale: 0.88).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Style.chipContentInset)
                .frame(height: AppDelegate.panelHeight)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: stripLayoutKeys)
            }
            .defaultScrollAnchor(.leading)
            .mask(alignment: .center) {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Style.edgeFadeWidth)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Style.edgeFadeWidth)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(Style.borderTopOpacity), .white.opacity(Style.borderBottomOpacity)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        // No .frame(maxWidth: .infinity) here — lets NSHostingView.fittingSize reflect
        // the natural content width so AppDelegate can read it for panel sizing.
    }

}

// MARK: - Chip View

struct ChipView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    let item: StripItem
    var scale: CGFloat = 1.0
    var iconOnly: Bool = false

    private var isPending: Bool {
        runtime.feedbackEntriesByWindowID[item.id]?.phase == .pending
    }

    var body: some View {
        Group {
            if !iconOnly && item.showsTitle {
                multiWindowChip
            } else {
                bareIconChip
            }
        }
        .animation(.easeInOut(duration: 0.2), value: item.showsTitle)
    }

    // MARK: - Icon-only chip

    private var bareIconChip: some View {
        let iconOpacity: Double = item.isOnDesktop ? 1.0 : 0.45
        return ZStack {
            appIcon(size: 36 * scale, opacity: iconOpacity)

            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.88))
                    .frame(width: 20 * scale, height: 20 * scale)
                    .background(Color.black.opacity(0.36), in: Circle())
                    .offset(x: 14 * scale, y: -14 * scale)
            }
        }
        .frame(width: 44 * scale, height: 52 * scale)
        .contentShape(Rectangle())
        .onTapGesture { guard !isPending else { return }; runtime.toggle(windowID: item.id) }
        .contextMenu { chipContextMenu }
        .help(displayTitle)
    }

    // MARK: - Labeled chip

    private var multiWindowChip: some View {
        let iconOpacity: Double = item.isOnDesktop ? 1.0 : 0.45
        let textOpacity: Double = item.isOnDesktop ? 0.9 : 0.42
        return HStack(spacing: 6 * scale) {
            appIcon(size: 22 * scale, opacity: iconOpacity)

            Text(displayTitle)
                .font(.system(size: max(10, 12 * scale), weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(textOpacity))
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(.horizontal, 10 * scale)
        .frame(height: 40 * scale)
        .background(
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(Color.white.opacity(0.09))
        )
        .overlay(alignment: .topTrailing) {
            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.8))
                    .padding(6 * scale)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous))
        .onTapGesture { guard !isPending else { return }; runtime.toggle(windowID: item.id) }
        .contextMenu { chipContextMenu }
        .help(displayTitle)
    }

    // MARK: - Shared Icon

    private func appIcon(size: CGFloat, opacity: Double) -> some View {
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
    private var chipContextMenu: some View {
        if item.isAppLevelFallback {
            if item.status == "hidden" {
                Button("显示") { runtime.activate(windowID: item.id) }.disabled(isPending)
            } else {
                Button("隐藏") { runtime.hide(windowID: item.id) }.disabled(isPending)
            }
            Divider()
            Button("退出 App") { runtime.quit(windowID: item.id) }.disabled(isPending)
            if let bid = item.bundleIdentifier {
                Divider()
                if drawerStore.contains(bid) {
                    Button("移回任务栏") { drawerStore.remove(bid) }
                } else {
                    Button("收进抽屉") { drawerStore.add(bid) }
                }
            }
        } else {
            if item.status == "minimized" {
                Button("还原") { runtime.activate(windowID: item.id) }.disabled(isPending)
            } else {
                Button("最小化") { runtime.minimize(windowID: item.id) }.disabled(isPending)
            }
            Button("关闭窗口") { runtime.close(windowID: item.id) }.disabled(isPending)
            Divider()
            Button("隐藏 App") { runtime.hide(windowID: item.id) }.disabled(isPending)
            Button("退出 App") { runtime.quit(windowID: item.id) }.disabled(isPending)
            if let bid = item.bundleIdentifier {
                Divider()
                if drawerStore.contains(bid) {
                    Button("移回任务栏") { drawerStore.remove(bid) }
                } else {
                    Button("收进抽屉") { drawerStore.add(bid) }
                }
            }
        }
    }

    // MARK: - Helpers

    private var displayTitle: String {
        item.title == "macos-dock-cc-v2" ? "任务条" : item.title
    }
}

// MARK: - Drawer Capsule Button

struct DrawerCapsuleButton: View {
    @EnvironmentObject var drawerStore: DrawerStore
    let action: () -> Void

    private static let iconSize: CGFloat = 10
    private static let gridSpacing: CGFloat = 5

    private var folderIDs: [String] { Array(drawerStore.bundleIDs.prefix(9)) }

    var body: some View {
        ZStack {
            DockVisualEffectView()
                .ignoresSafeArea()

            if folderIDs.isEmpty {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(Self.iconSize), spacing: Self.gridSpacing), count: 3),
                    spacing: Self.gridSpacing
                ) {
                    ForEach(folderIDs, id: \.self) { id in
                        Image(nsImage: AppIconResolver.icon(for: id))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: Self.iconSize, height: Self.iconSize)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }
                .padding(6)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(Style.borderTopOpacity), .white.opacity(Style.borderBottomOpacity)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
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

// MARK: - Visual Constants (hand-tune these)

private enum Style {
    // Shape
    static let cornerRadius: CGFloat   = 16   // panel corner radius

    // Content layout
    static let chipContentInset: CGFloat = 20  // horizontal padding inside blur; > cornerRadius avoids corner-clip
    static let edgeFadeWidth: CGFloat    = 16  // scroll edge fade-out width (pt)

    // Border
    static let borderTopOpacity: Double    = 0.12  // top-edge highlight (simulates light from above)
    static let borderBottomOpacity: Double = 0.06  // side/bottom edges (nearly invisible)
}

// MARK: - Visual Effect Background

private struct DockVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = Style.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
