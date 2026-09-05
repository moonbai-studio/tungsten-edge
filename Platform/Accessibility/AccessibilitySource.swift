import AppKit
import ApplicationServices
import Foundation
import OSLog

final class AccessibilitySource {
    private static let logger = Logger(
        subsystem: DockWindowEligibilityPolicy.selfBundleIdentifier,
        category: "WindowFiltering"
    )

    private let reader = AXWindowReader()
    private let eligibilityPolicy = DockWindowEligibilityPolicy()
    private var previousWindowKindsBySignature: [String: SystemObservation.ObservationKind] = [:]
    private var previousObservationsBySignature: [String: SystemObservation] = [:]
    private var previousHiddenSignatures: Set<String> = []

    func observe() -> [SystemObservation] {
        guard AXIsProcessTrusted() else { return [] }
        let now = Date()

        let apps = Array(NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated
                && $0.activationPolicy != .prohibited
                && FinderWindowRules.isFinder(bundleIdentifier: $0.bundleIdentifier) == false
        })
        let scannedPIDs = Set(apps.map(\.processIdentifier))

        var observations: [SystemObservation] = []
        var currentHiddenSignatures: Set<String> = []

        for app in apps {
            let appObservations = observeWindows(for: app, now: now)
            observations.append(contentsOf: appObservations)

            for observation in appObservations {
                if observation.kind == .hidden {
                    currentHiddenSignatures.insert(observationSignature(observation))
                }
            }
        }

        var nextKindsBySignature: [String: SystemObservation.ObservationKind] = [:]
        var nextObservationsBySignature: [String: SystemObservation] = [:]
        for observation in observations {
            let signature = observationSignature(observation)
            nextKindsBySignature[signature] = ObservationKindMergeRule.preferred(
                nextKindsBySignature[signature],
                observation.kind
            )
            nextObservationsBySignature[signature] = observation
        }

        for (signature, previous) in previousObservationsBySignature
            where nextObservationsBySignature[signature] == nil && scannedPIDs.contains(previous.pid) {
            observations.append(
                SystemObservation(
                    timestamp: now,
                    kind: .disappeared,
                    source: previous.source,
                    pid: previous.pid,
                    bundleIdentifier: previous.bundleIdentifier,
                    cgWindowID: previous.cgWindowID,
                    title: previous.title,
                    appName: previous.appName,
                    bounds: previous.bounds,
                    isMinimized: previous.isMinimized,
                    isFocusedWindow: false
                )
            )
        }

        previousWindowKindsBySignature = nextKindsBySignature
        previousObservationsBySignature = nextObservationsBySignature
        previousHiddenSignatures = currentHiddenSignatures
        return observations
    }

    private func observeWindows(for app: NSRunningApplication, now: Date) -> [SystemObservation] {
        let isAppHidden = app.isHidden

        return reader.windows(for: app).compactMap { window in
            let title = window.title
            guard title != nil else { return nil }
            let axDecision = AXTaskbarWindowRules.decision(
                role: window.role,
                subrole: window.subrole,
                bounds: window.bounds
            )
            guard axDecision.isAccepted else { return nil }
            logUnconfirmedWindowIfNeeded(axDecision, window: window, app: app)

            let decision = eligibilityPolicy.evaluate(
                DockWindowEligibilityPolicy.Candidate(
                    bundleIdentifier: app.bundleIdentifier,
                    appName: app.localizedName ?? "",
                    title: title,
                    subrole: window.subrole,
                    bounds: window.bounds,
                    alpha: nil,
                    activationPolicy: app.activationPolicy,
                    executablePath: app.executableURL?.path
                )
            )
            guard decision == .keep else { return nil }

            let baseObservation = SystemObservation(
                timestamp: now,
                kind: .unchanged,
                source: .accessibility,
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                cgWindowID: window.cgWindowID,
                title: title,
                appName: app.localizedName,
                bounds: window.bounds,
                isMinimized: window.isMinimized,
                isFocusedWindow: window.isFocusedWindow
            )
            let signature = observationSignature(baseObservation)
            let previousKind = previousWindowKindsBySignature[signature]
            let wasHidden = previousHiddenSignatures.contains(signature)
            let kind: SystemObservation.ObservationKind

            if window.isMinimized {
                kind = .minimized
            } else if isAppHidden {
                kind = .hidden
            } else if wasHidden || previousKind == .hidden {
                kind = .unhidden
            } else {
                kind = .unchanged
            }

            return SystemObservation(
                timestamp: now,
                kind: kind,
                source: .accessibility,
                pid: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                cgWindowID: window.cgWindowID,
                title: title,
                appName: app.localizedName,
                bounds: window.bounds,
                isMinimized: window.isMinimized,
                isFocusedWindow: window.isFocusedWindow
            )
        }
    }

    private func logUnconfirmedWindowIfNeeded(
        _ decision: AXTaskbarWindowRules.Decision,
        window: AXWindowSnapshot,
        app: NSRunningApplication
    ) {
        guard decision == .unconfirmedMainWindow else { return }
        Self.logger.debug(
            "Admitting AXWindow with missing subrole app=\(app.localizedName ?? "", privacy: .public) bundle=\(app.bundleIdentifier ?? "", privacy: .public) title=\(window.title ?? "", privacy: .public)"
        )
    }

    private func observationSignature(_ observation: SystemObservation) -> String {
        let title = observation.title?.lowercased() ?? "<untitled>"
        let frame = observation.bounds.map {
            "\($0.origin.x.rounded()):\($0.origin.y.rounded()):\($0.width.rounded()):\($0.height.rounded())"
        } ?? "<unknown>"
        return "\(observation.pid)|\(title)|\(frame)"
    }
}

