import AppKit
import Combine
import UniformTypeIdentifiers

protocol FinderTrashClienting {
    func permission(ask: Bool, completion: @escaping @MainActor (FinderAutomationStatus) -> Void)
    func count(completion: @escaping @MainActor (FinderTrashOutcome) -> Void)
    func empty(interactive: Bool, completion: @escaping @MainActor (FinderTrashOutcome) -> Void)
    func delete(_ urls: [URL], interactive: Bool, completion: @escaping @MainActor (FinderTrashOutcome) -> Void)
    func activateFinder(completion: @escaping @MainActor () -> Void)
    func openTrash()
    func listItemURLs(completion: @escaping @MainActor ([String]?) -> Void)
    func reveal(_ url: URL)
    func cancelPending()
}

/// What a drop on the Trash needs besides Finder: the fallback move, ejecting, the sound and the
/// alerts. Injected so tests run without touching the disk, the speakers or a modal loop.
struct TrashDropEffects {
    /// Move to Trash without Finder (Automation denied). Calls back once every item was tried.
    let recycle: @Sendable ([URL], @escaping @Sendable () -> Void) -> Void
    let eject: @Sendable (URL) throws -> Void
    /// Whether anything may still be at the URL itself, without following a symlink. Only a definite
    /// "no such file" counts as gone: an unreadable path is treated as still there, so a failed move
    /// never takes the app off the bar.
    let itemExists: @Sendable (URL) -> Bool
    let displayName: @Sendable (URL) -> String
    /// The Dock's drag-to-Trash sound, honouring the user-interface sound setting.
    let playTrashSound: @MainActor () -> Void
    let notify: @MainActor (TrashNotice) -> Void
}

enum TrashNotice: Equatable {
    /// Names of the apps that were left in place because they are running.
    case applicationsInUse([String])
    case ejectFailed(String)
}

@MainActor
final class TrashStateStore: ObservableObject {
    @Published private(set) var isFull = false
    @Published private(set) var status = FinderAutomationStatus.unavailable
    @Published private(set) var isEmptying = false
    /// The popup's contents. Kept across closes: the next open shows it at once while Finder
    /// answers again (~1s when a dead network mount stalls it), and the fading-out popup keeps
    /// rendering it — emptying it on close made the panel collapse to two cells mid-fade (owner: 残影).
    @Published private(set) var listing = TrashListing.idle
    private var listSequence: UInt64 = 0
    /// Whether the popup is showing, so mutations refresh only an open popup.
    private var popupShowing = false

    private let client: FinderTrashClienting
    private let fileTrasher: @Sendable (URL) throws -> Void
    private let workQueue: DispatchQueue
    private let changeStamp: @Sendable () -> TrashChangeStamp
    private let directoryObserver: TrashDirectoryObserving
    /// The stamp the latest activation check saw, and the one in effect when the last count that
    /// Finder actually answered was sent. Equal → Finder is not asked again.
    private var latestStamp: TrashChangeStamp?
    private var countedStamp: TrashChangeStamp?
    /// Asynchronous on purpose: the live alert must run its modal loop outside any main-queue
    /// block (see `TrashStateStore+Live.swift`), so the answer cannot be a return value.
    private let confirmEmpty: @MainActor (@escaping @MainActor (Bool) -> Void) -> Void
    private let beep: () -> Void
    private let effects: TrashDropEffects
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?
    private var reducer = TrashStateReducer()
    private var started = false
    private var enabled = false
    private var observingDirectories = false
    private var lifetime: UInt64 = 0
    private var permissionSequence: UInt64 = 0
    private var readSequence: UInt64 = 0
    private var reading: UInt64?
    private var pending: TrashRefreshSource?
    private var revealOpenedWindow: @MainActor () -> Void = {}

