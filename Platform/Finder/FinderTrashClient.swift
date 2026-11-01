import AppKit
import Carbon
import OSLog

final class FinderTrashClient: FinderTrashClienting {
    private let stateQueue = DispatchQueue(label: "com.tungsten.edge.trash-state", qos: .utility)
    /// Dedicated and serial: an interactive empty blocks here until Finder's own dialog closes
    /// (up to 600s), which must never hold a thread of the shared user-action queue.
    private let commandQueue = DispatchQueue(label: "com.tungsten.edge.trash-command", qos: .userInitiated)
    /// Listing, reveal and the window open: off `stateQueue` so a slow listing never delays the
    /// icon's count reads, off `commandQueue` so none of them queues behind an interactive empty.
    private let listQueue = DispatchQueue(label: "com.tungsten.edge.trash-list", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private static let logger = Logger(subsystem: "com.caye.macosdockcc.v2", category: "FinderTrash")

    private func currentGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func cancelPending() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
    }

    func permission(ask: Bool, completion: @escaping @MainActor (FinderAutomationStatus) -> Void) {
        let gen = currentGeneration()
        stateQueue.async { [self] in
            guard currentGeneration() == gen else {
                DispatchQueue.main.async { completion(.unavailable) }
                return
            }
            let raw = FinderAutomationPermission.status(askUserIfNeeded: ask)
            Self.logger.info("废纸篓授权检查 ask=\(ask) status=\(raw)")
            DispatchQueue.main.async { completion(FinderAutomationStatus(osStatus: raw)) }
        }
    }

