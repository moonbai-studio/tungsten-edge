import AppKit
import os
import SwiftUI

struct DrawerView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore

    private var drawerItems: [StripItem] {
        StripItem.items(from: runtime.snapshot)
            .filter { !$0.isAppLevelFallback }
            .filter { drawerStore.contains($0.bundleIdentifier ?? "") }
    }

    private var notRunningBundleIDs: [String] {
        // Only count apps with real window chips (not app-* fallback) as "running".
        // An app-* entry means the process exists but has no eligible windows; we still
        // want to show the launcher chip so the bounce animation can complete.
        let runningBundleIDs = Set(
            StripItem.items(from: runtime.snapshot)
                .filter { !$0.isAppLevelFallback }
                .compactMap(\.bundleIdentifier)
        )
        return drawerStore.bundleIDs.filter { !runningBundleIDs.contains($0) }
    }

    private let columns = Array(repeating: GridItem(.fixed(44 * 0.7), spacing: 8), count: 5)

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(drawerItems, id: \.id) { item in
                    ChipView(item: item, scale: 0.7, iconOnly: true)
                }
                ForEach(notRunningBundleIDs, id: \.self) { bundleID in
                    DrawerLauncherChip(bundleID: bundleID)
                }
            }
            .padding(12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }
}

// MARK: - Launcher Chip

private struct DrawerLauncherChip: View {
    let bundleID: String
    private let scale: CGFloat = 0.7
    private static let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "Drawer")

    @State private var isLaunching = false
    @State private var bounceOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Image(nsImage: AppIconResolver.icon(for: bundleID))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36 * scale, height: 36 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 36 * scale / 4, style: .continuous))
                .opacity(0.35)
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                .offset(y: bounceOffset)

            Image(systemName: "play.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 11, height: 11)
                .background(Color.white.opacity(0.22), in: Circle())
                .offset(x: 14 * scale, y: 14 * scale)
                .opacity(isLaunching ? 0 : 1)
                .animation(.easeInOut(duration: 0.15), value: isLaunching)
        }
        .frame(width: 44 * scale, height: 52 * scale)
        .contentShape(Rectangle())
        .onTapGesture { guard !isLaunching else { return }; launch() }
        .help(displayName)
        .onDisappear {
            stopBounce(reason: "流入snapshot")
        }
    }

    private var displayName: String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return Bundle(url: url)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    // Called on @MainActor; guard ensures only first path wins.
    private func stopBounce(reason: String) {
        guard isLaunching else { return }
        isLaunching = false
        Self.logger.info("启动按钮：结束，bundleID=\(bundleID, privacy: .public)，原因=\(reason, privacy: .public)")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            bounceOffset = 0
        }
    }

    private func launch() {
        let isAlreadyRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Self.logger.warning("启动按钮：找不到 app URL，bundleID=\(bundleID, privacy: .public)，已在跑=\(isAlreadyRunning)")
            return
        }

        isLaunching = true
        withAnimation(.easeInOut(duration: 0.25).repeatForever(autoreverses: true)) {
            bounceOffset = -6
        }
        Self.logger.info("启动按钮：开始，bundleID=\(bundleID, privacy: .public)，已在跑=\(isAlreadyRunning)")

        // Condition b: 8s timeout backstop (handles menubar-only apps with no windows)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            stopBounce(reason: "超时")
        }

        // Condition a: wait for openApplication callback, then 1.5s buffer
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, error in
            if let error {
                Self.logger.error("启动按钮：openApplication 失败，bundleID=\(bundleID, privacy: .public)，error=\(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                stopBounce(reason: "回调返回")
            }
        }
    }
}
