import CoreGraphics
import Foundation

struct AppTrackerCGWindowSnapshot: Equatable {
    let allWindowIDs: Set<CGWindowID>
    let onScreenWindowIDs: Set<CGWindowID>
    /// 按属主 pid 分组的 layer-0 窗口 id（影子标签池用：CG(pid) − AX 暴露集 = order-out 后台标签）。
    let windowIDsByPID: [pid_t: Set<CGWindowID>]
    /// AX inventory 没有透明度属性；按同轮 CG window id 补齐，供 admission 的 alpha=0 过滤使用。
    let alphaByWindowID: [CGWindowID: Double]
    /// layer-0 窗口的 `kCGWindowBounds`（Quartz 全局坐标）。多屏 ④ 的 5s tick 用它给**所有**座位
    /// 重算「在哪块屏」——包括被跳读门控跳过、没有 AX 读的 pid。只做屏归属，不替代 AX 帧。
    let boundsByWindowID: [CGWindowID: CGRect]
    /// Windows below the normal layer (`kCGWindowLayer < 0`): desktop widgets, wallpaper surfaces.
    /// A veto-only set for admission — none of these ids appear in the layer-0 fields above.
    /// Empty on a failed capture, so that round cannot veto anything.
    let belowNormalLayerWindowIDs: Set<CGWindowID>
    /// CG 查询本身失败（返回 nil）。与「真的没有 layer-0 窗口」是两回事：任何拿本快照当
    /// 「没变化」判据的门控（周期跳读、补扫门控）见此标志必须放弃跳过、走全量路径。
    /// 既有消费方不读它，失败时的下游行为与从前逐位一致。
    let captureFailed: Bool
    let layerByWindowID: [CGWindowID: Int]
    let diagnosticOnScreenWindowIDs: Set<CGWindowID>

    init(
        allWindowIDs: Set<CGWindowID>,
        onScreenWindowIDs: Set<CGWindowID>,
        windowIDsByPID: [pid_t: Set<CGWindowID>],
        alphaByWindowID: [CGWindowID: Double],
        boundsByWindowID: [CGWindowID: CGRect] = [:],
        belowNormalLayerWindowIDs: Set<CGWindowID> = [],
        captureFailed: Bool = false,
        layerByWindowID: [CGWindowID: Int] = [:],
        diagnosticOnScreenWindowIDs: Set<CGWindowID> = []
    ) {
        self.allWindowIDs = allWindowIDs
        self.onScreenWindowIDs = onScreenWindowIDs
        self.windowIDsByPID = windowIDsByPID
        self.alphaByWindowID = alphaByWindowID
        self.boundsByWindowID = boundsByWindowID
        self.belowNormalLayerWindowIDs = belowNormalLayerWindowIDs
        self.captureFailed = captureFailed
        self.layerByWindowID = layerByWindowID
        self.diagnosticOnScreenWindowIDs = diagnosticOnScreenWindowIDs
    }

    static var failed: AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [],
            onScreenWindowIDs: [],
            windowIDsByPID: [:],
            alphaByWindowID: [:],
            boundsByWindowID: [:],
            captureFailed: true
        )
    }

    static func capture(includeDiagnosticDetails: Bool = false) -> AppTrackerCGWindowSnapshot {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return .failed
        }
        return parse(windowInfo, includeDiagnosticDetails: includeDiagnosticDetails)
    }

    static func captureOnScreenWindowIDs() -> Set<CGWindowID> {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return layerZeroWindowIDs(in: windowInfo)
    }

    static func parse(_ windowInfo: [[String: Any]], includeDiagnosticDetails: Bool = false) -> AppTrackerCGWindowSnapshot {
        var allWindowIDs: Set<CGWindowID> = []
        var onScreenWindowIDs: Set<CGWindowID> = []
        var windowIDsByPID: [pid_t: Set<CGWindowID>] = [:]
        var alphaByWindowID: [CGWindowID: Double] = [:]
        var boundsByWindowID: [CGWindowID: CGRect] = [:]
        var belowNormalLayerWindowIDs: Set<CGWindowID> = []
        var layerByWindowID: [CGWindowID: Int] = [:]
        var diagnosticOnScreenWindowIDs: Set<CGWindowID> = []

        for info in windowInfo {
            if includeDiagnosticDetails, let number = info[kCGWindowNumber as String] as? Int {
                let windowID = CGWindowID(number)
                layerByWindowID[windowID] = info[kCGWindowLayer as String] as? Int
                if info[kCGWindowIsOnscreen as String] as? Bool == true {
                    diagnosticOnScreenWindowIDs.insert(windowID)
                }
            }
            if let layer = info[kCGWindowLayer as String] as? Int, layer < 0 {
                if let number = info[kCGWindowNumber as String] as? Int {
                    belowNormalLayerWindowIDs.insert(CGWindowID(number))
                }
                continue
            }
            guard let windowID = layerZeroWindowID(in: info) else { continue }
            allWindowIDs.insert(windowID)
            if info[kCGWindowIsOnscreen as String] as? Bool == true {
                onScreenWindowIDs.insert(windowID)
            }
            if let ownerPID = info[kCGWindowOwnerPID as String] as? Int {
                windowIDsByPID[pid_t(ownerPID), default: []].insert(windowID)
            }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue {
                alphaByWindowID[windowID] = alpha
            }
            if let dict = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dict) {
                boundsByWindowID[windowID] = rect
            }
        }

        return AppTrackerCGWindowSnapshot(
            allWindowIDs: allWindowIDs,
            onScreenWindowIDs: onScreenWindowIDs,
            windowIDsByPID: windowIDsByPID,
            alphaByWindowID: alphaByWindowID,
            boundsByWindowID: boundsByWindowID,
            belowNormalLayerWindowIDs: belowNormalLayerWindowIDs,
            layerByWindowID: layerByWindowID,
            diagnosticOnScreenWindowIDs: diagnosticOnScreenWindowIDs
        )
    }

    private static func layerZeroWindowIDs(in windowInfo: [[String: Any]]) -> Set<CGWindowID> {
        Set(windowInfo.compactMap(layerZeroWindowID(in:)))
    }

    private static func layerZeroWindowID(in info: [String: Any]) -> CGWindowID? {
        guard let layer = info[kCGWindowLayer as String] as? Int,
              layer == 0,
              let number = info[kCGWindowNumber as String] as? Int else {
            return nil
        }
        return CGWindowID(number)
    }
}
