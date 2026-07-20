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
    private let reader = AXWindowReader()
    private static let chipProbeLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "ChipProbe")

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

    struct MinimizePreparation {
        fileprivate let handle: WindowHandle
        fileprivate let minimizeButton: AXUIElement?
    }

    struct BackgroundRaisePreparation {
        fileprivate let element: AXUIElement
        fileprivate let deadline: TimeInterval
    }

    private static let backgroundRaiseBudget: TimeInterval = 0.1

    func captureHandleByCGWindowID(_ cgWindowID: CGWindowID, pid: Int32) -> WindowHandle? {
        guard case .success(let snapshots) = reader.inventoryWindows(forPID: pid, messagingTimeout: 0.5) else { return nil }
        guard let snap = snapshots.first(where: { $0.cgWindowID == cgWindowID }) else { return nil }
        return WindowHandle(pid: pid, title: snap.title, bounds: snap.bounds, element: snap.element)
    }

    func activateAppWithWindowRecovery(pid: Int32, runningApp: NSRunningApplication?) -> Bool {
        let liveWindows = reader.windows(forPID: pid)
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

    func prepareMinimize(_ handle: WindowHandle) -> MinimizePreparation {
        // ChipProbe: read-only AX survey (background thread, element already has 0.5s messaging timeout)
        let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: handle.element, maxAttempts: 1)
        let subrole = reader.stringAttribute(kAXSubroleAttribute as CFString, from: handle.element, maxAttempts: 1)
        let minimizeButton = axElementAttribute(kAXMinimizeButtonAttribute as CFString, from: handle.element)
        let hasMinimizeButton = minimizeButton != nil
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

        return MinimizePreparation(handle: handle, minimizeButton: minimizeButton)
    }

    func minimize(_ handle: WindowHandle) -> ActionExecution {
        minimize(prepareMinimize(handle))
    }

    /// 「命令已提交」与「状态已确认」分离（2026-07-20，Illustrator）：AX 属性写入返回
    /// success 只代表命令被接受，不代表窗口已经最小化。Illustrator 这类异步最小化的 App
    /// 同步读回仍是 false，把它判成失败会让上层记成失败反馈，并（在删除前的实现里）对正在
    /// order-out 的窗口反向聚焦，直接把窗口还原回来。
    /// `success` 从此表示「命令已提交」；`verifiedMinimized` 降级为纯诊断，最终状态一律由
    /// AppTracker 快照确认——同步 AX 读数不再作任何成败判据（与本轮 SkyLight 落位排查
    /// 得出的同一条结论：进程内同步读数不是状态真相，Docs/22 §14）。
    func minimize(_ preparation: MinimizePreparation) -> ActionExecution {
        let handle = preparation.handle

        if setMinimized(true, for: handle) {
            let observed = reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            if observed == true {
                return ActionExecution(
                    success: true,
                    mechanism: "set-minimized-attribute",
                    verifiedMinimized: observed
                )
            }
            // 写入已被接受、但同步读回还没翻面。按钮兜底照按：它覆盖的是「写入被静默忽略」
            // 的 App，而那种情形与异步最小化在同步读数上无法区分。按钮结果不再决定成败，
            // 于是既保住兜底覆盖，又不会把异步 App 误判成失败（本次修复只动判定、不动按钮
            // 行为，回归时才好归因）。
            if let button = preparation.minimizeButton {
                _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
            return ActionExecution(
                success: true,
                mechanism: "set-minimized-attribute-submitted",
                verifiedMinimized: reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            )
        }

        guard let button = preparation.minimizeButton else {
            return ActionExecution(
                success: false,
                mechanism: "missing-minimize-button",
                verifiedMinimized: reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            )
        }

        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            return ActionExecution(
                success: false,
                mechanism: "press-minimize-button-failed",
                verifiedMinimized: reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
            )
        }

        // 按钮按下成功同样只是「命令已提交」，不以同步读回定成败。
        return ActionExecution(
            success: true,
            mechanism: "press-minimize-button",
            verifiedMinimized: reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element)
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
        forceRestore: Bool = false
    ) -> Bool {
        let runningApp = NSRunningApplication(processIdentifier: handle.pid)
        // forceRestore 直接 OR 进既有条件、复用同一段恢复代码，绝不新开第二条恢复路径——
        // 下面这段 restore-then-switch 的「恢复→切换微秒相邻、中间零 AX」是硬纪律，两处
        // 分别恢复会变成双写或两次竞争的 SkyLight 投递。短路求值同时省掉一次 AX 读。
        if forceRestore || reader.boolAttribute(kAXMinimizedAttribute as CFString, from: handle.element) == true {
            _ = setMinimized(false, for: handle)
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

        let raised = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString) == .success
        // Trial focus patch: target the concrete window first so standard app activation
        // does not briefly restore a sibling/previous key window over the requested one.
        let focusedViaSkyLight = focusWindowViaSkyLight(pid: handle.pid, element: handle.element)
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

    /// Finds the previous regular window to return to before minimizing the current
    /// frontmost focused window. Only fires when this specific handle is focused,
    /// so right-click minimizing a background sibling does not steal focus.
    func findBackgroundActivationTarget(
        for handle: WindowHandle,
        knownCGWindowID: CGWindowID? = nil,
        trustedWindows: Set<BackgroundWindowIdentity>
    ) -> BackgroundActivationTarget? {
        // isActive（即时读）而非 NSWorkspace.frontmostApplication（滞后缓存）：SkyLight 激活后
        // ~1.5s 内读缓存会误判"App 不在前台"，静默跳过预切 → macOS 提拔同 App 兄弟窗口。
        let isTargetAppActive = NSRunningApplication(processIdentifier: handle.pid)?.isActive == true
        guard isTargetAppActive else { return nil }

        let appElement = AXUIElementCreateApplication(handle.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        guard let focused = axElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(focused, 0.2)
        let targetWindowID = knownCGWindowID ?? reader.cgWindowID(for: handle.element, maxAttempts: 1)
        let focusedWindowID = reader.cgWindowID(for: focused, maxAttempts: 1)
        let needsElementFallback = targetWindowID == nil || focusedWindowID == nil
        guard BackgroundActivationDecision.targetWindowIsFocused(
            isTargetAppActive: isTargetAppActive,
            targetWindowID: targetWindowID,
            focusedWindowID: focusedWindowID,
            elementsEqual: needsElementFallback && CFEqual(focused, handle.element)
        ) else { return nil }

        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let candidates = list.compactMap { info -> BackgroundWindowCandidate? in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else {
                return nil
            }
            let app = NSRunningApplication(processIdentifier: ownerPID)
            let rawWindowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            let cgWindowID = rawWindowID.flatMap { $0 == 0 ? nil : $0 }
            let identity = cgWindowID.map {
                BackgroundWindowIdentity(pid: ownerPID, cgWindowID: $0)
            }
            return BackgroundWindowCandidate(
                pid: ownerPID,
                cgWindowID: cgWindowID,
                layer: layer,
                isRegularApplication: app?.activationPolicy == .regular,
                isTrustedWindow: identity.map(trustedWindows.contains) ?? false
            )
        }

        if let target = BackgroundActivationDecision.target(
            frontToBack: candidates,
            excludingPID: handle.pid,
            dockPID: ourPID
        ) {
            Self.chipProbeLogger.info(
                "postactivate-target pid=\(target.pid, privacy: .public) wid=\(target.cgWindowID, privacy: .public)"
            )
            return target
        }

        Self.chipProbeLogger.info("postactivate-target no-eligible-candidate pid=\(handle.pid, privacy: .public) trustedWindows=\(trustedWindows.count, privacy: .public) cgCandidates=\(candidates.count, privacy: .public)")
        return nil
    }

    // MARK: - Front process and window-targeted focus helpers

    private typealias GetProcessForPIDFunc =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessFunc =
        @convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32) -> OSStatus

    private static let frontProcessSwitch: (get: GetProcessForPIDFunc, setFront: SetFrontProcessFunc)? = {
        let paths = [
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "/System/Library/Frameworks/CoreServices.framework/CoreServices"
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            guard let get = dlsym(handle, "GetProcessForPID"),
                  let setFront = dlsym(handle, "SetFrontProcessWithOptions") else { continue }
            return (
                unsafeBitCast(get, to: GetProcessForPIDFunc.self),
                unsafeBitCast(setFront, to: SetFrontProcessFunc.self)
            )
        }
        return nil
    }()

    /// Makes the previous app active before minimizing, preventing macOS from
    /// promoting a sibling window in the minimized app. Deprecated-but-public API,
    /// dlsym-loaded so failure degrades to the post-activate fallback.
    func switchFrontmostWithoutReorder(toPID pid: pid_t) -> Bool {
        guard let api = Self.frontProcessSwitch else {
            Self.chipProbeLogger.info("switch-frontmost-noreorder unavailable (symbols missing)")
            return false
        }
        var psn = ProcessSerialNumber()
        guard api.get(pid, &psn) == noErr else {
            Self.chipProbeLogger.info("switch-frontmost-noreorder GetProcessForPID failed pid=\(pid, privacy: .public)")
            return false
        }
        let kSetFrontProcessFrontWindowOnly: UInt32 = 1
        let result = withUnsafePointer(to: &psn) { api.setFront($0, kSetFrontProcessFrontWindowOnly) }
        Self.chipProbeLogger.info("switch-frontmost-noreorder pid=\(pid, privacy: .public) result=\(result, privacy: .public)")
        return result == noErr
    }

    func handoffFocusBeforeMinimizing(
        to target: BackgroundActivationTarget,
        raisePreparation: BackgroundRaisePreparation?
    ) -> BackgroundFocusHandoff.Outcome {
        let axRaise = raisePreparation.map { preparation in
            { raiseBackgroundWindow(preparation, target: target) }
        }
        return BackgroundFocusHandoff.perform(
            target: target,
            skyLightFocus: { pid, windowID in
                postSkyLightWindowFocus(pid: pid, windowID: windowID)
            },
            axRaise: axRaise,
            carbonSwitch: { pid in
                switchFrontmostWithoutReorder(toPID: pid)
            }
        )
    }

    func prepareBackgroundRaise(
        for target: BackgroundActivationTarget
    ) -> BackgroundRaisePreparation? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + Self.backgroundRaiseBudget
        let handle = reader.captureHandle(
            forPID: target.pid,
            cgWindowID: target.cgWindowID,
            messagingTimeout: Self.backgroundRaiseBudget
        )
        let elapsedMilliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        Self.chipProbeLogger.info("handoff-raise-capture pid=\(target.pid, privacy: .public) wid=\(target.cgWindowID, privacy: .public) available=\(handle != nil, privacy: .public) durationMs=\(elapsedMilliseconds, privacy: .public)")
        return handle.map {
            BackgroundRaisePreparation(element: $0.element, deadline: deadline)
        }
    }

    private func raiseBackgroundWindow(
        _ preparation: BackgroundRaisePreparation,
        target: BackgroundActivationTarget
    ) -> Bool {
        let remaining = preparation.deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            Self.chipProbeLogger.info("handoff-raise pid=\(target.pid, privacy: .public) wid=\(target.cgWindowID, privacy: .public) success=false durationMs=0 budgetExpired=true")
            return false
        }
        AXUIElementSetMessagingTimeout(preparation.element, Float(remaining))
        let startedAt = ProcessInfo.processInfo.systemUptime
        let success = AXUIElementPerformAction(
            preparation.element,
            kAXRaiseAction as CFString
        ) == .success
        let elapsedMilliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        Self.chipProbeLogger.info("handoff-raise pid=\(target.pid, privacy: .public) wid=\(target.cgWindowID, privacy: .public) success=\(success, privacy: .public) durationMs=\(elapsedMilliseconds, privacy: .public) budgetExpired=false")
        return success
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

    /// Shared SkyLight focus core: front-process switch + the two make-key events for a
    /// known cgWindowID. Pure event posts — no AX round-trips, so it never blocks on a
    /// napping target app. Record layout lives in SkyLightMakeKeyEventBuilder
    /// (unit-tested, see AGENTS.md); do not vary it.
    @discardableResult
    fileprivate func postSkyLightWindowFocus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard Self.skyLightFocusEnabled else { return false }
        guard let focus = Self.skyLightFocus,
              let getPSN = Self.frontProcessSwitch?.get else {
            Self.chipProbeLogger.info("skylight-focus unavailable pid=\(pid, privacy: .public)")
            return false
        }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else {
            Self.chipProbeLogger.info("skylight-focus GetProcessForPID failed pid=\(pid, privacy: .public)")
            return false
        }

        let kCPSUserGenerated: UInt32 = 0x200
        let records = SkyLightMakeKeyEventBuilder.makeKeyRecords(windowID: windowID)

        _ = withUnsafePointer(to: &psn) { focus.slps($0, windowID, kCPSUserGenerated) }
        withUnsafePointer(to: &psn) { pointer in
            records.first.withUnsafeBufferPointer { _ = focus.post(pointer, $0.baseAddress!) }
            records.second.withUnsafeBufferPointer { _ = focus.post(pointer, $0.baseAddress!) }
        }
        return true
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

