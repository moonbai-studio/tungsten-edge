import AppKit
import SwiftUI

struct WindowLabelWidthSlider: NSViewRepresentable {
    let width: WindowLabelWidth
    let coordinator: SettingsCoordinator

    func makeNSView(context: Context) -> WindowLabelWidthSliderView {
        let slider = WindowLabelWidthSliderView()
        slider.beginEditing = { coordinator.beginWindowLabelWidthEditing() }
        slider.endEditing = { coordinator.endWindowLabelWidthEditing(token: $0) }
        slider.change = { coordinator.setWindowLabelWidth($0, token: $1) }
        slider.setAccessibilityLabel(String(localized: "Window label width"))
        return slider
    }

    func updateNSView(_ slider: WindowLabelWidthSliderView, context: Context) {
        slider.doubleValue = Double(width.points)
    }

    static func dismantleNSView(_ slider: WindowLabelWidthSliderView, coordinator: ()) {
        slider.finishEditing()
        slider.beginEditing = nil
        slider.endEditing = nil
        slider.change = nil
    }
}

final class WindowLabelWidthSliderView: NSSlider {
    var beginEditing: (() -> UInt64?)?
    var endEditing: ((UInt64?) -> Void)?
    var change: ((WindowLabelWidth, UInt64?) -> Void)?
    private var sessionToken: UInt64?
    private var trackingMouse = false

    init() {
        super.init(frame: .zero)
        cell = WindowLabelWidthSliderCell()
        minValue = Double(WindowLabelWidth.minimum)
        maxValue = Double(WindowLabelWidth.maximum)
        doubleValue = Double(WindowLabelWidth.default.points)
        isContinuous = true
        target = self
        action = #selector(valueChanged)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        trackingMouse = true
        let point = convert(event.locationInWindow, from: nil)
        if let cell = cell as? NSSliderCell, cell.knobRect(flipped: isFlipped).contains(point) {
            sessionToken = beginEditing?()
        }
        defer { trackingMouse = false; finishEditing() }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: doubleValue -= 1
        case 124, 126: doubleValue += 1
        default: super.keyDown(with: event); return
        }
        valueChanged()
    }

    @objc private func valueChanged() {
        // A track click is a short commit; a subsequent drag holds a session until mouse-up.
        if trackingMouse, sessionToken == nil, NSApp.currentEvent?.type == .leftMouseDragged {
            sessionToken = beginEditing?()
        }
        let width = WindowLabelWidth(clamping: CGFloat(doubleValue))
        doubleValue = Double(width.points)
        change?(width, sessionToken)
    }

    func finishEditing() {
        if let token = sessionToken { endEditing?(token) }
        sessionToken = nil
    }
}

private final class WindowLabelWidthSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        super.drawBar(inside: rect, flipped: flipped)
        let fraction = (WindowLabelWidth.default.points - WindowLabelWidth.minimum)
            / (WindowLabelWidth.maximum - WindowLabelWidth.minimum)
        let x = rect.minX + rect.width * fraction
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: x, y: flipped ? rect.maxY + 1 : rect.minY - 1))
        marker.line(to: NSPoint(x: x, y: flipped ? rect.maxY + 5 : rect.minY - 5))
        marker.lineWidth = 1
        NSColor.secondaryLabelColor.setStroke()
        marker.stroke()
    }
}
