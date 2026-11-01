import AppKit
import XCTest

@MainActor
final class TrashStateStoreTests: XCTestCase {
    private final class FakeClient: FinderTrashClienting {
        var permissions: [(Bool, @MainActor (FinderAutomationStatus) -> Void)] = []
        var counts: [@MainActor (FinderTrashOutcome) -> Void] = []
        var empties: [(Bool, @MainActor (FinderTrashOutcome) -> Void)] = []
        var activations: [@MainActor () -> Void] = []
        var opens = 0
        var reveals = 0
        var lists: [@MainActor ([String]?) -> Void] = []
        var revealed: [URL] = []
        var asks: [Bool] = []
        func permission(ask: Bool, completion: @escaping @MainActor (FinderAutomationStatus) -> Void) {
            asks.append(ask); permissions.append((ask, completion))
        }
        func count(completion: @escaping @MainActor (FinderTrashOutcome) -> Void) { counts.append(completion) }
        func empty(interactive: Bool, completion: @escaping @MainActor (FinderTrashOutcome) -> Void) {
            empties.append((interactive, completion))
        }
        var deletes: [([URL], Bool, @MainActor (FinderTrashOutcome) -> Void)] = []
        func delete(_ urls: [URL], interactive: Bool, completion: @escaping @MainActor (FinderTrashOutcome) -> Void) {
            deletes.append((urls, interactive, completion))
        }
        func activateFinder(completion: @escaping @MainActor () -> Void) { activations.append(completion) }
        func openTrash() { opens += 1 }
        func listItemURLs(completion: @escaping @MainActor ([String]?) -> Void) { lists.append(completion) }
        func reveal(_ url: URL) { revealed.append(url) }
        func cancelPending() {}
    }

    /// A mutable stamp the store's `@Sendable` reader can see; tests move it to simulate a change.
    private final class StampBox: @unchecked Sendable {
        var value = TrashChangeStamp(marks: ["/trash": Date(timeIntervalSince1970: 1)])
    }

    /// Stands in for the FSEvents watcher: tests fire `onChange` to simulate a Trash change.
    private final class FakeObserver: TrashDirectoryObserving {
        var onChange: (@MainActor () -> Void)?
        var starts = 0
        var stops = 0
        func start(onChange: @escaping @MainActor () -> Void) { starts += 1; self.onChange = onChange }
        func stop() { stops += 1; onChange = nil }
    }

    /// Stands in for the disk, the speakers and the alerts of a drop on the Trash.
    private final class EffectsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _gone = Set<String>()
        private var _recycled: [[URL]] = []
        var sounds = 0
        var notices: [TrashNotice] = []
        var beeps = 0
        /// Paths the disk reports as gone; `recycle` empties every path it is given.
        var gone: Set<String> {
            get { lock.lock(); defer { lock.unlock() }; return _gone }
            set { lock.lock(); _gone = newValue; lock.unlock() }
        }
        var recycled: [[URL]] { lock.lock(); defer { lock.unlock() }; return _recycled }