struct AccessibilityWindowActionExecutor {
    private let reader: AXWindowReader
    private let chipProbeEnabled: Bool
    private static let chipProbeLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "ChipProbe")

    init(reader: AXWindowReader = AXWindowReader(), chipProbeEnabled: Bool = false) {
        self.reader = reader
        self.chipProbeEnabled = chipProbeEnabled
    }

    struct ActionExecution {
        let success: Bool
        let mechanism: String
        let verifiedMinimized: Bool?
    }

    struct WindowTarget {
        let pid: Int32
        let title: String?
        let bounds: CGRect?
    }

    struct WindowHandle {
        let pid: Int32
        let title: String?
        let bounds: CGRect?
        fileprivate let element: AXUIElement
    }

    /// 最快的一档：直接用 `AppTracker` 盘点时存下的 AX 元素（`AXElementCache`），只花一次
    /// `_AXUIElementGetWindow` 校验它仍指向期望的窗口，预算 50ms。
    ///
    /// 为什么值得单独一档：既有的快路径要依次问 `AXFocusedWindow` → `AXMainWindow` → 全量
    /// `AXWindows`，而**最小化的窗口既不是 focused 也不是 main**，必然走到最后那步；偏偏最小化的
    /// App 常在打盹，这一整套能把 100ms 预算吃光，再转 500ms 的慢路径。缓存这一档把它压到 ≤50ms。
    func captureHandleFromCache(
        _ cgWindowID: CGWindowID,
        pid: Int32,
        title: String?,
        bounds: CGRect?
    ) -> WindowHandle? {
        guard let element = AXElementCache.shared.element(pid: pid, cgWindowID: cgWindowID) else {
            return nil
        }
        switch reader.matchesCGWindowID(cgWindowID, element: element, messagingTimeout: 0.05) {
        case .some(true):
            // title / bounds 用快照值补齐——同 `fastHandle`，绝不透传 nil（透传 nil 会让后面
            // recapture 的 bestMatch 对任何 ≥2 窗口的应用必然返回 nil，静默废掉救援路径）。
            return WindowHandle(pid: pid, title: title, bounds: bounds, element: element)
        case .some(false):
            // 读到了、但已经换了窗口（cgWindowID 复用）——这条缓存必须作废。
            AXElementCache.shared.remove(pid: pid, cgWindowID: cgWindowID)
            return nil
        case .none:
            // 读不到 ≠ 陈旧。留着缓存，本次回落既有捕获链。
            return nil
        }
    }

    func captureHandleByCGWindowID(
        _ cgWindowID: CGWindowID,
        pid: Int32,
        title: String?,
        bounds: CGRect?
    ) -> WindowHandle? {
        guard let handle = reader.captureHandle(
            forPID: pid,
            cgWindowID: cgWindowID,
            messagingTimeout: 0.1
        ) else { return nil }
        return Self.fastHandle(
            from: handle,
            target: WindowTarget(pid: pid, title: title, bounds: bounds)
        )
    }

    static func fastHandle(from handle: AXWindowHandle, target: WindowTarget) -> WindowHandle {
        return WindowHandle(
            pid: target.pid,
            title: target.title,
            bounds: target.bounds,
            element: handle.element
        )
    }

    func activateAppWithWindowRecovery(pid: Int32, runningApp: NSRunningApplication?) -> Bool {
        // 限时 0.3s（2026-08-11）。这里原来走的是**无超时**的 `windows(forPID:)`，用的是系统默认
        // AX 超时，打盹的 App 上是秒级——而这是 `app-*` 卡片点击的唯一路径，人正在等。读不出来
        // 就当没有可见窗口，直接走下面的 openApplication 唤出（行为与 `.unread → 空` 一致）。
        let liveWindows: [AXWindowSnapshot]
        switch reader.inventoryWindows(forPID: pid, messagingTimeout: 0.3) {
        case .success(let windows): liveWindows = windows
        case .unread: liveWindows = []
        }
        let visibleWindows = liveWindows.filter { !$0.isMinimized }

        if !visibleWindows.isEmpty {
            _ = AXUIElementPerformAction(visibleWindows[0].element, kAXRaiseAction as CFString)
            return runningApp?.activate(options: [.activateIgnoringOtherApps]) ?? false
        }

        guard let app = runningApp, let url = app.bundleURL else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        return true
    }

    func captureHandle(
        for target: WindowTarget,
        attempts: Int = 1,
        retryIntervalMicroseconds: useconds_t = 0
    ) -> WindowHandle? {
        guard let handle = reader.captureHandle(
            for: AXWindowTarget(pid: target.pid, title: target.title, bounds: target.bounds),
            attempts: attempts,
            retryIntervalMicroseconds: retryIntervalMicroseconds,
            messagingTimeout: 0.5
        ) else {
            return nil
        }
        return WindowHandle(
            pid: target.pid,
            title: handle.title,
            bounds: handle.bounds,
            element: handle.element
        )
    }

    func minimize(_ handle: WindowHandle) -> ActionExecution {
        if chipProbeEnabled {
            // Read-only survey, intentionally absent from the default click path.
            let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: handle.element, maxAttempts: 1)
            let subrole = reader.stringAttribute(kAXSubroleAttribute as CFString, from: handle.element, maxAttempts: 1)
            let hasMinimizeButton = axElementAttribute(kAXMinimizeButtonAttribute as CFString, from: handle.element) != nil
            let currentMinimized = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element, maxAttempts: 1)
            var minimizedSettable: DarwinBoolean = false
            _ = AXUIElementIsAttributeSettable(handle.element, kAXMinimizedAttribute as CFString, &minimizedSettable)
            let probeApp = NSRunningApplication(processIdentifier: handle.pid)
            let probePolicyStr: String
            switch probeApp?.activationPolicy {
            case .regular: probePolicyStr = "regular"
            case .accessory: probePolicyStr = "accessory"
            case .prohibited: probePolicyStr = "prohibited"
            default: probePolicyStr = "nil"
            }
            Self.chipProbeLogger.info("minimize-ax-probe app=\(probeApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(probeApp?.bundleIdentifier ?? "(none)", privacy: .public) activationPolicy=\(probePolicyStr, privacy: .public) role=\(role ?? "nil", privacy: .public) subrole=\(subrole ?? "nil", privacy: .public) hasMinimizeButton=\(hasMinimizeButton, privacy: .public) currentMinimized=\(String(describing: currentMinimized), privacy: .public) minimizedSettable=\(minimizedSettable.boolValue, privacy: .public)")
        }

        if setMinimized(true, for: handle) {
            let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            if verified == true {
                return ActionExecution(
                    success: true,
                    mechanism: "set-minimized-attribute",
                    verifiedMinimized: verified
                )
            }
        }

        guard let button = axElementAttribute(kAXMinimizeButtonAttribute as CFString, from: handle.element) else {
            // 无最小化按钮但回读已是收起态（AXDialog 类窗口，Release 实测 2026-08-26）：
            // 目标状态已成立就是成功，报失败会让乐观态误回弹。
            let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            return ActionExecution(
                success: verified == true,
                mechanism: "missing-minimize-button",
                verifiedMinimized: verified
            )
        }

        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            return ActionExecution(
                success: false,
                mechanism: "press-minimize-button-failed",
                verifiedMinimized: reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            )
        }

        let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
        return ActionExecution(
            success: verified == true,
            mechanism: "press-minimize-button",
            verifiedMinimized: verified
        )
    }

    func restore(_ handle: WindowHandle) -> ActionExecution {
        if setMinimized(false, for: handle) {
            _ = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
            let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            return ActionExecution(
                success: verified == false,
                mechanism: "clear-minimized-attribute",
                verifiedMinimized: verified
            )
        }

        guard let rebound = recapture(from: handle) else {
            return ActionExecution(
                success: false,
                mechanism: "recapture-for-restore-failed",
                verifiedMinimized: nil
            )
        }
        guard setMinimized(false, for: rebound) else {
            return ActionExecution(
                success: false,
                mechanism: "clear-minimized-after-recapture-failed",
                verifiedMinimized: reader.boolAttribute(kAXMinimizedAttribute as CFString, from: rebound.element)
            )
        }
        _ = AXUIElementPerformAction(rebound.element, kAXRaiseAction as CFString)
        let verified = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: rebound.element)
        return ActionExecution(
            success: verified == false,
            mechanism: "clear-minimized-after-recapture",
            verifiedMinimized: verified
        )
    }

    func activate(_ handle: WindowHandle) -> Bool {
        activate(handle, requiresFocusedConfirmation: false)
    }

    func activate(
        _ handle: WindowHandle,
        requiresFocusedConfirmation: Bool,
        confirmationTimeout: TimeInterval = 0.6,
        pollIntervalMicroseconds: useconds_t = 100_000,
        knownCGWindowID: CGWindowID? = nil,
        knownMinimized: Bool = false,
        preActivateForRestore: Bool = false,
        awaitOnScreenBeforeFocus: Bool = false
    ) -> Bool {
        let runningApp = NSRunningApplication(processIdentifier: handle.pid)
        // `knownMinimized` 来自快照，只作**肯定**的快路径用（2026-08-11）：快照说它最小化，就直接
        // 还原，省掉一次对打盹 App 的 AX 往返——那正是「点最小化的窗口最慢」里最后一段等待。
        // 反过来**不能**用：快照说「没最小化」时仍必须现读，否则一次陈旧快照就会让窗口回不来。
        // 误判方向也无害：对一个其实没最小化的窗口写 `minimized = false` 是空操作。
        if knownMinimized || reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element) == true {
            // R2 序（2026-08-22 矩阵）：无非最小化兄弟时先切前台、微秒级紧跟还原——
            // AppKit 进程内把还原窗口直接立为 key，红绿灯在还原动画期间即为彩色，
            // 消掉「窗口出现后补聚焦」的过程（外部事件在动画期间进不了 App 事件队列，
            // 矩阵 R0/R1/R3 实证补发无效，唯一的原生同款路径就是让 App 自己做）。
            // 判定见 MinimizedRestorePreActivation；有兄弟时走下面的原有顺序。
            if preActivateForRestore, let wid = knownCGWindowID {
                postSkyLightFrontSwitchOnly(pid: handle.pid, windowID: wid)
            }
            _ = setMinimized(false, for: handle)
            // 回屏等待(2026-08-25 midMin/midMinWait 探针,仅连点先验路径):unminimize 落在
            // genie 尾段时窗口有约 40-100ms 离屏空窗,聚焦(含前台切换)若在空窗内被处理,
            // AppKit 会把可见兄弟**持久**提拔(访达 gap300 实测 1/3 踩中:+381ms B2 压 A1,
            // 目标回屏后伤害仍在);等 wid 回到 CG 在屏后再发聚焦,脏配置复测 2/2 干净,
            // 通常只等 ≤50ms(等待时长可从 DOCK_CLICK_TRACE 的 total 看出)。R2 预切路径与
            // 普通还原(目标本就稳定离屏,聚焦排队到还原动画尾,v3 实测 5/5)保持原序不动。
            if awaitOnScreenBeforeFocus, !preActivateForRestore, let wid = knownCGWindowID {
                waitForWindowOnScreen(wid)
            }
            // 恢复→切换必须紧贴、中间零 AX 问询（2026-07-05 探针 v3）：最小化恢复不做提前
            // 聚焦——B1 还在 order-out 时任何切前台（含 kCPSNoWindows、不发 make-key 的裸
            // psn 切换）都会让 App 自动提拔可见兄弟 B2 压到旧前台 A1 上（持久 z 序变化）。
            // 唯一干净路径：unminimize 之后立即用快照 wid 发完整 SkyLight 聚焦，make-key
            // 此刻正确落在刚恢复的 B1 上；间隔微秒级，re-asserter 源（Ghostty/Chromium 系
            // ~450ms 才回浮）来不及抢，激活闪不回归（500ms 最坏空窗实测无闪）。
            if let wid = knownCGWindowID {
                postSkyLightWindowFocus(pid: handle.pid, windowID: wid)
            }
            // 恢复后立刻把 App 内部焦点键回本窗口（kAXMain = App 内切窗的标准 AX 通道）。
            // 对「仍最小化的窗口」发过的 make-key 会被 App 落到可见兄弟窗口上；不纠正的话，
            // 键盘输入和「最小化回上一个 App」的 focused-window 保护都会错到兄弟窗口
            // （2026-07-03 Chrome/访达 B1B2 实测）。
            AXUIElementSetAttributeValue(handle.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }

        // Trial focus patch: target the concrete window first so standard app activation
        // does not briefly restore a sibling/previous key window over the requested one.
        // 顺序固定为「先 SkyLight（前置 + make-key down）后 kAXRaiseAction」——AltTab 同序，
        // CLI 连续切换实证（2026-08-22）；raise 是连续切换能持续生效的一环，不是可选项。
        let focusedViaSkyLight = focusWindowViaSkyLight(pid: handle.pid, element: handle.element)
        let raised = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString) == .success
        if !focusedViaSkyLight, runningApp?.isActive != true {
            _ = runningApp?.activate(options: [.activateIgnoringOtherApps])
        }

        if requiresFocusedConfirmation {
            return confirmFocused(
                handle,
                timeout: confirmationTimeout,
                pollIntervalMicroseconds: pollIntervalMicroseconds
            )
        }

        return focusedViaSkyLight || raised || runningApp?.isActive == true
    }

    /// 等窗口回到 CG 在屏列表(layer-0 onscreen)。Platform 首个 CG 轮询;语义与
    /// `scratch/minrestore_probe.swift` 的 midMinWait 变体一致(探针用全表 contains,这里用
    /// 单窗查询判 onscreen+layer0)。2ms 步长、0.9s 上限与探针一致、超时照做不阻塞(全仓惯例);
    /// 只在 actionQueue 后台线程上运行。
    @discardableResult
    private func waitForWindowOnScreen(_ windowID: CGWindowID, cap: TimeInterval = 0.9) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + cap
        repeat {
            if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
               let info = list.first,
               (info[kCGWindowIsOnscreen as String] as? Bool) == true,
               (info[kCGWindowLayer as String] as? Int) == 0 {
                return true
            }
            usleep(2_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    func close(_ handle: WindowHandle) -> Bool {
        guard let button = axElementAttribute(kAXCloseButtonAttribute as CFString, from: handle.element) else {
            return false
        }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private func recapture(from handle: WindowHandle) -> WindowHandle? {
        captureHandle(
            for: WindowTarget(
                pid: handle.pid,
                title: handle.title,
                bounds: handle.bounds
            )
        )
    }

    private func confirmFocused(
        _ handle: WindowHandle,
        timeout: TimeInterval,
        pollIntervalMicroseconds: useconds_t
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isFocused(handle) {
                return true
            }
            if let rebound = recapture(from: handle),
               isFocused(rebound) {
                return true
            }
            usleep(pollIntervalMicroseconds)
        } while Date() < deadline

        return false
    }

    private func isFocused(_ handle: WindowHandle) -> Bool {
        guard let focusedWindow = reader.focusedWindow(forPID: handle.pid) else {
            return false
        }
        return CFEqual(focusedWindow, handle.element)
    }

    /// 最小化前的前台交接：决定把前台交给谁（规则与理由见 `MinimizeHandoffTarget`）。
    /// 两道闸保留：目标 App 得在前台、且这扇窗就是它的 focused window——右键最小化后台兄弟不抢焦点。
    /// CG 列表只取 pid / wid / layer，**不读 `kCGWindowName`**（需要屏幕录制权限，装机版没有，
    /// 2026-08-23 实测原标题守卫让交接从未生效）；候选资格改由快照成员身份决定。
    func findBackgroundActivationTarget(
        for handle: WindowHandle,
        record: WindowRecord,
        snapshot: DockSnapshot
    ) -> MinimizeHandoffTarget.Verdict {
        // isActive（即时读）而非 NSWorkspace.frontmostApplication（滞后缓存）：SkyLight 激活后
        // ~1.5s 内读缓存会误判"App 不在前台"，静默跳过预切 → macOS 提拔同 App 兄弟窗口。
        guard NSRunningApplication(processIdentifier: handle.pid)?.isActive == true else { return .none }

        let appElement = AXUIElementCreateApplication(handle.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        guard let focused = axElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement),
              CFEqual(focused, handle.element) else { return .none }

        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return .none }

        var zOrder: [MinimizeHandoffTarget.ZOrderedWindow] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != ourPID else { continue }
            guard let wid = info[kCGWindowNumber as String] as? UInt32 else { continue }
            zOrder.append(.init(pid: ownerPID, cgWindowID: CGWindowID(wid)))
        }

        let verdict = MinimizeHandoffTarget.select(zOrder: zOrder, target: record, snapshot: snapshot)
        switch verdict {
        case .switchTo(let pid, let wid, let windowID):
            Self.chipProbeLogger.info(
                "postactivate-target candidate=\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "(unknown)", privacy: .public) pid=\(pid, privacy: .public) wid=\(wid, privacy: .public) windowID=\(windowID.rawValue, privacy: .public)"
            )
        case .siblingTakesOver(let windowID):
            Self.chipProbeLogger.info("postactivate-target sibling-takes-over pid=\(handle.pid, privacy: .public) windowID=\(windowID.rawValue, privacy: .public)")
        case .none:
            Self.chipProbeLogger.info("postactivate-target no-eligible-candidate pid=\(handle.pid, privacy: .public)")
        }
        return verdict
    }

    // MARK: - Front process and window-targeted focus helpers

    private typealias GetProcessForPIDFunc =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let getProcessForPID: GetProcessForPIDFunc? = {
        let paths = [
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "/System/Library/Frameworks/CoreServices.framework/CoreServices"
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            guard let get = dlsym(handle, "GetProcessForPID") else { continue }
            return unsafeBitCast(get, to: GetProcessForPIDFunc.self)
        }
        return nil
    }()

    /// 最小化前的前台交接（M4，2026-08-23 矩阵 0/20 提拔）：`_SLPSSetFrontProcessWithOptions`
    /// 以 `kCPSNoWindows` 切前台——**不抬交接 App 的任何窗口**，被收的窗口从最上层正常收起，收完
    /// 下面那扇自然就在最前；然后**等目标 App 自己通过 AX 回答「不在前台」**（典型 9–13ms，
    /// 上限 100ms）再最小化。`NSRunningApplication.isActive` 瞬间就翻、不能当这个闸：
    /// 它翻了之后目标 App 仍可能没处理完失活，此时最小化 AppKit 照样提拔兄弟（矩阵 M1/M2/M3
    /// 各 1–3/10；加 AX 闸后 M4/M5 均 0/20）。旧的公开 API `SetFrontProcessWithOptions(FrontWindowOnly)`
    /// 会先把交接窗口抬到被收窗口之上，动画从别人背后开始，已弃用。
    func switchFrontmostForHandoff(toPID pid: pid_t, windowID: CGWindowID, awaitingDeactivationOf targetPID: pid_t) -> Bool {
        guard postSkyLightFrontSwitchOnly(pid: pid, windowID: windowID, mode: Self.kCPSNoWindows) else {
            Self.chipProbeLogger.info("switch-frontmost-handoff unavailable pid=\(pid, privacy: .public)")
            return false
        }
        let targetApp = AXUIElementCreateApplication(targetPID)
        AXUIElementSetMessagingTimeout(targetApp, 0.05)
        let deadline = Date().addingTimeInterval(0.1)
        var stillFrontmost: Bool? = true
        repeat {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(targetApp, kAXFrontmostAttribute as CFString, &raw) == .success {
                stillFrontmost = (raw as? NSNumber)?.boolValue
            } else {
                stillFrontmost = nil
            }
            if stillFrontmost == false { break }
            usleep(2_000)
        } while Date() < deadline
        Self.chipProbeLogger.info("switch-frontmost-handoff pid=\(pid, privacy: .public) targetStillFrontmost=\(String(describing: stillFrontmost), privacy: .public)")
        return true
    }

    private typealias SLPSSetFrontWindowFunc =
        @convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias SLPSPostEventFunc =
        @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> Int32

    private static let skyLightFocus: (slps: SLPSSetFrontWindowFunc, post: SLPSPostEventFunc)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let slps = dlsym(handle, "_SLPSSetFrontProcessWithOptions"),
              let post = dlsym(handle, "SLPSPostEventRecordTo") else { return nil }
        return (
            unsafeBitCast(slps, to: SLPSSetFrontWindowFunc.self),
            unsafeBitCast(post, to: SLPSPostEventFunc.self)
        )
    }()

    private static let skyLightFocusEnabled =
        ProcessInfo.processInfo.environment["DOCK_SKYLIGHT_FOCUS"] != "0"

    /// 仅做 `_SLPSSetFrontProcessWithOptions` 前切、不发 make-key down（还原预激活用：
    /// down 要等 unminimize 之后发，见 activate() 还原分支的 R2 序注释）。
    fileprivate static let kCPSUserGenerated: UInt32 = 0x200
    /// 切前台但不抬该 App 的任何窗口（最小化交接用，见 `switchFrontmostForHandoff`）。
    fileprivate static let kCPSNoWindows: UInt32 = 0x400

    @discardableResult
    fileprivate func postSkyLightFrontSwitchOnly(
        pid: pid_t,
        windowID: CGWindowID,
        mode: UInt32 = AccessibilityWindowActionExecutor.kCPSUserGenerated
    ) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard let focus = Self.skyLightFocus,
              let getPSN = Self.getProcessForPID else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        _ = withUnsafePointer(to: &psn) { focus.slps($0, windowID, mode) }
        return true
    }

    /// Shared SkyLight focus core: front-process switch + one synthetic make-key mouse-down for a
    /// known cgWindowID. Pure event posts — no AX round-trips, so it never blocks on a
    /// napping target app. Byte layout is load-bearing (see AGENTS.md); do not vary it.
    ///
    /// 2026-08-22 换布局：旧的成对 0x0d make-key 事件在 macOS 26 (Tahoe) 上被 WindowServer
    /// 静默忽略（调用全部返回成功、焦点纹丝不动，CLI 探针实证），点标签后 kAXFocusedWindow
    /// 停在旧窗口 → 快照永远等不到 .active → 同应用切窗失效 + toggle 误最小化。现布局
    /// 移植自 AltTab（macOS 26.5 实测有效，src/macos/api-wrappers/SkyLight.framework.swift）：
    /// 按 windowID 投递一枚合成 kCGEventLeftMouseDown（0x08=0x01），只发 down 不发 up——
    /// down 单独即交付 key，且半次点击永远无法激活任何控件；落点 (300_000, 300_000) 远在
    /// 任何窗口右下之外（NaN 会被部分 App 消毒成 (0,0) 误点左上控件；贴框点会落进
    /// resize 抓取区）。缓冲区 0x100 而记录声明长度仍 0xf8：macOS 14.7.4+ 的
    /// CGSEncodeEventRecord 会越界读到 0xf8 之外，短缓冲会 SIGABRT。
    /// 事件后必须紧跟 kAXRaiseAction 才能连续切换（本文件 focusWindowViaSkyLight /
    /// activate() 均保持该顺序；CLI 连续 4 次切换实证）。
    @discardableResult
    fileprivate func postSkyLightWindowFocus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard Self.skyLightFocus != nil, Self.getProcessForPID != nil else {
            Self.chipProbeLogger.info("skylight-focus unavailable pid=\(pid, privacy: .public)")
            return false
        }
        guard postSkyLightFrontSwitchOnly(pid: pid, windowID: windowID, mode: Self.kCPSUserGenerated) else {
            Self.chipProbeLogger.info("skylight-focus GetProcessForPID failed pid=\(pid, privacy: .public)")
            return false
        }
        return postSkyLightMakeKeyDown(pid: pid, windowID: windowID)
    }

    /// 只发 make-key 的合成 mouse-down，不切前台（字节布局见上）。最小化交接后给接手 App 的那扇
    /// 窗口补 key 用：`kCPSNoWindows` 前切让 App 成了前台却没有 key 窗口（owner 2026-08-23
    /// 「聚焦是空的」），收起目标后补这一枚 down，接手窗口立刻成 key（矩阵 M6 5/5）。
    @discardableResult
    fileprivate func postSkyLightMakeKeyDown(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard let focus = Self.skyLightFocus, let getPSN = Self.getProcessForPID else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }

        var event = [UInt8](repeating: 0, count: 0x100)
        event[0x04] = 0xf8            // 记录声明长度（不随缓冲区变）
        event[0x08] = 0x01            // kCGEventLeftMouseDown；只发 down，不发 up
        event[0x3a] = 0x10            // 用途未知；yabai / Hammerspoon / AltTab 均置 0x10
        var wid = windowID
        withUnsafeBytes(of: &wid) { bytes in
            for index in 0..<4 {
                event[0x3c + index] = bytes[index]
            }
        }
        var offContentPoint = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &offContentPoint) { bytes in
            for index in 0..<16 {
                event[0x20 + index] = bytes[index]
            }
        }
        withUnsafePointer(to: &psn) { pointer in
            event.withUnsafeBufferPointer { _ = focus.post(pointer, $0.baseAddress!) }
        }
        return true
    }

    /// 最小化交接的收尾：目标已收起，给接手 App 的窗口补 key（见 `postSkyLightMakeKeyDown`）。
    func makeKeyAfterHandoff(pid: pid_t, windowID: CGWindowID) {
        postSkyLightMakeKeyDown(pid: pid, windowID: windowID)
    }

    /// 提前聚焦（激活闪根治 2026-07-03）：点击瞬间用快照里已知的 cgWindowID 直接切前台，
    /// 抢在任何可能阻塞 400–900ms 的 AX 问询（句柄捕获 / 最小化读取 / cgID 读取）之前。
    /// 空窗期正是 Ghostty / Chromium 系前台 App 把自己窗口抢回顶层造成激活闪的窗口期。
    /// 仅限可见窗口：最小化窗口不能提前切换（App 会提拔可见兄弟窗口，2026-07-05 探针），
    /// 它们走 activate() 里「unminimize 后立即切换」的路径（knownCGWindowID）。
    @discardableResult
    func focusWindowEarly(pid: pid_t, cgWindowID: CGWindowID) -> Bool {
        postSkyLightWindowFocus(pid: pid, windowID: cgWindowID)
    }

    /// Best-effort windowID-targeted focus. Return false only when we cannot even
    /// attempt the route; SkyLight return codes are not a fallback signal.
    @discardableResult
    func focusWindowViaSkyLight(pid: pid_t, element: AXUIElement) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard let windowID = reader.cgWindowID(for: element) else {
            Self.chipProbeLogger.info("skylight-focus unavailable pid=\(pid, privacy: .public)")
            return false
        }

        guard postSkyLightWindowFocus(pid: pid, windowID: windowID) else {
            return false
        }
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        return true
    }

    private func setMinimized(_ minimized: Bool, for handle: WindowHandle) -> Bool {
        reader.setMinimized(
            minimized,
            for: AXWindowHandle(pid: handle.pid, title: handle.title, bounds: handle.bounds, element: handle.element)
        )
    }

    private func bestMatch(for target: WindowTarget, from elements: [AXUIElement]) -> AXUIElement? {
        let scored = elements.compactMap { element -> (AXUIElement, Int)? in
            let title = axStringAttribute(kAXTitleAttribute as CFString, from: element)
            let bounds = axFrame(of: element)
            let score = AXWindowMatchPolicy.matchScore(
                targetTitle: target.title,
                targetBounds: target.bounds,
                candidateTitle: title,
                candidateBounds: bounds
            )
            return score.map { (element, $0) }
        }

        return scored.min(by: { $0.1 < $1.1 })?.0
    }

    private func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct ActionExecutionSwitches: Equatable {
    let fastWindowHandleEnabled: Bool
    /// `DOCK_AX_ELEMENT_CACHE=0` 关掉「缓存元素」那一档，回到 fast / fallback 两档。
    let axElementCacheEnabled: Bool
    let chipProbeEnabled: Bool
    let minimizeAppFallbackEnabled: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        fastWindowHandleEnabled = environment["DOCK_FAST_WINDOW_HANDLE"] != "0"
        axElementCacheEnabled = environment["DOCK_AX_ELEMENT_CACHE"] != "0"
        chipProbeEnabled = environment["DOCK_CHIP_PROBE"] == "1"
        minimizeAppFallbackEnabled = environment["DOCK_MINIMIZE_APP_FALLBACK"] == "1"
    }
}

