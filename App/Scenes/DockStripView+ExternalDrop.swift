import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · 外部文件拖入任务条：高亮、悬停目标、落下分发。
// 2026-09-05 从 DockStripView.swift 按 extension 拆出，只搬不改。
extension DockStripView {
    /// 任务条整条高亮：**只**服务「外部拖目录悬停文件夹区（pin）」。
    ///
    /// **抽屉图标拖回任务条不再点亮**（owner 2026-08-20，对齐原生程序坞）：原生拖图标进 Dock 时
    /// Dock 本身不描边也不发光，反馈全部由图标让位表达——而我们已经有让位了
    /// （`updateDrawerToStripConvert` 一进任务条就把卡转正、邻居实时让开），而且它的判定框比
    /// 这圈高亮的判定框（正好是可见条矩形）还大一圈，两者信息完全重复。
    /// 外部拖目录那条路径没有让位反馈，整条高亮是它唯一的「能放这儿」信号，所以留着。
    var stripHighlighted: Bool {
        if case .pin = externalDropTarget { return true }
        return false
    }

    /// 外部拖入高亮的三个生命周期入口 + 看门狗。`externalDropTarget` 只在这一组里改。
    /// dropEntered：一次悬停会话开始 → 允许点亮。
    func externalDropHoverBegan(_ target: StripDropRouting.Target) {
        externalDropHoverActive = true
        setExternalDropTarget(target)
    }

    /// dropUpdated：只在会话进行中才更新;落定/离开后系统补发的孤立 dropUpdated（hoverActive=false）忽略 → 无回闪。
    func externalDropHoverMoved(_ target: StripDropRouting.Target) {
        guard externalDropHoverActive else { return }
        setExternalDropTarget(target)
    }

    /// performDrop/dropExited：会话结束 → 立即清高亮、作废看门狗、关门控（同步清,落定即灭,不留尾巴）。
    func externalDropHoverEnded() {
        externalDropHoverActive = false
        externalDropGeneration &+= 1
        externalDropWatchdog?.invalidate()
        externalDropWatchdog = nil
        externalDropTarget = nil
    }

    /// 设落点目标 + 重置拖放结束看门狗。`dropUpdated` 悬停期每 ~50ms 来一次会不断把 0.35s Timer 推后
    /// → 移动/静止悬停都不会误清;一旦拖放结束却没给收尾回调（dropUpdated 停），Timer 到点即清遗留高亮。
    /// generation 仍匹配才清,避免已入队的旧 Timer 误清新拖放。只动 `externalDropTarget`,不碰抽屉 unstash 高亮。
    func setExternalDropTarget(_ target: StripDropRouting.Target) {
        externalDropTarget = target
        externalDropGeneration &+= 1
        externalDropWatchdog?.invalidate()
        let gen = externalDropGeneration
        let timer = Timer(timeInterval: 0.35, repeats: false) { _ in
            guard externalDropGeneration == gen else { return }
            externalDropHoverActive = false
            externalDropTarget = nil
            externalDropWatchdog = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        externalDropWatchdog = timer
    }

    /// 外部拖放落定（DropDelegate 异步取齐 URL 后回到主线程调）。
    /// 中转收一切；命中 chip 移入；间隙/尾部固定只收目录。
    func handleExternalDrop(_ target: StripDropRouting.Target, urls: [URL]) {
        switch target {
        case .stash:
            shelfStore.stash(paths: urls.map(\.path))
        case .moveInto(let path):
            onMoveExternalFiles(urls, path)
        case .pin(let insertIndex):
            var index = insertIndex
            for url in urls where isDirectoryURL(url) {
                pinnedFolderStore.insert(url.path, at: index)
                index += 1
            }
        case .none:
            break
        }
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }
}
