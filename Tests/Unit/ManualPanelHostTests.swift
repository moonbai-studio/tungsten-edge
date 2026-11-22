import AppKit
import Combine
import SwiftUI
import XCTest

@MainActor
final class ManualPanelHostTests: XCTestCase {
    private final class TitleModel: ObservableObject {
        @Published var title = "A"
    }

    private struct LabelProbe: View {
        @ObservedObject var store: AppSettingsStore
        @ObservedObject var title: TitleModel

        var body: some View {
            WindowChipTitleLabel(title: title.title, color: .primary, scale: store.dockPanelHeight.scale,
                                 sizing: store.chipLabelSizing, chipID: "probe")
        }
    }

    func testNativeSliderMouseTrackingBracketsDragButNotTrackClick() {
        let panel = makePanel(size: NSSize(width: 320, height: 50))
        panel.alphaValue = 0
        let slider = WindowLabelWidthSliderView()
        slider.frame = NSRect(x: 10, y: 10, width: 300, height: 26)
        panel.contentView?.addSubview(slider)
        panel.orderFront(nil)
        panel.displayIfNeeded()
        defer { panel.orderOut(nil); panel.close() }
        var began = 0
        var ended: [UInt64?] = []
        var updates: [(WindowLabelWidth, UInt64?)] = []
        slider.beginEditing = { began += 1; return UInt64(began) }
        slider.endEditing = { ended.append($0) }
        slider.change = { updates.append(($0, $1)) }
        let cell = slider.cell as! NSSliderCell
        let knob = cell.knobRect(flipped: slider.isFlipped)
        XCTAssertGreaterThan(knob.width, 0)
        let start = slider.convert(CGPoint(x: knob.midX, y: knob.midY), to: nil)
        let finish = CGPoint(x: start.x + 50, y: start.y)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.postEvent(event(.leftMouseUp, finish), atStart: true)
        NSApp.postEvent(event(.leftMouseDragged, finish), atStart: true)
        slider.mouseDown(with: event(.leftMouseDown, start))
        XCTAssertEqual(began, 1)
        XCTAssertEqual(ended, [1])
        XCTAssertFalse(updates.isEmpty)
        XCTAssertTrue(updates.allSatisfy { $0.1 == 1 })

        updates = []
        let track = slider.convert(CGPoint(x: 30, y: knob.midY), to: nil)
        NSApp.postEvent(event(.leftMouseUp, track), atStart: true)
        slider.mouseDown(with: event(.leftMouseDown, track))
        XCTAssertEqual(began, 1)
        XCTAssertEqual(ended, [1])
        XCTAssertFalse(updates.isEmpty)
        XCTAssertTrue(updates.allSatisfy { $0.1 == nil })
    }

    func testLabelWidthCommitsMeasureTheActualLabelSynchronously() {
        let defaultsName = "label-layout-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = AppSettingsStore(defaults: defaults)
        let title = TitleModel()
        title.title = String(repeating: "long title ", count: 20)
        let presentation = PanelHeightResizePresentation()
        let panel = makePanel()
        let content = NSHostingView(rootView: LabelProbe(store: store, title: title)
            .modifier(PanelHeightResizeModifier(presentation: presentation)))
        let host = ManualPanelHost(contentView: content, in: panel)
        defer { panel.close() }
        host.layoutContent()
        let session = TaskbarLayoutSession()
        session.prepare = { presentation.kind = $0; host.layoutContent() }
        session.commit = {
            host.layoutContent()
            XCTAssertEqual(host.fittingSize.width,
                ChipPillMetrics.labelWidth(title: title.title, scale: store.dockPanelHeight.scale,
                                          sizing: store.chipLabelSizing), accuracy: 0.001)
        }
        session.release = { _ in presentation.kind = nil }
        store.layoutChangeHandler = { session.change($0, mutation: $1) }

        let token = session.begin(.labelWidth)
        for width: CGFloat in [40, 240, 80, 141, 140] {
            store.setWindowLabelWidth(WindowLabelWidth(clamping: width))
            XCTAssertEqual(host.fittingSize.width, width)
        }
        session.end(token: token)
        store.setWindowLabelWidth(WindowLabelWidth(clamping: 240))
        store.setWindowLabelWidth(WindowLabelWidth(clamping: 239))
        store.setFixedWindowLabelWidth(true)
        store.setWindowLabelWidth(.default)
        XCTAssertNil(session.active)
        XCTAssertFalse(presentation.isActive)
    }

