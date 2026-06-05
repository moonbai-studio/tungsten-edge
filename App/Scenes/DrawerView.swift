import AppKit
import SwiftUI

struct DrawerView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore

    private var drawerItems: [StripItem] {
        StripItem.items(from: runtime.snapshot)
            .filter { drawerStore.contains($0.bundleIdentifier ?? "") }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))

            HStack(spacing: 8) {
                ForEach(drawerItems, id: \.id) { item in
                    ChipView(item: item, scale: 0.7)
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
