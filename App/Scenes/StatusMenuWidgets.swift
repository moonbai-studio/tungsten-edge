import AppKit

// 状态栏菜单里的自定义 NSView 组件（滑块行 / 确认行 / 按钮 / 端点圆点 / 跟踪滑块）。
// 2026-09-05 从 StatusMenuController.swift 搬出：纯搬家，零行为变化。

private enum StatusMenuLayout {
    static let textInsetX: CGFloat = 28
    static let trailingInsetX: CGFloat = 14
}

/// 系统 Dock 滑块的草稿账本。记着**改动前**的值，但只用来判「到底变没变」——
/// 写入失败时回滚到哪一档，由 `SettingsCoordinator.applyNativeDock` 自己重读系统真值决定
/// （界面手里的起点在草稿摊着的那段时间里可能已被 ⌥⌘D 改掉，见那里的注释）。
///
/// 提交源只有确认行一个（滑块本身不自动写系统），`consume()` 的**原子**语义是关键：
/// 它同时承担「值没变就不写」「没有起点就不写」两道闸，重复调用一律拿到 nil。
struct PreferenceSliderCommitTracker {
    private var baseline: Double?
    private var pending: Double?

    var hasPending: Bool { pending != nil }

    /// 记录草稿起点。一轮调整里只认第一次，中途重复调用不覆盖（拖动过程中会反复触发）。
    mutating func begin(currentDelay: Double) {
        if baseline == nil { baseline = currentDelay }
    }

    mutating func stage(_ value: Double) {
        pending = value
    }

    /// 原子取出待提交值。无起点、无变化、或已被别人消费过 → nil。
    mutating func consume() -> (previous: Double, target: Double)? {
        defer {
            baseline = nil
            pending = nil
        }
        guard let baseline, let pending, baseline != pending else { return nil }
        return (baseline, pending)
    }
}


@MainActor
final class PreferenceSliderMenuItemView: NSView {
    /// 每一格变化。即时生效型滑块（钨极，本地值）在这里直接写 store。
    var onDelayChange: ((Double) -> Void)?
    /// 草稿落定（鼠标松手，或键盘每调一格）。确认型滑块用它刷新确认行，
    /// **绝不能拿来写任何持久状态**——草稿的全部意义就是「还没生效」。
    var onDraftChange: ((Double) -> Void)?
    /// 确认提交。**设了它就启用草稿机制**：系统 Dock 每次写入都以 `killall Dock` 收尾、
    /// 屏幕必然闪一下，那一下只能发生在用户主动确认之后。
    var onDelayCommit: ((_ target: Double) -> Void)?

    /// 选中那一端的小字颜色：强调色**带一点透明**（owner 2026-08-03）。
    /// 实心圆点保持满强度，小字比它弱一档——圆点是主标记，小字是它的回声。
    /// 别把这个透明度做到字重上：加粗会让标签宽度变化、两端文字左右跳动。
    static let activeEndpointColor = NSColor.controlAccentColor.withAlphaComponent(0.7)

    /// 未选中那一端的小字颜色。**四个使用点必须都引用它**（左右各一次初始化 + `updateDisplay`
    /// 里左右各一次），散成四份字面量时漏改一份只有「拖到端点再拖回来」才看得见。
    /// 2026-09-01 由三级标签色深一档到这里（owner 嫌整块太灰）。
    /// 端点**圆点**的空心描边不跟着动——那是图形不是文字。
    static let inactiveEndpointColor = NSColor.secondaryLabelColor

    /// 用户已经动过滑块、还没提交。菜单显示后补读系统真值时要看它——正在拖的手不能被跳一下。
    var hasDraft: Bool { commitTracker.hasPending }

    private let accessibilityTitle: String
    private var delay = 0.0
    private var commitTracker = PreferenceSliderCommitTracker()
    private var displayString = "0.0s"
    private let leftEndpointDot = EndpointDotView()
    private let rightEndpointDot = EndpointDotView()
    private let delayLabel = NSTextField(labelWithString: "")
    // 端点小标签只有 34pt 宽（见 layout() 的 sliderSideInset），是刻度标记不是档位名：
    // 完整档位名由中间那行大字（delayLabel ← delayDisplayName）显示，那里有 ~190pt。
    // 英文因此用短词——实测 "Always Visible" 在 9pt 字体下 62.5pt，放不进 34pt。
    private let leftEndpointLabel = NSTextField(labelWithString: String(localized: "Always"))
    private let rightEndpointLabel = NSTextField(labelWithString: String(localized: "Never"))
    private let slider = MenuTrackingSlider()

