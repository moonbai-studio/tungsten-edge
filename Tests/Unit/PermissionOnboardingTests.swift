import XCTest

@MainActor
final class PermissionOnboardingTests: XCTestCase {
    func testPermissionWatchdogGateRejectsOverlapAndStoppedGeneration() {
        var gate = PermissionWatchdogGate()
        gate.start()
        guard let oldGeneration = gate.beginProbe() else {
            return XCTFail("first probe should start")
        }
        XCTAssertNil(gate.beginProbe())

        gate.stop()
        gate.start()
        guard let currentGeneration = gate.beginProbe() else {
            return XCTFail("new generation probe should start")
        }
        XCTAssertFalse(gate.completeProbe(generation: oldGeneration))
        XCTAssertTrue(gate.completeProbe(generation: currentGeneration))
    }

    // MARK: - 安装位置

    func testClassifiesStableLocations() {
        XCTAssertEqual(location("/Applications/Tungsten Edge.app"), .applications)
        XCTAssertEqual(
            location(NSHomeDirectory() + "/Applications/Tungsten Edge.app"),
            .applications
        )
        // 可写的外置卷 / 网络盘是合法安装位置，不该被当成临时副本误伤。
        XCTAssertEqual(location("/Volumes/Samsung T7/Tungsten Edge.app", readOnly: false), .other)
        XCTAssertEqual(location("/Users/someone/Downloads/Tungsten Edge.app"), .other)
    }

    func testClassifiesTransientLocations() {
        XCTAssertEqual(location("/Volumes/Tungsten Edge 0.7.0/Tungsten Edge.app", readOnly: true), .readOnlyVolume)
        XCTAssertEqual(
            location("/private/var/folders/ab/AppTranslocation/XYZ/d/Tungsten Edge.app"),
            .appTranslocation
        )
    }

    /// App Translocation 的判据是路径，不是卷的读写性——先于卷判定命中。
    func testTranslocationWinsOverVolumeReadability() {
        XCTAssertEqual(
            location("/Volumes/Foo/AppTranslocation/XYZ/d/Tungsten Edge.app", readOnly: false),
            .appTranslocation
        )
    }

    /// 读不到卷信息时一律放行：宁可漏拦，也不要把位置正常的用户锁死在搬家页上。
    func testUnknownVolumeReadabilityIsTreatedAsWritable() {
        XCTAssertEqual(location("/Volumes/Whatever/Tungsten Edge.app", readOnly: nil), .other)
    }

    func testTransientLocationsRejectAccessibilityPrompt() {
        XCTAssertFalse(AppInstallLocation.readOnlyVolume.allowsAccessibilityPrompt)
        XCTAssertFalse(AppInstallLocation.appTranslocation.allowsAccessibilityPrompt)
        XCTAssertTrue(AppInstallLocation.applications.allowsAccessibilityPrompt)
        XCTAssertTrue(AppInstallLocation.other.allowsAccessibilityPrompt)
        XCTAssertTrue(AppInstallLocation.readOnlyVolume.isTransient)
        XCTAssertTrue(AppInstallLocation.appTranslocation.isTransient)
        XCTAssertFalse(AppInstallLocation.applications.isTransient)
    }

    /// 临时副本即使当前已受信也要先搬家：那份授权会随副本一起消失。
    func testRelocationWinsEvenWhenTransientCopyIsAlreadyTrusted() {
        let state = PermissionOnboardingState.initial(installLocation: .readOnlyVolume, isTrusted: true)
        XCTAssertEqual(state, .moveToApplications(.readOnlyVolume))
    }

    // MARK: - 引导步骤

    func testWaitingBecomesStalledAtEightSecondsAndGrantedWhenTrusted() {
        let waiting = PermissionOnboardingState.waiting
        XCTAssertEqual(waiting.updated(isTrusted: false, elapsed: 7.999, stallAfter: 8), .waiting)
        XCTAssertEqual(waiting.updated(isTrusted: false, elapsed: 8, stallAfter: 8), .stalled)
        XCTAssertEqual(waiting.updated(isTrusted: true, elapsed: 99, stallAfter: 8), .granted)
    }

    func testMoveToApplicationsNeverLeavesItsBranch() {
        let state = PermissionOnboardingState.moveToApplications(.appTranslocation)
        XCTAssertEqual(state.updated(isTrusted: true, elapsed: 99, stallAfter: 8), state)
    }

    // MARK: - 轮询模型

