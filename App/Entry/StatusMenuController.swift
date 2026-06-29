import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let store: AppSettingsStore
    private let onShowDebugConsole: () -> Void
    private let onExportDebugSnapshot: () -> Void
    private let onQuit: () -> Void

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let launchAtLoginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let singleDisplayItem = NSMenuItem(title: "单屏显示", action: #selector(selectSingleDisplay), keyEquivalent: "")
    private let multipleDisplayItem = NSMenuItem(title: "多屏显示", action: #selector(selectMultipleDisplay), keyEquivalent: "")
    private let nativeDockSliderView: PreferenceSliderMenuItemView
    private let edgeSliderView: PreferenceSliderMenuItemView

    init(store: AppSettingsStore,
         onShowDebugConsole: @escaping () -> Void,
         onExportDebugSnapshot: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.store = store
        self.onShowDebugConsole = onShowDebugConsole
        self.onExportDebugSnapshot = onExportDebugSnapshot
        self.onQuit = onQuit
        nativeDockSliderView = PreferenceSliderMenuItemView(title: "自动隐藏系统 dock 栏")
        edgeSliderView = PreferenceSliderMenuItemView(title: "自动隐藏 Tungsten Edge 钨极")
        super.init()
        configureStatusItem()
        configureMenu()
        refreshCheckmarks()
        nativeDockSliderView.sync(delay: store.nativeDockAutoHideDelay)
        edgeSliderView.sync(delay: store.edgeAutoHideDelay)
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.offgrid.fill", accessibilityDescription: "Tungsten Edge")
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        let displayMenu = NSMenu()
        singleDisplayItem.target = self
        multipleDisplayItem.target = self
        displayMenu.addItem(singleDisplayItem)
        displayMenu.addItem(multipleDisplayItem)
        let displayItem = NSMenuItem(title: "多显示器策略", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        menu.addItem(.separator())

        nativeDockSliderView.onDelayChange = { [weak store] delay in
            store?.setNativeDockAutoHideDelay(delay)
        }
        let nativeDockItem = NSMenuItem()
        nativeDockItem.view = nativeDockSliderView
        menu.addItem(nativeDockItem)

        edgeSliderView.onDelayChange = { [weak store] delay in
            store?.setEdgeAutoHideDelay(delay)
        }
        let edgeItem = NSMenuItem()
        edgeItem.view = edgeSliderView
        menu.addItem(edgeItem)
        menu.addItem(.separator())

        #if DEBUG
        let debugMenu = NSMenu()
        let showDebug = NSMenuItem(title: "显示调试台", action: #selector(showDebugConsole), keyEquivalent: "")
        showDebug.target = self
        debugMenu.addItem(showDebug)
        let exportSnapshot = NSMenuItem(title: "导出任务条快照", action: #selector(exportDebugSnapshot), keyEquivalent: "")
        exportSnapshot.target = self
        debugMenu.addItem(exportSnapshot)
        let debugItem = NSMenuItem(title: "调试", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu
        menu.addItem(debugItem)
        #endif

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Tungsten Edge 钨极", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshCheckmarks()
        nativeDockSliderView.sync(delay: store.nativeDockAutoHideDelay)
        edgeSliderView.sync(delay: store.edgeAutoHideDelay)
    }

    private func refreshCheckmarks() {
        launchAtLoginItem.state = store.launchAtLogin ? .on : .off
        singleDisplayItem.state = store.displayMode == .single ? .on : .off
        multipleDisplayItem.state = store.displayMode == .multiple ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        store.setLaunchAtLogin(!store.launchAtLogin)
        refreshCheckmarks()
    }

    @objc private func selectSingleDisplay() {
        store.setDisplayMode(.single)
        refreshCheckmarks()
    }

    @objc private func selectMultipleDisplay() {
        store.setDisplayMode(.multiple)
        refreshCheckmarks()
    }

    @objc private func showDebugConsole() { onShowDebugConsole() }
    @objc private func exportDebugSnapshot() { onExportDebugSnapshot() }
    @objc private func quit() { onQuit() }
}

@MainActor
final class PreferenceSliderMenuItemView: NSView {
    var onDelayChange: ((Double) -> Void)?

    private let title: String
    private var delay = 0.0
    private var displayString = "0.0s"
    private let leftEndpointDot = EndpointDotView()
    private let rightEndpointDot = EndpointDotView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let delayLabel = NSTextField(labelWithString: "")
    private let slider = MenuTrackingSlider()

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 72))
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

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        delayLabel.font = .systemFont(ofSize: 11)
        delayLabel.textColor = .secondaryLabelColor
        delayLabel.alignment = .center
        addSubview(delayLabel)

        slider.minValue = 0
        slider.maxValue = Double(AppSettingsStore.sliderIndexMax)
        slider.integerValue = AppSettingsStore.sliderIndexFromDelay(delay)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        addSubview(slider)

        setAccessibilityRole(.group)
    }

    override func layout() {
        super.layout()
        let marginX: CGFloat = 14
        let dotSize: CGFloat = 8
        let titleY = bounds.height - 28
        let labelY = bounds.height - 48
        let sliderY: CGFloat = 10
        titleLabel.frame = NSRect(x: marginX, y: titleY, width: bounds.width - marginX * 2, height: 20)

        let sliderX = marginX + 34
        let sliderWidth = bounds.width - marginX * 2 - 68
        delayLabel.frame = NSRect(x: sliderX, y: labelY, width: sliderWidth, height: 14)

        let dotY = sliderY + 6
        leftEndpointDot.frame = NSRect(x: marginX + 14, y: dotY, width: dotSize, height: dotSize)
        slider.frame = NSRect(x: sliderX, y: sliderY, width: sliderWidth, height: 20)
        rightEndpointDot.frame = NSRect(x: slider.frame.maxX + 12, y: dotY, width: dotSize, height: dotSize)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let index = min(max(Int(sender.doubleValue.rounded()), 0), AppSettingsStore.sliderIndexMax)
        sender.integerValue = index
        delay = AppSettingsStore.delayFromSliderIndex(index)
        updateDisplay()
        onDelayChange?(delay)
    }

    private func updateDisplay() {
        let index = slider.integerValue
        displayString = displayString(for: index)
        delay = AppSettingsStore.delayFromSliderIndex(index)
        titleLabel.stringValue = title
        delayLabel.stringValue = displayString
        leftEndpointDot.isOn = index == 0
        rightEndpointDot.isOn = index == AppSettingsStore.sliderIndexMax
        setAccessibilityLabel("\(title)，\(displayString)")
        setAccessibilityValue(displayString)
        slider.displayString = displayString
    }

    private func displayString(for index: Int) -> String {
        switch index {
        case 0:
            return "常驻"
        case AppSettingsStore.sliderIndexMax:
            return "不唤醒"
        default:
            return String(format: "%.1fs", AppSettingsStore.delayFromSliderIndex(index))
        }
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityValue() -> Any? {
        displayString
    }
}
