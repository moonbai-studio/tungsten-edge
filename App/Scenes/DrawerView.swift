import AppKit
import os
import SwiftUI

/// Two-zone drawer (抽屉双区, 2026-06-12):
/// - Running zone: stashed (收进抽屉) apps whose PROCESS is running — real-window
///   chips and app-* (running, no eligible windows) launcher chips alike. The zone
///   split follows the 命门 rule: "running" = any snapshot presence, never "has
///   windows" (Tailscale-style menubar apps must not land in the launch zone).
/// - Launch zone: launcher chips for apps not running at all, stable registration
///   order (方案 B) — stashed apps whose process exited + 固定到启动台 favorites
///   that are currently closed. A running favorite lives on the strip, never here.
///
/// No zone titles: the running dot (lit icon + dot vs dim icon, same three-tier
/// language as the strip) plus the divider carry the distinction.
struct DrawerView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var launchFavoriteStore: LaunchFavoriteStore
    @EnvironmentObject var messagingStore: MessagingAppStore

    private var drawerItems: [StripItem] {
        StripItem.items(from: runtime.snapshot)
            .filter { !$0.isAppLevelFallback }
            .filter { drawerStore.contains($0.bundleIdentifier ?? "") }
    }

    /// Stashed apps running WITHOUT real windows (app-* fallback only): they belong
    /// in the running zone, rendered as launcher chips (lit + dot, show/hide on tap).
    private var runningNoWindowStashedIDs: [String] {
        let windowBackedIDs = Set(drawerItems.compactMap(\.bundleIdentifier))
        return drawerStore.bundleIDs.filter {
            snapshotBundleIDs.contains($0) && !windowBackedIDs.contains($0)
        }
    }

    private var notRunningStashedIDs: [String] {
        drawerStore.bundleIDs.filter { !snapshotBundleIDs.contains($0) }
    }

    private var notRunningFavoriteIDs: [String] {
        // Exclude apps already shown via notRunningStashedIDs (收纳+固定共存时去重).
        launchFavoriteStore.bundleIDs.filter { !snapshotBundleIDs.contains($0) && !drawerStore.contains($0) }
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
        let runningStashedIDs = runningNoWindowStashedIDs
        let launcherIDs = notRunningStashedIDs + notRunningFavoriteIDs
        let hasRunningZone = !drawerItems.isEmpty || !runningStashedIDs.isEmpty

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))

            VStack(alignment: .leading, spacing: 0) {
                if hasRunningZone {
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
                        ForEach(runningStashedIDs, id: \.self) { bundleID in
                            LauncherChip(bundleID: bundleID,
                                         isRunning: true,
                                         isHidden: isHiddenInSnapshot(bundleID: bundleID),
                                         scale: 0.7,
                                         removeMenuLabel: "移回任务栏",
                                         onRemove: { drawerStore.remove(bundleID) },
                                         pinMenuLabel: launchFavoriteStore.contains(bundleID) ? "取消固定" : "固定到启动台",
                                         onPin: {
                                             if launchFavoriteStore.contains(bundleID) {
                                                 launchFavoriteStore.remove(bundleID)
                                             } else {
                                                 launchFavoriteStore.add(bundleID)
                                                 if messagingStore.contains(bundleID) { messagingStore.unmark(bundleID) }
                                             }
                                         })
                        }
                    }
                }
                if !launcherIDs.isEmpty {
                    Spacer().frame(height: hasRunningZone ? 12 : 0)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(notRunningStashedIDs, id: \.self) { bundleID in
                            LauncherChip(bundleID: bundleID,
                                         isRunning: false,
                                         isHidden: false,
                                         scale: 0.7,
                                         removeMenuLabel: "移回任务栏",
                                         onRemove: { drawerStore.remove(bundleID) })
                        }
                        // Favorites: never in the snapshot here (filtered above), and
                        // no membership menu — 取消固定 lives on the running strip
                        // chip's context menu only.
                        ForEach(notRunningFavoriteIDs, id: \.self) { bundleID in
                            LauncherChip(bundleID: bundleID,
                                         isRunning: false,
                                         isHidden: false,
                                         scale: 0.7)
                        }
                    }
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