enum WindowHandleCapturePlan {
    /// 三档，从快到慢：**缓存元素（零枚举）→ 按 cgWindowID 现问（100ms）→ 全量标题/几何链（500ms）**。
    ///
    /// `justUnhid` 对**前两档**一律禁用：刚 unhide 出来的 App，其 AX 元素可能仍在过渡态，
    /// 缓存里那个更是最小化/隐藏之前存的，两者都不可信，必须走带重试的慢路径（既有规则，不变）。
    static func capture<Handle>(
        cachedEnabled: Bool,
        fastEnabled: Bool,
        cgWindowID: CGWindowID?,
        justUnhid: Bool,
        cached: (CGWindowID) -> Handle?,
        fast: (CGWindowID) -> Handle?,
        fallback: () -> Handle?
    ) -> Handle? {
        if let cgWindowID, !justUnhid {
            if cachedEnabled, let handle = cached(cgWindowID) { return handle }
            if fastEnabled, let handle = fast(cgWindowID) { return handle }
        }
        return fallback()
    }

    /// `knownMinimized` 的 activate 禁止 app 级兜底(2026-08-25,无条件生效、不挂沉降门开关):
    /// `activateAppWithWindowRecovery` raise 的是 `visibleWindows[0]`——对最小化目标永远还原
    /// 不了它,只会把兄弟窗口带到前面(owner 连点实测的确切出处)。捕获全败就返回失败让乐观态
    /// 回弹,与 2026-08-11「minimize 捕获失败绝不 hide 整 App」同构,故同样不挂开关。
    static func usesAppFallbackAfterCaptureFailure(
        requestKind: PlatformActionRequest.ActionKind,
        isFinderWindow: Bool,
        minimizeAppFallbackEnabled: Bool,
        knownMinimized: Bool
    ) -> Bool {
        guard !isFinderWindow else { return false }
        if requestKind == .minimizeWindow { return minimizeAppFallbackEnabled }
        if requestKind == .activateWindow && knownMinimized { return false }
        return true
    }
}

