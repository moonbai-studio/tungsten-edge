import Foundation

/// Plain-text diagnostics the user copies from Settings and pastes to us.
///
/// It is data for us, like a log line: the labels stay English in every UI language. Nothing
/// here is sent anywhere — the feedback form's disclosed fields are unchanged.
struct DiagnosticReport: Equatable {
    struct GlassReading: Equatable {
        let label: String
        /// `TEDockGlassDescribeLayer`'s output; nil when no glass filter could be read.
        let reading: String?
        /// Only for a live panel on the system-variant plate: which window state its material is.
        var state: GlassState? = nil
    }

    /// Which window state AppKit sampled into a live glass panel, decided against two throwaway
    /// windows of the same size and variant on the same machine — never against a table of
    /// per-version numbers: the inactive blur radius grows with the panel's height, so a reading
    /// from any other size (the `glass variants` line is 400x54) is not comparable.
    enum GlassState: Equatable {
        case active
        case inactive
        /// Matches neither reference; both are carried so the paste still tells us what they were.
        case unmatched(inactive: String?, active: String?)
        /// The two references read the same on this machine (the fields that differ here are
        /// unreadable, or the predicates are ignored), so no reading could tell the states apart.
        case undecidable(inactive: String, active: String)
    }

    /// `R` (refraction) is dropped before comparing: the taskbar and capsule overwrite it with the
    /// fixed Dock amount, and it also scales with height, so it never tells states apart.
    static func classify(reading: String?, inactive: String?, active: String?) -> GlassState? {
        guard let reading, inactive != nil || active != nil else { return nil }
        if let inactive, let active, stateSignature(inactive) == stateSignature(active) {
            return .undecidable(inactive: inactive, active: active)
        }
        let signature = stateSignature(reading)
        if let active, stateSignature(active) == signature { return .active }
        if let inactive, stateSignature(inactive) == signature { return .inactive }
        return .unmatched(inactive: inactive, active: active)
    }

    private static func stateSignature(_ reading: String) -> [String] {
        reading.split(separator: " ").map(String.init).filter { !$0.hasPrefix("R") }
    }

    var appVersion: String?
    var systemVersion: String
    var hardwareModel: String?
    var language: String
    var appearance: String
    var reduceTransparency: Bool
    var increaseContrast: Bool
    var displays: [String]
    var glassPath: String
    /// Whether the taskbar's glass composite is actually up (`glassPath` is only the configuration).
    var glassComposite: String
    /// Whether this AppKit still has the hook the glass view uses to re-sample its window state.
    var glassRefresh: String
    var glassTint: String?
    /// What each private variant number resolves to on this system.
    var glassVariants: [GlassReading]
    /// What the live glass panels actually carry, hidden ones included (an auto-hidden bar is
    /// still the bar; the label says so).
    var glassPanels: [GlassReading]
    /// The live panels as they were the first time this process became active with the bar up;
    /// nil when that has not happened yet. Activation re-samples the glass (healing the inactive
    /// material) and Settings activates the app before the user can press Copy, so `glassPanels`
    /// may already be post-activation. This line covers only those panels at that moment:
    /// panels rebuilt later (a display change) and later faults are outside it.
    var glassPanelsAtFirstActivation: [GlassReading]? = nil

    var text: String {
        let system = [systemVersion, hardwareModel].compactMap { $0 }.joined(separator: " · ")
        return [
            "Tungsten Edge diagnostics",
            "app: \(appVersion ?? "unknown")",
            "macOS: \(system)",
            "language: \(language)",
            "appearance: \(appearance)",
            "accessibility: reduceTransparency=\(reduceTransparency ? 1 : 0) increaseContrast=\(increaseContrast ? 1 : 0)",
            "displays: \(Self.joined(displays, separator: ", "))",
            "glass path: \(glassPath)",
            "glass composite: \(glassComposite)",
            "glass refresh: \(glassRefresh)",
            "glass tint: \(glassTint ?? "unset")",
            "glass variants: \(Self.joined(glassVariants.map(Self.line), separator: " | "))",
            "glass panels: \(Self.joined(glassPanels.map(Self.line), separator: " | "))",
            "glass panels at first activation: "
                + (glassPanelsAtFirstActivation.map { Self.joined($0.map(Self.line), separator: " | ") }
                    ?? "not captured"),
        ].joined(separator: "\n")
    }