    init(client: FinderTrashClienting, fileTrasher: @escaping @Sendable (URL) throws -> Void,
         workQueue: DispatchQueue, changeStamp: @escaping @Sendable () -> TrashChangeStamp,
         directoryObserver: TrashDirectoryObserving,
         confirmEmpty: @escaping @MainActor (@escaping @MainActor (Bool) -> Void) -> Void,
         beep: @escaping () -> Void, effects: TrashDropEffects, notificationCenter: NotificationCenter) {
        self.client = client
        self.fileTrasher = fileTrasher
        self.workQueue = workQueue
        self.changeStamp = changeStamp
        self.directoryObserver = directoryObserver
        self.confirmEmpty = confirmEmpty
        self.beep = beep
        self.effects = effects
        self.notificationCenter = notificationCenter
    }

    private var active: Bool { started && enabled }

    /// `revealOpenedWindow` brings the Trash window forward after each open; it has no default
    /// because an omission would leave every open behind the current app.
    func start(revealOpenedWindow: @escaping @MainActor () -> Void) {
        guard !started else { return }
        started = true
        self.revealOpenedWindow = revealOpenedWindow
        observer = notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.noteApplicationActivated() }
        }
        updateDirectoryObserver()
        refresh()
    }

    func stop() {
        if let observer { notificationCenter.removeObserver(observer) }
        observer = nil
        started = false
        updateDirectoryObserver()
        invalidate()
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        updateDirectoryObserver()
        if value { refresh() } else { invalidate() }
    }

    private func updateDirectoryObserver() {
        guard observingDirectories != active else { return }
        observingDirectories = active
        if active {
            directoryObserver.start { [weak self] in self?.noteTrashDirectoryChanged() }
        } else {
            directoryObserver.stop()
        }
    }

    private func invalidate() {
        lifetime &+= 1
        permissionSequence &+= 1
        listSequence &+= 1
        listing = .idle
        popupShowing = false
        client.cancelPending()
        reducer.disabled()
        latestStamp = nil
        countedStamp = nil
        pending = nil
        isEmptying = false
        // Keep the physical read occupied until it returns, even across a restart.
    }

    func refresh() { requestRead(.external) }

    /// App activation fires on every front switch — including the ones this app's own minimize
    /// hand-offs cause — and a count parks Finder's main thread in file coordination (0.6–1.2s
    /// with a dead network mount), so every AX call then in flight to Finder times out (-25204):
    /// the Finder minimize/restore lag of 2026-09-16. Finder is therefore asked only when a Trash
    /// directory's date moved since the last count it answered; a failed count leaves the gate open.
    func noteApplicationActivated() { refreshIfTrashChanged() }

    /// A Trash directory changed under the user's hands (Finder ⌘⌫, a put-back, an empty) while
    /// no activation happens — the user stays in Finder. Same gate as activation: the report may
    /// trail an own operation whose post-mutation read already answered.
    func noteTrashDirectoryChanged() { refreshIfTrashChanged() }

    private func refreshIfTrashChanged() {
        guard active else { return }
        let life = lifetime
        let stamp = changeStamp
        workQueue.async { [weak self] in
            let current = stamp()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.lifetime == life else { return }
                self.latestStamp = current
                guard current != self.countedStamp else { return }
                self.requestRead(.external)
            }
        }
    }

    private func requestRead(_ source: TrashRefreshSource) {
        guard active else { return }
        if pending != .external { pending = source }
        drainRead()
    }

    private func drainRead() {
        guard active, reading == nil, !reducer.isMutating, let source = pending else { return }
        pending = nil
        readSequence &+= 1
        let request = readSequence
        reading = request
        let life = lifetime
        let epoch = reducer.epoch
        let stampAtSend = latestStamp
        client.permission(ask: false) { [weak self] permission in
            guard let self else { return }
            guard self.active, self.lifetime == life, self.reducer.epoch == epoch else {
                self.finishRead(request)
                return
            }
            guard permission == .granted else {
                self.reducer.readReturned(epoch: epoch, source: source, status: permission, outcome: nil)
                self.publish()
                self.finishRead(request)
                return
            }
            self.client.count { [weak self] outcome in
                guard let self else { return }
                if self.active, self.lifetime == life {
                    if case .count = outcome { self.countedStamp = stampAtSend }
                    self.reducer.readReturned(epoch: epoch, source: source, status: permission, outcome: outcome)
                    self.publish()
                }
                self.finishRead(request)
            }
        }
    }

    private func finishRead(_ request: UInt64) {
        if reading == request { reading = nil }
        drainRead()
    }

    private func publish() {
        if isFull != reducer.isFull { isFull = reducer.isFull }
        if status != reducer.status { status = reducer.status }
    }

    /// Explicit permission requests supersede background permission observations.
    private func obtainPermission(trigger: TrashPermissionTrigger,
                                  completion: @escaping @MainActor (Bool) -> Void) {
        permissionSequence &+= 1
        let sequence = permissionSequence
        let life = lifetime
        reducer.setPermission(status)
        client.permission(ask: false) { [weak self] fresh in
            guard let self, self.active, self.lifetime == life else { return }
            guard self.permissionSequence == sequence else { completion(false); return }
            self.reducer.setPermission(fresh)
            self.publish()
            guard trigger.shouldAskUser(status: fresh) else {
                completion(fresh == .granted)
                return
            }
            self.client.permission(ask: true) { [weak self] result in
                guard let self, self.active, self.lifetime == life else { return }
                guard self.permissionSequence == sequence else { completion(false); return }
                self.reducer.setPermission(result)
                self.publish()
                completion(result == .granted)
            }
        }
    }

    func trash(_ urls: [URL]) {
        guard active, !urls.isEmpty else { return }
        let mutation = reducer.mutationBegan()
        let life = lifetime
        let fileTrasher = fileTrasher
        workQueue.async { [weak self] in
            var successes = 0
            var failed = false
            for url in urls {
                guard Self.canTrash(url) else { failed = true; continue }
                do { try fileTrasher(url); successes += 1 } catch { failed = true }
            }
            let didSucceed = successes > 0
            let hadFailure = failed
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.lifetime == life else { return }
                if hadFailure { self.beep() }
                if didSucceed { self.effects.playTrashSound() }
                if didSucceed, !self.isEmptying {
                    self.obtainPermission(trigger: .ownDrop) { [weak self] _ in
                        self?.endMutation(mutation, direction: true)
                    }
                } else {
                    self.endMutation(mutation, direction: didSucceed ? true : nil)
                }
            }
        }
    }

    /// Apps dropped on the Trash chip, moved by Finder's own `delete`: that is what leaves Finder's
    /// Put Back record and puts up its administrator prompt for an app another user installed. With
    /// Automation denied the move falls back to `effects.recycle`. `completion` gets the items that
    /// are gone from where they were — success is read off the disk, not the reply, because Finder
    /// may move part of a list. Running apps never get here (`TrashDropPlan`).
    func trashApplications(_ urls: [URL], completion: @escaping @MainActor ([URL]) -> Void) {
        guard active, !urls.isEmpty else { return }
        let mutation = reducer.mutationBegan()
        let life = lifetime
        obtainPermission(trigger: .ownDrop) { [weak self] granted in
            guard let self, self.active, self.lifetime == life else { return }
            if granted {
                self.sendDelete(urls, mutation: mutation, life: life, interactive: false, completion: completion)
            } else {
                self.recycleApplications(urls, reportingOver: urls, mutation: mutation, life: life, completion: completion)
            }
        }
    }

    private func sendDelete(_ urls: [URL], mutation: UInt64, life: UInt64, interactive: Bool,
                            completion: @escaping @MainActor ([URL]) -> Void) {
        let permissionVersion = permissionSequence
        client.delete(urls, interactive: interactive) { [weak self] outcome in
            guard let self, self.active, self.lifetime == life else { return }
            if outcome == .needsInteraction, !interactive {
                self.client.activateFinder { [weak self] in
                    guard let self, self.active, self.lifetime == life else { return }
                    self.resendDeleteInteractively(urls, mutation: mutation, life: life, completion: completion)
                }
                return
            }
            if self.permissionSequence == permissionVersion, let permission = outcome.permission {
                self.reducer.setPermission(permission)
            }
            switch outcome {
            case .denied, .wouldPrompt, .finderUnavailable:
                self.recycleApplications(urls, reportingOver: urls, mutation: mutation, life: life, completion: completion)
            default:
                // Finder plays the Trash sound for its own move.
                self.finishApplicationTrash(urls, mutation: mutation, life: life, playsSound: false,
                                            reportsFailure: outcome != .cancelled, completion: completion)
            }
        }
    }

    /// Finder may have moved part of the list before it stopped for a prompt; only what is still in
    /// place is sent again, and the result is still counted over the whole drop.
    private func resendDeleteInteractively(_ urls: [URL], mutation: UInt64, life: UInt64,
                                           completion: @escaping @MainActor ([URL]) -> Void) {
        let itemExists = effects.itemExists
        workQueue.async { [weak self] in
            let remaining = urls.filter(itemExists)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.lifetime == life else { return }
                guard !remaining.isEmpty else {
                    return self.finishApplicationTrash(urls, mutation: mutation, life: life, playsSound: false,
                                                       reportsFailure: true, completion: completion)
                }
                let permissionVersion = self.permissionSequence
                self.client.delete(remaining, interactive: true) { [weak self] outcome in
                    guard let self, self.active, self.lifetime == life else { return }
                    if self.permissionSequence == permissionVersion, let permission = outcome.permission {
                        self.reducer.setPermission(permission)
                    }
                    switch outcome {
                    case .denied, .wouldPrompt, .finderUnavailable:
                        self.recycleApplications(remaining, reportingOver: urls, mutation: mutation, life: life,
                                                 completion: completion)
                    default:
                        self.finishApplicationTrash(urls, mutation: mutation, life: life, playsSound: false,
                                                    reportsFailure: outcome != .cancelled, completion: completion)
                    }
                }
            }
        }
    }

    /// `reportingOver` is the whole drop: items Finder already moved before falling back count too.
    private func recycleApplications(_ urls: [URL], reportingOver dropped: [URL], mutation: UInt64, life: UInt64,
                                     completion: @escaping @MainActor ([URL]) -> Void) {
        effects.recycle(urls) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.lifetime == life else { return }
                self.finishApplicationTrash(dropped, mutation: mutation, life: life, playsSound: true,
                                            reportsFailure: true, completion: completion)
            }
        }
    }

    private func finishApplicationTrash(_ urls: [URL], mutation: UInt64, life: UInt64, playsSound: Bool,
                                        reportsFailure: Bool, completion: @escaping @MainActor ([URL]) -> Void) {
        let itemExists = effects.itemExists
        workQueue.async { [weak self] in
            let moved = urls.filter { !itemExists($0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.lifetime == life else { return }
                if reportsFailure, moved.count < urls.count { self.beep() }
                if !moved.isEmpty {
                    if playsSound { self.effects.playTrashSound() }
                    completion(moved)
                }
                self.endMutation(mutation, direction: moved.isEmpty ? nil : true)
            }
        }
    }

    /// Volume roots dropped on the Trash chip are ejected, as on the native Dock. A volume in use
    /// says so instead of failing silently.
    func eject(_ volumes: [URL]) {
        guard active, !volumes.isEmpty else { return }
        let life = lifetime
        let effects = effects
        workQueue.async { [weak self] in
            let failed = volumes.filter { volume in
                do { try effects.eject(volume); return false } catch { return true }
            }.map(effects.displayName)
            guard let first = failed.first else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.lifetime == life else { return }
                self.effects.notify(.ejectFailed(first))
            }
        }
    }

    /// Apps dropped on the Trash while running stay where they are, and the user is told why.
    func noteApplicationsInUse(_ urls: [URL]) {
        guard active, !urls.isEmpty else { return }
        let life = lifetime
        let effects = effects
        workQueue.async { [weak self] in
            let names = urls.map(effects.displayName)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.lifetime == life else { return }
                self.effects.notify(.applicationsInUse(names))
            }
        }
    }

    nonisolated static func canTrash(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isVolumeKey, .volumeURLKey])
        let isApp = values?.contentType?.conforms(to: .application)
            ?? (url.pathExtension.lowercased() == "app")
        guard !isApp, values?.isVolume != true else { return false }
        let normalized = url.standardizedFileURL
        return normalized.path != "/" && normalized != values?.volume?.standardizedFileURL
    }

    func emptyTrash() {
        guard active, !isEmptying else { return }
        isEmptying = true
        let life = lifetime
        obtainPermission(trigger: .emptyCommand) { [weak self] granted in
            guard let self, self.active, self.lifetime == life else { return }
            // obtainPermission discarded any read in flight, so both early exits queue a fresh one.
            guard granted else {
                self.isEmptying = false
                self.openTrash()
                self.requestRead(.external)
                return
            }
            self.confirmEmpty { [weak self] confirmed in
                guard let self, self.active, self.lifetime == life else { return }
                guard confirmed else {
                    self.isEmptying = false
                    self.requestRead(.external)
                    return
                }
                let mutation = self.reducer.mutationBegan()
                self.sendEmpty(mutation: mutation, life: life, interactive: false)
            }
        }
    }

    private func sendEmpty(mutation: UInt64, life: UInt64, interactive: Bool) {
        let permissionVersion = permissionSequence
        client.empty(interactive: interactive) { [weak self] outcome in
            guard let self, self.active, self.lifetime == life else { return }
            if outcome == .needsInteraction, !interactive {
                self.client.activateFinder { [weak self] in
                    guard let self, self.active, self.lifetime == life else { return }
                    self.sendEmpty(mutation: mutation, life: life, interactive: true)
                }
                return
            }
            if self.permissionSequence == permissionVersion, let permission = outcome.permission {
                self.reducer.setPermission(permission)
            }
            if outcome == .denied || outcome == .wouldPrompt { self.openTrash() }
            if outcome != .succeeded && outcome != .cancelled { self.beep() }
            self.isEmptying = false
            self.endMutation(mutation, direction: outcome == .succeeded ? false : nil)
        }
    }

    private func endMutation(_ id: UInt64, direction: Bool?) {
        let source = reducer.mutationEnded(id, successfulDirection: direction)
        publish()
        if let source { requestRead(source) }
        if popupShowing { loadItems() }
    }

    /// The popup's listing. Opening the popup is a deliberate act on the Trash, so a never-asked
    /// user gets the automation prompt here once (`.panelOpened`); denied → `.unavailable` and the
    /// popup keeps only Open in Finder. The permission step discards any read in flight, so a fresh
    /// read follows either way.
    func loadItems() {
        guard active else { return }
        let life = lifetime
        listSequence &+= 1
        let sequence = listSequence
        popupShowing = true
        if case .loaded = listing {} else { listing = .loading }
        obtainPermission(trigger: .panelOpened) { [weak self] granted in
            guard let self, self.active, self.lifetime == life, self.listSequence == sequence else { return }
            guard granted else {
                self.listing = .unavailable
                self.requestRead(.external)
                return
            }
            self.client.listItemURLs { [weak self] urls in
                guard let self, self.active, self.lifetime == life, self.listSequence == sequence else { return }
                self.listing = urls.map { TrashListingPlan.build(urlStrings: $0) } ?? .unavailable
                self.requestRead(.external)
            }
        }
    }

    /// The popup closed: stop any load in flight and stop refreshing on mutations. The listing
    /// itself stays for the fade-out and the next open.
    func clearListing() {
        listSequence &+= 1
        popupShowing = false
    }

    /// Selects one item in the Trash window (Finder's `reveal`, non-activating) and brings that
    /// window forward the way `openTrash` does.
    func revealItem(_ url: URL) {
        guard active else { return }
        client.reveal(url)
        revealOpenedWindow()
    }

    func noteTrashedInApp() {
        guard active else { return }
        let mutation = reducer.mutationBegan()
        endMutation(mutation, direction: true)
    }

    /// Finder opens the window without activating, so every open is followed by bringing that one
    /// window forward.
    func openTrash() {
        guard active else { return }
        client.openTrash()
        revealOpenedWindow()
    }
}
