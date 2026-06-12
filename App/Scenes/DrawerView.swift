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

    private var snapshotBundleIDs: Set<String> {
        Set(StripItem.items(from: runtime.snapshot).compactMap(\.bundleIdentifier))
    }

    private func isHiddenInSnapshot(bundleID: String) -> Bool {
        StripItem.items(from: runtime.snapshot)
            .first { $0.bundleIdentifier == bundleID }?
            .status == "hidden"
    }

    private let columns = Array(repeating: GridItem(.fixed(44 * 0.7), spacing: 8), count: 5)

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(drawerItems, id: \.id) { item in
                    ChipView(item: item, scale: 0.7, iconOnly: true, showRunningDot: true,
                             drawerTap: {
                                 if item.status == "hidden" {
                                     runtime.activate(windowID: item.id)
                                 } else {
                                     runtime.hide(windowID: item.id)
                                 }
                             })
                }
                ForEach(notRunningBundleIDs, id: \.self) { bundleID in
                    DrawerLauncherChip(bundleID: bundleID,
                                       isRunning: snapshotBundleIDs.contains(bundleID),
                                       isHidden: isHiddenInSnapshot(bundleID: bundleID))
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
    @EnvironmentObject var drawerStore: DrawerStore

    let bundleID: String
    let isRunning: Bool  // derived from runtime.snapshot in DrawerView
    let isHidden: Bool   // derived from runtime.snapshot in DrawerView
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
                .opacity(!isRunning ? 0.35 : (isHidden ? 0.45 : 1.0))
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                .offset(y: bounceOffset)
        }
        .frame(width: 44 * scale, height: 52 * scale)
        .overlay(alignment: .bottom) {
            if isRunning {
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 4, height: 4)
                    .padding(.bottom, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .contextMenu { launcherContextMenu }
        .help(displayName)
        .onDisappear { stopBounce(reason: "流入snapshot") }
        .onChange(of: isRunning) { _, newValue in
            if newValue { stopBounce(reason: "进程已启动") }
        }
    }

    @ViewBuilder
    private var launcherContextMenu: some View {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            if app.isHidden {
                Button("显示") {
                    _ = app.unhide()
                    app.activate(options: .activateIgnoringOtherApps)
                }
            } else {
                Button("隐藏") { _ = app.hide() }
            }
            Button("退出 App") { _ = app.terminate() }
            Divider()
        }
        Button("移回任务栏") { drawerStore.remove(bundleID) }
    }

    private func handleTap() {
        if isRunning {
            let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
            if let app, app.isActive {
                // 在前台 → 收起
                _ = app.hide()
            } else {
                // 未激活 / 隐藏 / 窗口已关 → 唤出
                guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
                _ = app?.unhide()
                NSWorkspace.shared.openApplication(at: appURL, configuration: .init(), completionHandler: nil)
            }
        } else {
            guard !isLaunching else { return }
            launch()
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

    private func stopBounce(reason: String) {
        Self.logger.info("stopBounce() 入口，bundleID=\(bundleID, privacy: .public)，isLaunching=\(isLaunching)，原因=\(reason, privacy: .public)")
        guard isLaunching else { return }
        isLaunching = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            bounceOffset = 0
        }
    }

    private func launch() {
        Self.logger.info("launch() 入口，bundleID=\(bundleID, privacy: .public)")
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Self.logger.warning("launch()：找不到 app URL，bundleID=\(bundleID, privacy: .public)")
            return
        }

        isLaunching = true
        withAnimation(.easeInOut(duration: 0.25).repeatForever(autoreverses: true)) {
            bounceOffset = -6
        }

        // 8s timeout backstop（对 menubar-only app 无窗口回调的情况兜底）
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            stopBounce(reason: "超时")
        }

        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, error in
            if let error {
                Self.logger.error("launch()：openApplication 失败，bundleID=\(bundleID, privacy: .public)，error=\(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                stopBounce(reason: "回调返回")
            }
        }
    }
}