    private static func line(_ reading: GlassReading) -> String {
        let base = "\(reading.label)=\(reading.reading ?? "unreadable")"
        switch reading.state {
        case nil: return base
        case .active?: return base + " [active]"
        case .inactive?: return base + " [inactive]"
        case .unmatched(let inactive, let active)?:
            return base + " [unmatched; inactive=\(inactive ?? "unreadable") active=\(active ?? "unreadable")]"
        case .undecidable(let inactive, let active)?:
            return base + " [undecidable; inactive=\(inactive) active=\(active)]"
        }
    }

    private static func joined(_ items: [String], separator: String) -> String {
        items.isEmpty ? "none" : items.joined(separator: separator)
    }
}

enum DiagnosticText {
    static let byteLimit = 60 * 1024

    static func clean(_ value: String, home: String = NSHomeDirectory()) -> String {
        let redacted = home.isEmpty ? value : value.replacingOccurrences(of: home, with: "~")
        return String(String.UnicodeScalarView(redacted.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
    }

    static func title(_ value: String?, include: Bool) -> String {
        guard let value else { return "title: unread" }
        guard !value.isEmpty else { return "title: empty" }
        return include ? "title: \(clean(String(value.prefix(120))))" : "title: <\(value.count) chars>"
    }

    static func flag(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "?" }

    static func prefix(_ value: String, bytes: Int) -> String {
        var end = value.startIndex
        var count = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let size = value[end..<next].utf8.count
            if count + size > max(0, bytes) { break }
            count += size
            end = next
        }
        return String(value[..<end])
    }
}

struct DiagnosticApplicationBlock: Equatable {
    var header: String
    var hasSeatOrStrip: Bool
    var entries: [String] = []
    var inventory: [String] = []
    var differences: [String] = []
}

struct DiagnosticSnapshotReport {
    var basic: String
    var permissions: [String]
    var settings: [String]
    var panels: [String]
    var applications: [DiagnosticApplicationBlock]
    var stripExtras: [String] = []

    var text: String {
        struct Block {
            var value: DiagnosticApplicationBlock
            var removed = 0
            var removedEntries = 0
            var omitted = false

            var bytes: Int {
                value.header.utf8.count + value.entries.reduce(0) { $0 + $1.utf8.count + 1 }
                    + value.inventory.reduce(0) { $0 + $1.utf8.count + 1 }
                    + value.differences.reduce(0) { $0 + $1.utf8.count + 1 }
            }

            var hasLines: Bool { !value.entries.isEmpty || !value.inventory.isEmpty || !value.differences.isEmpty }

            mutating func trim() {
                removed += 1
                if !value.differences.isEmpty { value.differences.removeLast() }
                else if !value.inventory.isEmpty { value.inventory.removeLast() }
                else { value.entries.removeLast(); removedEntries += 1 }
            }
        }
        let required = ["## A. Basic\n" + basic,
                        "## B. Permissions\n" + permissions.joined(separator: "\n"),
                        "## C. Settings\n" + settings.joined(separator: "\n"),
                        "## D. Taskbar state\n" + panels.joined(separator: "\n")].joined(separator: "\n\n")
        var blocks = applications.map { Block(value: $0) }
        var extras = stripExtras
        var removedExtras = 0
        func render() -> String {
            let live = blocks.filter { !$0.omitted }
            let omitted = blocks.count - live.count
            let e = extras + live.flatMap { block in
                block.value.entries + (block.removedEntries > 0 ? ["... \(block.removedEntries) more strip entries"] : [])
            } + (removedExtras > 0 ? ["... \(removedExtras) more strip entries"] : [])
            let f = live.map { block in
                ([block.value.header] + block.value.inventory
                 + (block.removed > 0 ? ["... \(block.removed) more"] : [])).joined(separator: "\n")
            } + (omitted > 0 ? ["... \(omitted) apps omitted"] : [])
            return required + "\n\n## E. Strip entries\n" + e.sorted().joined(separator: "\n")
                + "\n\n## F. Window inventory\n" + f.joined(separator: "\n\n")
                + "\n\n## Differences\n" + live.flatMap(\.value.differences).joined(separator: "\n")
        }
        var rendered = render()
        while rendered.utf8.count > DiagnosticText.byteLimit {
            if let longest = blocks.indices.filter({ !blocks[$0].omitted && blocks[$0].hasLines })
                .max(by: { blocks[$0].bytes < blocks[$1].bytes }) {
                blocks[longest].trim()
            } else if !extras.isEmpty {
                extras.removeLast()
                removedExtras += 1
            } else if let victim = blocks.indices.filter({ !blocks[$0].omitted }).min(by: {
                !blocks[$0].value.hasSeatOrStrip && blocks[$1].value.hasSeatOrStrip
            }) {
                blocks[victim].omitted = true
            } else {
                // Even required metadata may exceed the budget on an extreme display topology.
                return DiagnosticText.prefix(rendered, bytes: DiagnosticText.byteLimit - 24) + "\n... report truncated"
            }
            rendered = render()
        }
        return rendered
    }
}

struct DiagnosticSeatIdentity: Equatable {
    let token: String
    let cgID: UInt32
    let formerCgIDs: Set<UInt32>
    let minimized: Bool

