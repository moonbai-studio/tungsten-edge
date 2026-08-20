import XCTest

/// 主题表只有**一套**值（`DockThemeTokens.standard`）——产品固定浅色，深色模式已于
/// 2026-08-16 由 owner 拍板删除。
///
/// 本文件在那之前锁的是「深色列逐字节冻结 + 浅色列逐项断言」共 38 个字段。**那套契约随
/// 功能一起消失了，不要按旧值把它恢复回来。** 现在只锁与功能绑定的不变量：
/// 前景必须加黑（加白在浅玻璃上等于消失）、药丸与光晕必须把底板推离文字、阴影不超预算、
/// 所有效果开关默认关。逐个数值是可以自由调的观感，不该由测试钉死。
final class DockThemeTests: XCTestCase {
    private let theme = DockThemeTokens.standard
    private let shadowPadding: CGFloat = 20

    // MARK: - 前景方向

    /// 前景必须是**加黑**而不是加白：浅色玻璃上加白等于消失，只剩描边孤零零留着，
    /// 每张卡就变成一个空心方格——这正是用户抱怨过的「周围有很明显的方格」。
    func testForegroundsAreDarkTinted() {
        let mustBeBlack: [(String, DockTint)] = [
            ("labelActive", theme.labelActive),
            ("labelInactive", theme.labelInactive),
            ("labelHover", theme.labelHover),
            ("labelSubtitle", theme.labelSubtitle),
            ("runningDot", theme.runningDot),
            ("zoneDivider", theme.zoneDivider),
            ("capsuleGlyph", theme.capsuleGlyph),
            ("folderDropRing", theme.folderDropRing),
            ("popupCellLabel", theme.popupCellLabel),
            ("popupCellHover", theme.popupCellHover),
            ("popupSecondaryText", theme.popupSecondaryText),
            ("backChipFill", theme.backChipFill),
            ("tooltipText", theme.tooltipText),
        ]
        for (name, tint) in mustBeBlack {
            XCTAssertEqual(tint.base, .black, "\(name) 必须加黑，加白在浅玻璃上会消失")
        }
    }

    /// 中转格是条上唯一一个**不是应用图标**的 chip。它必须是**不透明的实心瓷砖**：
    /// 半透明的话玻璃底下一暗就消失（owner 2026-08-16 报过），所以它的配色走 `DockRGB`
    /// 而不是只有黑白两种基色的 `DockTint`——这条断言就是防止有人把它改回半透明染色。
    func testShelfTileIsAnOpaqueColouredTile() {
        for style in DockShelfTileStyle.allCases {
            let c = style.colors
            XCTAssertNotEqual(c.top, c.bottom, "\(style) 要有渐变，纯平色不像一枚真图标")
            // 符号与瓷砖必须分处明暗两端，否则符号在自己的底上消失。
            let tileLuma = (c.top.luminance + c.bottom.luminance) / 2
            XCTAssertGreaterThan(abs(c.glyph.luminance - tileLuma), 0.3,
                                 "\(style) 的符号和瓷砖对比不够")
        }
    }

    /// 投放命中是**整块提亮**（实心瓷砖上「加浓」没有意义）。
    func testShelfTileDropTargetLifts() {
        XCTAssertGreaterThan(DockShelfTileStyle.dropTargetLift, 0)
        let base = DockShelfTileStyle.blue.colors.top
        XCTAssertGreaterThan(base.lightened(by: DockShelfTileStyle.dropTargetLift).luminance,
                             base.luminance)
    }

    /// 认不出的名字回落到默认档，别崩也别黑屏。
    func testShelfTileStyleFallsBackToDefault() {
        for bad in ["", " ", "purple", "1"] {
            XCTAssertEqual(DockShelfTileStyle.resolve(bad), .tray, "非法值 \(bad) 要回落")
        }
        XCTAssertEqual(DockShelfTileStyle.resolve(" GRAPHITE "), .graphite)
        XCTAssertEqual(theme.effectiveShelfTile, theme.shelfTile,
                       "测试进程没设环境变量，生效值必须是表里的值")
    }

    /// 面板描边是「上沿亮（白高光）+ 下沿暗（黑细线）」——苹果原生玻璃的打光方向。
    /// 均匀一圈白描边在浅底板上就是用户看到的那种灰框。
    func testPanelRimIsBrightTopDarkBottom() {
        XCTAssertEqual(theme.panelRimTop.base, .white)
        XCTAssertEqual(theme.panelRimBottom.base, .black)
        XCTAssertGreaterThan(theme.panelRimTop.opacity, theme.panelRimBottom.opacity)
    }

