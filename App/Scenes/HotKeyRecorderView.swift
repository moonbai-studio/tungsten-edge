import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 设置窗口里的快捷键录制框。点击进入录制态（「按下新组合…」），按下组合立即上报；
/// Esc、再点一下、失焦或设置窗口失去前台（`SettingsWindowController.windowDidResignKey`）都取消。**固定尺寸**：录制态只换文案不换行高，
/// 设置窗口不用重新量高度（`SettingsWindowController` 的量高规则）。
///
/// 用第一响应者的 `keyDown` 而不是 `NSEvent.addLocalMonitorForEvents`：monitor 要记着拆、
/// 还会截走其它输入框的按键；第一响应者天然只收自己的。录制中 `performKeyEquivalent`
/// 必须返回 true——⌘Q / ⌘W 这类组合先走 key equivalent 通道，不拦会直接触发窗口命令。
struct HotKeyRecorder: NSViewRepresentable {
    let currentGlyphs: String
    let onRecord: (StoredHotKeyShortcut) -> Void
    /// 主键不可展示（表里没有的功能键等）时报给上层弹提示。
    let onRejectKey: () -> Void

    func makeNSView(context: Context) -> HotKeyRecorderNSView {
        let view = HotKeyRecorderNSView()
        view.idleGlyphs = currentGlyphs
        view.onRecord = onRecord
        view.onRejectKey = onRejectKey
        return view
    }

    func updateNSView(_ view: HotKeyRecorderNSView, context: Context) {
        view.idleGlyphs = currentGlyphs
        view.onRecord = onRecord
        view.onRejectKey = onRejectKey
    }
}

final class HotKeyRecorderNSView: NSView {
    var idleGlyphs: String = "" {
        didSet { if !isRecording { label.stringValue = idleGlyphs } }
    }
    var onRecord: ((StoredHotKeyShortcut) -> Void)?
    var onRejectKey: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
        ])
        refreshChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("HotKeyRecorderNSView is code-only") }

    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    /// Focus means "recording", so only a click may give it: left in the key-view loop, the
    /// window hands it focus on open and the next shortcut typed rebinds the hot key.
    override var canBecomeKeyView: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        showPrompt()
        refreshChrome()
        return true
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        let mods = Self.carbonModifiers(from: event.modifierFlags)
        if mods == 0 {
            showPrompt()
        } else {
            label.stringValue = HotKeyGlyphs.modifierString(carbonModifiers: mods)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handleRecordingKey(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        handleRecordingKey(event)
        return true
    }

    private func handleRecordingKey(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            window?.makeFirstResponder(nil)
            return
        }
        let mods = Self.carbonModifiers(from: event.modifierFlags)
        guard let glyphs = HotKeyGlyphs.display(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: mods,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else {
            window?.makeFirstResponder(nil)
            onRejectKey?()
            return
        }
        let stored = StoredHotKeyShortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: mods,
            glyphs: glyphs
        )
        window?.makeFirstResponder(nil)
        onRecord?(stored)
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        label.stringValue = idleGlyphs
        refreshChrome()
    }

    private func showPrompt() {
        label.stringValue = String(localized: "Press new shortcut…")
    }

    // A `CGColor` is resolved once, for the appearance current at that moment: re-resolve under
    // this view's own appearance, and again whenever it changes, or the box keeps the old one.
    private func refreshChrome() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChrome()
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}