struct PlatformActionExecutor {
    private let windowExecutor = AccessibilityWindowActionExecutor()
    private static let chipProbeLogger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "ChipProbe")
    private static let postMinimizeActivateDelayMicroseconds: useconds_t = 50_000

    @discardableResult
    func execute(_ request: PlatformActionRequest, snapshot: DockSnapshot) -> Bool {
        guard let windowID = request.windowID,
              let record = snapshot.windows[windowID] else {
            return false
        }

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
        if request.kind == .activateWindow,
           !request.forceRestoreBeforeFocus,
           let cgWindowID = record.cgWindowID,
           record.status == .active || record.status == .inactive,
           NSRunningApplication(processIdentifier: record.pid)?.isActive != true {
            windowExecutor.focusWindowEarly(pid: record.pid, cgWindowID: cgWindowID)
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
        let handle: AccessibilityWindowActionExecutor.WindowHandle?
        if let cgWindowID = record.cgWindowID, !justUnhid {
            handle = windowExecutor.captureHandleByCGWindowID(cgWindowID, pid: record.pid)
                ?? windowExecutor.captureHandle(
                    for: target,
                    attempts: isFinderWindow ? 3 : 1,
                    retryIntervalMicroseconds: isFinderWindow ? 150_000 : 0
                )
        } else {
            handle = windowExecutor.captureHandle(
                for: target,
                attempts: isFinderWindow ? 3 : 1,
                retryIntervalMicroseconds: isFinderWindow ? 150_000 : 0
            )
        }

        guard let handle else {
            if isFinderWindow { return false }
            return executeAppFallback(request: request, record: record)
        }

        switch request.kind {
        case .activateWindow:
            return windowExecutor.activate(
                handle,
                requiresFocusedConfirmation: isFinderWindow,
                knownCGWindowID: record.cgWindowID,
                forceRestore: request.forceRestoreBeforeFocus
            )
        case .minimizeWindow:
            // Complete every AX read before handing key-window ownership to the background
            // target. The only optional AX operation after make-key is the bounded raise write;
            // minimize follows immediately and never depends on whether that raise succeeds.
            let minimizePreparation = windowExecutor.prepareMinimize(handle)
            let backgroundTarget = windowExecutor.findBackgroundActivationTarget(
                for: handle,
                knownCGWindowID: record.cgWindowID,
                trustedWindows: BackgroundActivationDecision.trustedWindowIdentities(in: snapshot)
            )
            let raisePreparation = backgroundTarget.flatMap {
                windowExecutor.prepareBackgroundRaise(for: $0)
            }
            let initialHandoff = backgroundTarget.map {
                windowExecutor.handoffFocusBeforeMinimizing(
                    to: $0,
                    raisePreparation: raisePreparation
                )
            }
            let minExec = windowExecutor.minimize(minimizePreparation)
            var handoffSubmitted = initialHandoff?.focusRequestSubmitted == true
            if minExec.success {
                postActivateBackgroundIfNeeded(target: backgroundTarget, handoffSubmitted: handoffSubmitted)
                Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(minExec.success, privacy: .public) focusRequestSubmitted=\(handoffSubmitted, privacy: .public) handoffOutcome=\(String(describing: initialHandoff), privacy: .public) mechanism=\(minExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: minExec.verifiedMinimized), privacy: .public)")
                return true
            }
            if justUnhid {
                usleep(100_000)
                if let h = windowExecutor.captureHandle(for: target, attempts: 2, retryIntervalMicroseconds: 100_000) {
                    let retryPreparation = windowExecutor.prepareMinimize(h)
                    let retryHandoff = handoffSubmitted ? nil : backgroundTarget.map {
                        windowExecutor.handoffFocusBeforeMinimizing(
                            to: $0,
                            raisePreparation: raisePreparation
                        )
                    }
                    let retryExec = windowExecutor.minimize(retryPreparation)
                    handoffSubmitted = handoffSubmitted || retryHandoff?.focusRequestSubmitted == true
                    if retryExec.success {
                        postActivateBackgroundIfNeeded(
                            target: backgroundTarget,
                            handoffSubmitted: handoffSubmitted
                        )
                    }
                    Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(retryExec.success, privacy: .public) focusRequestSubmitted=\(handoffSubmitted, privacy: .public) handoffOutcome=\(String(describing: retryHandoff ?? initialHandoff), privacy: .public) mechanism=\(retryExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: retryExec.verifiedMinimized), privacy: .public)")
                    return retryExec.success
                }
            }
            // 最小化全通道失败时【不】把焦点还给原窗口（2026-07-20 撤销）：曾经的反向聚焦
            // 是为了修「焦点已交接给 B、但窗口没最小化」的错位，实测却成了 Illustrator 自动
            // 还原的直接原因——对一个可能正在 order-out 的窗口发 make-key，会把它拉回来。
            // 已知代价：真失败时焦点留在 B、原窗口还立着。这是刻意取舍——罕见路径的焦点错位
            // 换掉每次必现的自动还原。不要「修」回来。
            Self.chipProbeLogger.info("minimize-exec-result windowID=\(request.windowID?.rawValue ?? "nil", privacy: .public) success=\(minExec.success, privacy: .public) focusRequestSubmitted=\(handoffSubmitted, privacy: .public) handoffOutcome=\(String(describing: initialHandoff), privacy: .public) mechanism=\(minExec.mechanism, privacy: .public) verifiedMinimized=\(String(describing: minExec.verifiedMinimized), privacy: .public)")
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

    private func postActivateBackgroundIfNeeded(
        target: BackgroundActivationTarget?,
        handoffSubmitted: Bool
    ) {
        guard !handoffSubmitted, let target else { return }
        usleep(Self.postMinimizeActivateDelayMicroseconds)
        let activated = NSRunningApplication(processIdentifier: target.pid)?
            .activate(options: [.activateIgnoringOtherApps]) ?? false
        Self.chipProbeLogger.info("postactivate-background-fallback pid=\(target.pid, privacy: .public) activated=\(activated, privacy: .public)")
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
    guard let value = axCopyAttributeValue(attribute, from: element) else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func axFrame(of element: AXUIElement) -> CGRect? {
    guard let positionAX = axCopyAttributeValue(kAXPositionAttribute as CFString, from: element),
          let sizeAX = axCopyAttributeValue(kAXSizeAttribute as CFString, from: element) else {
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
