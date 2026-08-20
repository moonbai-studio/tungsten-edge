import Foundation

// MARK: - 浅 / 深色视觉数值表（纯数据层）
//
// 为什么存在：整套视觉原本是照着**深色模式**手调出来的，全仓库零处按外观分支——所有前景色写死成
// 白、所有阴影写死成黑。浅色模式下 `NSVisualEffectView` 会自己变浅（材质跟随系统），但上面的白字、
// 白描边、白圆点全部失效，黑阴影则变成一圈灰污渍。真实用户报告见 GitHub issue #3 第 3 条：
// 「周围有很明显的方格，然后旁边有阴影，并且还会延伸溢出，整体样式质感不行」——他用的是浅色模式，
// 抱怨的每一点都能对应到下面某个 token 在浅色下的失效。
//
// **本文件不 import SwiftUI**：只存基色 + 不透明度 + 阴影几何，全部是可精确比较的值类型，
// 因此 `DockThemeTests` 能逐项冻结深色列。`Color` / `NSVisualEffectView.Material` 的桥接在
// `App/Scenes/DockTheme.swift`。
//
// ⚠️ **深色列是冻结的**：它逐项等于 2026-07-30 改造前散落在各视图里的字面值，`DockThemeTests`
// 机械保证任何漂移直接红。要调观感只动 `light`——动 `dark` 等于改 owner 天天在用的界面。
//
// ⚠️ 两个「看着像颜色其实不是」的坑，不属于本表、也绝不能按外观改：
//   · `DockStripView` 滚动边缘淡出的 `.black` / `.clear` 是 **mask 的 alpha 通道**，不是颜色。
//   · `PanelCoordinator` 里的 `NSColor(white: 1.0, alpha: 0.0)` 是**全透明**，不是「白色底」。

/// 基色。整套视觉只用纯白 / 纯黑加不透明度叠在毛玻璃上，没有第三种基色
///（唯一的彩色是角标红，它两种模式都成立，不进本表）。
enum DockTintBase: Equatable {
    case white
    case black
}

/// 一个「基色 + 不透明度」的着色值。
struct DockTint: Equatable {
    let base: DockTintBase
    let opacity: Double

    static func white(_ opacity: Double) -> DockTint { .init(base: .white, opacity: opacity) }
    static func black(_ opacity: Double) -> DockTint { .init(base: .black, opacity: opacity) }
}

/// 同一处视觉的常态 / 强调态两个值（强调 = 悬停，或投放命中）。
struct DockTintPair: Equatable {
    let normal: DockTint
    let emphasized: DockTint
}

/// 阴影：颜色 + 模糊半径 + 向下偏移（x 恒为 0，整套视觉没有横向偏移的阴影）。
struct DockShadow: Equatable {
    let tint: DockTint
    let radius: CGFloat
    let y: CGFloat

    /// 阴影向下延伸的总量。**必须 ≤ `PanelCoordinator.shadowPadding`（20pt）**，否则在面板的
    /// 透明边处被硬切成一道齐口直边——这正是用户说的「阴影还会延伸溢出」。
    /// 深色任务条现值 15 + 8 = 23 就超了 3pt；深色冻结，本轮不动它（已单独记待办）。
    /// 浅色列全部收进预算内。
    var verticalExtent: CGFloat { radius + abs(y) }
}

/// 毛玻璃材质。用自己的枚举而不是 `NSVisualEffectView.Material`，是为了让本文件保持不依赖 AppKit
///（映射在 `DockTheme.swift`）。浅色下若觉得底板太白，这里是换材质的出口。
enum DockPanelMaterial: Equatable {
    case popover
    case hudWindow
    case menu
    case underWindowBackground
    case sidebar
    case titlebar
    case selection
    case headerView
    case fullScreenUI
    case toolTip
    case sheet
    case windowBackground
    case contentBackground
    case underPageBackground