    init(accessibilityTitle: String) {
        self.accessibilityTitle = accessibilityTitle
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        autoresizingMask = [.width]
        configureSubviews()
        updateDisplay()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityValue() -> Any? {
        displayString
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let width = window?.frame.width, width > frame.width {
            frame.size.width = width
        }
    }

    func sync(delay: Double) {
        let index = AppSettingsStore.sliderIndexFromDelay(delay)
        self.delay = AppSettingsStore.delayFromSliderIndex(index)
        slider.integerValue = index
        updateDisplay()
    }

    private func configureSubviews() {
        wantsLayer = true

        leftEndpointDot.setAccessibilityElement(false)
        addSubview(leftEndpointDot)

        rightEndpointDot.setAccessibilityElement(false)
        addSubview(rightEndpointDot)

        delayLabel.font = .systemFont(ofSize: 11)
        delayLabel.textColor = .secondaryLabelColor
        delayLabel.alignment = .center
        addSubview(delayLabel)

        leftEndpointLabel.font = .systemFont(ofSize: 9)
        leftEndpointLabel.textColor = Self.inactiveEndpointColor
        leftEndpointLabel.alignment = .center
        leftEndpointLabel.setAccessibilityElement(false)
        addSubview(leftEndpointLabel)

        rightEndpointLabel.font = .systemFont(ofSize: 9)
        rightEndpointLabel.textColor = Self.inactiveEndpointColor
        rightEndpointLabel.alignment = .center
        rightEndpointLabel.setAccessibilityElement(false)
        addSubview(rightEndpointLabel)

        slider.minValue = 0
        slider.maxValue = Double(AppSettingsStore.sliderIndexMax)
        slider.integerValue = AppSettingsStore.sliderIndexFromDelay(delay)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.onTrackingStarted = { [weak self] in
            guard let self else { return }
            self.commitTracker.begin(currentDelay: self.delay)
        }
        slider.onTrackingEnded = { [weak self] in
            // 拖动全程不碰确认行：每经过一格就增删一次菜单项会让整个菜单反复重排。
            // 松手才刷新这一次。
            guard let self else { return }
            self.onDraftChange?(self.delay)
        }
        addSubview(slider)

        setAccessibilityRole(.group)
    }

    override func layout() {
        super.layout()
        let dotSize: CGFloat = 8
        let contentX = StatusMenuLayout.textInsetX
        let contentWidth = bounds.width - contentX - StatusMenuLayout.trailingInsetX
        let labelY: CGFloat = 28
        let sliderY: CGFloat = 10

        let sliderSideInset: CGFloat = 34
        let sliderX = contentX + sliderSideInset
        let sliderWidth = max(0, contentWidth - sliderSideInset * 2)
        delayLabel.frame = NSRect(x: sliderX, y: labelY, width: sliderWidth, height: 14)

        let dotY = sliderY + 6
        leftEndpointDot.frame = NSRect(x: contentX + 14, y: dotY, width: dotSize, height: dotSize)
        slider.frame = NSRect(x: sliderX, y: sliderY, width: sliderWidth, height: 20)
        rightEndpointDot.frame = NSRect(x: slider.frame.maxX + 12, y: dotY, width: dotSize, height: dotSize)
        leftEndpointLabel.frame = NSRect(x: contentX, y: labelY, width: sliderSideInset, height: 14)
        rightEndpointLabel.frame = NSRect(x: slider.frame.maxX, y: labelY, width: sliderSideInset, height: 14)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let index = min(max(Int(sender.doubleValue.rounded()), 0), AppSettingsStore.sliderIndexMax)
        sender.integerValue = index
        let previousDelay = delay
        delay = AppSettingsStore.delayFromSliderIndex(index)
        updateDisplay()
        onDelayChange?(delay)

        guard onDelayCommit != nil else { return }
        // 键盘 / VoiceOver 调整不经过 mouseDown，没有 tracking 起点，这里补一个
        // （鼠标路径里 begin 已由 onTrackingStarted 调过，重复调用不覆盖起点）。
        commitTracker.begin(currentDelay: previousDelay)
        commitTracker.stage(delay)
        // 键盘 / VoiceOver 没有「松手」这个时刻，只能当场刷新确认行。它们因此和鼠标
        // 走同一条确认路径，不再需要 debounce 自动提交，也就不会再被静默丢弃。
        if !slider.isMouseTracking {
            onDraftChange?(delay)
        }
    }

    /// 用户按下确认行。**唯一**的提交入口——滑块自己在任何情况下都不写系统。
    func commitDraft() {
        guard let commit = commitTracker.consume() else { return }
        onDelayCommit?(commit.target)
    }

    /// 未确认的草稿作废，滑块拨回草稿开始前的已生效值。
    /// 调用点是**菜单打开时**（`menuWillOpen`），不是关闭时——理由见那里。
    /// 已被 `commitDraft` 消费过就拿到 nil，不会把刚确认的新值又拨回去。
    func discardDraft() {
        guard let discarded = commitTracker.consume() else { return }
        sync(delay: discarded.previous)
    }

    private func updateDisplay() {
        let index = slider.integerValue
        displayString = displayString(for: index)
        delay = AppSettingsStore.delayFromSliderIndex(index)
        delayLabel.stringValue = displayString
        // 两端「常驻/不唤醒」小字恒定可见；选中时圆点变实心、**小字同时染成强调色**
        //（owner 2026-08-03：光靠圆点不够明显）。**只换颜色、不加粗**——加粗会让这一行的
        // 排版宽度变化、两端标签左右跳动。
        // 中间数值文字到达端点时改为隐藏，避免和恒定可见的端点小字重复显示同一个词。
        let isAtLeftEnd = index == 0
        let isAtRightEnd = index == AppSettingsStore.sliderIndexMax
        delayLabel.isHidden = isAtLeftEnd || isAtRightEnd
        leftEndpointDot.isOn = isAtLeftEnd
        rightEndpointDot.isOn = isAtRightEnd
        leftEndpointLabel.textColor = isAtLeftEnd ? Self.activeEndpointColor : Self.inactiveEndpointColor
        rightEndpointLabel.textColor = isAtRightEnd ? Self.activeEndpointColor : Self.inactiveEndpointColor
        setAccessibilityLabel("\(accessibilityTitle)，\(displayString)")
        setAccessibilityValue(displayString)
        slider.displayString = displayString
    }

    /// 与确认行共用一份档位口径，免得确认行说的和滑块上显示的不是一回事。
    private func displayString(for index: Int) -> String {
        AutoHideToggleMenuModel.delayDisplayName(sliderIndex: index)
    }
}

/// 系统 Dock 滑块的确认按钮行。做成**按钮**而不是普通菜单文字行是有意的：
/// 菜单行和它的邻居视觉权重相同，用户刚拖完滑块、视线还在滑块上，很容易整行错过；
/// 一旦错过就直接关菜单，结果是「以为设好了其实没生效」——比原本那一下闪更糟。
/// 按钮的形态本身就在说「这是要点的东西」。
///
/// 左侧那句小灰字不是装饰：`killall Dock` 的闪消除不了，提前说明白它才不显得怪。
@MainActor
final class NativeDockApplyRowView: NSView {
    var onApply: (() -> Void)?

