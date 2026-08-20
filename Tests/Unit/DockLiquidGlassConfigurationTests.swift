import XCTest
@testable import macos_dock_cc_v2

final class DockLiquidGlassConfigurationTests: XCTestCase {
    /// **默认现在是开**（owner 2026-08-17 转正玻璃观感）。
    ///
    /// 这条以前叫「默认保持已验收的毛玻璃路径」，锁的是探路期「默认关 + `=1` 才开」。
    /// 那条护栏的用意是「未验收的效果不许默认生效」——观感验收通过之后它就该翻面，
    /// 否则系统重启后自动拉起的进程（不带环境变量）看到的永远是旧观感，真发生过。
    func testDefaultNowShipsTheAcceptedGlassLook() {
        let configuration = DockLiquidGlassConfiguration.resolve(environment: [:])

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.clearTintOpacity, 0.4)
        XCTAssertEqual(configuration.whiteOverlayOpacity, 0)
        XCTAssertEqual(configuration.dimmingOpacity, 0)
        XCTAssertEqual(configuration.borderPeakOpacity, 0.75, "峰值档（↖↘ 两角）：实测调出来的，不是 78/171 算出来的")
        XCTAssertEqual(configuration.borderEdgeLevel, 0.5, "长边要的是 0.375，除以峰值 0.75")
        XCTAssertEqual(configuration.borderCornerCut, 0.92, "↗↙ 两角挖掉，原生那里亮线几乎没有")
        XCTAssertEqual(configuration.borderCornerSpread, 2.2, "角落调制半径 = 圆角半径的倍数")
        XCTAssertEqual(configuration.borderLineWidth, 0.5, "原生实测最外那道 1px @2x = 0.5pt")
        XCTAssertEqual(configuration.borderInnerOpacity, 0.21, "内圈半档：底板 84 打到原生的 120")
        XCTAssertEqual(configuration.backgroundMaterialOpacity, 0)
        XCTAssertEqual(configuration.windowBlurRadius, 0, "窗口级模糊不跟圆角走，会在四角糊出方块；通透度不靠它")
        XCTAssertEqual(configuration.contentInset, 4)
        XCTAssertEqual(configuration.backgroundPlateOpacity, 0.001)
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: true, isCompositeAvailable: true),
            .layeredTaskbar
        )
        // 12–25 上没有玻璃 API，仍然回退到毛玻璃——默认翻面不影响老系统。
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: false, isCompositeAvailable: true),
            .visualEffectFallback
        )
    }

    /// 关掉玻璃的开关**只认 `0`**。其余一切（含未设、乱填）都是开。
    func testOnlyZeroTurnsGlassOff() {
        XCTAssertFalse(resolve(["DOCK_LIQUID_GLASS": "0"]).isEnabled)
        XCTAssertFalse(resolve(["DOCK_LIQUID_GLASS": " 0 \n"]).isEnabled)

        for value in ["", "1", "true", "yes", "2"] {
            XCTAssertTrue(resolve(["DOCK_LIQUID_GLASS": value]).isEnabled)
        }
    }

    func testCompositeRequiresSystemAPIAndBackgroundPanel() {
        let configuration = resolve(["DOCK_LIQUID_GLASS": "1"])

        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: true, isCompositeAvailable: true),
            .layeredTaskbar
        )
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: false, isCompositeAvailable: true),
            .visualEffectFallback
        )
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: true, isCompositeAvailable: false),
            .visualEffectFallback
        )
    }

    func testNumericOverridesAcceptBounds() {
        let configuration = resolve([
            "DOCK_LIQUID_GLASS_CLEAR_TINT": "0",
            "DOCK_LIQUID_GLASS_WHITE_OVERLAY": "1",
            "DOCK_LIQUID_GLASS_DIMMING": "1",
            "DOCK_LIQUID_GLASS_BORDER": "1",
            "DOCK_LIQUID_GLASS_BORDER_EDGE": "1",
            "DOCK_LIQUID_GLASS_BORDER_CUT": "0",
            "DOCK_LIQUID_GLASS_BORDER_SPREAD": "6",
            "DOCK_LIQUID_GLASS_BORDER_WIDTH": "4",
            "DOCK_LIQUID_GLASS_BORDER_INNER": "1",
            "DOCK_LIQUID_GLASS_BACKGROUND_OPACITY": "0",
            "DOCK_LIQUID_GLASS_WINDOW_BLUR": "64",
            "DOCK_LIQUID_GLASS_CONTENT_INSET": "12",
        ])

        XCTAssertEqual(configuration.clearTintOpacity, 0)
        XCTAssertEqual(configuration.whiteOverlayOpacity, 1)
        XCTAssertEqual(configuration.dimmingOpacity, 1)
        XCTAssertEqual(configuration.borderPeakOpacity, 1)
        XCTAssertEqual(configuration.borderEdgeLevel, 1)
        XCTAssertEqual(configuration.borderCornerCut, 0)
        XCTAssertEqual(configuration.borderCornerSpread, 6)
        XCTAssertEqual(configuration.borderLineWidth, 4)
        XCTAssertEqual(configuration.borderInnerOpacity, 1)
        XCTAssertEqual(configuration.backgroundMaterialOpacity, 0)
        XCTAssertEqual(configuration.windowBlurRadius, 64)
        XCTAssertEqual(configuration.contentInset, 12)
    }

    func testInvalidNumericOverridesUseCandidateDefaults() {
        let invalidValues = ["", "abc", "nan", "inf", "-1", "999"]
        for value in invalidValues {
            let configuration = resolve([
                "DOCK_LIQUID_GLASS_CLEAR_TINT": value,
                "DOCK_LIQUID_GLASS_WHITE_OVERLAY": value,
                "DOCK_LIQUID_GLASS_DIMMING": value,
                "DOCK_LIQUID_GLASS_BORDER": value,
                "DOCK_LIQUID_GLASS_BORDER_EDGE": value,
                "DOCK_LIQUID_GLASS_BORDER_CUT": value,
                "DOCK_LIQUID_GLASS_BORDER_SPREAD": value,
                "DOCK_LIQUID_GLASS_BORDER_WIDTH": value,
                "DOCK_LIQUID_GLASS_BORDER_INNER": value,
                "DOCK_LIQUID_GLASS_BACKGROUND_OPACITY": value,
                "DOCK_LIQUID_GLASS_WINDOW_BLUR": value,
                "DOCK_LIQUID_GLASS_CONTENT_INSET": value,
            ])
            XCTAssertEqual(configuration.clearTintOpacity, 0.4, "clear tint: \(value)")
            XCTAssertEqual(configuration.whiteOverlayOpacity, 0, "white overlay: \(value)")
            XCTAssertEqual(configuration.dimmingOpacity, 0, "dimming: \(value)")
            XCTAssertEqual(configuration.borderPeakOpacity, 0.75, "border peak: \(value)")
            XCTAssertEqual(configuration.borderEdgeLevel, 0.5, "border edge: \(value)")
            XCTAssertEqual(configuration.borderCornerCut, 0.92, "border cut: \(value)")
            XCTAssertEqual(configuration.borderCornerSpread, 2.2, "border spread: \(value)")
            XCTAssertEqual(configuration.borderLineWidth, 0.5, "border width: \(value)")
            XCTAssertEqual(configuration.borderInnerOpacity, 0.21, "border inner: \(value)")
            XCTAssertEqual(configuration.backgroundMaterialOpacity, 0, "background: \(value)")
            XCTAssertEqual(configuration.windowBlurRadius, 0, "window blur: \(value)")
            XCTAssertEqual(configuration.contentInset, 4, "content inset: \(value)")
        }
    }

    /// 背景窗口 = 内容窗口减掉 20pt 阴影透明边后的可视底板，高度由 `DockSize.metrics` 决定
    /// （92 − 2×20 = 52 = 中档面板高），**不再有玻璃自带的第二套高度**。
    func testBackgroundFrameIsTheVisiblePlateInsideTheShadowPadding() {
        XCTAssertEqual(
            DockLiquidGlassPanelGeometry.backgroundFrame(
                for: CGRect(x: 80, y: 10, width: 440, height: 92),
                shadowPadding: 20
            ),
            CGRect(x: 100, y: 30, width: 400, height: 52)
        )
    }

    func testBackgroundFrameIsIdentityWithoutShadowPadding() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 40)
        XCTAssertEqual(
            DockLiquidGlassPanelGeometry.backgroundFrame(for: frame, shadowPadding: 0),
            frame
        )
        XCTAssertEqual(
            DockLiquidGlassPanelGeometry.backgroundFrame(for: frame, shadowPadding: -2),
            frame,
            "负值不该把窗口撑大"
        )
    }

    func testCompositePanelLifecycleOrderingIsAtomic() {
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: true,
                shouldShow: true
            ),
            [.background, .content]
        )
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: true,
                shouldShow: false
            ),
            [.content, .background]
        )
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: false,
                shouldShow: true
            ),
            [.content]
        )
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: false,
                shouldShow: false
            ),
            [.content]
        )
    }

    private func resolve(_ environment: [String: String]) -> DockLiquidGlassConfiguration {
        DockLiquidGlassConfiguration.resolve(environment: environment)
    }
}