    static func unstable(_ before: [Self], _ after: [Self]) -> Bool {
        before.sorted { $0.token < $1.token } != after.sorted { $0.token < $1.token }
    }
}

struct DiagnosticInventorySeat {
    var identity: DiagnosticSeatIdentity
    var title: String
    var retention: String
    var placement: String
    var titleRules: String
}

struct DiagnosticReadWindow {
    var cgID: UInt32?
    var title: String?
    var role: String?
    var subrole: String?
    var size: String?
    var onScreen: Bool?
    var layer: Int?
    var minimized: Bool?
    var verdict: String
    var titleRules: String
}

struct DiagnosticInventoryApplication {
    var header: String
    var seats: [DiagnosticInventorySeat]
    var after: [DiagnosticSeatIdentity]
    var readAt: Date
    var readError: Int32?
    var windows: [DiagnosticReadWindow]
    var cgOnlyIDs: [UInt32]
    var stripEntries: [String]
    var duplicateStripIDs: [UInt32]
    var cgReadFailed = false

    func block(includeTitles: Bool) -> DiagnosticApplicationBlock {
        let unstable = DiagnosticSeatIdentity.unstable(seats.map(\.identity), after)
        let suffix = unstable ? " unstable" : ""
        var lines = ["F1 remembered seats:"]
        var differences: [String] = []
        for seat in seats {
            let id = seat.identity
            let evidence = "token=\(DiagnosticText.clean(id.token)) active=\(id.cgID) formerCount=\(id.formerCgIDs.count) min=\(DiagnosticText.flag(id.minimized)) \(seat.retention)"
            lines.append("  \(evidence) E=\(seat.placement) \(DiagnosticText.title(seat.title, include: includeTitles)) \(seat.titleRules)")
            if readError == nil && !windows.contains(where: { $0.cgID == id.cgID || $0.cgID.map(id.formerCgIDs.contains) == true }) {
                differences.append("F1 absent from F2: \(evidence)\(suffix)")
            }
        }
        lines.append("F2 reread at=\(readAt.timeIntervalSince1970):")
        if let readError { lines.append("  unread(\(readError))") }
        for window in windows {
            let matched = seats.filter { seat in
                window.cgID == seat.identity.cgID || window.cgID.map(seat.identity.formerCgIDs.contains) == true
            }
            let tokens = matched.map { DiagnosticText.clean($0.identity.token) }.joined(separator: ",")
            lines.append("  cgID=\(window.cgID.map(String.init) ?? "?") role=\(DiagnosticText.clean(window.role ?? "?")) subrole=\(DiagnosticText.clean(window.subrole ?? "?")) size=\(window.size ?? "?") onScreen=\(DiagnosticText.flag(window.onScreen)) layer=\(window.layer.map(String.init) ?? "?") min=\(DiagnosticText.flag(window.minimized)) currentWindowEligibility=\(window.verdict) seats=[\(tokens)] \(DiagnosticText.title(window.title, include: includeTitles)) \(window.titleRules)")
            if matched.count > 1 {
                differences.append("F2 multiple seats cgID=\(window.cgID.map(String.init) ?? "?")\(suffix): "
                    + matched.map { "\($0.identity.token) \($0.retention)" }.joined(separator: " | "))
            }
        }
        let cgOnly = readError != nil ? "? (AX unread)"
            : (cgReadFailed ? "? (CG unread)" : cgOnlyIDs.map(String.init).joined(separator: ","))
        lines.append("CG layer-0 absent from AX: " + cgOnly)
        for id in duplicateStripIDs {
            differences.append("E duplicate cgID=\(id)\(suffix): "
                + seats.filter { $0.identity.cgID == id }.map { "\($0.identity.token) \($0.retention)" }.joined(separator: " | "))
        }
        return DiagnosticApplicationBlock(header: header + suffix, hasSeatOrStrip: !seats.isEmpty || !stripEntries.isEmpty,
                                          entries: stripEntries, inventory: lines, differences: differences)
    }
}