    func testWidthChangeSettlesAnInFlightTitleAnimationEvenWhenItsTargetIsUnchanged() {
        let defaultsName = "label-animation-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = AppSettingsStore(defaults: defaults)
        let title = TitleModel()
        let presentation = PanelHeightResizePresentation()
        let panel = makePanel(size: NSSize(width: 400, height: 100))
        panel.alphaValue = 0
        var liveWidth: CGFloat = 0
        let content = NSHostingView(rootView: LabelProbe(store: store, title: title)
            .environment(\.labelBoxWidthTick, { _, width in liveWidth = width })
            .modifier(PanelHeightResizeModifier(presentation: presentation)))
        let host = ManualPanelHost(contentView: content, in: panel)
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        host.layoutContent()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        let initialWidth = liveWidth
        title.title = String(repeating: "long title ", count: 20)
        host.layoutContent()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        XCTAssertGreaterThan(liveWidth, initialWidth)
        XCTAssertLessThan(liveWidth, 140, "The probe must be sampling a moving label, not its terminal width")
        let session = TaskbarLayoutSession()
        session.prepare = { presentation.kind = $0; host.layoutContent() }
        session.commit = { host.layoutContent() }
        session.release = { _ in presentation.kind = nil }
        store.layoutChangeHandler = { session.change($0, mutation: $1) }
        store.setFixedWindowLabelWidth(true)
        XCTAssertEqual(liveWidth, 140)
        XCTAssertEqual(host.fittingSize.width, 140)
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            XCTAssertEqual(liveWidth, 140)
        }
    }

    func testLayoutSessionsAreExclusiveAndOldTokensCannotEndTheirSuccessor() {
        let session = TaskbarLayoutSession()
        var events: [String] = []
        session.prepare = { events.append("begin:\($0)") }
        session.commit = { events.append("commit") }
        session.release = { events.append("release:\($0)") }
        let width = session.begin(.labelWidth)
        let height = session.begin(.height)
        XCTAssertGreaterThan(height, width)
        XCTAssertFalse(session.accepts(width, kind: .labelWidth))
        XCTAssertTrue(session.accepts(height, kind: .height))
        XCTAssertEqual(events, ["begin:labelWidth", "commit", "release:labelWidth", "begin:height"])
        session.end(token: width)
        XCTAssertTrue(session.accepts(height, kind: .height))
        session.end(token: height)
        session.end(token: height)
        XCTAssertEqual(Array(events.suffix(2)), ["commit", "release:height"])
        XCTAssertEqual(events.count, 6)
        XCTAssertNil(session.active)
    }

    func testAllDisplayModesAndUnplugReleaseOnlyTheSelectedWakeInhibitorAfterFinalCommit() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                       CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        let modes: [TaskbarScreenPlacement] = [.followMouse, .pinned(.init(uuid: "B", name: "B")),
                                             .allScreens, .allScreensPerDisplay]
        for mode in modes {
            let keys = TaskbarDisplaySet.desiredUnitKeys(placement: mode, connectedKeys: ["A", "B"])
            let frames: [CGRect?] = keys.map { $0 == "B" ? screens[1] : screens[0] }
            let wake = TaskbarLayoutSession.wakeUnitIndex(screenFrames: frames, settingsScreen: screens[1],
                                                         pointer: CGPoint(x: 10, y: 10))!
            XCTAssertEqual(wake, keys.count == 1 ? 0 : 1)
            XCTAssertEqual(TaskbarLayoutSession.wakeUnitIndex(screenFrames: frames, settingsScreen: nil,
                pointer: CGPoint(x: 10, y: 10)), 0)
            var visibility = keys.map { _ in PanelVisibilityState() }
            var finalCommit = false
            let session = TaskbarLayoutSession()
            session.prepare = { _ in visibility[wake].setInhibitor(.interactiveLabelWidth, active: true) }
            session.commit = {
                XCTAssertTrue(visibility[wake].autoHideInhibitors.contains(.interactiveLabelWidth))
                finalCommit = true
            }
            session.release = { _ in
                XCTAssertTrue(finalCommit)
                visibility[wake].setInhibitor(.interactiveLabelWidth, active: false)
            }
            for nextMode in modes {
                let token = session.begin(.labelWidth)
                XCTAssertEqual(visibility.filter { !$0.autoHideInhibitors.isEmpty }.count, 1)
                // Rebuild ends the session even when modes 3 and 4 have identical unit keys.
                session.end()
                _ = TaskbarDisplaySet.desiredUnitKeys(placement: nextMode, connectedKeys: ["A", "B"])
                XCTAssertTrue(visibility.allSatisfy { $0.autoHideInhibitors.isEmpty })
                XCTAssertFalse(session.accepts(token, kind: .labelWidth))
            }
            session.begin(.labelWidth)
            session.end()
            let unplugged = TaskbarDisplaySet.desiredUnitKeys(placement: mode, connectedKeys: ["A"])
            XCTAssertEqual(unplugged.count, 1)
            XCTAssertTrue(visibility.allSatisfy { $0.autoHideInhibitors.isEmpty })
            XCTAssertNil(session.active)
        }
        XCTAssertNil(TaskbarLayoutSession.wakeUnitIndex(screenFrames: [], settingsScreen: nil, pointer: .zero))
    }

    func testQueuedLayoutsAreDiscardedAcrossACompleteShortTransaction() async {
        let presentation = PanelHeightResizePresentation()
        let changes = PassthroughSubject<Bool, Never>()
        var delivered = 0
        let subscription = presentation.deferredChanges(from: changes).sink { _ in delivered += 1 }
        defer { subscription.cancel() }
        changes.send(true)
        presentation.kind = .labelWidth
        // The drag cancellation publishes a reopened slot while teardown is still on the stack.
        changes.send(false)
        presentation.invalidateQueuedLayouts()
        presentation.kind = nil
        await drainMainQueue()
        XCTAssertEqual(delivered, 0)
        changes.send(true)
        await drainMainQueue()
        XCTAssertEqual(delivered, 1)
    }

    func testWidthAndFixedPublishersFilterBeforeQueueingAndAtDelivery() async {
        let defaultsName = "label-publisher-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = AppSettingsStore(defaults: defaults)
        let presentation = PanelHeightResizePresentation()
        var delivered = 0
        let subscription = presentation.deferredChanges(from: Publishers.Merge(
            store.$windowLabelWidth.removeDuplicates().dropFirst().map { _ in () },
            store.$fixedWindowLabelWidth.removeDuplicates().dropFirst().map { _ in () }
        )).sink { delivered += 1 }
        defer { subscription.cancel() }
        store.setWindowLabelWidth(WindowLabelWidth(clamping: 40))
        presentation.kind = .height
        presentation.kind = nil
        await drainMainQueue()
        XCTAssertEqual(delivered, 0)
        presentation.kind = .labelWidth
        store.setFixedWindowLabelWidth(true)
        presentation.kind = nil
        await drainMainQueue()
        XCTAssertEqual(delivered, 0)
        store.setFixedWindowLabelWidth(false)
        await drainMainQueue()
        XCTAssertEqual(delivered, 1)
    }

    private final class ResizeModel: ObservableObject {
        @Published var height: CGFloat = 54
    }

    private final class HeightChangesModel: ObservableObject {
        @Published var height = DockPanelHeight.native
    }

    private struct ResizingProbe: View {
        @ObservedObject var model: ResizeModel

        var body: some View {
            HStack(spacing: 0) {
                Color.red.frame(width: model.height, height: model.height)
                Color.blue.frame(width: model.height * 3, height: model.height)
                    .animation(.linear(duration: 1), value: model.height)
            }
            .padding(20)
        }
    }

    private struct SizedProbeView: View {
        let size: CGSize

        var body: some View {
            Color.clear.frame(width: size.width, height: size.height)
        }
    }

    private final class FittingProbeView: NSView {
        var desiredSize = NSSize(width: 240, height: 80)

        override var fittingSize: NSSize { desiredSize }
        override var intrinsicContentSize: NSSize { desiredSize }
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testHostedViewIsIsolatedFromPanelContentView() {
        let panel = makePanel()
        let content = NSView()

        let host = ManualPanelHost(contentView: content, in: panel)

        XCTAssertTrue(host.contentView === content)
        XCTAssertFalse(panel.contentView === content)
        XCTAssertEqual(panel.contentView?.subviews.count, 1)
        XCTAssertTrue(panel.contentView?.subviews.first === content)
    }

    func testHostedViewTracksPanelContentBounds() {
        let panel = makePanel(size: NSSize(width: 320, height: 100))
        let content = NSView()
        _ = ManualPanelHost(contentView: content, in: panel)

        XCTAssertEqual(content.frame, panel.contentView?.bounds)

        panel.setContentSize(NSSize(width: 640, height: 180))

        XCTAssertEqual(content.frame, panel.contentView?.bounds)
        XCTAssertEqual(content.frame.size, NSSize(width: 640, height: 180))
    }

    func testFittingSizeIsDelegatedToHostedView() {
        let panel = makePanel()
        let content = FittingProbeView()
        let host = ManualPanelHost(contentView: content, in: panel)

        XCTAssertEqual(host.fittingSize, NSSize(width: 240, height: 80))

        content.desiredSize = NSSize(width: 420, height: 160)

        XCTAssertEqual(host.fittingSize, NSSize(width: 420, height: 160))
    }

    func testHostedDesiredSizeChangeDoesNotResizePanel() {
        let panel = makePanel(size: NSSize(width: 500, height: 120))
        let content = FittingProbeView()
        _ = ManualPanelHost(contentView: content, in: panel)
        let originalFrame = panel.frame

        content.desiredSize = NSSize(width: 900, height: 400)
        content.invalidateIntrinsicContentSize()
        content.needsLayout = true
        panel.layoutIfNeeded()

        XCTAssertEqual(panel.frame, originalFrame)
    }

    func testHostingViewSizeChangeDoesNotResizeVisiblePanel() {
        let panel = makePanel(size: NSSize(width: 500, height: 120))
        panel.alphaValue = 0
        let content = NSHostingView(rootView: SizedProbeView(size: CGSize(width: 240, height: 80)))
        _ = ManualPanelHost(contentView: content, in: panel)
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        panel.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let originalFrame = panel.frame

        content.rootView = SizedProbeView(size: CGSize(width: 900, height: 400))
        content.invalidateIntrinsicContentSize()
        content.needsLayout = true
        panel.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        XCTAssertEqual(panel.frame, originalFrame)
    }

    func testZeroSizedPanelStillMeasuresHostingContent() {
        let panel = makePanel(size: .zero)
        let content = NSHostingView(rootView: SizedProbeView(size: CGSize(width: 380, height: 36)))
        let host = ManualPanelHost(contentView: content, in: panel)

        panel.layoutIfNeeded()

        XCTAssertEqual(host.fittingSize, NSSize(width: 380, height: 36))
        XCTAssertEqual(panel.frame.size, .zero)
    }

    func testReplacingPanelContentDetachesHostedViewFromWindow() {
        let panel = makePanel()
        let content = NSView()
        let host = ManualPanelHost(contentView: content, in: panel)
        XCTAssertTrue(content.window === panel)

        panel.contentView = NSView()

        XCTAssertNil(content.window)
        XCTAssertFalse(panel.contentView === content)
        XCTAssertTrue(host.contentView === content)
    }

    func testInteractiveResizeMeasuresPublishedSizeWithoutWaitingForRunLoop() {
        let panel = makePanel(size: NSSize(width: 256, height: 94))
        let model = ResizeModel()
        let presentation = PanelHeightResizePresentation()
        presentation.isActive = true
        let content = NSHostingView(rootView: ResizingProbe(model: model)
            .modifier(PanelHeightResizeModifier(presentation: presentation)))
        let host = ManualPanelHost(contentView: content, in: panel)
        host.layoutContent()

        // Reverse direction repeatedly: neither a stale fitting size nor a label-width
        // animation may put the next panel frame on a different scale from its content.
        for height: CGFloat in [55, 70, 32, 120, 40, 80, 54] {
            model.height = height
            host.layoutContent()
            let expected = NSSize(width: height * 4 + 40, height: height + 40)
            XCTAssertEqual(host.fittingSize, expected)
            panel.setFrame(NSRect(origin: .zero, size: expected), display: false)
            panel.layoutIfNeeded()
            host.layoutContent()
            XCTAssertEqual(content.frame.size, expected)
            XCTAssertEqual(host.fittingSize, expected)
        }
    }

    func testInteractiveHeightChangesAreNotReplayedAfterTheSessionEnds() async {
        let model = HeightChangesModel()
        let presentation = PanelHeightResizePresentation()
        var delivered: [DockPanelHeight] = []
        let subscription = presentation.nonInteractiveHeightChanges(from: model.$height)
            .sink { delivered.append($0) }
        defer { subscription.cancel() }

        presentation.isActive = true
        model.height = DockPanelHeight(clamping: 32)
        model.height = DockPanelHeight(clamping: 120)
        presentation.isActive = false
        await drainMainQueue()
        XCTAssertTrue(delivered.isEmpty)

        model.height = .native
        await drainMainQueue()
        XCTAssertEqual(delivered, [.native])
    }

    func testQueuedOrdinaryHeightChangeStandsDownWhenADragStarts() async {
        let model = HeightChangesModel()
        let presentation = PanelHeightResizePresentation()
        var delivered: [DockPanelHeight] = []
        let subscription = presentation.nonInteractiveHeightChanges(from: model.$height)
            .sink { delivered.append($0) }
        defer { subscription.cancel() }

        model.height = DockPanelHeight(clamping: 80)
        presentation.isActive = true
        await drainMainQueue()
        XCTAssertTrue(delivered.isEmpty)

        presentation.isActive = false
        await drainMainQueue()
        XCTAssertTrue(delivered.isEmpty)
    }

    func testOrdinaryHeightChangesArriveAfterAssignmentWithoutAnInitialLayout() async {
        let model = HeightChangesModel()
        let presentation = PanelHeightResizePresentation()
        var delivered: [DockPanelHeight] = []
        let subscription = presentation.nonInteractiveHeightChanges(from: model.$height)
            .sink { height in
                XCTAssertEqual(model.height, height)
                delivered.append(height)
            }
        defer { subscription.cancel() }

        await drainMainQueue()
        XCTAssertTrue(delivered.isEmpty)
        let height = DockPanelHeight(clamping: 80)
        model.height = height
        model.height = height
        XCTAssertTrue(delivered.isEmpty)
        await drainMainQueue()
        XCTAssertEqual(delivered, [height])
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makePanel(size: NSSize = NSSize(width: 400, height: 100)) -> NonConstrainingPanel {
        NonConstrainingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }
}
