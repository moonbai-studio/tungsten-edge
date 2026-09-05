import AppKit
import Foundation

/// 我们所有面板（任务条 / 玻璃底板 / 胶囊，以及抽屉 / 弹窗 / 名字气泡 / 拖拽载体）的 SkyLight 私有空间宿主。
///
/// **凡是会和任务条重叠的窗口都必须钉进来。** 留在桌面空间的窗口不论 `level` 都被合成在这个
/// 空间**下面**：拖拽载体一压进玻璃底板就显得半透明，抽屉最下一行压在胶囊窗口的阴影边里就发暗
/// （owner 2026-09-03，`DOCK_OVERLAY_SPACE=0` A/B 坐实）。2026-09-02 首版只钉了三块常驻面板。
///
/// 为什么需要它：桌面互滑时 WindowServer 把 `.canJoinAllSpaces` 的常驻面板烤进两侧桌面的过渡
/// 快照，Liquid Glass 底板在快照里取不到背后画面，退化成一块实心深灰（毛玻璃路径则发白），
/// 落定才恢复（owner 2026-09-02 截图 + `scratch/space_transition_lab` 实测）。系统 Dock 不受影响，
/// 是因为它根本不在任何桌面空间里。把面板挪进一个我们自己建的空间（`SLSSpaceCreate` →
/// `SLSSpaceSetAbsoluteLevel 0` → `SLSShowSpaces` → `SLSSpaceAddWindowsAndRemoveFromSpaces`），
/// 面板就和 Dock 一样纹丝不动、材质实时跟着底下内容变。
///
/// 实测过的边界（`scratch/overlay_space_lab`，macOS 26.5.2，两块屏）：
/// - 点击 / 进入事件照常到达，切桌面前后都到；
/// - 两块屏**共用一个**空间即可，各面板只在自己 frame 所在的屏上显示；
/// - `orderOut` → `orderFrontRegardless` **不会**掉成员资格，切桌面也不会——所以只需在面板
///   首次显示后钉一次，显隐路径上的补钉只是一次廉价读回；
/// - 私有空间在 `SLSCopySpacesForWindows` 掩码 `0x7` 下**读不到**（issue #19 修复用的就是这个掩码，
///   会把钉住的面板当成「不在任何桌面」而反复修），读回必须用 `0xF`；`SLSShowSpaces` /
///   `SLSSpaceAddWindowsAndRemoveFromSpaces` 的返回值不是错误码（实测返回大整数），只认读回。
///
/// 任一符号取不到（老系统 / 苹果改名）→ `make()` 返回 nil，面板保持 `.canJoinAllSpaces` 的老行为，
/// issue #19 修复照旧。开关 `DOCK_OVERLAY_SPACE=0`。
@MainActor
final class OverlaySpaceHost {
    static let isEnabled = DebugSwitch.overlaySpace.isEnabled(in: ProcessInfo.processInfo.environment)

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceDestroyFn = @convention(c) (Int32, UInt64) -> Int32
    private typealias SpaceSetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpaceListFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?

    private struct Symbols {
        let cid: Int32
        let create: SpaceCreateFn
        let destroy: SpaceDestroyFn
        let setAbsoluteLevel: SpaceSetAbsoluteLevelFn
        let show: SpaceListFn
        let hide: SpaceListFn
        let addWindows: SpaceAddWindowsFn
        let copySpaces: CopySpacesForWindowsFn
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else { return nil }
        func load<T>(_ name: String, as: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let cidFn = load("SLSMainConnectionID", as: MainConnectionIDFn.self),
              let create = load("SLSSpaceCreate", as: SpaceCreateFn.self),
              let destroy = load("SLSSpaceDestroy", as: SpaceDestroyFn.self),
              let setLevel = load("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevelFn.self),
              let show = load("SLSShowSpaces", as: SpaceListFn.self),
              let hide = load("SLSHideSpaces", as: SpaceListFn.self),
              let addWindows = load("SLSSpaceAddWindowsAndRemoveFromSpaces", as: SpaceAddWindowsFn.self),
              let copySpaces = load("SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
        else { return nil }
        return Symbols(cid: cidFn(), create: create, destroy: destroy, setAbsoluteLevel: setLevel,
                       show: show, hide: hide, addWindows: addWindows, copySpaces: copySpaces)
    }()

    /// 开关关闭或符号缺失时返回 nil：调用方按「没有宿主」走老行为。
    static func make() -> OverlaySpaceHost? {
        guard isEnabled, symbols != nil else { return nil }
        return OverlaySpaceHost()
    }

    private init() {}

    private var spaceID: UInt64?

    /// 把窗口挪进私有空间。已经在里面的跳过；返回「全部目标读回后确实在空间里」。
    /// 空间在第一次调用时才建，避免宿主存在但从未用到时凭空多一个空间。
    @discardableResult
    func pin(windowNumbers: [Int]) -> Bool {
        guard let symbols = Self.symbols else { return false }
        let targets = windowNumbers.filter { $0 > 0 }
        guard !targets.isEmpty, let sid = ensureSpace(symbols) else { return false }
        let missing = targets.filter { !isPinned(windowNumber: $0) }
        guard !missing.isEmpty else { return true }
        // selector 0x7：从窗口原来所属的全部空间里移除（否则它同时留在各桌面上，照样被烤进快照）。
        _ = symbols.addWindows(symbols.cid, sid, missing.map { NSNumber(value: $0) } as CFArray, 0x7)
        return missing.allSatisfy { isPinned(windowNumber: $0) }
    }

    /// 读回：这扇窗现在是否在我们的私有空间里。读不到 / 空间未建 → false。
    func isPinned(windowNumber: Int) -> Bool {
        guard let sid = spaceID, windowNumber > 0, let symbols = Self.symbols,
              let raw = symbols.copySpaces(
                symbols.cid,
                0xF,
                [NSNumber(value: windowNumber)] as CFArray
              ) as? [NSNumber]
        else { return false }
        return raw.contains { $0.uint64Value == sid }
    }

    /// 退出前收掉。进程死亡时 WindowServer 会一并回收，这里只是不留垃圾空间。
    func tearDown() {
        guard let sid = spaceID, let symbols = Self.symbols else { return }
        _ = symbols.hide(symbols.cid, [NSNumber(value: sid)] as CFArray)
        _ = symbols.destroy(symbols.cid, sid)
        spaceID = nil
    }

    private func ensureSpace(_ symbols: Symbols) -> UInt64? {
        if let spaceID { return spaceID }
        // type 1：实测建出来的空间 `SLSSpaceGetType` 报 3（系统级），窗口在其中不参与桌面过渡。
        let sid = symbols.create(symbols.cid, 1, nil)
        guard sid != 0 else { return nil }
        // 绝对层级 0：与桌面同层，窗口自己的 level（.floating）决定它压在普通窗口之上。
        _ = symbols.setAbsoluteLevel(symbols.cid, sid, 0)
        _ = symbols.show(symbols.cid, [NSNumber(value: sid)] as CFArray)
        spaceID = sid
        return sid
    }
}