    /// 调参用：`DOCK_PANEL_MATERIAL=<名字>` 可以在**不重新构建**的前提下换材质，
    /// 一轮迭代约 8 秒，方便一次拍完整张候选对照表。名字就是上面这些 case（大小写不敏感）。
    /// 认不出的名字**回落到传入的默认值**，绝不崩——调参时手滑打错不该让应用起不来。
    static func resolved(from environment: [String: String], fallback: DockPanelMaterial) -> DockPanelMaterial {
        guard let raw = environment["DOCK_PANEL_MATERIAL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else { return fallback }
        return all.first { "\($0)".lowercased() == raw } ?? fallback
    }

    /// 候选全集，供解析与对照表遍历。系统材质全部 macOS 10.14+，我们最低 12，无需可用性分支。
    static let all: [DockPanelMaterial] = [
        .popover, .hudWindow, .menu, .underWindowBackground, .sidebar,
        .titlebar, .selection, .headerView, .fullScreenUI, .toolTip,
        .sheet, .windowBackground, .contentBackground, .underPageBackground,
    ]
}

// 图标**不再按状态淡化**（owner 2026-08-02 拿掉，浅深两色一起）。状态信号只剩两处：
// 图标下方的运行点（是否运行）、带标题卡片的 `labelActive` / `labelInactive`（是否在桌面）。
// 理由与旧数值见 `Docs/27-product-decisions.md`。

/// 与外观无关的形状常量。原先 `cornerRadius: 16` 在 `DockStripView` 的 private `Style` 里，
/// 导致 `DrawerView` / `FolderGridPopupView` / `ShelfGridPopupView` 各自硬写一遍 16。
enum DockShape {
    /// 所有悬浮面板（任务条 / 抽屉 / 胶囊 / 两个弹窗）的圆角。
    static let panelCornerRadius: CGFloat = 16
}

/// 中转格图标的实心配色。
///
/// **不能用 `DockTint`**：那个只有黑 / 白两种基色，而这块要的是一张「看起来像原生应用图标」
/// 的彩色瓷砖。三档候选放在这里而不是主题表里——它们是同一个位置的互斥选项，不是三个独立数值。
enum DockShelfTileStyle: String, CaseIterable {
    /// 深色收纳袋 + 露出上沿的白纸，矢量自绘（`ShelfTrayArt`）。owner 2026-08-16 指定的样子。
    case tray
    /// 石墨渐变 + 白托盘符号。tray 画得不像时的退路（owner 说的「先用石墨灰」）。
    case graphite
    /// 系统蓝渐变 + 白符号。像一枚第一方工具图标，和右边的文件夹区同色系。
    case blue
    /// 近白渐变 + 深灰符号。最不抢眼，浅色壁纸下靠符号和投影立住。
    case light

    static func resolve(_ raw: String?) -> DockShelfTileStyle {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let style = DockShelfTileStyle(rawValue: raw) else { return .tray }
        return style
    }

    /// 是不是那张自绘插画（`tray`）。其余三档都是「纯色瓷砖 + SF 符号」。
    var isIllustration: Bool { self == .tray }

    /// (上, 下) 渐变端点与符号色，全部是不透明 RGB。`tray` 不走这条路，返回它自己的近似色
    /// 只为让「符号与底对比够」这类不变量对四档统一成立。
    var colors: (top: DockRGB, bottom: DockRGB, glyph: DockRGB) {
        switch self {
        case .tray:
            return (DockRGB(0.30, 0.30, 0.30), DockRGB(0.19, 0.19, 0.19), DockRGB(0.97, 0.97, 0.97))
        case .graphite:
            return (DockRGB(0.45, 0.47, 0.51), DockRGB(0.27, 0.29, 0.33), DockRGB(1, 1, 1))
        case .blue:
            return (DockRGB(0.36, 0.66, 0.98), DockRGB(0.13, 0.45, 0.90), DockRGB(1, 1, 1))
        case .light:
            return (DockRGB(0.99, 0.99, 1.00), DockRGB(0.88, 0.89, 0.92), DockRGB(0.26, 0.28, 0.32))
        }
    }

    /// 投放命中时整块提亮（原来是"底板加浓"，实心块上要反过来）。
    static let dropTargetLift: Double = 0.12
}

/// 不透明 RGB。故意最小化——只有中转格瓷砖用得到，别拿它去替代 `DockTint`。
struct DockRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 朝白色插值，用于投放命中的提亮。
    func lightened(by amount: Double) -> DockRGB {
        let t = min(max(amount, 0), 1)
        return DockRGB(red + (1 - red) * t, green + (1 - green) * t, blue + (1 - blue) * t)
    }

    /// 感知亮度（Rec. 709）。只给单测用，用来断言符号和瓷砖别撞到一起。
    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

// MARK: - Tokens

struct DockThemeTokens: Equatable {

    // MARK: 面板（任务条 / 抽屉 / 抽屉胶囊 / 文件夹弹窗 / 中转弹窗 共用）

