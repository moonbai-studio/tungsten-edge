import ApplicationServices
import CoreGraphics
import Foundation

/// `pid + cgWindowID → AXUIElement` 的旁路缓存。
///
/// **它解决什么**（owner 2026-08-11 指认「最小化的窗口点回来最慢」）：`AppTracker` 每 0.5 秒、
/// 每次 AX 事件都在后台读一遍全量 `AXWindows`，手上**本来就握着**每个窗口的 AX 元素；但动作
/// 路径每次点击都要重新向目标 App 问一遍句柄——快路径 100ms 封顶，抓不到再转 500ms 超时的
/// 全量枚举。最小化窗口尤其容易命中慢路径（它既不是 focused 也不是 main window，快路径必须
/// 走到全量 `AXWindows` 那一步），而最小化的 App 往往正在打盹，AX 问询本身就慢。
///
/// **为什么不塞进 `DockSnapshot` / `WindowRecord`**：那两个类型的相等性是任务条渲染的门控
/// （AGENTS《Taskbar Interaction Performance》"`DockSnapshot` publications are equality-gated"）。
/// 塞一个每轮都在变的 `AXUIElement` 进去会打破等值门控，把整条任务条变成每 0.5 秒重渲染一次
/// ——正是 `4120119` 刚修掉的那个病。所以走旁路：快照一个字段都不用改。
///
/// **失效规则刻意与座位释放规则一致**（AGENTS《Taskbar Trust And Placement》）：
/// - 窗口销毁（destroy 通知）→ 删该条
/// - 进程消失 / app 条目删除 → 删该 pid 全部
/// - 每轮对账与 CG 全列表求交 → CG 里没有的 cgID 删掉
///
/// **绝不因为「AX 里读不到了」就删**：Safari 系的窗口最小化后会整个从 `AXWindows` 里消失
/// （AGENTS 幽灵座位自愈那条的前提），而那恰恰是本缓存最该发挥作用的时刻——缓存里那个
/// 最小化前存下的元素依然指向同一个窗口，`setMinimized(false)` 用得上。
final class AXElementCache: @unchecked Sendable {
    static let shared = AXElementCache()

    /// `DOCK_AX_ELEMENT_CACHE=0` 关掉最快那一档，回到既有的 fast / fallback 两档。
    static let isEnabled = DebugSwitch.axElementCache.isEnabled(in: ProcessInfo.processInfo.environment)

    struct Key: Hashable {
        let pid: pid_t
        let cgWindowID: CGWindowID
    }

    private let lock = NSLock()
    private var elements: [Key: AXUIElement] = [:]

    init() {}

    func store(pid: pid_t, cgWindowID: CGWindowID, element: AXUIElement) {
        guard pid > 0, cgWindowID != 0 else { return }
        lock.lock()
        elements[Key(pid: pid, cgWindowID: cgWindowID)] = element
        lock.unlock()
    }

    func element(pid: pid_t, cgWindowID: CGWindowID) -> AXUIElement? {
        guard pid > 0, cgWindowID != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return elements[Key(pid: pid, cgWindowID: cgWindowID)]
    }

    func remove(pid: pid_t, cgWindowID: CGWindowID) {
        lock.lock()
        elements.removeValue(forKey: Key(pid: pid, cgWindowID: cgWindowID))
        lock.unlock()
    }

    func removeAll(pid: pid_t) {
        lock.lock()
        elements = elements.filter { $0.key.pid != pid }
        lock.unlock()
    }

    /// 与 CG 全列表求交：CG 里已经没有的窗口一定是真关掉了，缓存跟着出列。
    /// 这是防 cgWindowID 复用的那道闸，和 `formerCgIDs` 的卫生规则同源。
    func retain(pid: pid_t, liveCGWindowIDs: Set<CGWindowID>) {
        lock.lock()
        elements = elements.filter { $0.key.pid != pid || liveCGWindowIDs.contains($0.key.cgWindowID) }
        lock.unlock()
    }

    #if DEBUG
    /// 单测用：直接读当前条目数。
    var countForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return elements.count
    }

    func containsForTesting(pid: pid_t, cgWindowID: CGWindowID) -> Bool {
        element(pid: pid, cgWindowID: cgWindowID) != nil
    }
    #endif
}

/// 缓存条目的**保留判定**，抽成纯函数便于单测：这条规则一旦写错，要么留下指向已销毁窗口的
/// 陈旧元素（可能操作到错误的窗口），要么把最小化后离开 AX 的窗口误删（缓存就白建了）。
enum AXElementCacheRetention {
    /// - Parameters:
    ///   - cachedCGWindowIDs: 该 pid 当前缓存着的窗口
    ///   - liveCGWindowIDs: CG **全列表**（不是 on-screen 集合，也不是 AX 列表）
    /// - Returns: 应当删除的窗口
    static func expired(
        cachedCGWindowIDs: Set<CGWindowID>,
        liveCGWindowIDs: Set<CGWindowID>
    ) -> Set<CGWindowID> {
        cachedCGWindowIDs.subtracting(liveCGWindowIDs)
    }
}