    /// 气泡底板锁的是**合成后的读数**，不是单个数值——这样换写法也不会漂。
    /// 两个锚点来自同一颗原生气泡在两种背景上的实测：纯黑底 173、绿壁纸（145）底 216。
    func testTooltipPlateMatchesTheMeasuredNativeBubble() {
        func composite(over background: Double) -> Double {
            theme.tooltipPlateOpacity * theme.tooltipPlate.luminance * 255
                + (1 - theme.tooltipPlateOpacity) * background
        }
        XCTAssertEqual(composite(over: 0), 173, accuracy: 6, "黑底实测 173")
        XCTAssertEqual(composite(over: 145), 216, accuracy: 6, "绿壁纸底实测 216")
        XCTAssertEqual(composite(over: 235), 247, accuracy: 6, "浅色窗口底实测 247（2026-08-17 新增第三点）")
        // 反过来钉住「它是半透的」：完全不透就跟不上背景，浅壁纸下会显得脏。
        XCTAssertLessThan(theme.tooltipPlateOpacity, 0.85)
    }

    /// **气泡描边必须比填充更亮。** 原生剖面（黑底 @2x）是 0 → 191 → 209 → 173：
    /// 一圈比填充还亮的镜面边，气泡靠它从背景里切出来。我们曾经用加黑 0.1，
    /// 等于没有边，观感就是 owner 说的「不利落」。
    func testTooltipRimIsBrighterThanItsFill() {
        XCTAssertEqual(theme.tooltipRim.base, .white, "暗边等于没有边")
        // 描边压在**合成后的填充**上，不是压在底板色上——两者在近白底板下差很多。
        func fill(over background: Double) -> Double {
            theme.tooltipPlateOpacity * theme.tooltipPlate.luminance * 255
                + (1 - theme.tooltipPlateOpacity) * background
        }
        func rim(over background: Double) -> Double {
            let f = fill(over: background)
            return f + theme.tooltipRim.opacity * (255 - f)
        }
        // 原生实测：黑底 209（填充 173）、绿壁纸底 235（填充 216）。
        XCTAssertEqual(rim(over: 0), 209, accuracy: 6)
        XCTAssertEqual(rim(over: 145), 235, accuracy: 6)
        // 两种背景下都必须真的看得见，这才是「利落」的来源。
        XCTAssertGreaterThan(rim(over: 0) - fill(over: 0), 20)
        XCTAssertGreaterThan(rim(over: 145) - fill(over: 145), 12)
    }

    // MARK: - 药丸与光晕：必须把底板推离文字

    /// **药丸的方向必须和文字相反。**
    ///
    /// 底板是透的、亮度跟**壁纸**走，而文字颜色是固定的黑；药丸和文字同向就等于把对比度抹平。
    /// 2026-08-16 之前这里是加黑 0.05——当年为了「让卡看起来像张卡」调的，不是为了读得清，
    /// 正好同向。**别按那个直觉把它改回加黑。** 卡片的「像张卡」由 `chipPillRimTop`
    /// 那圈描边承担，不靠填充。
    func testChipPillPushesAgainstTheTextColour() {
        XCTAssertEqual(theme.labelActive.base, .black, "前提：文字是黑的")
        XCTAssertEqual(theme.chipPillFill.normal.base, .white, "方向反了——药丸要把底板推离黑字")
        XCTAssertEqual(theme.chipPillFill.emphasized.base, .white)
        XCTAssertGreaterThan(theme.chipPillFill.emphasized.opacity, theme.chipPillFill.normal.opacity,
                             "悬停态要比常态更浓")
    }

    /// 裸文字（没有药丸兜底的那些）的光晕同样取文字的反方向，`y = 0`：
    /// 要的是包住字的一圈，不是投影。
    func testLabelHaloOpposesTheTextColour() {
        XCTAssertEqual(theme.labelHalo.tint.base, .white, "文字是黑的，光晕必须是白的")
        XCTAssertEqual(theme.labelHalo.y, 0, "光晕不向下偏移")
        XCTAssertGreaterThan(theme.labelHalo.radius, 0)
    }

    // MARK: - 数值合法性

    func testShadowsFitInsideShadowPaddingBudget() {
        XCTAssertLessThanOrEqual(theme.stripShadow.verticalExtent, shadowPadding)
        XCTAssertLessThanOrEqual(theme.popupShadow.verticalExtent, shadowPadding)
        XCTAssertLessThanOrEqual(theme.labelHalo.verticalExtent, shadowPadding)
    }

    /// 手调时容易顺手写超。
    func testAllOpacitiesAreInRange() {
        for tint in theme.allTints {
            XCTAssertTrue((0 ... 1).contains(tint.opacity), "不透明度越界：\(tint)")
        }
    }

