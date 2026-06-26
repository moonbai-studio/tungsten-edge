import AppKit
import SwiftUI

// MARK: - Native right-click menu infrastructure
//
// The chips use a hand-built AppKit `NSMenu` instead of SwiftUI's `.contextMenu`,
// so the「退出 App」/「强制退出」pair can use AppKit's native *alternate item*
// (`isAlternate` + Option modifier): with the menu already open, holding Option
// swaps the visible item live — exactly like the system Dock. SwiftUI's
// `.contextMenu` is a static snapshot once open and cannot do this.

/// An `NSMenuItem` that runs a closure when picked (AppKit needs target/action).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

/// A transparent overlay NSView that provides a native menu on right-click /
/// control-click, while passing every other click through to the SwiftUI chip
/// beneath it (so tap-to-activate and drag-reorder are unaffected).
final class MenuHostNSView: NSView {
    var builder: (() -> NSMenu)?

    // Only claim right-click / control-click; return nil otherwise so the click
    // falls through to the SwiftUI content below this overlay.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil, let e = NSApp.currentEvent else { return nil }
        switch e.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return self
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return e.modifierFlags.contains(.control) ? self : nil
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) { popUp(event) }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { popUp(event) }
        else { super.mouseDown(with: event) }
    }

    private func popUp(_ event: NSEvent) {
        guard let menu = builder?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

struct NativeMenuHost: NSViewRepresentable {
    let builder: () -> NSMenu
    func makeNSView(context: Context) -> MenuHostNSView {
        let v = MenuHostNSView()
        v.builder = builder
        return v
    }
    func updateNSView(_ v: MenuHostNSView, context: Context) {
        v.builder = builder   // keep the closure capturing current SwiftUI state
    }
}

extension View {
    /// Attach a native AppKit right-click menu, rebuilt fresh on each open.
    func nativeContextMenu(_ builder: @escaping () -> NSMenu) -> some View {
        overlay(NativeMenuHost(builder: builder))
    }
}

// MARK: - Shared menu fragments

enum AppMenuBuilder {

    /// Append「退出 App」plus, for non-self apps, the Option-alternate「强制退出」.
    /// The two are an alternate pair: same (empty) key equivalent, the second
    /// `isAlternate` with the Option modifier → live swap while the menu is open.
    static func appendQuitItems(to menu: NSMenu, bundleID: String?, onQuit: @escaping () -> Void) {
        let quit = ClosureMenuItem("退出 App", handler: onQuit)
        quit.keyEquivalentModifierMask = []
        menu.addItem(quit)

        guard let bid = bundleID, bid != Bundle.main.bundleIdentifier else { return }
        let force = ClosureMenuItem("强制退出") {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: bid)
                .first?
                .forceTerminate()
        }
        force.keyEquivalentModifierMask = [.option]
        force.isAlternate = true
        menu.addItem(force)
    }

    /// Finder-only shortcuts at the top of the Finder chip menu, plus a separator.
    static func appendFinderItems(to menu: NSMenu) {
        menu.addItem(ClosureMenuItem("前往文件夹\u{2026}") { triggerFinderShortcut(goToFolder: true) })
        menu.addItem(ClosureMenuItem("连接服务器\u{2026}") { triggerFinderShortcut(goToFolder: false) })
        menu.addItem(.separator())
    }

    // Key codes from HIToolbox/Events.h — defined locally to avoid a Carbon dependency
    private static let keyG: CGKeyCode = 0x05  // kVK_ANSI_G
    private static let keyK: CGKeyCode = 0x28  // kVK_ANSI_K

    private static func triggerFinderShortcut(goToFolder: Bool) {
        guard let finder = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        finder.activate(options: .activateIgnoringOtherApps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let keyCode = goToFolder ? keyG : keyK
            let flags: CGEventFlags = goToFolder ? [.maskCommand, .maskShift] : [.maskCommand]
            for keyDown in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: keyDown)
                e?.flags = flags
                e?.postToPid(finder.processIdentifier)
            }
        }
    }
}