    /// 面板描边的**上沿**。苹果原生玻璃是「上沿亮、下沿几乎没有」，模拟来自上方的光；
    /// 改造前是均匀一圈白 0.15，浅色下就变成用户说的那圈「明显的方格」灰框。
    /// 深色两端同值（0.15 / 0.15）→ 渐变退化成均匀色，与改造前逐像素一致。
    let panelRimTop: DockTint
    /// 面板描边的**下沿 / 两侧**。
    let panelRimBottom: DockTint
    /// 投放命中时的整框高亮（抽屉图标拖到任务条上方、外部目录悬停文件夹区）。
    let panelRimHighlighted: DockTint
    let panelRimLineWidth: CGFloat
    let panelRimHighlightedLineWidth: CGFloat

    // MARK: 玻璃厚度感（内高光 + 内阴影）
    //
    // 真玻璃的「厚」来自边缘两道信号：上内沿一条亮线（光从上方进入介质）+ 下内沿一道暗收
    // （介质底部的自阴影）。这两层画在材质**之上**、内容**之下**，是我们自己的像素，
    // 因此不受「拿不到窗口背后像素」那条限制——折射和背景饱和度做不到，厚度感能做。
    //
    // **深色一律 opacity 0 + width 0**，渲染上等价于不画，深色继续逐像素冻结。

    let panelInnerHighlight: DockTint
    let panelInnerHighlightWidth: CGFloat
    let panelInnerHighlightBlur: CGFloat
    let panelInnerShadow: DockTint
    let panelInnerShadowWidth: CGFloat
    let panelInnerShadowBlur: CGFloat

    /// 背景饱和度倍数。**1.0 = 不加滤镜**（此时整个修饰符都不挂，同厚度层的理由）。
    ///
    /// 2026-07-30 实测：SwiftUI 的 `.saturation()` 作用在毛玻璃的**合成结果**上（材质 + 已模糊
    /// 的背景），所以能真的把背景颜色提浓，而且**模糊保留**——彩色靶实测条内饱和度
    /// 0.221 → 0.534，条外对照 0.398 不变。
    ///
    /// 对比之下 `.opacity()` 是**死路**，别再试：它把材质本身抹掉一部分、露出**没模糊过**的
    /// 原始桌面（实测条内过渡带从 115px 塌成 0.9px，和条外一样锐利），观感廉价，
    /// 不是"更透的玻璃"而是"挖了个洞的玻璃"。通透度只能靠换材质。
    let panelBackdropSaturation: Double
    /// 任务条 + 抽屉胶囊的落地阴影。
    let stripShadow: DockShadow
    /// 抽屉 + 两个弹窗的落地阴影（比任务条略收，因为它们悬在更高处）。
    let popupShadow: DockShadow
    let panelMaterial: DockPanelMaterial

    // MARK: 多窗口 chip 的标题胶囊

    /// 卡片底。
    ///
    /// **方向必须和文字相反。** 底板是透的、亮度跟着**壁纸**走，而文字颜色是固定的黑；
    /// 两者同向就等于把对比度抹平。2026-08-16 之前这里是「加黑 0.05」——当年为了
    /// 「让卡看起来像张卡」调的，不是为了读得清，正好同向。现在是 owner 从
    /// 0.10 / 0.12 / 0.13 三次实机对比里定下的加白 0.13。
    ///
    /// 卡片的「像张卡」由 `chipPillRimTop` 那圈描边承担，不靠填充。
    let chipPillFill: DockTintPair
    let chipPillRimTop: DockTintPair
    let chipPillRimBottom: DockTint

    // MARK: 文字

    /// 窗口标题（该窗口在桌面上可见时）。
    let labelActive: DockTint
    /// 窗口标题（已最小化 / 隐藏时）。
    let labelInactive: DockTint
    /// 悬停时冒出的名字（窗口 chip / 抽屉图标 / 文件夹名 / 中转格）。
    let labelHover: DockTint
    /// 标题胶囊下方的应用名副标题。
    let labelSubtitle: DockTint
    /// **裸文字**（没有药丸兜底的那些）的描边光晕：悬停冒出的应用名、图标卡悬停标题、
    /// 抽屉图标悬停名、中转站悬停标签、固定文件夹名。
    ///
    /// 颜色取文字的**反方向**——深色列黑光晕托白字、浅色列白光晕托黑字，
    /// 和 macOS 自己给桌面图标标签的做法一样。`y = 0`：要的是包住字的一圈，不是投影。
    /// 药丸**里面**的窗口标题不用它，那里靠药丸底解决，两个手段叠加会让小字发糊。
    let labelHalo: DockShadow

