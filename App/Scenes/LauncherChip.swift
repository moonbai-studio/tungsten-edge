import AppKit
import os
import SwiftUI

/// A chip that represents an app by bundle identifier rather than a concrete window.
/// Renders the three launcher states (not running / running-no-window / running-hidden)
/// and handles tap-to-launch, tap-to-reopen, and the launch bounce animation.
///
/// Shared by the drawer (collected apps, scale 0.7) and the main strip (pinned
/// messaging apps, scale 1.0). The only call-site difference is the membership-removal
/// menu item, injected via `removeMenuLabel` + `onRemove`.
struct LauncherChip: View {
    let bundleID: String
    let isRunning: Bool   // derived from runtime.snapshot by the parent view
    let isHidden: Bool    // derived from runtime.snapshot by the parent view
    var scale: CGFloat = 0.7
    /// Last context-menu item, e.g. "移回任务栏" (drawer) or "取消标记消息应用" (messaging).
    let removeMenuLabel: String
    let onRemove: () -> Void

    private static let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "LauncherChip")

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
        .contextMenu { contextMenu }
        .help(displayName)
        .onDisappear { stopBounce(reason: "流入snapshot") }
        .onChange(of: isRunning) { _, newValue in
            if newValue { stopBounce(reason: "进程已启动") }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
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
        Button(removeMenuLabel) { onRemove() }
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
