import Foundation

enum FinderAutomationStatus: Equatable {
    case granted, denied, notDetermined, unavailable

    init(osStatus: Int32) {
        switch osStatus {
        case 0: self = .granted
        case -1743: self = .denied
        case -1744: self = .notDetermined
        default: self = .unavailable
        }
    }
}

enum TrashPermissionTrigger: CaseIterable {
    case launch, shown, appActivated, ownDrop, inAppTrash, emptyCommand, panelOpened

    /// Only deliberate acts on the Trash may put up the automation prompt — never launch, show or
    /// activation refreshes. Opening the popup counts: it is the user asking what is in there.
    func shouldAskUser(status: FinderAutomationStatus) -> Bool {
        (self == .ownDrop || self == .emptyCommand || self == .panelOpened) && status == .notDetermined
    }
}

enum FinderTrashEvent {
    static let core: UInt32 = 0x636f7265
    static let count: UInt32 = 0x636e7465
    static let finder: UInt32 = 0x666e6472
    static let empty: UInt32 = 0x656d7074
    /// `core` / `delo`: Finder's `delete`, i.e. Move to Trash — with Finder's put-back record and
    /// its own administrator prompt.
    static let delete: UInt32 = 0x64656c6f
    static let trashProperty: UInt32 = 0x74727368
    static let itemClass: UInt32 = 0x636f626a
    static let getData: UInt32 = 0x67657464
    static let urlProperty: UInt32 = 0x7055524c
    static let reveal: UInt32 = 0x6d766973
    static let miscellaneous: UInt32 = 0x6d697363
    /// `aevt` / `odoc`: the open-documents event, on Finder's `trash` object the merged Trash window.
    static let application: UInt32 = 0x61657674
    static let openDocuments: UInt32 = 0x6f646f63
    /// `kAEAll`, the ordinal of `every item`.
    static let absoluteAll: UInt32 = 0x616c6c20
    static let noConsentPrompt: UInt = 0x00020000
    static let countOptions: NSAppleEventDescriptor.SendOptions = [
        .waitForReply, .neverInteract, .init(rawValue: noConsentPrompt)
    ]
    static let emptyOptions = countOptions
    static let emptyInteractiveOptions: NSAppleEventDescriptor.SendOptions = [
        .waitForReply, .canInteract, .init(rawValue: noConsentPrompt)
    ]
}

enum FinderTrashOutcome: Equatable {
    case count(Int), succeeded, cancelled, needsInteraction, timedOut
    case denied, wouldPrompt, finderUnavailable, failed(Int)

    var permission: FinderAutomationStatus? {
        switch self {
        case .count, .succeeded: return .granted
        case .denied: return .denied
        case .wouldPrompt: return .notDetermined
        case .finderUnavailable: return .unavailable
        default: return nil
        }
    }
}

enum FinderTrashReply {
    static func parse(isCount: Bool, sendError: Int?, replyError: Int?,
                      integer: Int?, hasReply: Bool) -> FinderTrashOutcome {
        if let error = [sendError, replyError].compactMap({ $0 }).first(where: { $0 != 0 }) {
            switch error {
            case -128: return .cancelled
            case -1713: return .needsInteraction
            case -1712: return .timedOut
            case -1743: return .denied
            case -1744: return .wouldPrompt
            case -600: return .finderUnavailable
            default: return .failed(error)
            }
        }
        guard hasReply else { return .failed(-1708) }
        if isCount {
            guard let integer, integer >= 0 else { return .failed(-1700) }
            return .count(integer)
        }
        return .succeeded
    }
}

/// The Trash directories' modification dates, so an app activation asks Finder for a count only
/// after something changed there. `~/.Trash` cannot be listed or opened without Full Disk Access,
/// but `stat` on it is allowed and its date moves on every add, remove, put-back and empty. A
/// per-volume trash whose date cannot be read is present by path alone (mount/unmount still shows).
struct TrashChangeStamp: Equatable {
    let marks: [String: Date?]