    func testTransientCopyNeverChecksOrRequestsPermission() {
        let spy = PermissionSpy(trusted: false)
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .readOnlyVolume,
            initialTrusted: false,
            now: { 0 }
        )
        model.startPolling()
        model.requestSystemPromptIfNeeded()
        model.checkNow()

        XCTAssertEqual(spy.promptCount, 0)
        XCTAssertEqual(model.state, .moveToApplications(.readOnlyVolume))
    }

    func testStableCopyRequestsNativePromptAtMostOnce() {
        let spy = PermissionSpy(trusted: false)
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .applications,
            initialTrusted: false,
            now: { 0 }
        )
        model.requestSystemPromptIfNeeded()
        model.requestSystemPromptIfNeeded()

        XCTAssertEqual(spy.promptCount, 1)
    }

    func testPollingTransitionsToStalledAfterEightSeconds() {
        let spy = PermissionSpy(trusted: false)
        var clock: TimeInterval = 0
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .applications,
            initialTrusted: false,
            now: { clock },
            stallAfter: 8
        )
        model.startPolling()
        XCTAssertEqual(model.state, .waiting)

        clock = 7.999
        model.checkNow()
        XCTAssertEqual(model.state, .waiting)

        clock = 8
        model.checkNow()
        XCTAssertEqual(model.state, .stalled)
        model.stop()
    }

    func testActivationRechecksAndGrantCallbackIsOneShot() {
        let spy = PermissionSpy(trusted: false)
        let model = AccessibilityPermissionModel(
            permissionService: spy.service,
            installLocation: .applications,
            initialTrusted: false,
            now: { 0 }
        )
        var grants = 0
        model.onGranted = { grants += 1 }
        model.startPolling()
        XCTAssertEqual(grants, 0)

        spy.trusted = true
        model.applicationDidBecomeActive()
        model.applicationDidBecomeActive()
        model.checkNow()

        XCTAssertEqual(grants, 1)
        XCTAssertEqual(model.state, .granted)
    }

    // MARK: - 丢失防抖

    func testFirstFalseIsUncertainAndTwoSustainedFalsesAreLost() {
        var detector = PermissionLossDetector()
        XCTAssertEqual(detector.record(trusted: true, at: 0), .stable)
        XCTAssertEqual(detector.record(trusted: false, at: 10), .uncertain)
        // 连续两次但间隔不够（定时器和 didBecomeActive 可能挨着来）→ 还不算丢失。
        XCTAssertEqual(detector.record(trusted: false, at: 14.999), .uncertain)
        XCTAssertEqual(detector.record(trusted: false, at: 15), .lost)
    }

    func testSingleFalseNeverBecomesLostNoMatterHowLate() {
        var detector = PermissionLossDetector()
        XCTAssertEqual(detector.record(trusted: false, at: 0), .uncertain)
        XCTAssertEqual(detector.record(trusted: true, at: 100), .stable)
        // 清零之后重新开始计数与计时。
        XCTAssertEqual(detector.record(trusted: false, at: 200), .uncertain)
    }

    func testTrueResetsTheAnchor() {
        var detector = PermissionLossDetector()
        _ = detector.record(trusted: false, at: 0)
        _ = detector.record(trusted: true, at: 1)
        XCTAssertEqual(detector.record(trusted: false, at: 2), .uncertain)
        XCTAssertEqual(detector.record(trusted: false, at: 6.999), .uncertain)
        XCTAssertEqual(detector.record(trusted: false, at: 7), .lost)
    }

    /// 乱序/提前到达的采样不许把锚点往回拨，否则一串抖动能无限推迟判定。
    func testEarlyArrivingFalseDoesNotResetTheAnchor() {
        var detector = PermissionLossDetector()
        XCTAssertEqual(detector.record(trusted: false, at: 10), .uncertain)
        XCTAssertEqual(detector.record(trusted: false, at: 5), .uncertain)
        XCTAssertEqual(detector.record(trusted: false, at: 15), .lost)
    }

    // MARK: - 状态机

    func testTransientLaunchNeverPromptsOrStartsApp() {
        var machine = PermissionRecoveryMachine()
        let effects = machine.handle(.launched(location: .readOnlyVolume, trusted: false))

        XCTAssertEqual(machine.phase, .transientShell(.readOnlyVolume))
        XCTAssertEqual(effects, [.setActivationPolicy(.regular), .showGuide])
        XCTAssertFalse(effects.contains(.requestSystemPrompt))
        XCTAssertFalse(effects.contains(.startApp))
    }

    func testTrustedLaunchStartsAppAndWatchdog() {
        var machine = PermissionRecoveryMachine()
        let effects = machine.handle(.launched(location: .applications, trusted: true))

        XCTAssertEqual(machine.phase, .running)
        XCTAssertEqual(effects, [.setActivationPolicy(.accessory), .startApp, .startWatchdog])
    }

    func testInitialGrantContinuesInProcessWithoutRelaunch() {
        var machine = PermissionRecoveryMachine()
        _ = machine.handle(.launched(location: .applications, trusted: false))
        guard case let .onboarding(episode) = machine.phase else { return XCTFail("expected onboarding") }

        let effects = machine.handle(.grantObserved(episode: episode))
        XCTAssertEqual(machine.phase, .running)
        XCTAssertTrue(effects.contains(.startApp))
        XCTAssertFalse(effects.contains(.launchNewInstance(episode: episode)))
        XCTAssertFalse(effects.contains(.restoreLiftedWindows(episode: episode)))
    }

    func testFirstFalseFreezesLiftAndRecoveredTrustUnfreezes() {
        var machine = runningMachine()
        XCTAssertEqual(machine.handle(.trustVerdict(.uncertain)), [.freezeLift])
        XCTAssertEqual(machine.phase, .uncertain)
        XCTAssertEqual(machine.handle(.trustVerdict(.stable)), [.unfreezeLift])
        XCTAssertEqual(machine.phase, .running)
    }

    func testLostTrustSuspendsAndReRegistersWithTheSystem() {
        var machine = runningMachine()
        _ = machine.handle(.trustVerdict(.uncertain))
        let effects = machine.handle(.trustVerdict(.lost))

        guard case let .suspended(episode) = machine.phase else { return XCTFail("expected suspended") }
        XCTAssertEqual(effects, [
            .stopWatchdog,
            .freezeLift,
            .suspendPanelsAndStores,
            .setActivationPolicy(.regular),
            .showGuide,
            .startPermissionEpisode(purpose: .runtimeRecovery, episode: episode),
            .requestSystemPrompt,
        ])
    }

    func testRecoveryRestoresWindowsBeforeReleasingHotKeyAndRelaunching() {
        var machine = suspendedMachine()
        guard case let .suspended(episode) = machine.phase else { return XCTFail("expected suspended") }

        let granted = machine.handle(.grantObserved(episode: episode))
        XCTAssertEqual(machine.phase, .restoringWindows(episode: episode))
        XCTAssertTrue(granted.contains(.restoreLiftedWindows(episode: episode)))

        let restored = machine.handle(.windowsRestored(episode: episode))
        XCTAssertEqual(machine.phase, .relaunching(episode: episode))
        XCTAssertEqual(restored, [.updateGuide, .releaseHotKey, .launchNewInstance(episode: episode)])

        XCTAssertEqual(machine.handle(.relaunchSucceeded(episode: episode)), [.terminateSelf])
    }

    func testRepeatedEventsDuringRelaunchDoNotStartASecondRelaunch() {
        var machine = relaunchingMachine()
        guard case let .relaunching(episode) = machine.phase else { return XCTFail("expected relaunching") }

        XCTAssertEqual(machine.handle(.grantObserved(episode: episode)), [])
        XCTAssertEqual(machine.handle(.windowsRestored(episode: episode)), [])
        XCTAssertEqual(machine.handle(.trustVerdict(.lost)), [])
        XCTAssertEqual(machine.phase, .relaunching(episode: episode))
    }

    func testStaleEpisodeCompletionsAreDropped() {
        var machine = relaunchingMachine()
        guard case let .relaunching(episode) = machine.phase else { return XCTFail("expected relaunching") }

        XCTAssertEqual(machine.handle(.relaunchSucceeded(episode: episode &- 1)), [])
        XCTAssertEqual(machine.handle(.relaunchFailed(episode: episode &+ 1, message: "x")), [])
        XCTAssertEqual(machine.phase, .relaunching(episode: episode))
    }

    func testRelaunchFailureKeepsOldInstanceAliveAndGivesTheHotKeyBack() {
        var machine = relaunchingMachine()
        guard case let .relaunching(episode) = machine.phase else { return XCTFail("expected relaunching") }

        let effects = machine.handle(.relaunchFailed(episode: episode, message: "找不到应用"))
        XCTAssertEqual(machine.phase, .relaunchFailed(episode: episode, message: "找不到应用"))
        XCTAssertEqual(effects, [.registerHotKey, .updateGuide])
        XCTAssertFalse(effects.contains(.terminateSelf))
    }

    /// 失败分支把热键注册回来了，重试必须再释放一次，不能因为「上次释放过」就跳过。
    func testRetryReleasesTheHotKeyAgain() {
        var machine = relaunchingMachine()
        guard case let .relaunching(episode) = machine.phase else { return XCTFail("expected relaunching") }
        _ = machine.handle(.relaunchFailed(episode: episode, message: "找不到应用"))

        let effects = machine.handle(.retryRequested)
        XCTAssertEqual(machine.phase, .relaunching(episode: episode))
        XCTAssertEqual(effects, [.updateGuide, .releaseHotKey, .launchNewInstance(episode: episode)])
    }

    func testTerminationPreemptsEverythingAndSwallowsLateEvents() {
        var machine = relaunchingMachine()
        guard case let .relaunching(episode) = machine.phase else { return XCTFail("expected relaunching") }

        let effects = machine.handle(.terminationRequested)
        XCTAssertEqual(machine.phase, .terminating)
        XCTAssertEqual(effects, [.stopWatchdog, .cancelRecoveryTask, .stopPermissionEpisode])

        XCTAssertEqual(machine.handle(.windowsRestored(episode: episode)), [])
        XCTAssertEqual(machine.handle(.relaunchSucceeded(episode: episode)), [])
        XCTAssertEqual(machine.handle(.retryRequested), [])
    }

    // MARK: - 展示态

    /// 首次授权和运行期恢复的排障文案必须分开：首次授权是当前进程继续启动，
    /// 既没有「自动重启」，也不存在本轮被抬起的窗口残留。
    func testStalledAndRecoveryStalledArePresentedSeparately() {
        XCTAssertEqual(
            PermissionRecoveryMachine.presentation(phase: .onboarding(episode: 1), onboarding: .stalled),
            .stalled
        )
        XCTAssertEqual(
            PermissionRecoveryMachine.presentation(phase: .suspended(episode: 2), onboarding: .stalled),
            .recoveryStalled
        )
        XCTAssertEqual(
            PermissionRecoveryMachine.presentation(phase: .onboarding(episode: 1), onboarding: .waiting),
            .waiting
        )
        XCTAssertEqual(
            PermissionRecoveryMachine.presentation(phase: .suspended(episode: 2), onboarding: .waiting),
            .recoveryWaiting
        )
    }

    func testNoGuideWhileRunning() {
        XCTAssertNil(PermissionRecoveryMachine.presentation(phase: .running, onboarding: .waiting))
        XCTAssertNil(PermissionRecoveryMachine.presentation(phase: .uncertain, onboarding: .waiting))
        XCTAssertNil(PermissionRecoveryMachine.presentation(phase: .terminating, onboarding: .stalled))
    }

    // MARK: - 协调器：episode 隔离

    /// `didRequestPrompt` / `didNotifyGranted` 是模型的**终身**一次性门控。
    /// 复用同一个模型的话，第二次（运行期恢复）既不会再弹系统请求框、也不会再回调——
    /// 而 `tccutil reset` 之后本实例可能已经不在辅助功能列表里，不重新注册用户根本没东西可勾。
    func testRecoveryEpisodeUsesAFreshModelSoTheSystemPromptCanFireAgain() {
        var clock: TimeInterval = 0
        let spy = PermissionSpy(trusted: false)
        let handler = EffectSpy()
        var made: [AccessibilityPermissionModel] = []

        let coordinator = PermissionRecoveryCoordinator(
            handler: handler,
            permissionService: spy.service,
            installLocation: .applications,
            now: { clock },
            makeModel: { _, _ in
                let model = AccessibilityPermissionModel(
                    permissionService: spy.service,
                    installLocation: .applications,
                    now: { clock }
                )
                made.append(model)
                return model
            }
        )

        coordinator.launched(trusted: false)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(spy.promptCount, 1)
        XCTAssertEqual(coordinator.presentation, .waiting)

        // 用户打开开关：当前进程直接继续启动，不重启、不还原窗口。
        spy.trusted = true
        made[0].checkNow()
        XCTAssertTrue(handler.calls.contains("startApp"))
        XCTAssertFalse(handler.calls.contains("launchNewInstance"))
        XCTAssertNil(coordinator.presentation)

        // 运行中撤权：第一次 false 只冻结快照，第二次且持续够久才真的停运。
        spy.trusted = false
        clock = 10
        coordinator.sampleTrust(false)
        XCTAssertEqual(handler.calls.last, "freezeLift")
        XCTAssertNil(coordinator.presentation)

        clock = 20
        coordinator.sampleTrust(false)

        XCTAssertEqual(made.count, 2)
        XCTAssertFalse(made[0] === made[1])
        XCTAssertEqual(spy.promptCount, 2)
        XCTAssertEqual(coordinator.presentation, .recoveryWaiting)
        XCTAssertTrue(handler.calls.contains("suspendPanelsAndStores"))
        XCTAssertTrue(handler.calls.contains("stopWatchdog"))

        // 收掉还在跑的轮询定时器，别让它漏进后面的测试。
        coordinator.quit()
    }

    func testTransientCopyCoordinatorNeitherTerminatesNorPrompts() {
        let spy = PermissionSpy(trusted: false)
        let handler = EffectSpy()
        let coordinator = PermissionRecoveryCoordinator(
            handler: handler,
            permissionService: spy.service,
            installLocation: .appTranslocation
        )

        coordinator.launched(trusted: false)

        XCTAssertEqual(coordinator.presentation, .moveToApplications(.appTranslocation))
        XCTAssertEqual(spy.promptCount, 0)
        XCTAssertFalse(handler.calls.contains("startApp"))
        XCTAssertFalse(handler.calls.contains("startWatchdog"))
    }

    // MARK: - Helpers

    private func location(_ path: String, readOnly: Bool? = false) -> AppInstallLocation {
        AppInstallLocation(
            bundleURL: URL(fileURLWithPath: path, isDirectory: true),
            isReadOnlyVolume: { _ in readOnly }
        )
    }

    private func runningMachine() -> PermissionRecoveryMachine {
        var machine = PermissionRecoveryMachine()
        _ = machine.handle(.launched(location: .applications, trusted: true))
        return machine
    }

    private func suspendedMachine() -> PermissionRecoveryMachine {
        var machine = runningMachine()
        _ = machine.handle(.trustVerdict(.uncertain))
        _ = machine.handle(.trustVerdict(.lost))
        return machine
    }

    private func relaunchingMachine() -> PermissionRecoveryMachine {
        var machine = suspendedMachine()
        guard case let .suspended(episode) = machine.phase else { return machine }
        _ = machine.handle(.grantObserved(episode: episode))
        _ = machine.handle(.windowsRestored(episode: episode))
        return machine
    }
}