    /// 厚度层的闸门：**两对（内高光 / 内阴影）里只要有一对「颜色和线宽都非零」就画**。
    /// 判据落在「同一对内部」——颜色 0 或线宽 0 的那一对不算数，否则会画出一层看不见的
    /// 离屏渲染（`.blur(radius: 0)` 一样会触发）。
    func testThicknessGateNeedsBothColourAndWidthWithinAPair() {
        XCTAssertFalse(DockThemeTokens.drawsThickness(
            highlight: .white(0), highlightWidth: 3, shadow: .black(0), shadowWidth: 3),
            "两对的颜色都是 0 → 不画")
        XCTAssertFalse(DockThemeTokens.drawsThickness(
            highlight: .white(0.1), highlightWidth: 0, shadow: .black(0.1), shadowWidth: 0),
            "两对的线宽都是 0 → 不画")
        XCTAssertTrue(DockThemeTokens.drawsThickness(
            highlight: .white(0), highlightWidth: 3, shadow: .black(0.1), shadowWidth: 3),
            "内阴影这一对齐全 → 画")
        XCTAssertTrue(DockThemeTokens.drawsThickness(
            highlight: .white(0.1), highlightWidth: 3, shadow: .black(0), shadowWidth: 0),
            "内高光这一对齐全 → 画")
    }

    // MARK: - 效果开关

    /// **未验收的效果一律默认关。** 2026-07-30 栽过一次：玻璃探路正确地做成了默认关，
    /// 同一天落地的提饱和和厚度层却默认开，于是 owner 眼里的条悄悄偏离了他签收过的版本。
    func testAllEffectsAreOffByDefault() {
        let empty: [String: String] = [:]
        XCTAssertEqual(DockEffectSwitches.saturation(from: empty, candidate: 1.25), 1.0,
                       "没设环境变量 → 不提饱和")
        XCTAssertFalse(DockEffectSwitches.thicknessEnabled(from: empty), "没设环境变量 → 不画厚度层")
        XCTAssertEqual(DockPanelMaterial.resolved(from: empty, fallback: .popover), .popover,
                       "没设环境变量 → 用 token 里的材质")
    }

    func testSaturationSwitch() {
        XCTAssertEqual(DockEffectSwitches.saturation(
            from: ["DOCK_PANEL_SATURATION": "candidate"], candidate: 1.25), 1.25)
        XCTAssertEqual(DockEffectSwitches.saturation(
            from: ["DOCK_PANEL_SATURATION": " 1.8 "], candidate: 1.25), 1.8)
        for bad in ["", "abc", "0", "-1", "99"] {
            XCTAssertEqual(DockEffectSwitches.saturation(
                from: ["DOCK_PANEL_SATURATION": bad], candidate: 1.25), 1.0, "非法值 \(bad) 要回落")
        }
    }

    func testThicknessSwitch() {
        XCTAssertTrue(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": "1"]))
        XCTAssertTrue(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": " 1 "]))
        for bad in ["", "0", "true", "yes"] {
            XCTAssertFalse(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": bad]))
        }
    }

    func testMaterialOverrideParsesKnownNames() {
        XCTAssertEqual(DockPanelMaterial.resolved(
            from: ["DOCK_PANEL_MATERIAL": "hudWindow"], fallback: .popover), .hudWindow)
        XCTAssertEqual(DockPanelMaterial.resolved(
            from: ["DOCK_PANEL_MATERIAL": " MENU "], fallback: .popover), .menu)
    }

    func testMaterialOverrideFallsBackOnUnknownOrEmpty() {
        for bad in ["", "  ", "notAMaterial"] {
            XCTAssertEqual(DockPanelMaterial.resolved(
                from: ["DOCK_PANEL_MATERIAL": bad], fallback: .popover), .popover, "「\(bad)」要回落")
        }
    }

    func testMaterialAllCoversEveryCase() {
        XCTAssertEqual(DockPanelMaterial.all.count, 14, "系统材质候选共 14 种；新增 case 时同步这里")
    }
}

private extension DockThemeTokens {
    /// 遍历用：本表里所有着色值（含阴影自带的着色）。新增字段时补进来。
    var allTints: [DockTint] {
        [panelRimTop, panelRimBottom, panelRimHighlighted,
         panelInnerHighlight, panelInnerShadow,
         stripShadow.tint, popupShadow.tint,
         chipPillFill.normal, chipPillFill.emphasized,
         chipPillRimTop.normal, chipPillRimTop.emphasized, chipPillRimBottom,
         labelActive, labelInactive, labelHover, labelSubtitle, labelHalo.tint,
         runningDot, zoneDivider,
         shelfDropGlow,
         capsuleGlyph, capsuleStashGlow,
         folderDropRing, folderThumbHairline,
         popupCellLabel, popupCellHover, popupPrimaryText, popupSecondaryText,
         backChipFill, backChipRim, backChipGlyph,
         tooltipRim, tooltipText, tooltipShadow.tint]
    }
}