/// 还原前预激活判定（2026-08-22 还原时序矩阵）：仅当目标 App 除目标窗口外
/// **没有任何非最小化窗口**时，才允许「先切前台、紧跟还原」（R2 序）——那时 AppKit
/// 无可提拔对象，进程内 deminiaturize-as-key 让红绿灯在还原动画期间即为彩色（原生观感）。
/// 存在任何非最小化兄弟（可见 / 隐藏 / disappeared 一律保守算数）时禁用：矩阵实证
/// 即便切换与还原微秒级相邻，AppKit 仍会把可见兄弟持久抬到旧前台之上（07-05 护栏
/// 在新事件机制下依然成立）。纯函数，FinderP0Tests 锁行为。
enum MinimizedRestorePreActivation {
    static func canPreActivate(snapshot: DockSnapshot, target: WindowRecord) -> Bool {
        !snapshot.windows.values.contains {
            $0.pid == target.pid && $0.id != target.id && $0.status != .minimized
        }
    }
}

struct PlatformActionExecutor {
    private let windowExecutor: AccessibilityWindowActionExecutor
    private let switches: ActionExecutionSwitches
    private static let chipProbeLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "ChipProbe")
    private static let postMinimizeActivateDelayMicroseconds: useconds_t = 50_000

    init(switches: ActionExecutionSwitches = ActionExecutionSwitches()) {
        self.switches = switches
        windowExecutor = AccessibilityWindowActionExecutor(chipProbeEnabled: switches.chipProbeEnabled)
    }

    @discardableResult
    func execute(
        _ request: PlatformActionRequest,
        snapshot: DockSnapshot,
        forcedMinimizedPrior: Bool,
        onHandoffActivePrediction: ((WindowID) -> Void)?
    ) -> Bool {
        guard let windowID = request.windowID,
              let record = snapshot.windows[windowID] else {
            return false
        }
        // 沉降门先验(v2,2026-08-25):门层刚对该窗口派发过 minimize(priorWindow 内)。
        // 只作**肯定**信号合成进 knownMinimized——真最小化走实测锁死的 v3 还原序;其实没
        // 最小化时 unminimize 是无害空操作 + 正常聚焦。绝不反向使用(affirmative-only)。
        let effectiveKnownMinimized = forcedMinimizedPrior || record.status == .minimized

        if record.id.rawValue.hasPrefix("app-") {
            return executeAppFallback(request: request, record: record)
        }

        // New window needs no window handle — just activate the app and send Cmd+N.
        if request.kind == .newWindow {
            return performNewWindow(record: record)
        }

        if request.kind == .hideApp || request.kind == .quitApp {
            return executeAppFallback(request: request, record: record)
        }

        let isFinderWindow = FinderWindowRules.isFinder(bundleIdentifier: record.bundleIdentifier)

        // 提前聚焦（激活闪根治 2026-07-03）：仅 activate + 跨 App + 可见窗口，
        // 访达也包含（confirmFocused 保护路径在后面照常执行；访达的多次捕获重试空窗更长，
        // 曾是"只剩访达还闪"的原因）。必须发生在下面的句柄捕获之前 —— 捕获/恢复对目标 App
        // 的 AX 问询可阻塞数百毫秒，这段空窗正是仍聚焦的旧前台 App（Ghostty / Chromium 系）
        // 把窗口抢回顶层的窗口期。隐藏 App 的窗口不提前（unhide 流程另算）。
        // 最小化窗口【不】提前（2026-07-05 探针 v0–v3）：B1 仍 order-out 时任何切前台都会
        // 让 App 把可见兄弟 B2 提拔到旧前台之上（持久 z 序 bug）；改为 activate() 里
        // unminimize 之后立即切换（见 knownCGWindowID 路径），实测同样无闪。
        // 沉降门先验在飞时跳过提前聚焦(2026-08-25):连点风暴中快照可能仍陈旧地写着
        // inactive,而窗口实际在 genie 中/屏外——此时提前聚焦的前台切换就是 07-05 矩阵里
        // 3/3 提拔兄弟的裸切换(owner 点击日志实锤该路径在风暴中触发过)。
        if request.kind == .activateWindow,
           !forcedMinimizedPrior,
           let cgWindowID = record.cgWindowID,
           record.status == .active || record.status == .inactive,
           NSRunningApplication(processIdentifier: record.pid)?.isActive != true {
            windowExecutor.focusWindowEarly(pid: record.pid, cgWindowID: cgWindowID)
            ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "earlyFocus")
        }

        // If Finder is hidden, unhide it first so its AX windows become accessible.
        // Then fall through to the normal window-level capture path — avoids regressing
        // to app-level activate, which can raise the wrong window (guardrail in AGENTS.md).
        var justUnhid = false
        if isFinderWindow {
            let finderApp = NSRunningApplication(processIdentifier: record.pid)
            if finderApp?.isHidden == true {
                finderApp?.unhide()
                // Poll until the app transitions out of hidden (max ~200ms) so the AX
                // element is accessible before the handle-capture below runs.
                let deadline = Date().addingTimeInterval(0.2)
                while finderApp?.isHidden == true, Date() < deadline {
                    usleep(20_000)
                }
                justUnhid = true
            }
        }

        let target = AccessibilityWindowActionExecutor.WindowTarget(
            pid: record.pid, title: record.title, bounds: record.bounds)
        // After unhide, skip the fast cgWindowID path — it may return a handle whose AX
        // element is still transitioning. Use the retry-capable captureHandle instead.
        // 命中的是哪一档，是这轮改动能不能证明有效的关键分类信息（缓存 / 快路径 / 全量链）。
        var captureTier = "none"
        let handle = WindowHandleCapturePlan.capture(
            cachedEnabled: switches.axElementCacheEnabled,
            fastEnabled: switches.fastWindowHandleEnabled,
            cgWindowID: record.cgWindowID,
            justUnhid: justUnhid,
            cached: {
                let h = windowExecutor.captureHandleFromCache(
                    $0,
                    pid: record.pid,
                    title: record.title,
                    bounds: record.bounds
                )
                if h != nil { captureTier = "cached" }
                return h
            },
            fast: {
                let h = windowExecutor.captureHandleByCGWindowID(
                    $0,
                    pid: record.pid,
                    title: record.title,
                    bounds: record.bounds
                )
                if h != nil { captureTier = "fast" }
                return h
            },
            fallback: {
                let h = windowExecutor.captureHandle(
                    for: target,
                    attempts: isFinderWindow ? 3 : 1,
                    retryIntervalMicroseconds: isFinderWindow ? 150_000 : 0
                )
                if h != nil { captureTier = "fallback" }
                return h
            }
        )
        ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "handle", detail: captureTier)

        guard let handle else {
            guard WindowHandleCapturePlan.usesAppFallbackAfterCaptureFailure(
                requestKind: request.kind,
                isFinderWindow: isFinderWindow,
                minimizeAppFallbackEnabled: switches.minimizeAppFallbackEnabled,
                knownMinimized: effectiveKnownMinimized
            ) else {
                return false
            }
            return executeAppFallback(request: request, record: record)
        }

        switch request.kind {
        case .activateWindow:
            return windowExecutor.activate(
                handle,
                requiresFocusedConfirmation: isFinderWindow,
                knownCGWindowID: record.cgWindowID,
                knownMinimized: effectiveKnownMinimized,
                preActivateForRestore: effectiveKnownMinimized
                    && MinimizedRestorePreActivation.canPreActivate(snapshot: snapshot, target: record),
                awaitOnScreenBeforeFocus: forcedMinimizedPrior
            )
        case .minimizeWindow:
            let handoff = windowExecutor.findBackgroundActivationTarget(for: handle, record: record, snapshot: snapshot)
            // 接手者预测尽早回传（minimize 尚未执行）：越早写乐观 .active，越能覆盖极快的
            // 「收窗 1 → 点窗 2」第二击。minimize 失败时预测由顶替清除自愈（目标仍 .active 兑现）。
            switch handoff {
            case .switchTo(_, _, let windowID), .siblingTakesOver(let windowID):
                onHandoffActivePrediction?(windowID)
            case .none:
                break
            }
            var targetPID: pid_t?
            var handoffWindowID: CGWindowID?
            var preSwitched = false
            if case .switchTo(let pid, let wid, _) = handoff {
                targetPID = pid
                handoffWindowID = wid
                preSwitched = windowExecutor.switchFrontmostForHandoff(
                    toPID: pid, windowID: wid, awaitingDeactivationOf: handle.pid
                )
            }

            func finishSuccessfulMinimize(_ exec: AccessibilityWindowActionExecutor.ActionExecution) -> Bool {
                if preSwitched, let targetPID, let handoffWindowID {
                    windowExecutor.makeKeyAfterHandoff(pid: targetPID, windowID: handoffWindowID)
                }
                if !preSwitched, let targetPID {
                    usleep(Self.postMinimizeActivateDelayMicroseconds)
                    let activated = NSRunningApplication(processIdentifier: targetPID)?
                        .activate(options: [.activateIgnoringOtherApps]) ?? false
                    if switches.chipProbeEnabled {
                        Self.chipProbeLogger.info("postactivate-background-fallback pid=\(targetPID, privacy: .public) activated=\(activated, privacy: .public)")
                    }
                }
                if switches.chipProbeEnabled {
                    Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(exec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(exec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: exec.verifiedMinimized), privacy: .public)")
                }
                return true
            }

            let minExec = windowExecutor.minimize(handle)
            if minExec.success {
                return finishSuccessfulMinimize(minExec)
            }
            if justUnhid {
                usleep(100_000)
                if let h = windowExecutor.captureHandle(for: target, attempts: 2, retryIntervalMicroseconds: 100_000) {
                    let retryExec = windowExecutor.minimize(h)
                    if switches.chipProbeEnabled {
                        Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(retryExec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(retryExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: retryExec.verifiedMinimized), privacy: .public)")
                    }
                    return retryExec.success
                }
            }
            // 还原动画期的写入丢弃（2026-08-26 Release 实测）：还原 genie 未结束时，
            // kAXMinimized 写入与最小化按钮点击都被应用丢弃（11–16ms 快速失败、回读 false）。
            // 中途反向打断不可行（scratch/minrestore_probe 2026-08-25），有界重试等窗口恢复
            // 接受写入后立刻补上这一击——是能达到的最早收起时点。8×120ms 总覆盖 ~1s
            //（访达 887ms 动画；同日 Release 实测 27/27 次首试 +250ms 即成功，故间隔收紧到
            // 120ms 磨掉落地零头）；只走失败路径，正常收起零成本。全部失败则照旧返回失败、
            // 乐观态回弹。
            if minExec.verifiedMinimized != true {
                for attempt in 1...8 {
                    usleep(120_000)
                    let retryExec = windowExecutor.minimize(handle)
                    if switches.chipProbeEnabled {
                        Self.chipProbeLogger.info("minimize-retry attempt=\(attempt, privacy: .public) windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(retryExec.success, privacy: .public) mechanism=\(retryExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: retryExec.verifiedMinimized), privacy: .public)")
                    }
                    if retryExec.success {
                        return finishSuccessfulMinimize(retryExec)
                    }
                }
            }
            if switches.chipProbeEnabled {
                Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(minExec.success, privacy: .public) preSwitched=\(preSwitched, privacy: .public) mechanism=\(minExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: minExec.verifiedMinimized), privacy: .public)")
            }
            return false
        case .closeWindow:
            if windowExecutor.close(handle) { return true }
            if justUnhid {
                usleep(100_000)
                if let h = windowExecutor.captureHandle(for: target, attempts: 2, retryIntervalMicroseconds: 100_000) {
                    return windowExecutor.close(h)
                }
            }
            return false
        case .hideApp, .quitApp:
            return executeAppFallback(request: request, record: record)
        case .newWindow:
            return performNewWindow(record: record)
        }
    }

    private func executeAppFallback(request: PlatformActionRequest, record: WindowRecord) -> Bool {
        let runningApp = NSRunningApplication(processIdentifier: record.pid)

        switch request.kind {
        case .activateWindow:
            // Finder persistent chip (no open windows): open home directory to create a new Finder
            // window, matching system Dock behavior when clicking Finder with no windows open.
            if record.id.rawValue.hasPrefix("app-"),
               FinderWindowRules.isFinder(bundleIdentifier: record.bundleIdentifier) {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
                return true
            }
            return windowExecutor.activateAppWithWindowRecovery(pid: record.pid, runningApp: runningApp)
        case .minimizeWindow, .hideApp:
            return runningApp?.hide() ?? false
        case .closeWindow:
            return false
        case .quitApp:
            return runningApp?.terminate() ?? false
        case .newWindow:
            return performNewWindow(record: record)
        }
    }

    /// Opens a new window for a window-backed app by activating it and synthesizing
    /// the standard Cmd+N key equivalent.
    ///
    /// v1 limitations (accepted, documented in README/Backlog): apps where Cmd+N means
    /// "new document" (Pages/TextEdit) yield a new document; apps not bound to Cmd+N
    /// do nothing. Covers ~90% of common apps. v2 upgrade path is AX menu traversal
    /// for a "New Window" item.
    private func performNewWindow(record: WindowRecord) -> Bool {
        guard let runningApp = NSRunningApplication(processIdentifier: record.pid) else { return false }
        runningApp.activate(options: [.activateIgnoringOtherApps])
        // Short tick so activation settles before the key equivalent is delivered.
        usleep(80_000)
        return postCommandN(toPID: record.pid)
    }

    private func postCommandN(toPID pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let keyN: CGKeyCode = 45 // kVK_ANSI_N
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyN, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyN, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }
}