    static func build(directories: [URL], modificationDate: (URL) -> Date?) -> TrashChangeStamp {
        var marks: [String: Date?] = [:]
        for directory in directories { marks.updateValue(modificationDate(directory), forKey: directory.path) }
        return TrashChangeStamp(marks: marks)
    }
}

enum TrashRefreshSource: Equatable {
    case external
    case postMutation(expectedFull: Bool)
}

struct TrashStateReducer {
    private(set) var isFull = false
    private(set) var status = FinderAutomationStatus.unavailable
    private(set) var epoch: UInt64 = 0
    private(set) var needsAuthoritativeRead = false
    private var nextMutation: UInt64 = 0
    private var mutations = Set<UInt64>()
    private var overlapped = false

    var isMutating: Bool { !mutations.isEmpty }

    mutating func setPermission(_ value: FinderAutomationStatus) {
        epoch &+= 1
        status = value
        if value == .denied { isFull = false }
    }

    mutating func readReturned(epoch requestEpoch: UInt64, source: TrashRefreshSource,
                               status permission: FinderAutomationStatus,
                               outcome: FinderTrashOutcome?) {
        guard requestEpoch == epoch, !isMutating else { return }
        status = outcome?.permission ?? permission
        if status == .denied { isFull = false; return }
        guard case let .count(count) = outcome else { return }
        let full = count > 0
        if case let .postMutation(expectedFull) = source, full != expectedFull {
            needsAuthoritativeRead = true
            return
        }
        needsAuthoritativeRead = false
        isFull = full
    }

    mutating func mutationBegan() -> UInt64 {
        epoch &+= 1
        if mutations.isEmpty { overlapped = false } else { overlapped = true }
        nextMutation &+= 1
        mutations.insert(nextMutation)
        return nextMutation
    }

    /// Only an isolated success can predict direction. An overlapping batch must read truth.
    mutating func mutationEnded(_ id: UInt64, successfulDirection: Bool?) -> TrashRefreshSource? {
        guard mutations.remove(id) != nil else { return nil }
        epoch &+= 1
        guard mutations.isEmpty else { return nil }
        needsAuthoritativeRead = false
        if !overlapped, let full = successfulDirection, status == .granted {
            isFull = full
            return .postMutation(expectedFull: full)
        }
        return .external
    }

    mutating func disabled() {
        epoch &+= 1
        mutations.removeAll()
        overlapped = false
        needsAuthoritativeRead = false
    }
}

/// Finds the Finder window already showing the Trash, so a click toggles that window like its own
/// window chip would instead of asking Finder to open another one.
enum TrashWindowLookup {
    /// Finder's title for the Trash window on an English or Chinese system. Data, not copy — never
    /// localize: they match another app's window title. `localizedName` adds the name in this
    /// process's language for the rest.
    static let finderTitles: Set<String> = ["Trash", "废纸篓"]

    static func titles(localizedName: String?) -> Set<String> {
        guard let localizedName, !localizedName.isEmpty else { return finderTitles }
        return finderTitles.union([localizedName])
    }

    /// Prefers the front window (a click then closes it), then a visible one, then a minimized one.
    static func actionWindowID(finderWindows: [WindowMenuEntry], titles: Set<String>) -> String? {
        let matches = finderWindows.filter { titles.contains($0.title) }
        let chosen = matches.first { $0.marker == .front }
            ?? matches.first { $0.marker == .none }
            ?? matches.first
        return chosen?.actionWindowID
    }

    /// Reads the inventory snapshot only — no AX on the click path.
    static func actionWindowID(snapshot: DockSnapshot, titles: Set<String>) -> String? {
        actionWindowID(finderWindows: WindowListMenuPlan.entries(snapshot: snapshot,
                                                                 bundleID: FinderTaskbarPolicy.bundleID,
                                                                 fallbackTitle: ""),
                       titles: titles)
    }
}

/// One entry of the Trash popup, parsed from the file URL Finder reports for the item.
struct TrashItem: Equatable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
}

