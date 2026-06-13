import ApplicationServices
import Foundation

private struct AXElementKey: Hashable {
    let e: AXUIElement
    static func == (l: AXElementKey, r: AXElementKey) -> Bool { CFEqual(l.e, r.e) }
    func hash(into h: inout Hasher) { h.combine(CFHash(e)) }
}

final class AppWindowObserver {
    let pid: pid_t
    private var observer: AXObserver?
    private var registeredWindowIDs: Set<CGWindowID> = []
    private var elementToCGID: [AXElementKey: CGWindowID] = [:]

    var onWindowCreated: ((pid_t) -> Void)?
    var onWindowDestroyed: ((pid_t, CGWindowID) -> Void)?
    var onWindowMinimized: ((pid_t, CGWindowID) -> Void)?
    var onWindowDeminiaturized: ((pid_t, CGWindowID) -> Void)?
    var onFocusedWindowChanged: ((pid_t) -> Void)?
    var onTitleChanged: ((pid_t, CGWindowID) -> Void)?

    init(pid: pid_t) {
        self.pid = pid
    }

    deinit {
        stop()
    }

    func start() {
        guard observer == nil, AXIsProcessTrusted() else { return }

        var obs: AXObserver?
        let result = AXObserverCreate(pid, appWindowObserverCallback, &obs)
        guard result == .success, let obs else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(obs, appElement, kAXWindowCreatedNotification as CFString, selfPtr)
        AXObserverAddNotification(obs, appElement, kAXFocusedWindowChangedNotification as CFString, selfPtr)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    func stop() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observer = nil
        }
        registeredWindowIDs.removeAll()
        elementToCGID.removeAll()
    }

    func registerWindow(_ element: AXUIElement, cgWindowID: CGWindowID) {
        guard let obs = observer else { return }
        guard registeredWindowIDs.insert(cgWindowID).inserted else { return }

        elementToCGID[AXElementKey(e: element)] = cgWindowID

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, element, kAXUIElementDestroyedNotification as CFString, selfPtr)
        AXObserverAddNotification(obs, element, kAXWindowMiniaturizedNotification as CFString, selfPtr)
        AXObserverAddNotification(obs, element, kAXWindowDeminiaturizedNotification as CFString, selfPtr)
        AXObserverAddNotification(obs, element, kAXTitleChangedNotification as CFString, selfPtr)
    }

    fileprivate func handleNotification(element: AXUIElement, notification: CFString) {
        let notifStr = notification as String
        if notifStr == (kAXWindowCreatedNotification as String) {
            onWindowCreated?(pid)
        } else if notifStr == (kAXFocusedWindowChangedNotification as String) {
            onFocusedWindowChanged?(pid)
        } else if notifStr == (kAXUIElementDestroyedNotification as String) {
            let key = AXElementKey(e: element)
            if let cgID = AXWindowReader.cgWindowID(for: element) ?? elementToCGID[key] {
                registeredWindowIDs.remove(cgID)
                elementToCGID.removeValue(forKey: key)
                onWindowDestroyed?(pid, cgID)
            }
        } else if notifStr == (kAXWindowMiniaturizedNotification as String) {
            if let cgID = AXWindowReader.cgWindowID(for: element) {
                onWindowMinimized?(pid, cgID)
            }
        } else if notifStr == (kAXWindowDeminiaturizedNotification as String) {
            if let cgID = AXWindowReader.cgWindowID(for: element) {
                onWindowDeminiaturized?(pid, cgID)
            }
        } else if notifStr == (kAXTitleChangedNotification as String) {
            let key = AXElementKey(e: element)
            if let cgID = AXWindowReader.cgWindowID(for: element) ?? elementToCGID[key] {
                onTitleChanged?(pid, cgID)
            }
        }
    }
}

private let appWindowObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let obs = Unmanaged<AppWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    let notif = notification
    let el = element
    DispatchQueue.main.async {
        obs.handleNotification(element: el, notification: notif)
    }
}