private func windows(for pid: pid_t) -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(pid)
    guard let value = axCopyAttributeValue(kAXWindowsAttribute as CFString, from: appElement),
          let elements = value as? [AXUIElement] else {
        return []
    }
    return elements
}

private func axStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
    guard let value = axCopyAttributeValue(attribute, from: element),
          let text = value as? String else {
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func axBoolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
    guard let value = axCopyAttributeValue(attribute, from: element),
          let number = value as? NSNumber else {
        return nil
    }
    return number.boolValue
}

private func axElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
    // 跨进程 AX 返回值的类型由对方进程决定，实现有 bug 的 App 可能返回别的 CF 类型。
    // 不验类型直接 bitcast 是未定义行为，强制转换会直接 trap——代价都是整条任务条崩掉，先验类型再转。
    guard let value = axCopyAttributeValue(attribute, from: element),
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return (value as! AXUIElement)
}

private func axFrame(of element: AXUIElement) -> CGRect? {
    guard let positionAX = axCopyAttributeValue(kAXPositionAttribute as CFString, from: element),
          let sizeAX = axCopyAttributeValue(kAXSizeAttribute as CFString, from: element) else {
        return nil
    }

    // 同上：位置 / 尺寸也可能不是 AXValue，先验 CF 类型再转（`FrontmostWindowGeometryObserver` 同一条守则）。
    guard CFGetTypeID(positionAX) == AXValueGetTypeID(),
          CFGetTypeID(sizeAX) == AXValueGetTypeID() else {
        return nil
    }
    let position = positionAX as! AXValue
    let sizeValueRef = sizeAX as! AXValue

    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetType(position) == .cgPoint,
          AXValueGetType(sizeValueRef) == .cgSize,
          AXValueGetValue(position, .cgPoint, &point),
          AXValueGetValue(sizeValueRef, .cgSize, &size) else {
        return nil
    }

    return CGRect(origin: point, size: size)
}

private func axCopyAttributeValue(
    _ attribute: CFString,
    from element: AXUIElement,
    maxAttempts: Int = 2
) -> CFTypeRef? {
    var attempt = 0
    while attempt < maxAttempts {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        if result == .success {
            return value
        }

        if result != .cannotComplete {
            return nil
        }

        attempt += 1
        usleep(20_000)
    }

    return nil
}