/// What the Trash popup shows. `.loaded` carries at most `TrashListingPlan.itemLimit` items and
/// how many more Finder holds beyond them.
enum TrashListing: Equatable {
    case idle, loading
    case loaded(items: [TrashItem], hiddenCount: Int)
    case unavailable
}

enum TrashListingPlan {
    /// The grid caps here; a line points at Finder for the rest.
    static let itemLimit = 200

    /// Finder answers `URL of every item of trash` with file URL strings; a folder's ends in "/".
    /// Sorted by name the way the Trash window sorts, so the two agree.
    static func build(urlStrings: [String], limit: Int = itemLimit) -> TrashListing {
        var items: [TrashItem] = []
        for string in urlStrings {
            guard let url = URL(string: string), url.isFileURL else { continue }
            let name = url.lastPathComponent
            guard !name.isEmpty, name != "/" else { continue }
            items.append(TrashItem(url: url, name: name, isDirectory: url.hasDirectoryPath))
        }
        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let hidden = max(0, items.count - limit)
        return .loaded(items: Array(items.prefix(limit)), hiddenCount: hidden)
    }
}

/// Keeps Finder's Trash window from also showing as its own card: the Trash chip stands in for it.
enum TrashWindowAbsorption {
    /// Single-window Finder seats titled as the Trash — but only while Finder keeps another card.
    /// A lone Finder window already renders as the plain Finder icon (no title), and absorbing it
    /// would take Finder off the bar entirely. Tab groups stay: dropping the visible tab's record
    /// would re-title the card from a background tab.
    static func absorbedWindowIDs(in snapshot: DockSnapshot, trashTitles: Set<String>) -> Set<WindowID> {
        var groups: [String: [WindowRecord]] = [:]
        for record in snapshot.windows.values
        where record.bundleIdentifier == FinderTaskbarPolicy.bundleID && !record.groupID.hasPrefix("app-") {
            groups[record.groupID, default: []].append(record)
        }
        let trashGroups = groups.values.filter { $0.count == 1 && trashTitles.contains($0[0].title) }
        guard !trashGroups.isEmpty, groups.count > trashGroups.count else { return [] }
        return Set(trashGroups.map { $0[0].id })
    }

    /// Filters before `StripItem.items(from:)` so the remaining Finder cards count themselves
    /// correctly (a single remaining one renders as the bare icon, as it would without the Trash).
    static func removing(_ ids: Set<WindowID>, from snapshot: DockSnapshot) -> DockSnapshot {
        guard !ids.isEmpty else { return snapshot }
        return DockSnapshot(windows: snapshot.windows.filter { !ids.contains($0.key) },
                            orderedWindowIDs: snapshot.orderedWindowIDs.filter { !ids.contains($0) })
    }
}

/// Paths inside a Trash: the user's `~/.Trash` or a volume root's `.Trashes`. Matched by whole path
/// components, never by string prefix, and only strictly inside — the Trash folder itself is not
/// an item. Such URLs never reach a taskbar drop target: the shelf would keep a reference into the
/// Trash, and a pinned-folder move would need Full Disk Access, which Tungsten Edge does not have.
enum TrashPath {
    static func isInsideTrash(_ url: URL, homeDirectory: URL) -> Bool {
        guard url.isFileURL else { return false }
        let parts = url.standardizedFileURL.pathComponents
        let home = homeDirectory.standardizedFileURL.pathComponents
        if parts.count > home.count + 1, Array(parts.prefix(home.count)) == home, parts[home.count] == ".Trash" {
            return true
        }
        // `/.Trashes/<uid>/item` on the startup volume, `/Volumes/<name>/.Trashes/<uid>/item` elsewhere.
        if parts.count > 3, parts[1] == ".Trashes" { return true }
        if parts.count > 5, parts[1] == "Volumes", parts[3] == ".Trashes" { return true }
        return false
    }
}

enum TrashMenuPlan {
    enum Item: Equatable { case open, empty(enabled: Bool) }

    static func items(status: FinderAutomationStatus, isEmptying: Bool) -> [Item] {
        status == .denied ? [.open] : [.open, .empty(enabled: !isEmptying)]
    }
}