    private let hintLabel = NSTextField(labelWithString: String(localized: "The Dock will restart"))
    private let applyButton = MenuActionButton(title: String(localized: "Apply"))

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 42))
        autoresizingMask = [.width]
        configureSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 按钮标题恒为「应用」，目标档位只走 accessibility：滑块上已经显示过档位，
    /// 但 VoiceOver 用户听不到滑块，这句是他们唯一的信息来源。
    func updateTarget(description: String) {
        applyButton.setAccessibilityLabel(description)
        setAccessibilityLabel(description)
    }

    /// 每次浮出都从静息态开始：上一轮可能停在 hover 态，而菜单重开时鼠标未必还在按钮上。
    func resetInteractionState() {
        applyButton.resetInteractionState()
    }

    private func configureSubviews() {
        wantsLayer = true

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.setAccessibilityElement(false)
        addSubview(hintLabel)

        applyButton.onClick = { [weak self] in
            self?.onApply?()
        }
        addSubview(applyButton)

        setAccessibilityRole(.group)
    }

    override func layout() {
        super.layout()
        let contentX = StatusMenuLayout.textInsetX
        let rightEdge = bounds.width - StatusMenuLayout.trailingInsetX

        let buttonSize = applyButton.intrinsicContentSize
        applyButton.frame = NSRect(
            x: rightEdge - buttonSize.width,
            y: (bounds.height - buttonSize.height) / 2,
            width: buttonSize.width,
            height: buttonSize.height
        )

        let hintWidth = max(0, applyButton.frame.minX - 8 - contentX)
        hintLabel.frame = NSRect(x: contentX, y: (bounds.height - 14) / 2, width: hintWidth, height: 14)
    }

}

/// 菜单里的强调按钮，**自绘**。
///
/// 用 `NSButton` 试过：一旦设了 `bezelColor` 把底色改成强调色，AppKit 自己那套按下变暗
/// 基本被盖住；而菜单打开时 run loop 处在事件追踪模式，标准按钮的 hover / 按下态在这里
/// 都不可靠——按上去像块死图（owner 2026-08-02 报「按钮怎么没有反馈交互」）。
/// 自绘之后三态完全可控：静息 / 悬停（提亮）/ 按下（压暗）。
final class MenuActionButton: NSView {
    var onClick: (() -> Void)?

