import AppKit
import XCTest

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    func testFreshDefaultsKeepFiniteDelaysWhenLegacyEnabledKeysAreMissing() {
        let defaults = makeDefaults()

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.nativeDockAutoHideDelay, 1.0)
        XCTAssertEqual(store.edgeAutoHideDelay, 0.1)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.nativeDockAutoHideDelay), 10)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.edgeAutoHideDelay), 1)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.autoHide.nativeDock.enabled"))
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.autoHide.edge.enabled"))
    }

    func testLegacyDisabledEnabledKeyMigratesToNeverHideOnlyWhenKeyExists() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "com.tungsten.edge.autoHide.nativeDock.enabled")
        defaults.set(0.0, forKey: "com.tungsten.edge.autoHide.nativeDock.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.nativeDockAutoHideDelay), 0)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.autoHide.nativeDock.enabled"))
    }

    func testLegacyEnabledTrueWithZeroDelaySnapsToFiniteMinimum() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "com.tungsten.edge.autoHide.nativeDock.enabled")
        defaults.set(0.0, forKey: "com.tungsten.edge.autoHide.nativeDock.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.nativeDockAutoHideDelay), 1)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.autoHide.nativeDock.enabled"))
    }

    func testLegacyEnabledTrueWithSubMinimumDelaySnapsToFiniteMinimum() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "com.tungsten.edge.autoHide.edge.enabled")
        defaults.set(0.05, forKey: "com.tungsten.edge.autoHide.edge.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.edgeAutoHideDelay), 1)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.autoHide.edge.enabled"))
    }

    func testSliderDelayMappingKeepsSubMinimumSecondsDistinctFromNeverHide() {
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(0), AppSettingsStore.neverHideDelay)
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(1), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(30), AppSettingsStore.finiteDelayMax)
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(31), AppSettingsStore.neverWakeDelay)

        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(-99.0), 0)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(AppSettingsStore.neverHideDelay), 0)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(0.0), 1)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(0.3), 3)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(1.0), 10)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(3.0), 30)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(AppSettingsStore.neverWakeDelay), 31)
    }

    func testSnapDelayClampsOnlySentinelBoundsToSpecialStates() {
        XCTAssertEqual(AppSettingsStore.snapDelay(-99.0), AppSettingsStore.neverHideDelay)
        XCTAssertEqual(AppSettingsStore.snapDelay(-0.2), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.snapDelay(0.0), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.snapDelay(0.05), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.snapDelay(0.3), 0.3)
        XCTAssertEqual(AppSettingsStore.snapDelay(3.3), AppSettingsStore.finiteDelayMax)
        XCTAssertEqual(AppSettingsStore.snapDelay(999.0), AppSettingsStore.neverWakeDelay)
        XCTAssertEqual(AppSettingsStore.snapDelay(1.34), 1.3)
    }

    @MainActor
    func testShowShelfDefaultsToOnAndPersists() {
        let defaults = makeDefaults()
        XCTAssertTrue(AppSettingsStore(defaults: defaults).showShelf, "默认显示中转格，升级不改变现有观感")

        let store = AppSettingsStore(defaults: defaults)
        store.setShowShelf(false)
        XCTAssertFalse(store.showShelf)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).showShelf, "关掉后要跨重启保持")

        store.setShowShelf(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).showShelf)
    }

    @MainActor
    func testDockSizeDefaultsToMediumAndPersists() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockSize, .medium)

        let store = AppSettingsStore(defaults: defaults)
        store.setDockSize(.extraLarge)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockSize, .extraLarge, "档位要跨重启保持")
    }

    @MainActor
    func testDockSizeRewritesCorruptStoredValueToMedium() {
        let defaults = makeDefaults()
        defaults.set("gigantic", forKey: "com.tungsten.edge.dockSize")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockSize, .medium)
        // 必须**立刻重写**，否则每次启动都要重走一遍回退，存值和 UI 勾选也一直对不上。
        XCTAssertEqual(defaults.string(forKey: "com.tungsten.edge.dockSize"), DockSize.medium.rawValue)

        defaults.set(42, forKey: "com.tungsten.edge.dockSize")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockSize, .medium, "类型不对也要回退")
    }

    @MainActor
    func testHoverStyleDefaultsToStandardAndPersists() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, .standard, "默认保持现有悬停手感，升级用户零变化")

        let store = AppSettingsStore(defaults: defaults)
        store.setHoverStyle(.quiet)
        XCTAssertEqual(store.hoverStyle, .quiet)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, .quiet, "档位要跨重启保持")

        store.setHoverStyle(.standard)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, .standard)
    }

    @MainActor
    func testWindowLiftEnabledDefaultsToOffAndPersists() {
        let defaults = makeDefaults()
        // 默认关是**拍板过的**，不是漏注册的默认值：最大化避让会真的改写别人应用的窗口尺寸，
        // 没主动选过的人不该被改。别顺手把它「修」成 true（理由与复议条件见 Docs/27）。
        XCTAssertFalse(AppSettingsStore(defaults: defaults).windowLiftEnabled, "默认不动用户窗口，由用户主动开")

        let store = AppSettingsStore(defaults: defaults)
        store.setWindowLiftEnabled(true)
        XCTAssertTrue(store.windowLiftEnabled)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).windowLiftEnabled, "开启后要跨重启保持")

        store.setWindowLiftEnabled(false)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).windowLiftEnabled)
    }

    @MainActor
    func testFinderAlwaysInDockDefaultsToOnAndPersists() {
        let defaults = makeDefaults()
        XCTAssertTrue(AppSettingsStore(defaults: defaults).finderAlwaysInDock, "默认常驻访达，还原系统 Dock 行为")

        let store = AppSettingsStore(defaults: defaults)
        store.setFinderAlwaysInDock(false)
        XCTAssertFalse(store.finderAlwaysInDock)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).finderAlwaysInDock, "关掉后要跨重启保持")

        store.setFinderAlwaysInDock(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).finderAlwaysInDock)
    }

    @MainActor
    func testFinderAlwaysInDockStoredFalseSurvivesMissingRegister() {
        // 显式存 false 后，即使 register 默认值仍在，读到的也必须是用户关掉的值。
        let defaults = makeDefaults()
        defaults.set(false, forKey: "com.tungsten.edge.finderAlwaysInDock")
        XCTAssertFalse(AppSettingsStore(defaults: defaults).finderAlwaysInDock)
    }

    @MainActor
    func testFullscreenIntentDefaultsToOnAndPersists() {
        let defaults = makeDefaults()
        XCTAssertTrue(AppSettingsStore(defaults: defaults).fullscreenIntentEnabled)

        let store = AppSettingsStore(defaults: defaults)
        store.setFullscreenIntentEnabled(false)
        XCTAssertFalse(store.fullscreenIntentEnabled)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).fullscreenIntentEnabled)

        store.setFullscreenIntentEnabled(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).fullscreenIntentEnabled)
    }

    @MainActor
    func testHoverStyleRewritesCorruptStoredValueToStandard() {
        let defaults = makeDefaults()
        defaults.set("silent", forKey: "com.tungsten.edge.hoverStyle")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, .standard)
        // 同 dockSize：必须**立刻重写**，否则每次启动都要重走一遍回退，存值和菜单勾选也一直对不上。
        XCTAssertEqual(defaults.string(forKey: "com.tungsten.edge.hoverStyle"), HoverStyle.standard.rawValue)

        defaults.set(7, forKey: "com.tungsten.edge.hoverStyle")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, .standard, "类型不对也要回退")
    }

    @MainActor
    func testHoverStyleDoesNotDisturbOtherSettings() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setDockSize(.large)
        store.setShowShelf(false)

        store.setHoverStyle(.quiet)

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.hoverStyle, .quiet)
        XCTAssertEqual(reloaded.dockSize, .large, "悬停档位与尺寸档位是两把独立的钥匙")
        XCTAssertFalse(reloaded.showShelf)
    }

    func testHoverStyleRawValuesAreStableAcrossReleases() {
        // 同 dockSize：raw value 进了 UserDefaults，改名等于把所有老用户悄悄重置回标准档。
        XCTAssertEqual(HoverStyle.allCases.map(\.rawValue), ["standard", "quiet"])
        XCTAssertEqual(HoverStyle.default, .standard)
        // isExpressive 是所有 chip 视图的唯一判据，也是菜单勾选态的判据，反了就是整档失效。
        XCTAssertTrue(HoverStyle.standard.isExpressive)
        XCTAssertFalse(HoverStyle.quiet.isExpressive)
    }

    /// 安静档的悬停反馈：**标准档必须恒 false**。
    ///
    /// owner 2026-08-17 定：标准档的反馈是名字气泡，观感一个像素不变；
    /// 这一条只补给关掉名字的那一档（在此之前它悬停时一点反馈都没有）。
    func testQuietHoverFeedbackOnlyExistsInTheQuietTier() {
        for hovering in [true, false] {
            XCTAssertFalse(
                HoverStyle.standard.showsQuietHoverFeedback(isHovering: hovering),
                "标准档任何输入都不该有反馈（hover=\(hovering)）"
            )
        }
        XCTAssertTrue(HoverStyle.quiet.showsQuietHoverFeedback(isHovering: true))
        XCTAssertFalse(HoverStyle.quiet.showsQuietHoverFeedback(isHovering: false))
    }

    @MainActor
    func testDockSizeRawValuesAreStableAcrossReleases() {
        // raw value 进了 UserDefaults，改名等于把所有老用户的档位悄悄重置成中档。
        XCTAssertEqual(DockSize.allCases.map(\.rawValue), ["small", "medium", "large", "extraLarge"])
        XCTAssertEqual(DockSize.allCases.map(\.title),
                       [String(localized: "Small"), String(localized: "Medium"), String(localized: "Large"), String(localized: "Extra Large")])
    }

    @MainActor
    func testNativeDockSliderCommandsCoverResidentFiniteAndNeverWake() {
        // 常驻档只关 autohide，不写延迟——此时延迟没有意义，写了反而覆盖用户原值。
        let resident = NativeDockPreferencesService.commands(for: AppSettingsStore.neverHideDelay)
        XCTAssertEqual(resident.count, 2)
        XCTAssertEqual(resident[0].executable, "/usr/bin/defaults")
        XCTAssertEqual(resident[0].arguments, ["write", "com.apple.dock", "autohide", "-bool", "false"])
        XCTAssertEqual(resident[1].arguments, ["Dock"])

        let finite = NativeDockPreferencesService.commands(for: 0.5)
        XCTAssertEqual(finite.count, 3)
        XCTAssertEqual(finite[0].arguments, ["write", "com.apple.dock", "autohide", "-bool", "true"])
        XCTAssertEqual(finite[1].arguments, ["write", "com.apple.dock", "autohide-delay", "-float", "0.5"])
        XCTAssertEqual(finite[2].arguments, ["Dock"])

        let neverWake = NativeDockPreferencesService.commands(for: AppSettingsStore.neverWakeDelay)
        XCTAssertEqual(neverWake[1].arguments, ["write", "com.apple.dock", "autohide-delay", "-float", "999.0"])
    }

    @MainActor
    func testNativeDockPreferenceServiceDoesNotRunWhenSandboxed() {
        var didRun = false
        let service = NativeDockPreferencesService(sandbox: SandboxEnvironment(isSandboxed: true)) { _, _ in
            didRun = true
        }

        XCTAssertFalse(service.isAvailable)
        XCTAssertThrowsError(try service.apply(delay: 0.5))
        XCTAssertFalse(didRun)
    }

    @MainActor
    func testNativeDockSliderApplyStopsAtFirstFailedCommand() {
        var ranCommands: [(String, [String])] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { executable, arguments in
                ranCommands.append((executable, arguments))
                if arguments.contains("autohide-delay") {
                    throw NativeDockPreferencesError.commandFailed(executable: executable, status: 1)
                }
            },
            autohideReader: { nil }
        )

        XCTAssertThrowsError(try service.apply(delay: 0.5))
        XCTAssertEqual(ranCommands.count, 2, "第二条失败后不得继续 killall Dock")
    }

    func testNativeDockStateReadStopsBeforeValueAccessWhenSynchronizeFails() {
        var requestedKeys: [String] = []

        let state = NativeDockPreferencesService.readAutohideState(
            synchronize: { false },
            valueForKey: { key in
                requestedKeys.append(key)
                return nil
            }
        )

        XCTAssertNil(state)
        XCTAssertTrue(requestedKeys.isEmpty)
    }

    func testNativeDockStateDecoderDistinguishesMissingKeysFromCorruptValues() {
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: nil, delayValue: nil),
            NativeDockAutohideState(enabled: false, delay: nil)
        )
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: true, delayValue: 0.2),
            NativeDockAutohideState(enabled: true, delay: 0.2)
        )
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: nil, delayValue: 0.2),
            NativeDockAutohideState(enabled: false, delay: 0.2)
        )
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: false, delayValue: "bad"),
            NativeDockAutohideState(enabled: false, delay: nil),
            "系统明确关闭时，坏 delay 不得掩盖可信的 autohide 真值"
        )

        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: "true", delayValue: 0.2))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: NSNumber(value: 1), delayValue: 0.2))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: true, delayValue: "0.2"))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: true, delayValue: false))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(
            autohideValue: true,
            delayValue: NSNumber(value: Double.nan)
        ))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(
            autohideValue: true,
            delayValue: NSNumber(value: Double.infinity)
        ))
    }

    func testLaunchAtLoginMenuPresentationCoversFourStates() {
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .unsupported),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login (macOS 13+)"), isEnabled: false, isChecked: false, showsSettingsItem: false)
        )
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .off),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login"), isEnabled: true, isChecked: false, showsSettingsItem: false)
        )
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .on),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login"), isEnabled: true, isChecked: true, showsSettingsItem: false)
        )
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .requiresApproval),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login (Pending Approval)"), isEnabled: true, isChecked: false, showsSettingsItem: true)
        )
    }

    func testLaunchAtLoginMenuToggleDecisionCoversFourStates() {
        XCTAssertNil(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .unsupported))
        XCTAssertEqual(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .off), true)
        XCTAssertEqual(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .on), false)
        XCTAssertEqual(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .requiresApproval), true)
    }

    func testLaunchAtLoginColdStartPresentationUsesRealStatusOverStoredIntent() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "com.tungsten.edge.launchAtLogin")
        let store = AppSettingsStore(defaults: defaults)

        let presentation = LaunchAtLoginMenuPresentation(state: .off)

        XCTAssertTrue(store.launchAtLogin)
        XCTAssertFalse(presentation.isChecked)
    }

    func testPanelVisibilityKeepsHiddenUntilAllReasonsAreCleared() {
        var state = PanelVisibilityState()

        state.setFullscreen(true)
        state.setEdgeAutoHidden(true)
        XCTAssertFalse(state.isVisible)

        state.setFullscreen(false)
        XCTAssertFalse(state.isVisible)

        state.setEdgeAutoHidden(false)
        XCTAssertTrue(state.isVisible)
    }

    func testPanelVisibilityInhibitorClearsEdgeAutoHideEvenAfterFullscreenExit() {
        var state = PanelVisibilityState()

        state.setEdgeAutoHidden(true)
        state.setFullscreen(true)
        state.setInhibitor(.dragging, active: true)
        state.setFullscreen(false)
        state.reconcileEdgeAutoHide(isEnabled: true)

        XCTAssertFalse(state.hideReasons.contains(.edgeAutoHide))
        XCTAssertTrue(state.isVisible)
    }

    func testPanelVisibilityConstantModeClearsEdgeAutoHide() {
        var state = PanelVisibilityState()

        state.setEdgeAutoHidden(true)
        state.reconcileEdgeAutoHide(isEnabled: false)

        XCTAssertTrue(state.isVisible)
    }

    /// 钨极菜单（状态栏图标或任务条右键弹出的同一个）开着时，边缘自动隐藏必须停摆——
    /// 否则空闲计时照跑，任务条会从弹出的菜单底下缩掉。
    func testTaskbarMenuOpenInhibitsIdleHideAndReleasesOnClose() {
        var state = PanelVisibilityState()
        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))

        state.setInhibitor(.taskbarMenuOpen, active: true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))

        state.setInhibitor(.taskbarMenuOpen, active: false)
        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))
    }

    /// 菜单是在任务条已经缩起来的状态下弹的（用户从状态栏图标点开）：
    /// 抑制器要把它拉回来，不能让菜单孤零零地挂在没有任务条的地方。
    func testTaskbarMenuOpenClearsAnAlreadyHiddenEdgeAutoHide() {
        var state = PanelVisibilityState()
        state.setEdgeAutoHidden(true)
        XCTAssertFalse(state.isVisible)

        state.setInhibitor(.taskbarMenuOpen, active: true)
        state.reconcileEdgeAutoHide(isEnabled: true)

        XCTAssertTrue(state.isVisible)
    }

    func testEdgeAutoHideWakeRulesRequireHiddenFiniteDelayAndNoInhibitors() {
        var state = PanelVisibilityState()

        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.9))

        state.setEdgeAutoHidden(true)
        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.9))
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: AppSettingsStore.neverWakeDelay))
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: AppSettingsStore.neverHideDelay))

        state.setInhibitor(.drawerOpen, active: true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.9))
    }

    func testEdgeAutoHideIdleRulesRequireVisibleAndNoInhibitors() {
        var state = PanelVisibilityState()

        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))
        XCTAssertEqual(EdgeAutoHideRuntimeRules.idleHideInterval(for: 0.9), EdgeAutoHideRuntimeRules.fixedIdleHideDelay)
        XCTAssertEqual(EdgeAutoHideRuntimeRules.idleHideInterval(for: AppSettingsStore.neverWakeDelay), EdgeAutoHideRuntimeRules.fixedIdleHideDelay)
        XCTAssertNil(EdgeAutoHideRuntimeRules.idleHideInterval(for: AppSettingsStore.neverHideDelay))

        state.setEdgeAutoHidden(true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))

        state.setEdgeAutoHidden(false)
        state.setInhibitor(.dragging, active: true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))
    }

    func testBottomHotZoneSuppressesIdleHideOnlyForFiniteWakeDelays() {
        XCTAssertTrue(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: 0.1))
        XCTAssertTrue(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: 0.9))
        XCTAssertTrue(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: 3.0))

        // 999：自动隐藏但不唤醒——没有唤醒动作就没有"打架"风险，底边热区不该额外压住隐藏。
        XCTAssertFalse(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: AppSettingsStore.neverWakeDelay))

        // -1：常驻显示——本来就不会隐藏，压不压都一样，规则仍应返回 false（不代表要生效）。
        XCTAssertFalse(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: AppSettingsStore.neverHideDelay))
    }

    // MARK: - 常驻切换（toggleEdgeAutoHideMode）与 remembered 播种

    func testToggleFromFiniteDelayEntersResidentAndRestoresSameDelay() {
        let defaults = makeDefaults()
        defaults.set(0.5, forKey: "com.tungsten.edge.autoHide.edge.delay")
        let store = AppSettingsStore(defaults: defaults)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 0.5)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, 0.5)
    }

    func testToggleFromNeverWakeRoundTripsBackToNeverWake() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setEdgeAutoHideDelay(AppSettingsStore.neverWakeDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverWakeDelay)
    }

    func testToggleFromResidentWithoutHistoryFallsBackToDefaultDelay() {
        let defaults = makeDefaults()
        defaults.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.edge.delay")
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.defaultEdgeAutoHideDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.defaultEdgeAutoHideDelay)
    }

    func testRememberedSeedsFromCurrentFiniteValueOverStaleStoredValue() {
        let defaults = makeDefaults()
        defaults.set(0.5, forKey: "com.tungsten.edge.autoHide.edge.delay")
        defaults.set(2.0, forKey: "com.tungsten.edge.autoHide.edge.lastEnabledDelay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 0.5)
        XCTAssertEqual(defaults.double(forKey: "com.tungsten.edge.autoHide.edge.lastEnabledDelay"), 0.5)
    }

    func testRememberedIsReadOnlyWhenCurrentIsResident() {
        let defaults = makeDefaults()
        defaults.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.edge.delay")
        defaults.set(2.0, forKey: "com.tungsten.edge.autoHide.edge.lastEnabledDelay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 2.0)
    }

    func testCorruptRememberedValuesFallBackToDefault() {
        let corruptValues: [Any] = ["字符串", Double.nan, AppSettingsStore.neverHideDelay, -50.0]
        for corrupt in corruptValues {
            let defaults = makeDefaults()
            defaults.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.edge.delay")
            defaults.set(corrupt, forKey: "com.tungsten.edge.autoHide.edge.lastEnabledDelay")

            let store = AppSettingsStore(defaults: defaults)

            XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.defaultEdgeAutoHideDelay, "corrupt=\(corrupt)")
        }
    }

    func testLegacyDisabledMigrationThenToggleRestoresDefaultDelay() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "com.tungsten.edge.autoHide.edge.enabled")
        defaults.set(0.7, forKey: "com.tungsten.edge.autoHide.edge.delay")

        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.defaultEdgeAutoHideDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.defaultEdgeAutoHideDelay)
    }

    func testCrossStoreRebuildKeepsRememberedDelay() {
        let defaults = makeDefaults()
        let first = AppSettingsStore(defaults: defaults)
        first.setEdgeAutoHideDelay(2.0)
        first.toggleEdgeAutoHideMode()
        XCTAssertEqual(first.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)

        let second = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(second.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(second.lastEnabledEdgeAutoHideDelay, 2.0)

        second.toggleEdgeAutoHideMode()
        XCTAssertEqual(second.edgeAutoHideDelay, 2.0)
    }

    func testNonFiniteSetterInputsAreIgnored() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setEdgeAutoHideDelay(0.5)

        store.setEdgeAutoHideDelay(.nan)
        store.setEdgeAutoHideDelay(.infinity)
        store.setEdgeAutoHideDelay(-.infinity)
        store.setNativeDockAutoHideDelay(.nan)

        XCTAssertEqual(store.edgeAutoHideDelay, 0.5)
        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 0.5)
        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.defaultNativeDockAutoHideDelay)
    }

    func testSnapDelayReturnsFallbackForNonFiniteInput() {
        XCTAssertEqual(AppSettingsStore.snapDelay(.nan), AppSettingsStore.defaultEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.snapDelay(.infinity, fallbackForNonFinite: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.snapDelay(-.infinity, fallbackForNonFinite: 2.0), 2.0)
    }

    func testStoredActiveDelayRejectsWrongTypesAndUsesPerGroupFallback() {
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay("bad", fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay(true, fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay(NSNumber(value: Double.nan), fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay(2.04, fallback: 1.0), 2.0)

        let defaults = makeDefaults()
        defaults.set("bad", forKey: "com.tungsten.edge.autoHide.nativeDock.delay")
        defaults.set(true, forKey: "com.tungsten.edge.autoHide.edge.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.defaultNativeDockAutoHideDelay)
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.defaultEdgeAutoHideDelay)
        XCTAssertEqual(defaults.double(forKey: "com.tungsten.edge.autoHide.nativeDock.delay"), 1.0)
        XCTAssertEqual(defaults.double(forKey: "com.tungsten.edge.autoHide.edge.delay"), 0.1)
    }

    func testSanitizedLastEnabledDelayNeverReturnsResident() {
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(nil), AppSettingsStore.defaultEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(.nan), AppSettingsStore.defaultEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(AppSettingsStore.neverHideDelay), AppSettingsStore.defaultEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(-50.0), AppSettingsStore.defaultEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(0.05), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(2.0), 2.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(AppSettingsStore.neverWakeDelay), AppSettingsStore.neverWakeDelay)
    }

    // MARK: - 菜单分组标题纯逻辑

    /// 快捷键只在 Carbon 注册成功时才写进标题——注册失败时按不出来，提了就是骗人。
    func testEdgeSectionTitleMentionsShortcutOnlyWhenRegistered() {
        XCTAssertEqual(
            AutoHideToggleMenuModel.edgeSectionTitle(isHotKeyRegistered: true),
            String(localized: "Tungsten Edge (⌥⇧⌘D to show/hide)")
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.edgeSectionTitle(isHotKeyRegistered: false),
            String(localized: "Tungsten Edge")
        )
    }

    @MainActor
    func testEdgeSliderIsCompactAndKeepsAccessibilityContext() {
        let view = PreferenceSliderMenuItemView(accessibilityTitle: "Tungsten Edge 钨极唤醒时间")
        view.sync(delay: 0.5)

        XCTAssertEqual(view.frame.height, 58)
        XCTAssertEqual(view.accessibilityLabel(), "Tungsten Edge 钨极唤醒时间，0.5s")
        XCTAssertEqual(view.accessibilityValue() as? String, "0.5s")
    }

    @MainActor
    func testNativeDockApplyRowIsAButtonWiredToApply() {
        let row = NativeDockApplyRowView()
        var fired = 0
        row.onApply = { fired += 1 }

        // 必须是真按钮，不是普通菜单文字行：菜单行和邻居视觉权重相同，用户刚拖完滑块
        // 视线还在滑块上，错过它就变成「以为设好了其实没生效」。
        guard let button = row.subviews.compactMap({ $0 as? MenuActionButton }).first else {
            return XCTFail("确认行里必须有一个真按钮")
        }

        // 菜单里的自定义 view 不在 key window 里，不重写 acceptsFirstMouse 第一次点击会被吞，
        // 用户会以为按钮坏了。这个重写看着像冗余，删掉就复现。
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))

        // 子视图（文字 / 图标）不许截走鼠标，否则按钮中间一块点不动。
        let center = NSPoint(x: button.frame.midX, y: button.frame.midY)
        XCTAssertIdentical(button.hitTest(center), button)

        button.performClickForTesting()
        XCTAssertEqual(fired, 1, "按钮必须接到 onApply，否则确认整个是死的")
    }

    @MainActor
    func testNativeDockApplyRowCarriesTargetTierForVoiceOver() {
        let row = NativeDockApplyRowView()
        row.updateTarget(
            description: AutoHideToggleMenuModel.nativeApplyTitle(draft: AppSettingsStore.neverWakeDelay)
        )
        // 按钮标题恒为「应用」，档位只走 accessibility：VoiceOver 用户看不到滑块位置。
        XCTAssertEqual(row.accessibilityLabel(),
                       String(format: String(localized: "Apply “%@” (the Dock will restart)"), String(localized: "Never Wake")))
    }

    func testNativeApplyRowAppearsOnlyWhenDraftDiffersFromAppliedTier() {
        // 同一档位（含浮点表示误差）不该浮出确认行：没有要应用的东西。
        XCTAssertFalse(AutoHideToggleMenuModel.shouldShowNativeApply(draft: 1.0, applied: 1.0))
        XCTAssertFalse(AutoHideToggleMenuModel.shouldShowNativeApply(
            draft: AppSettingsStore.neverHideDelay,
            applied: AppSettingsStore.neverHideDelay
        ))
        // 比的是整数档位而非浮点：滑块只能停在档位上，档间的值归到同一档就是「没变」。
        XCTAssertFalse(AutoHideToggleMenuModel.shouldShowNativeApply(draft: 1.0 + 1e-12, applied: 1.0))

        XCTAssertTrue(AutoHideToggleMenuModel.shouldShowNativeApply(
            draft: AppSettingsStore.neverWakeDelay,
            applied: AppSettingsStore.neverHideDelay
        ))
        XCTAssertTrue(AutoHideToggleMenuModel.shouldShowNativeApply(draft: 0.5, applied: 1.0))
    }

    func testNativeApplyTitleNamesTheTargetTier() {
        XCTAssertEqual(
            AutoHideToggleMenuModel.nativeApplyTitle(draft: AppSettingsStore.neverWakeDelay),
            String(format: String(localized: "Apply “%@” (the Dock will restart)"), String(localized: "Never Wake"))
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.nativeApplyTitle(draft: AppSettingsStore.neverHideDelay),
            String(format: String(localized: "Apply “%@” (the Dock will restart)"), String(localized: "Always Visible"))
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.nativeApplyTitle(draft: 1.0),
            String(format: String(localized: "Apply “%@” (the Dock will restart)"), "1.0s")
        )
    }

    func testDelayDisplayNameIsSharedBySliderAndApplyRow() {
        // 滑块本体与确认行必须同一口径，否则确认行说的档位和滑块显示的不是一回事。
        XCTAssertEqual(AutoHideToggleMenuModel.delayDisplayName(sliderIndex: 0), String(localized: "Always Visible"))
        XCTAssertEqual(
            AutoHideToggleMenuModel.delayDisplayName(sliderIndex: AppSettingsStore.sliderIndexMax),
            String(localized: "Never Wake")
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.delayDisplayName(
                sliderIndex: AppSettingsStore.sliderIndexFromDelay(1.0)
            ),
            "1.0s"
        )
    }

    func testResolvedStoreDelayCoversWriteAndReadQuadrants() {
        let target = 0.5
        let previous = AppSettingsStore.neverHideDelay

        // 系统可读 → 一律以系统真值为准，与写入是否成功无关。
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: true,
                systemState: NativeDockAutohideState(enabled: true, delay: 0.5),
                target: target,
                previous: previous
            ),
            0.5
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: false,
                systemState: NativeDockAutohideState(enabled: true, delay: 0.5),
                target: target,
                previous: previous
            ),
            0.5,
            "多步写入可能已部分生效，读得到就按读到的来"
        )
        // 写成功但读不回来 → 保留 target。回滚会让 UI 和已经生效的系统设置相反。
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: true,
                systemState: nil,
                target: target,
                previous: previous
            ),
            target
        )
        // 写失败又读不回来 → 只能整体退回改动前。
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: false,
                systemState: nil,
                target: target,
                previous: previous
            ),
            previous
        )
    }

    func testPreferenceSliderCommitIsConsumedExactlyOnce() {
        var tracker = PreferenceSliderCommitTracker()
        tracker.begin(currentDelay: 0.5)
        tracker.stage(1.0)
        // 拖动过程中反复 begin 不得覆盖起点，否则 previous 变成中间值。
        tracker.begin(currentDelay: 0.9)
        tracker.stage(1.5)

        let first = tracker.consume()
        XCTAssertEqual(first?.previous, 0.5)
        XCTAssertEqual(first?.target, 1.5)
        // 确认行提交与「打开菜单时作废草稿」都走 consume，只有第一个拿得到值：
        // 否则确认过的值会被随后的作废逻辑又拨回旧值，或者多写一遍 defaults + killall Dock。
        XCTAssertNil(tracker.consume())
        XCTAssertNil(tracker.consume())
    }

    func testPreferenceSliderCommitSkipsUnchangedAndUnstartedAdjustments() {
        var unchanged = PreferenceSliderCommitTracker()
        unchanged.begin(currentDelay: 0.5)
        unchanged.stage(0.5)
        XCTAssertNil(unchanged.consume(), "值没变不该写系统")

        var neverStarted = PreferenceSliderCommitTracker()
        neverStarted.stage(1.0)
        XCTAssertNil(neverStarted.consume(), "没有起点就没有 previous，不能提交")

        // 消费过之后重新开一轮仍然正常工作。
        var reused = PreferenceSliderCommitTracker()
        reused.begin(currentDelay: 0.2)
        reused.stage(0.4)
        XCTAssertNotNil(reused.consume())
        reused.begin(currentDelay: 0.4)
        reused.stage(0.8)
        XCTAssertEqual(reused.consume()?.previous, 0.4)
    }

    func testNativeDockSectionTitleMentionsSystemShortcutAsPlainText() {
        // ⌥⌘D 归 macOS，我们不定义也不注册它。删掉显隐命令后它是「把 Dock 临时叫回来」的
        // 唯一一键入口，所以标题必须提到它——但只能是纯文字，设成 keyEquivalent 会被菜单捕获。
        XCTAssertTrue(AutoHideToggleMenuModel.nativeDockSectionTitle.contains("⌥⌘D"))
        // 「Dock」两种语言里都在（中文「系统 Dock」/ 英文「The Dock」），断言语言无关的那部分。
        XCTAssertTrue(AutoHideToggleMenuModel.nativeDockSectionTitle.contains("Dock"))
    }

    func testReconciledStoreDelayAlignsStoreWithSystemTruth() {
        // 系统关着：存值不是常驻就改成常驻；已是常驻则无需改动。
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: false, systemDelay: nil, currentStoreDelay: 1.0),
            AppSettingsStore.neverHideDelay
        )
        XCTAssertNil(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: false, systemDelay: 0.5, currentStoreDelay: AppSettingsStore.neverHideDelay)
        )

        // 系统开着：对齐到系统延迟（吸附到合法档位）；键不存在用系统默认 0.5。
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 0.2, currentStoreDelay: AppSettingsStore.neverHideDelay),
            0.2
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: nil, currentStoreDelay: AppSettingsStore.neverHideDelay),
            AutoHideToggleMenuModel.systemDefaultAutohideDelay
        )
        // 999（不唤醒档）原样往返；0 吸附到最小档 0.1；已一致返回 nil。
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 999.0, currentStoreDelay: 1.0),
            AppSettingsStore.neverWakeDelay
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 0.0, currentStoreDelay: 1.0),
            AppSettingsStore.finiteDelayMin
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: -1.0, currentStoreDelay: 1.0),
            AppSettingsStore.finiteDelayMin,
            "系统开关明确开启时，负 delay 不能被解释成 App 的常驻哨兵"
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: .nan, currentStoreDelay: 0.2),
            AppSettingsStore.defaultNativeDockAutoHideDelay
        )
        XCTAssertNil(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 1.0, currentStoreDelay: 1.0)
        )
    }

    @MainActor
    func testNativeDockAutohideStateReadRespectsSandboxAndInjectedReader() async {
        let sandboxed = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: true),
            runner: { _, _ in },
            autohideReader: { NativeDockAutohideState(enabled: true, delay: 0.5) }
        )
        let sandboxedState = await sandboxed.currentAutohideState()
        XCTAssertNil(sandboxedState, "沙箱下读不到，返回 nil 让调用方回退存值")

        let readable = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { NativeDockAutohideState(enabled: true, delay: 0.2) }
        )
        let readableState = await readable.currentAutohideState()
        XCTAssertEqual(readableState, NativeDockAutohideState(enabled: true, delay: 0.2))
    }

    @MainActor
    func testSystemTruthReadersRunOffMainThread() async {
        let launch = LaunchAtLoginService(stateReader: { Thread.isMainThread ? .off : .on })
        let launchState = await launch.currentState()
        XCTAssertEqual(launchState, .on)

        let native = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: {
                NativeDockAutohideState(enabled: !Thread.isMainThread, delay: 0.4)
            }
        )
        let nativeState = await native.currentAutohideState()
        XCTAssertEqual(
            nativeState,
            NativeDockAutohideState(enabled: true, delay: 0.4)
        )
    }

    func testOpenSystemDockSettingsUsesDeepLinkFirst() {
        var openedURLs: [URL] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertTrue(service.openSystemSettings())
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["x-apple.systempreferences:com.apple.preference.dock"])
    }

    func testOpenSystemDockSettingsFallsBackToPreferencePane() {
        var openedURLs: [URL] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { url in
                openedURLs.append(url)
                return url.isFileURL
            }
        )

        XCTAssertTrue(service.openSystemSettings())
        XCTAssertEqual(openedURLs.count, 2)
        XCTAssertEqual(openedURLs[0].absoluteString, "x-apple.systempreferences:com.apple.preference.dock")
        XCTAssertEqual(openedURLs[1].path, "/System/Library/PreferencePanes/Dock.prefPane")
    }

    func testOpenSystemDockSettingsReportsFailureAfterBothAttempts() {
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { _ in false }
        )

        XCTAssertFalse(service.openSystemSettings())
    }

    func testOpenSystemDockSettingsIsNotBlockedBySandboxWriteGate() {
        var openedURLs: [URL] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: true),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertFalse(service.isAvailable)
        XCTAssertTrue(service.openSystemSettings())
        XCTAssertEqual(openedURLs.count, 1)
    }

    // MARK: - 系统 Dock 组 remembered 镜像

    func testNativeRememberedSeedsFromCurrentFiniteValueOverStaleStoredValue() {
        let defaults = makeDefaults()
        defaults.set(2.0, forKey: "com.tungsten.edge.autoHide.nativeDock.delay")
        defaults.set(0.5, forKey: "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledNativeDockAutoHideDelay, 2.0)
        XCTAssertEqual(defaults.double(forKey: "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay"), 2.0)
    }

    func testNativeRememberedIsReadWhenCurrentIsResidentAndCorruptFallsBackToNativeDefault() {
        let defaults = makeDefaults()
        defaults.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.nativeDock.delay")
        defaults.set(2.0, forKey: "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).lastEnabledNativeDockAutoHideDelay, 2.0)

        let corrupted = makeDefaults()
        corrupted.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.nativeDock.delay")
        corrupted.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay")
        // 回退值是 native 组自己的默认档位 1.0，不是 edge 的 0.1。
        XCTAssertEqual(AppSettingsStore(defaults: corrupted).lastEnabledNativeDockAutoHideDelay, AppSettingsStore.defaultNativeDockAutoHideDelay)
    }

    func testNativeSetterSyncsRememberedBeforeActiveDedup() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        store.setNativeDockAutoHideDelay(2.0)
        XCTAssertEqual(store.lastEnabledNativeDockAutoHideDelay, 2.0)

        store.setNativeDockAutoHideDelay(AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.lastEnabledNativeDockAutoHideDelay, 2.0, "写入常驻不动 remembered")

        let rebuilt = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(rebuilt.lastEnabledNativeDockAutoHideDelay, 2.0, "跨 Store 重建保留 remembered")
    }

    func testSanitizedLastEnabledDelayHonorsPerGroupFallback() {
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(nil, fallback: AppSettingsStore.defaultNativeDockAutoHideDelay), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(.nan, fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(AppSettingsStore.neverHideDelay, fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(2.0, fallback: 1.0), 2.0)
    }

    func testFullscreenPendingConfirmationIsAtomicAndStaleTimeoutCannotRevealPanels() {
        var state = PanelVisibilityState()
        state.beginFullscreenTransition(generation: 7)
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.timeoutFullscreenTransition(generation: 6))
        XCTAssertFalse(state.isVisible)

        XCTAssertTrue(state.confirmFullscreenTransition(generation: 7))
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.hideReasons.contains(.fullscreenTransitionPending))
        XCTAssertTrue(state.hideReasons.contains(.fullscreen))
    }

    func testFullscreenPendingTimeoutPreservesEdgeHiddenStateAndBlocksEdgeTimers() {
        var state = PanelVisibilityState()
        state.setEdgeAutoHidden(true)
        state.beginFullscreenTransition(generation: 8)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.5))
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.5))

        XCTAssertTrue(state.timeoutFullscreenTransition(generation: 8))
        XCTAssertFalse(state.isVisible)
        XCTAssertTrue(state.hideReasons.contains(.edgeAutoHide))
    }

    func testFullscreenSpaceHoldBeginsOnlyFromConfirmedFullscreen() {
        XCTAssertTrue(FullscreenSpaceHoldDecision.shouldBegin(isFullscreen: true, hasInputIntent: false))
        XCTAssertFalse(FullscreenSpaceHoldDecision.shouldBegin(isFullscreen: false, hasInputIntent: false))
        XCTAssertFalse(FullscreenSpaceHoldDecision.shouldBegin(isFullscreen: true, hasInputIntent: true))
    }

    func testFullscreenSpaceHoldSuppressesTransientFalseButAcceptsFullscreen() {
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 4,
                activeGeneration: 4,
                isFinalWindowedConfirmation: false
            ),
            .hold
        )
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: true,
                expectedGeneration: 4,
                activeGeneration: 4,
                isFinalWindowedConfirmation: false
            ),
            .apply
        )
    }

    func testFullscreenSpaceHoldRequiresFinalConfirmationBeforeWindowedReveal() {
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 7,
                activeGeneration: 7,
                isFinalWindowedConfirmation: true
            ),
            .apply
        )
        XCTAssertEqual(FullscreenSpaceHoldDecision.postSpaceConfirmationDelay, 0.12)
        XCTAssertEqual(FullscreenSpaceHoldDecision.activationFallbackDelay, 0.5)
    }

    func testFullscreenSpaceHoldRejectsOldGenerationAndAppliesWithoutHold() {
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 8,
                activeGeneration: 9,
                isFinalWindowedConfirmation: true
            ),
            .stale
        )
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 9,
                activeGeneration: nil,
                isFinalWindowedConfirmation: true
            ),
            .stale
        )
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: nil,
                activeGeneration: nil,
                isFinalWindowedConfirmation: false
            ),
            .apply
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
extension AppSettingsStoreTests {
    /// 复现 issue：开关切换必须通过 @Published → dropFirst/removeDuplicates → sink 送达。
    func testFinderSettingPublishesOnToggleThroughDropFirstChain() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        var deliveries: [Bool] = []
        let subscription = store.$finderAlwaysInDock
            .dropFirst()
            .removeDuplicates()
            .sink { deliveries.append($0) }

        store.setFinderAlwaysInDock(false)
        store.setFinderAlwaysInDock(false)   // 同值去重，不应再投递
        store.setFinderAlwaysInDock(true)

        XCTAssertEqual(deliveries, [false, true], "初值被 dropFirst 丢弃，两次真实切换各投递一次")
        withExtendedLifetime(subscription) {}
    }
}
