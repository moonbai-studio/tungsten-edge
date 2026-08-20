import AppKit
import SwiftUI

/// 中转弹窗：暂存文件的网格。与文件夹弹窗共用 `FolderGridCell` / `FolderPopupStyle`，
/// 但**无下钻、无「在访达中打开」尾格、无目录监视**——数据源是 `ShelfStore` 的路径列表
/// （顺序 = 暂存序，最新在前；协调器开窗前已 prune）。空态一行提示。
/// 格子可系统拖出（.onDrag）；右键菜单带「移出中转」，废纸篓成功后同步移出。
struct ShelfGridPopupView: View {
    @ObservedObject var shelfStore: ShelfStore
    let maxContentHeight: CGFloat
    /// 底板走不走原生 Liquid Glass。**显式传入、无默认值**（同 `scale` / `hoverStyle`）——
    /// 每个面板都是独立的 hosting 根视图，漏传就会出现「这个面板是玻璃、旁边那个还是
    /// 毛玻璃」这种一眼可见的不一致。
    let usesLiquidGlass: Bool
    var onClosePopup: () -> Void = {}
    var onContentResize: () -> Void = {}
    var onPinFolder: ((URL) -> Void)?
    var isFolderPinned: ((URL) -> Bool)?

    private let theme = DockThemeTokens.standard

    @State private var gridHeight: CGFloat = 0

    private typealias Style = FolderPopupStyle

    var body: some View {
        // 每次渲染按当前暂存序读一次文件属性（中转量级小,同步读可接受;弹窗打开前协调器已 prune）。
        let entries = FolderContentsLoader.entries(forPaths: shelfStore.itemPaths)
        let columnCount = min(Style.maxColumns, max(Style.minColumns, max(entries.count, 1)))
        let contentWidth = CGFloat(columnCount) * Style.cellWidth
            + CGFloat(columnCount - 1) * Style.cellSpacing
            + Style.contentPadding * 2
        let availableGridHeight = min(max(140, maxContentHeight), Style.maxGridHeight)

        ZStack(alignment: .bottomLeading) {
            DockPanelBackdrop(theme: theme,
                              cornerRadius: DockShape.panelCornerRadius,
                              usesLiquidGlass: usesLiquidGlass)

            Group {
                if gridHeight > availableGridHeight + 0.5 {
                    ScrollView(.vertical, showsIndicators: true) { gridBody(entries: entries, contentWidth: contentWidth, columnCount: columnCount) }
                        .frame(height: availableGridHeight)
                } else {
                    gridBody(entries: entries, contentWidth: contentWidth, columnCount: columnCount)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DockShape.panelCornerRadius, style: .continuous))
        }
        .dockPanelRim(cornerRadius: DockShape.panelCornerRadius,
                      style: theme.panelRimStyle,
                      lineWidth: theme.panelRimLineWidth,
                      usesLiquidGlass: usesLiquidGlass)
        // 淡入淡出由协调器在 AppKit 层做（panel.alphaValue）,内容层不另加（同 FolderGridPopupView）。
        // 阴影延伸(radius+|y|)必须 ≤ shadowPadding(20)（AGENTS 护栏,同文件夹弹窗）。
        .dockShadow(theme.popupShadow)
        .padding(PanelCoordinator.shadowPadding)
        .onChange(of: gridHeight) { _ in onContentResize() }
        .onChange(of: columnCount) { _ in onContentResize() }
    }

    private func gridBody(entries: [FolderContentsLoader.Entry], contentWidth: CGFloat, columnCount: Int) -> some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text("Drag files here to park them")
                    .font(.system(size: Style.labelSize))
                    .foregroundStyle(theme.popupSecondaryText.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Style.cellWidth), spacing: Style.cellSpacing), count: columnCount),
                      spacing: Style.cellSpacing) {
                ForEach(entries, id: \.url) { entry in
                    FolderGridCell(iconPath: entry.url.path,
                                   staticIcon: nil,
                                   label: entry.name,
                                   dragURL: entry.url,
                                   contextMenu: { cellMenu(for: entry) }) {
                        // 中转不下钻：点击一律打开（文件夹开访达）,主用途是拖出。
                        NSWorkspace.shared.open(entry.url)
                        onClosePopup()
                    }
                }
            }
            .animation(.easeInOut(duration: DrawerAnimation.duration), value: shelfStore.itemPaths)
        }
        .padding(Style.contentPadding)
        .frame(width: contentWidth)
        .background(GeometryReader { g in
            Color.clear.preference(key: ShelfGridHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(ShelfGridHeightKey.self) { gridHeight = $0 }
    }

    private func cellMenu(for entry: FolderContentsLoader.Entry) -> NSMenu {
        let canPin = entry.isDirectory && !(isFolderPinned?(entry.url) ?? true)
        let path = entry.url.path
        return FileItemMenuBuilder.menu(for: .init(
            url: entry.url,
            isDirectory: entry.isDirectory,
            closePopup: onClosePopup,
            pinFolder: canPin ? { onPinFolder?(entry.url) } : nil,
            removeFromShelf: { shelfStore.remove(path) },
            onTrashed: { shelfStore.remove(path) }
        ))
    }
}

private struct ShelfGridHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