    private let title: String
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    private static let cornerRadius: CGFloat = 6
    private static let horizontalPadding: CGFloat = 12
    private static let iconTitleGap: CGFloat = 5
    private static let height: CGFloat = 25

    /// 通透而不是实心（owner 2026-08-02 定）：菜单本身是半透明材质，压一块强调色实心
    /// 在上面显得又厚又重。改成淡强调色底 + 强调色字，颜色还在、分量降下来。
    private static let restingAlpha: CGFloat = 0.16
    private static let hoverAlpha: CGFloat = 0.30
    private static let pressedAlpha: CGFloat = 0.42

    init(title: String) {
        self.title = title
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 92, height: Self.height))
        wantsLayer = true

        // 字重用常规（owner 2026-08-02 定）；文字取强调色本身而不是白色——
        // 白字要靠实心底才立得住，通透底上只有强调色字才够清楚。
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .controlAccentColor
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)

        iconView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        iconView.contentTintColor = .controlAccentColor
        iconView.setAccessibilityElement(false)
        addSubview(iconView)

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let titleWidth = titleLabel.intrinsicContentSize.width
        let iconWidth = iconView.image?.size.width ?? 0
        return NSSize(
            width: Self.horizontalPadding * 2 + iconWidth + Self.iconTitleGap + titleWidth,
            height: Self.height
        )
    }

    /// 菜单里的自定义 view 不属于 key window，不重写这个第一次点击会被整个吞掉——
    /// 用户会以为按钮坏了。`MenuTrackingSlider` 同理。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 子视图（文字、图标）不能把鼠标事件截走，否则按钮中间一块点不动。
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    func resetInteractionState() {
        isHovering = false
        isPressed = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways`：菜单面板不是 key window，`.activeInKeyWindow` 在这里永远不触发。
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// 菜单事件追踪期间 `mouseUp` 不会自然回到这里，必须自己跑一轮 tracking——
    /// 这和 `MenuTrackingSlider` 靠 `super.mouseDown` 阻塞到松手是同一个道理。
    /// 期间跟踪指针在不在按钮内：拖出去再松手 = 取消，和系统按钮的行为一致。
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        var releasedInside = true

        window?.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { trackedEvent, stop in
            guard let trackedEvent else {
                stop.pointee = true
                return
            }
            let local = self.convert(trackedEvent.locationInWindow, from: nil)
            releasedInside = self.bounds.contains(local)
            self.isPressed = releasedInside
            if trackedEvent.type == .leftMouseUp {
                stop.pointee = true
            }
        }

        isPressed = false
        isHovering = releasedInside
        if releasedInside {
            onClick?()
        }
    }

    /// 单测入口：真实路径是上面那轮 tracking loop，测试环境跑不了事件循环。
    func performClickForTesting() {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 三态只改透明度，不改色相：底始终是同一个强调色，按下去只是"更实"一点。
        let alpha: CGFloat
        if isPressed {
            alpha = Self.pressedAlpha
        } else if isHovering {
            alpha = Self.hoverAlpha
        } else {
            alpha = Self.restingAlpha
        }
        let shape = NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
        shape.fill()
    }

    override func layout() {
        super.layout()
        let iconSize = iconView.image?.size ?? .zero
        let titleSize = titleLabel.intrinsicContentSize
        let contentWidth = iconSize.width + Self.iconTitleGap + titleSize.width
        let startX = (bounds.width - contentWidth) / 2

        iconView.frame = NSRect(
            x: startX,
            y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        titleLabel.frame = NSRect(
            x: iconView.frame.maxX + Self.iconTitleGap,
            y: (bounds.height - titleSize.height) / 2,
            width: titleSize.width,
            height: titleSize.height
        )
    }
}

final class EndpointDotView: NSView {
    var isOn = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(ovalIn: rect)
        (isOn ? NSColor.controlAccentColor : .clear).setFill()
        path.fill()
        (isOn ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

final class MenuTrackingSlider: NSSlider {
    var displayString = "0.0s"
    var onTrackingStarted: (() -> Void)?
    var onTrackingEnded: (() -> Void)?
    /// `mouseDown` 在拖动全程不返回，因此这个标志就是「当前是不是鼠标拖动」的准确答案，
    /// 用来把键盘 / 辅助功能路径分流到 debounce 提交。
    private(set) var isMouseTracking = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isMouseTracking = true
        onTrackingStarted?()
        super.mouseDown(with: event)
        isMouseTracking = false
        onTrackingEnded?()
    }

    override func accessibilityValue() -> Any? {
        displayString
    }
}