        var effects: TrashDropEffects {
            TrashDropEffects(
                recycle: { [self] urls, done in
                    lock.lock(); _recycled.append(urls); _gone.formUnion(urls.map(\.path)); lock.unlock()
                    done()
                },
                eject: { url in if url.path.hasSuffix("Busy") { throw CocoaError(.fileWriteNoPermission) } },
                itemExists: { [self] url in !gone.contains(url.path) },
                displayName: { $0.deletingPathExtension().lastPathComponent },
                playTrashSound: { [self] in sounds += 1 },
                notify: { [self] in notices.append($0) })
        }
    }

    private func make(_ client: FakeClient, confirm: @escaping () -> Bool = { true },
                      trasher: @escaping @Sendable (URL) throws -> Void = { _ in },
                      stamps: StampBox = StampBox(), observer: FakeObserver = FakeObserver(),
                      effects: EffectsBox = EffectsBox(),
                      workQueue: DispatchQueue = DispatchQueue(label: "trash-tests", attributes: .concurrent)) -> TrashStateStore {
        let store = TrashStateStore(client: client, fileTrasher: trasher,
            workQueue: workQueue, changeStamp: { stamps.value }, directoryObserver: observer,
            confirmEmpty: { completion in completion(confirm()) },
            beep: { effects.beeps += 1 }, effects: effects.effects, notificationCenter: NotificationCenter())
        store.setEnabled(true)
        store.start(revealOpenedWindow: { client.reveals += 1 })
        addTeardownBlock { @MainActor in store.stop() }
        return store
    }

    private func initialize(_ client: FakeClient, count: Int = 3) {
        client.permissions.removeFirst().1(.granted)
        client.counts.removeFirst()(.count(count))
    }

    func testNoEmptyWithoutConfirmationAndReentryIsBlocked() {
        let client = FakeClient()
        var confirmations = 0
        let store = make(client, confirm: { confirmations += 1; return false })
        initialize(client)
        store.emptyTrash()
        store.emptyTrash()
        XCTAssertEqual(client.permissions.count, 1)
        client.permissions.removeFirst().1(.granted)
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(client.empties.isEmpty)
        XCTAssertFalse(store.isEmptying)
    }

    /// The live alert answers later, from a run-loop block; nothing may be sent before it does,
    /// and a cancel must queue a fresh read because the permission step discarded the one in flight.
    func testPendingConfirmationSendsNothingAndCancelRereads() {
        let client = FakeClient()
        var answer: (@MainActor (Bool) -> Void)?
        let store = TrashStateStore(client: client, fileTrasher: { _ in },
            workQueue: DispatchQueue(label: "trash-tests"), changeStamp: { StampBox().value },
            directoryObserver: FakeObserver(),
            confirmEmpty: { answer = $0 },
            beep: {}, effects: EffectsBox().effects, notificationCenter: NotificationCenter())
        store.setEnabled(true)
        store.start(revealOpenedWindow: { client.reveals += 1 })
        addTeardownBlock { @MainActor in store.stop() }
        initialize(client)
        store.refresh()
        client.permissions.removeFirst().1(.granted)   // count now in flight
        store.emptyTrash()
        client.permissions.removeFirst().1(.granted)   // confirmation now pending
        XCTAssertNotNil(answer)
        XCTAssertTrue(client.empties.isEmpty)
        XCTAssertTrue(store.isEmptying)
        client.counts.removeFirst()(.count(0))
        XCTAssertTrue(store.isFull, "a read overtaken by the permission step must not apply")
        answer?(false)
        XCTAssertTrue(client.empties.isEmpty)
        XCTAssertFalse(store.isEmptying)
        client.permissions.removeFirst().1(.granted)
        client.counts.removeFirst()(.count(0))
        XCTAssertFalse(store.isFull)
    }

    func testSuccessfulEmptyDropsOldCountAndProtectsImmediateRead() {
        let client = FakeClient()
        let store = make(client)
        initialize(client)
        store.refresh()
        client.permissions.removeFirst().1(.granted)
        store.emptyTrash()
        client.permissions.removeFirst().1(.granted)
        XCTAssertFalse(client.empties[0].0)
        client.empties.removeFirst().1(.succeeded)
        XCTAssertFalse(store.isFull)
        client.counts.removeFirst()(.count(5))
        XCTAssertFalse(store.isFull)
        client.permissions.removeFirst().1(.granted)
        client.counts.removeFirst()(.count(5))
        XCTAssertFalse(store.isFull)
        store.refresh()
        client.permissions.removeFirst().1(.granted)
        client.counts.removeFirst()(.count(5))
        XCTAssertTrue(store.isFull)
    }

    func testInteractiveRetryCancelAndTimeout() {
        for outcome in [FinderTrashOutcome.cancelled, .timedOut, .failed(-10000)] {
            let client = FakeClient()
            var confirmations = 0
            let store = make(client, confirm: { confirmations += 1; return true })
            initialize(client)
            store.emptyTrash()
            client.permissions.removeFirst().1(.granted)
            client.empties.removeFirst().1(.needsInteraction)
            XCTAssertEqual(client.activations.count, 1)
            client.activations.removeFirst()()
            XCTAssertTrue(client.empties[0].0)
            client.empties.removeFirst().1(outcome)
            XCTAssertEqual(confirmations, 1)
            XCTAssertFalse(store.isEmptying)
            XCTAssertTrue(store.isFull)
            client.permissions.removeFirst().1(.granted)
            client.counts.removeFirst()(.count(0))
            XCTAssertFalse(store.isFull)
        }
    }

    func testActivationRefreshesCoalesceAndNeverAsk() {
        let client = FakeClient()
        let store = make(client)
        for _ in 0..<3 { store.refresh() }
        XCTAssertEqual(client.permissions.count, 1)
        initialize(client)
        XCTAssertEqual(client.permissions.count, 1)
        initialize(client)
        XCTAssertTrue(client.permissions.isEmpty)
        XCTAssertFalse(client.asks.contains(true))
    }

    /// Activation fires on every front switch, including the ones our own hand-offs cause, and a
    /// count stalls Finder's main thread; so it asks Finder only after a Trash directory's date
    /// moved since the last answered count, and a count Finder did not answer leaves the gate open.
    func testActivationAsksFinderOnlyAfterTrashChanged() async {
        let client = FakeClient()
        let stamps = StampBox()
        let queue = DispatchQueue(label: "trash-tests-serial")
        let store = make(client, stamps: stamps, workQueue: queue)
        initialize(client)
        func activate() async {
            store.noteApplicationActivated()
            let settled = expectation(description: "Stamp compared on main")
            queue.async { DispatchQueue.main.async { settled.fulfill() } }
            await fulfillment(of: [settled], timeout: 3)
        }
        await activate()
        XCTAssertEqual(client.permissions.count, 1, "no answered count carries a stamp yet")
        initialize(client)
        await activate()
        await activate()
        XCTAssertTrue(client.permissions.isEmpty, "unchanged Trash: Finder is not asked")
        stamps.value = TrashChangeStamp(marks: ["/trash": Date(timeIntervalSince1970: 2)])
        await activate()
        XCTAssertEqual(client.permissions.count, 1)
        client.permissions.removeFirst().1(.granted)
        client.counts.removeFirst()(.failed(-1712))
        await activate()
        XCTAssertEqual(client.permissions.count, 1, "an unanswered count must not close the gate")
        initialize(client)
        await activate()
        XCTAssertTrue(client.permissions.isEmpty)
    }

    /// The user stays in Finder and deletes with ⌘⌫: no activation ever fires, so the directory
    /// watcher is the only trigger. It passes the same stamp gate — a report that merely trails an
    /// own operation whose answered count already carries the new stamp sends nothing.
    func testTrashDirectoryChangeAsksFinderThroughTheStampGate() async {
        let client = FakeClient()
        let stamps = StampBox()
        let observer = FakeObserver()
        let queue = DispatchQueue(label: "trash-tests-serial")
        let store = make(client, stamps: stamps, observer: observer, workQueue: queue)
        XCTAssertEqual(observer.starts, 1)
        initialize(client)
        func changed() async {
            observer.onChange?()
            let settled = expectation(description: "Stamp compared on main")
            queue.async { DispatchQueue.main.async { settled.fulfill() } }
            await fulfillment(of: [settled], timeout: 3)
        }
        await changed()
        XCTAssertEqual(client.permissions.count, 1, "no answered count carries a stamp yet")
        initialize(client, count: 0)
        XCTAssertFalse(store.isFull)
        stamps.value = TrashChangeStamp(marks: ["/trash": Date(timeIntervalSince1970: 2)])
        await changed()
        XCTAssertEqual(client.permissions.count, 1, "Finder ⌘⌫ moved the Trash: ask Finder")
        initialize(client, count: 1)
        XCTAssertTrue(store.isFull, "the icon fills without any app switch")
        await changed()
        XCTAssertTrue(client.permissions.isEmpty, "same stamp as the answered count: nothing sent")
        store.setEnabled(false)
        XCTAssertEqual(observer.stops, 1)
        XCTAssertNil(observer.onChange, "a disabled chip stops watching")
        store.setEnabled(true)
        XCTAssertEqual(observer.starts, 2)
        store.stop()
        XCTAssertEqual(observer.stops, 2)
    }

    func testDisabledCallbacksCannotChangePermissionOrSendFollowup() {
        let client = FakeClient()
        let store = make(client)
        initialize(client)
        store.refresh()
        store.setEnabled(false)
        client.permissions.removeFirst().1(.denied)
        XCTAssertEqual(store.status, .granted)
        XCTAssertTrue(store.isFull)
        store.refresh()
        store.emptyTrash()
        XCTAssertTrue(client.permissions.isEmpty)
        store.setEnabled(true)
        initialize(client)
        store.emptyTrash()
        client.permissions.removeFirst().1(.granted)
        client.empties.removeFirst().1(.needsInteraction)
        store.stop()
        client.activations.removeFirst()()
        XCTAssertTrue(client.empties.isEmpty)
    }

    func testOldGrantedCountCannotUndoNewDeniedPermission() {
        let client = FakeClient()
        let store = make(client)
        initialize(client)
        store.refresh()
        client.permissions.removeFirst().1(.granted)
        store.emptyTrash()
        client.permissions.removeFirst().1(.denied)
        client.counts.removeFirst()(.count(8))
        XCTAssertEqual(store.status, .denied)
        XCTAssertFalse(store.isFull)
        XCTAssertTrue(client.empties.isEmpty)
    }

    func testOnlyExplicitEmptyMayAskAndDeniedFallsBackToOpen() {
        let client = FakeClient()
        let store = make(client)
        client.permissions.removeFirst().1(.notDetermined)
        XCTAssertEqual(client.asks, [false])
        store.emptyTrash()
        client.permissions.removeFirst().1(.notDetermined)
        XCTAssertTrue(client.permissions[0].0)
        client.permissions.removeFirst().1(.denied)
        XCTAssertEqual(client.opens, 1)
        // Finder opens it without activating, so the open must bring that window forward.
        XCTAssertEqual(client.reveals, 1)
        XCTAssertTrue(client.empties.isEmpty)
    }

    func testPopupListingAsksOnceAndDeniedLeavesItUnavailable() {
        let client = FakeClient()
        let store = make(client)
        client.permissions.removeFirst().1(.notDetermined)
        store.loadItems()
        XCTAssertEqual(store.listing, .loading)
        client.permissions.removeFirst().1(.notDetermined)
        XCTAssertTrue(client.permissions[0].0)
        client.permissions.removeFirst().1(.granted)
        client.lists.removeFirst()(["file:///Users/me/.Trash/x.txt"])
        XCTAssertEqual(store.listing, .loaded(items: [TrashItem(url: URL(string: "file:///Users/me/.Trash/x.txt")!,
                                                                name: "x.txt", isDirectory: false)], hiddenCount: 0))
        XCTAssertEqual(store.status, .granted)
        // A reveal brings the Trash window forward like an open does.
        store.revealItem(URL(string: "file:///Users/me/.Trash/x.txt")!)
        XCTAssertEqual(client.revealed.count, 1)
        XCTAssertEqual(client.reveals, 1)
        let loaded = store.listing
        store.clearListing()
        // Closed: the listing stays (the fading popup still renders it), but a mutation no longer
        // asks Finder for it.
        XCTAssertEqual(store.listing, loaded)
        client.permissions.removeAll()
        store.noteTrashedInApp()
        XCTAssertTrue(client.lists.isEmpty)
        // The next open shows the last listing at once instead of 正在读取, then refreshes.
        client.permissions.removeAll()
        store.loadItems()
        XCTAssertEqual(store.listing, loaded)
        // Denied: nothing is listed and the popup degrades.
        client.permissions.removeFirst().1(.denied)
        XCTAssertTrue(client.lists.isEmpty)
        XCTAssertEqual(store.listing, .unavailable)
    }

    func testSuccessfulDropAsksAndOldReadCannotClearFullIcon() async {
        let client = FakeClient()
        let trashed = expectation(description: "File action completed")
        let store = make(client, trasher: { _ in trashed.fulfill() })
        client.permissions.removeFirst().1(.notDetermined)
        store.trash([URL(fileURLWithPath: "/tmp/tungsten-trash-test-file")])
        await fulfillment(of: [trashed], timeout: 3)
        // Drain the main-queue completion following the file operation.
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)
        client.permissions.removeFirst().1(.notDetermined)
        XCTAssertTrue(client.permissions[0].0)
        client.permissions.removeFirst().1(.granted)
        XCTAssertTrue(store.isFull)
        client.permissions.removeFirst().1(.granted)
        client.counts.removeFirst()(.count(0))
        XCTAssertTrue(store.isFull)
    }

    func testFirstDropCanRequestPermissionBeforeStartupReadReturns() async {
        let client = FakeClient()
        let trashed = expectation(description: "File trashed")
        let store = make(client, trasher: { _ in trashed.fulfill() })
        store.trash([URL(fileURLWithPath: "/tmp/tungsten-trash-test-file")])
        await fulfillment(of: [trashed], timeout: 3)
        let drained = expectation(description: "Completion delivered")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(client.permissions.count, 2)
        client.permissions.remove(at: 1).1(.notDetermined)
        client.permissions.removeLast().1(.granted)
        XCTAssertTrue(store.isFull)
        client.permissions.removeFirst().1(.denied)
        XCTAssertEqual(store.status, .granted)
        XCTAssertTrue(store.isFull)
    }

    func testOverlappingDropCompletionAfterEmptyUsesAuthoritativeRead() async {
        let client = FakeClient()
        let entered = expectation(description: "File operation in flight")
        let completed = expectation(description: "File operation finished")
        let release = DispatchSemaphore(value: 0)
        let store = make(client, trasher: { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            completed.fulfill()
        })
        initialize(client)
        store.trash([URL(fileURLWithPath: "/tmp/tungsten-trash-test-file")])
        await fulfillment(of: [entered], timeout: 3)
        store.emptyTrash()
        client.permissions.removeFirst().1(.granted)
        client.empties.removeFirst().1(.succeeded)
        XCTAssertTrue(client.counts.isEmpty)
        release.signal()
        await fulfillment(of: [completed], timeout: 3)
        let drained = expectation(description: "Drop completion delivered")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)
        client.permissions.removeFirst().1(.granted)
        client.permissions.removeFirst().1(.granted)
        client.counts.removeFirst()(.count(0))
        XCTAssertFalse(store.isFull)
    }

    func testApplicationAndVolumeRootsCannotReachTrasher() {
        XCTAssertFalse(TrashStateStore.canTrash(URL(fileURLWithPath: "/Applications/Missing.app")))
        XCTAssertFalse(TrashStateStore.canTrash(URL(fileURLWithPath: "/")))
        XCTAssertFalse(TrashStateStore.canTrash(URL(string: "https://example.com/file")!))
        XCTAssertTrue(TrashStateStore.canTrash(URL(fileURLWithPath: "/tmp/missing-document.txt")))
    }

    /// The store's work queue in these tests: serial, so `drain` can wait behind whatever it holds.
    private let serialQueue = DispatchQueue(label: "trash-tests-serial")

    /// Waits until every block queued on the store's work queue has run and posted back to main —
    /// twice, because a completion may queue one more round (interactive resend, then finish).
    private func drain() async {
        for _ in 0..<3 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                serialQueue.async { DispatchQueue.main.async { done.resume() } }
            }
        }
    }

    /// Finder moves the app (its Put Back record and admin prompt come with it); the items reported
    /// moved are the ones gone from the disk, and Finder's own sound is not doubled.
    func testAppDropGoesThroughFinderAndReportsWhatLeft() async {
        let client = FakeClient()
        let box = EffectsBox()
        let store = make(client, effects: box, workQueue: serialQueue)
        initialize(client)
        let a = URL(fileURLWithPath: "/Applications/A.app"), b = URL(fileURLWithPath: "/Applications/B.app")
        var moved: [URL]?
        store.trashApplications([a, b]) { moved = $0 }
        client.permissions.removeFirst().1(.granted)
        XCTAssertEqual(client.deletes.count, 1)
        XCTAssertEqual(client.deletes[0].0, [a, b])
        XCTAssertFalse(client.deletes[0].1)
        box.gone = [a.path]
        client.deletes.removeFirst().2(.succeeded)
        await drain()
        XCTAssertEqual(moved, [a])
        XCTAssertEqual(box.sounds, 0)
        XCTAssertEqual(box.beeps, 1, "B stayed where it was")
        XCTAssertTrue(box.recycled.isEmpty)
    }

    func testAppDropNeedingAPromptRetriesInteractively() async {
        let client = FakeClient()
        let box = EffectsBox()
        let store = make(client, effects: box, workQueue: serialQueue)
        initialize(client)
        let a = URL(fileURLWithPath: "/Applications/A.app")
        var moved: [URL]?
        store.trashApplications([a]) { moved = $0 }
        client.permissions.removeFirst().1(.granted)
        client.deletes.removeFirst().2(.needsInteraction)
        client.activations.removeFirst()()
        await drain()
        XCTAssertTrue(client.deletes[0].1)
        client.deletes.removeFirst().2(.cancelled)
        await drain()
        XCTAssertNil(moved)
        XCTAssertEqual(box.beeps, 0, "a cancelled password prompt is the user's answer, not a failure")
        XCTAssertEqual(client.permissions.count, 1, "the mutation ended, so a fresh read was queued")
    }

    /// Finder moved A, then stopped at B's administrator prompt: only B is sent again, and A still
    /// counts as moved.
    func testInteractiveResendSkipsWhatFinderAlreadyMoved() async {
        let client = FakeClient()
        let box = EffectsBox()
        let store = make(client, effects: box, workQueue: serialQueue)
        initialize(client)
        let a = URL(fileURLWithPath: "/Applications/A.app"), b = URL(fileURLWithPath: "/Applications/B.app")
        var moved: [URL]?
        store.trashApplications([a, b]) { moved = $0 }
        client.permissions.removeFirst().1(.granted)
        box.gone = [a.path]
        client.deletes.removeFirst().2(.needsInteraction)
        client.activations.removeFirst()()
        await drain()
        XCTAssertEqual(client.deletes.count, 1)
        XCTAssertEqual(client.deletes[0].0, [b])
        XCTAssertTrue(client.deletes[0].1)
        box.gone = [a.path, b.path]
        client.deletes.removeFirst().2(.succeeded)
        await drain()
        XCTAssertEqual(moved, [a, b])
        XCTAssertEqual(box.beeps, 0)
    }

    /// Without Automation the move still happens, through the system's own recycle, with our sound.
    func testAppDropWithoutAutomationFallsBackToRecycle() async {
        for refusal in [FinderAutomationStatus.denied, .notDetermined] {
            let client = FakeClient()
            let box = EffectsBox()
            let store = make(client, effects: box, workQueue: serialQueue)
            initialize(client)
            let a = URL(fileURLWithPath: "/Applications/A.app")
            var moved: [URL]?
            store.trashApplications([a]) { moved = $0 }
            client.permissions.removeFirst().1(refusal)
            if refusal == .notDetermined {
                XCTAssertTrue(client.permissions[0].0, "an app drop is a deliberate act on the Trash: it may ask")
                client.permissions.removeFirst().1(.denied)
            }
            await drain()
            XCTAssertTrue(client.deletes.isEmpty)
            XCTAssertEqual(box.recycled, [[a]])
            XCTAssertEqual(moved, [a])
            XCTAssertEqual(box.sounds, 1)
        }
    }

    func testFinderRefusingAutomationMidwayFallsBackToRecycle() async {
        let client = FakeClient()
        let box = EffectsBox()
        let store = make(client, effects: box, workQueue: serialQueue)
        initialize(client)
        let a = URL(fileURLWithPath: "/Applications/A.app")
        var moved: [URL]?
        store.trashApplications([a]) { moved = $0 }
        client.permissions.removeFirst().1(.granted)
        client.deletes.removeFirst().2(.denied)
        await drain()
        XCTAssertEqual(box.recycled, [[a]])
        XCTAssertEqual(moved, [a])
        XCTAssertEqual(store.status, .denied)
    }

    func testEjectFailureAndRunningAppsAreReported() async {
        let client = FakeClient()
        let box = EffectsBox()
        let store = make(client, effects: box, workQueue: serialQueue)
        initialize(client)
        store.eject([URL(fileURLWithPath: "/Volumes/Free"), URL(fileURLWithPath: "/Volumes/Busy")])
        await drain()
        XCTAssertEqual(box.notices, [.ejectFailed("Busy")])
        store.noteApplicationsInUse([URL(fileURLWithPath: "/Applications/Notes Probe.app")])
        await drain()
        XCTAssertEqual(box.notices.last, .applicationsInUse(["Notes Probe"]))
        store.noteApplicationsInUse([])
        await drain()
        XCTAssertEqual(box.notices.count, 2)
    }

    func testSuccessfulFileDropPlaysTheTrashSound() async {
        let client = FakeClient()
        let box = EffectsBox()
        let store = make(client, effects: box, workQueue: serialQueue)
        initialize(client)
        store.trash([URL(fileURLWithPath: "/tmp/tungsten-trash-test-file")])
        await drain()
        XCTAssertEqual(box.sounds, 1)
    }
}