    func count(completion: @escaping @MainActor (FinderTrashOutcome) -> Void) {
        let gen = currentGeneration()
        stateQueue.async { [self] in
            guard currentGeneration() == gen else {
                DispatchQueue.main.async { completion(.cancelled) }
                return
            }
            guard let trash = Self.trashObject() else {
                DispatchQueue.main.async { completion(.failed(-1700)) }
                return
            }
            let event = Self.event(eventClass: FinderTrashEvent.core, id: FinderTrashEvent.count)
            event.setParam(trash, forKeyword: keyDirectObject)
            event.setParam(NSAppleEventDescriptor(typeCode: FinderTrashEvent.itemClass),
                           forKeyword: keyAEObjectClass)
            let outcome = Self.send(event, options: FinderTrashEvent.countOptions, timeout: 5, isCount: true)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    func empty(interactive: Bool, completion: @escaping @MainActor (FinderTrashOutcome) -> Void) {
        let gen = currentGeneration()
        commandQueue.async { [self] in
            guard currentGeneration() == gen else {
                DispatchQueue.main.async { completion(.cancelled) }
                return
            }
            let event = Self.event(eventClass: FinderTrashEvent.finder, id: FinderTrashEvent.empty)
            let options = interactive ? FinderTrashEvent.emptyInteractiveOptions : FinderTrashEvent.emptyOptions
            let outcome = Self.send(event, options: options, timeout: interactive ? 600 : 30, isCount: false)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Finder's `delete` of the dropped items (Move to Trash). Same queue and interaction ladder as
    /// `empty`: a prompt Finder needs (an administrator password for an app installed by another
    /// user) answers -1713 without interaction and is resent with it. The non-interactive timeout is
    /// generous because a large bundle on a slow disk is still a single reply.
    func delete(_ urls: [URL], interactive: Bool, completion: @escaping @MainActor (FinderTrashOutcome) -> Void) {
        let gen = currentGeneration()
        commandQueue.async { [self] in
            guard currentGeneration() == gen else {
                DispatchQueue.main.async { completion(.cancelled) }
                return
            }
            let items = NSAppleEventDescriptor.list()
            for (index, url) in urls.enumerated() {
                items.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1)
            }
            let event = Self.event(eventClass: FinderTrashEvent.core, id: FinderTrashEvent.delete)
            event.setParam(items, forKeyword: keyDirectObject)
            let options = interactive ? FinderTrashEvent.emptyInteractiveOptions : FinderTrashEvent.emptyOptions
            let outcome = Self.send(event, options: options, timeout: interactive ? 600 : 120, isCount: false)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    func activateFinder(completion: @escaping @MainActor () -> Void) {
        let gen = currentGeneration()
        commandQueue.async { [self] in
            if currentGeneration() == gen {
                let event = Self.event(eventClass: 0x6d697363, id: 0x61637476)
                _ = Self.send(event, options: FinderTrashEvent.countOptions, timeout: 5, isCount: false)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Opens Finder's Trash window: `odoc` on Finder's `trash` object first, because that window is
    /// Finder's merged view (the home Trash plus every volume's `.Trashes/<uid>`), while a window on
    /// the `~/.Trash` folder shows the home Trash alone — a user with a volume's files in the Trash
    /// saw 4 items where the Dock's Trash showed 38. The folder open stays as the fallback for a
    /// refused event (Automation denied, Finder's -8072). A timed-out event gets no fallback: Finder
    /// usually opens the window late, and a second open would make two. Never activates Finder on
    /// either path: activation also raises Finder's last-used window over the current app; bringing
    /// the Trash window forward is the caller's job. Off the main thread: the event waits for its
    /// reply, and the LaunchServices lookup and the open request both block (with Finder loaded the
    /// first open of a process kept the main thread from reaching the open call for ~1.9s).
    func openTrash() {
        let gen = currentGeneration()
        listQueue.async { [self] in
            guard currentGeneration() == gen else { return }
            let startedAt = Date()
            if let trash = Self.trashObject() {
                let event = Self.event(eventClass: FinderTrashEvent.application, id: FinderTrashEvent.openDocuments)
                event.setParam(trash, forKeyword: keyDirectObject)
                let outcome = Self.send(event, options: FinderTrashEvent.countOptions, timeout: 5, isCount: false)
                Self.logger.info("打开废纸篓 odoc issuedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) outcome=\(String(describing: outcome), privacy: .public)")
                switch outcome {
                case .succeeded, .timedOut, .cancelled: return
                default: break
                }
            }
            guard currentGeneration() == gen else { return }
            openHomeTrashFolder(startedAt: startedAt)
        }
    }

    /// Fallback: Finder opens the `~/.Trash` folder itself (no Automation consent needed), without
    /// activating. This window shows the home Trash only, see `openTrash`.
    private func openHomeTrashFolder(startedAt: Date) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            Self.logger.error("open trash folder failed: Finder not found")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: finderURL, configuration: configuration) { _, error in
            Self.logger.info("打开废纸篓文件夹 issuedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// `URL of every item of trash`, one round trip (a loaded Finder takes ~1s). nil = Finder did not
    /// answer or refused; an empty Trash is `[]`.
    func listItemURLs(completion: @escaping @MainActor ([String]?) -> Void) {
        let gen = currentGeneration()
        listQueue.async { [self] in
            guard currentGeneration() == gen,
                  let trash = Self.trashObject(),
                  let every = Self.everyItem(of: trash),
                  let urls = Self.propertySpecifier(FinderTrashEvent.urlProperty, of: every) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let event = Self.event(eventClass: FinderTrashEvent.core, id: FinderTrashEvent.getData)
            event.setParam(urls, forKeyword: keyDirectObject)
            let strings = Self.sendForStrings(event, timeout: 10)
            Self.logger.info("废纸篓列表 count=\(strings?.count ?? -1)")
            guard currentGeneration() == gen else { return }
            DispatchQueue.main.async { completion(strings) }
        }
    }

    /// Finder's `reveal`: selects the item in the Trash window without activating Finder — the only
    /// scriptable road to "put back" (the user presses ⌘⌫ there). Bringing that window forward is
    /// the caller's job, as with `openTrash`.
    func reveal(_ url: URL) {
        let gen = currentGeneration()
        listQueue.async { [self] in
            guard currentGeneration() == gen else { return }
            let event = Self.event(eventClass: FinderTrashEvent.miscellaneous, id: FinderTrashEvent.reveal)
            event.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: keyDirectObject)
            _ = Self.send(event, options: FinderTrashEvent.countOptions, timeout: 5, isCount: false)
        }
    }

    private static func event(eventClass: UInt32, id: UInt32) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: eventClass, eventID: id,
                              targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
                              returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    /// `nil` when the coercion fails; this runs off the main thread, so it must never trap.
    private static func trashObject() -> NSAppleEventDescriptor? {
        propertySpecifier(FinderTrashEvent.trashProperty, of: .null())
    }

    private static func propertySpecifier(_ property: UInt32, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        objectSpecifier(desiredClass: typeProperty, form: OSType(formPropertyID),
                        data: NSAppleEventDescriptor(typeCode: property), container: container)
    }

    /// `every item of <container>`. The ordinal's bytes are the OSType in **native** order — that is
    /// what AppleScript itself sends (`AEDebugSends`); big-endian bytes make Finder answer -1728.
    private static func everyItem(of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        var ordinal = FinderTrashEvent.absoluteAll
        let data = Data(bytes: &ordinal, count: MemoryLayout<UInt32>.size)
        guard let all = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal), data: data) else { return nil }
        return objectSpecifier(desiredClass: FinderTrashEvent.itemClass, form: OSType(formAbsolutePosition),
                               data: all, container: container)
    }

    private static func objectSpecifier(desiredClass: UInt32, form: OSType, data: NSAppleEventDescriptor,
                                        container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: desiredClass), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: typeObjectSpecifier)
    }

    /// Reply → list of strings. Finder may answer a single item as a bare string, and an error
    /// number in the reply is a failure even though the send succeeded.
    private static func sendForStrings(_ event: NSAppleEventDescriptor, timeout: TimeInterval) -> [String]? {
        do {
            let reply = try event.sendEvent(options: FinderTrashEvent.countOptions, timeout: timeout)
            if let error = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, error != 0 {
                logger.info("废纸篓列表失败 code=\(error)")
                return nil
            }
            guard let list = reply.paramDescriptor(forKeyword: keyDirectObject) else { return nil }
            guard list.descriptorType == DescType(typeAEList) else {
                return list.stringValue.map { [$0] } ?? []
            }
            guard list.numberOfItems > 0 else { return [] }
            return (1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue }
        } catch {
            logger.info("废纸篓列表发送失败 code=\((error as NSError).code)")
            return nil
        }
    }

    private static func send(_ event: NSAppleEventDescriptor, options: NSAppleEventDescriptor.SendOptions,
                             timeout: TimeInterval, isCount: Bool) -> FinderTrashOutcome {
        do {
            let reply = try event.sendEvent(options: options, timeout: timeout)
            let error = reply.paramDescriptor(forKeyword: keyErrorNumber).map { Int($0.int32Value) }
            let integer = reply.paramDescriptor(forKeyword: keyDirectObject)?
                .coerce(toDescriptorType: typeSInt32).map { Int($0.int32Value) }
            let outcome = FinderTrashReply.parse(isCount: isCount, sendError: nil, replyError: error,
                                                integer: integer, hasReply: true)
            logger.info("废纸篓回复 count=\(isCount) outcome=\(String(describing: outcome), privacy: .public)")
            return outcome
        } catch {
            let code = (error as NSError).code
            logger.info("废纸篓发送失败 count=\(isCount) code=\(code)")
            return FinderTrashReply.parse(isCount: isCount, sendError: code, replyError: nil,
                                         integer: nil, hasReply: false)
        }
    }
}