    // MARK: 指示器

    /// 图标底下的运行小圆点。浅色下白点在浅玻璃上完全看不见。
    let runningDot: DockTint
    /// 任务条分区之间的竖分隔线。
    let zoneDivider: DockTint

    // MARK: 中转格

    /// 中转格瓷砖的配色。**必须不透明**——它是条上唯一一个不是应用图标的 chip，
    /// 半透明的话玻璃底下一暗就消失（owner 2026-08-16 报过）。见 `ShelfChip.shelfIcon`。
    /// 用 `DOCK_SHELF_TILE=blue|graphite|light` 现场换档，不用重编译。
    let shelfTile: DockShelfTileStyle
    /// 投放命中时底板外扩的光晕。
    let shelfDropGlow: DockTint

    // MARK: 抽屉胶囊

    /// 抽屉为空时的九宫格占位符号。
    let capsuleGlyph: DockTint
    /// 拖卡悬到胶囊上的「微微发光」（去掉过生硬白圈后的替代反馈，owner 2026-06-21）。
    let capsuleStashGlow: DockTint

    // MARK: 固定文件夹 chip

    /// 外部文件拖到文件夹 chip 上（= 移入该文件夹）的命中环。
    let folderDropRing: DockTint
    /// 真缩略图封面的细描边（图标封面不描边）。
    let folderThumbHairline: DockTint

    // MARK: 文件夹 / 中转弹窗

    let popupCellLabel: DockTint
    let popupCellHover: DockTint
    /// 「无法读取文件夹内容」这类主提示。
    let popupPrimaryText: DockTint
    /// 「文件夹是空的」「拖文件到中转格暂存」这类次级提示。
    let popupSecondaryText: DockTint
    let backChipFill: DockTint
    let backChipRim: DockTint
    let backChipGlyph: DockTint

    // MARK: 窗口标题 tooltip

    /// 气泡的底板。**不是 `DockTint`**：白/黑两种基色调不出「近白但不是纯白」。
    ///
    /// 数值是解出来的，不是调出来的。同一颗原生气泡在两种背景上的读数：
    /// 纯黑底 **173**、绿壁纸（约 145）底 **216**。设 `读数 = a·L + (1-a)·背景`：
    /// `173 = a·L`，`216 = 173 + (1-a)·145` → **a = 0.70，L = 246**。
    ///
    /// 也就是说原生是**一块近白的板、透三成**。中间走过一次弯路：只拿到黑底那一个读数时，
    /// 我把 173 当成了它的本色，得出「不透明的中性灰」——方向正好反了。**一个背景解不出
    /// 两个未知数**，以后再量这类半透明面，必须取两种背景。
    let tooltipPlate: DockRGB
    /// 见 `tooltipPlate`：0.70 = 透三成背景。
    let tooltipPlateOpacity: Double
    /// 气泡描边。**必须比填充更亮**——这是玻璃的镜面边，也是「利落」的来源；
    /// 反成暗边等于没有边，气泡会化在背景里（2026-08-17 实测原生剖面）。
    let tooltipRim: DockTint
    let tooltipText: DockTint
    let tooltipShadow: DockShadow

    /// 这一套值到底画不画厚度层。**深色必须是 `false`**——不是"画一层全透明的"，而是
    /// 整层根本不进视图树。`.blur(radius: 0)` 在 SwiftUI 里仍可能触发离屏渲染，
    /// 多一层就可能让深色的逐像素比对出现差异，冻结就不再是严格的。
    var drawsPanelThickness: Bool {
        Self.drawsThickness(highlight: panelInnerHighlight, highlightWidth: panelInnerHighlightWidth,
                            shadow: panelInnerShadow, shadowWidth: panelInnerShadowWidth)
    }

