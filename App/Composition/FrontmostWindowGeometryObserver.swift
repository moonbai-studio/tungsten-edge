import AppKit
@preconcurrency import ApplicationServices
import Foundation

/// Observes geometry changes for only the active app's focused window.
/// AX reads used to retarget the focused element stay off the main thread.
@MainActor
final class FrontmostWindowGeometryObserver {
    enum Event {
        case focusedWindowChanged
        case windowCreated
        case geometryChanged
        case windowDestroyed
    }

    var onEvent: ((Event) -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var focusedElement: AXUIElement?
    private var activePID: pid_t?
    private var observationGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var needsTrailingRefresh = false

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    func start(pid: pid_t?) {
        activate(pid: pid)
    }

    func activate(pid: pid_t?) {
        if activePID == pid, observer != nil {
            requestFocusedRefresh()
            return
        }

        stopObservation()
        activePID = pid
        observationGeneration &+= 1
        guard let pid else { return }

        var newObserver: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &newObserver) == .success,
              let newObserver else { return }

        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.1)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(
            newObserver,
            app,
            kAXFocusedWindowChangedNotification as CFString,
            refcon
        )
        AXObserverAddNotification(
            newObserver,
            app,
            kAXWindowCreatedNotification as CFString,
            refcon
        )
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(newObserver),
            .commonModes
        )
        observer = newObserver
        appElement = app
        requestFocusedRefresh()
    }

    func stop() {
        activePID = nil
        observationGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        needsTrailingRefresh = false
        stopObservation()
        onEvent = nil
    }

    private func stopObservation() {
        if let observer {
            unregisterFocusedElement(observer: observer)
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        appElement = nil
        focusedElement = nil
    }

    private func requestFocusedRefresh() {
        guard let pid = activePID else { return }
        guard refreshTask == nil else {
            needsTrailingRefresh = true
            return
        }

        let generation = observationGeneration
        refreshTask = Task.detached { [weak self] in
            let element = Self.readFocusedWindow(pid: pid)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.finishFocusedRefresh(
                    element,
                    pid: pid,
                    generation: generation
                )
            }
        }
    }

    private func finishFocusedRefresh(
        _ element: AXUIElement?,
        pid: pid_t,
        generation: UInt64
    ) {
        refreshTask = nil
        guard activePID == pid, observationGeneration == generation else {
            if needsTrailingRefresh {
                needsTrailingRefresh = false
                requestFocusedRefresh()
            }
            return
        }

        if let element {
            registerFocusedElement(element)
            // Activation/window-created can arrive before the new window finishes settling.
            // Once the focused element is readable and bound, request one final coalesced scan.
            onEvent?(.focusedWindowChanged)
        } else {
            unregisterFocusedElement(observer: observer)
        }

        if needsTrailingRefresh {
            needsTrailingRefresh = false
            requestFocusedRefresh()
        }
    }

    private func registerFocusedElement(_ element: AXUIElement) {
        guard let observer else { return }
        if let focusedElement, CFEqual(focusedElement, element) { return }

        unregisterFocusedElement(observer: observer)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(
            observer,
            element,
            kAXWindowMovedNotification as CFString,
            refcon
        )
        AXObserverAddNotification(
            observer,
            element,
            kAXWindowResizedNotification as CFString,
            refcon
        )
        AXObserverAddNotification(
            observer,
            element,
            kAXUIElementDestroyedNotification as CFString,
            refcon
        )
        focusedElement = element
    }

    private func unregisterFocusedElement(observer: AXObserver?) {
        guard let observer, let focusedElement else {
            self.focusedElement = nil
            return
        }
        AXObserverRemoveNotification(
            observer,
            focusedElement,
            kAXWindowMovedNotification as CFString
        )
        AXObserverRemoveNotification(
            observer,
            focusedElement,
            kAXWindowResizedNotification as CFString
        )
        AXObserverRemoveNotification(
            observer,
            focusedElement,
            kAXUIElementDestroyedNotification as CFString
        )
        self.focusedElement = nil
    }

    private func handleNotification(_ notification: CFString) {
        let name = notification as String
        if name == (kAXFocusedWindowChangedNotification as String) {
            onEvent?(.focusedWindowChanged)
            requestFocusedRefresh()
        } else if name == (kAXWindowCreatedNotification as String) {
            onEvent?(.windowCreated)
            requestFocusedRefresh()
        } else if name == (kAXWindowMovedNotification as String)
            || name == (kAXWindowResizedNotification as String) {
            onEvent?(.geometryChanged)
        } else if name == (kAXUIElementDestroyedNotification as String) {
            onEvent?(.windowDestroyed)
            unregisterFocusedElement(observer: observer)
            requestFocusedRefresh()
        }
    }

    nonisolated private static func readFocusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
        let value,
        // 跨进程 AX 返回值的类型由对方进程决定，实现有 bug 的 App 可能返回别的 CF 类型。
        // 强制转换在那里会直接 trap，代价是整条任务条崩掉——先验类型再转。
        CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<FrontmostWindowGeometryObserver>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.handleNotification(notification)
        }
    }
}
