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
                    LauncherChip(bundleID: bundleID,
                                 isRunning: snapshotBundleIDs.contains(bundleID),
                                 isHidden: isHiddenInSnapshot(bundleID: bundleID),
                                 scale: 0.7,
                                 removeMenuLabel: "移回任务栏",
                                 onRemove: { drawerStore.remove(bundleID) })
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