    /// 上面那条判断的纯函数形式（单测直接打这个，不用为了试 4 个值去构造整张 44 字段的表）。
    /// 颜色透明**或**线宽为 0 都等于看不见，两个条件必须同时满足才算"要画"。
    static func drawsThickness(highlight: DockTint, highlightWidth: CGFloat,
                               shadow: DockTint, shadowWidth: CGFloat) -> Bool {
        (highlight.opacity > 0 && highlightWidth > 0) || (shadow.opacity > 0 && shadowWidth > 0)
    }
}

// MARK: - 唯一那套主题值

extension DockThemeTokens {
    /// **唯一那套主题值。** 产品固定浅色（owner 2026-08-16 拍板删掉深色模式），
    /// 所以这里不再有「浅 / 深」两列，名字也不带相对概念——它就是全部。
    ///
    /// 前提是 `AppDelegate` 无条件把 `NSApp.appearance` 钉成 `.aqua`：
    /// `NSVisualEffectView` 和 Liquid Glass 跟的是**窗口的 effectiveAppearance**，
    /// 不看 SwiftUI 环境。系统处于深色而不强制的话，材质会渲染成深色、而这张表是浅色数值，
    /// 结果就是「文字翻了、底板没翻」（实测同屏同壁纸，底板亮度 37.7 对 143.2）。
    static let standard = DockThemeTokens(
        panelRimTop: .white(0.6),
        panelRimBottom: .black(0.1),
        panelRimHighlighted: .black(0.35),
        panelRimLineWidth: 0.5,
        panelRimHighlightedLineWidth: 1,
        // ⚠️ 下面两组是**候选值，默认不生效**——owner 还没验收，按「未验收一律 opt-in」
        // 的规矩由环境变量开（`DOCK_PANEL_THICKNESS=1` / `DOCK_PANEL_SATURATION=candidate`，
        // 见 `DockEffectSwitches`）。数值留在表里是为了调参时只有一张表可改。
        //
        // 厚度感候选：上内沿一条亮线 + 下内沿一道暗收。
        panelInnerHighlight: .white(0.5),
        panelInnerHighlightWidth: 1.5,
        panelInnerHighlightBlur: 2,
        panelInnerShadow: .black(0.06),
        panelInnerShadowWidth: 2,
        panelInnerShadowBlur: 3,
        // 背景提饱和候选。3.0 是实验用的极端值，日常这个量级即可。
        panelBackdropSaturation: 1.25,
        stripShadow: DockShadow(tint: .black(0.14), radius: 8, y: 3),
        popupShadow: DockShadow(tint: .black(0.14), radius: 8, y: 3),
        // 通透度候选待 owner 从对照表里指定；在那之前保持 .popover。
        panelMaterial: .popover,

        // owner 2026-08-16 实机比过 0.10 / 0.12 / 0.13，定 0.13。悬停态 ×1.4。
        chipPillFill: DockTintPair(normal: .white(0.13), emphasized: .white(0.182)),
        chipPillRimTop: DockTintPair(normal: .white(0.55), emphasized: .white(0.7)),
        chipPillRimBottom: .black(0.1),

        labelActive: .black(0.85),
        labelInactive: .black(0.45),
        labelHover: .black(0.75),
        labelSubtitle: .black(0.55),
        labelHalo: DockShadow(tint: .white(0.70), radius: 1.5, y: 0),

        runningDot: .black(0.5),
        zoneDivider: .black(0.12),

        shelfTile: .tray,
        shelfDropGlow: .black(0.1),

        capsuleGlyph: .black(0.55),
        capsuleStashGlow: .black(0.1),

        folderDropRing: .black(0.45),
        folderThumbHairline: .black(0.15),

        popupCellLabel: .black(0.85),
        popupCellHover: .black(0.06),
        popupPrimaryText: .black(0.7),
        popupSecondaryText: .black(0.45),
        backChipFill: .black(0.06),
        backChipRim: .black(0.12),
        backChipGlyph: .black(0.75),

        // 2026-08-17 对着原生截图的边缘剖面定的（黑底、@2x）：
        // 原生是「0 → 191 → **209** → 173 173 173…」——一圈**比填充更亮**的 1px 高光，
        // 然后才是填充 173。我们原来是「59 → 157 → 189 → 202」：没有边、填充还偏白，
        // 于是气泡是「化」在背景里的，owner 说的「不利落 / 软」就是这个。
        //
        // 亮边是玻璃的镜面边，和面板描边同一个道理（见 `panelRimTop`），方向不能反。
        // 246/255 = 0.965，透三成——解方程得来的，见 `tooltipPlate` 的注释。
        tooltipPlate: DockRGB(0.965, 0.965, 0.968),
        tooltipPlateOpacity: 0.70,
        // 起始值，待实测标定（见字段注释里的三个目标点）。
        tooltipRim: .white(0.45),
        tooltipText: .black(0.85),
        tooltipShadow: DockShadow(tint: .black(0.14), radius: 5, y: 2)
    )
}