/// 只记录调用序列的副作用替身。
@MainActor
private final class EffectSpy: PermissionEffectHandler {
    var calls: [String] = []
    var launchResult: Result<Void, Error> = .success(())

    func startApp() { calls.append("startApp") }
    func setActivationPolicy(_ policy: PermissionActivationPolicy) { calls.append("policy:\(policy)") }
    func showGuideWindow() { calls.append("showGuide") }
    func updateGuideWindow() { calls.append("updateGuide") }
    func closeGuideWindow() { calls.append("closeGuide") }
    func openAccessibilitySettings() { calls.append("openSettings") }
    func openApplicationsFolder() { calls.append("openApplications") }
    func startWatchdog() { calls.append("startWatchdog") }
    func stopWatchdog() { calls.append("stopWatchdog") }
    func freezeLiftSnapshots() { calls.append("freezeLift") }
    func unfreezeLiftSnapshots() { calls.append("unfreezeLift") }
    func restoreLiftedWindows(episode: UInt64) async { calls.append("restoreLiftedWindows") }
    func suspendPanelsAndStores() { calls.append("suspendPanelsAndStores") }
    func releaseHotKey() { calls.append("releaseHotKey") }
    func registerHotKey() { calls.append("registerHotKey") }
    func launchNewInstance(episode: UInt64) async -> Result<Void, Error> {
        calls.append("launchNewInstance")
        return launchResult
    }
    func terminateSelf() { calls.append("terminateSelf") }
}

/// 记录 prompt 次数、可切换受信状态的替身。
private final class PermissionSpy {
    var trusted: Bool
    private(set) var promptCount = 0

    init(trusted: Bool) {
        self.trusted = trusted
    }

    /// 强捕获，不用 `unowned`：模型的 1 秒轮询定时器活在主 runloop 上，
    /// 测试结束后还可能再响一次——那时替身若已释放，`unowned` 会直接崩。
    var service: PermissionService {
        PermissionService(
            trustCheck: { self.trusted },
            promptRequest: {
                self.promptCount += 1
                return self.trusted
            },
            readOnlyVolumeCheck: { _ in false }
        )
    }
}
