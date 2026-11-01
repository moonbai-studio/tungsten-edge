import AppKit
import ApplicationServices
import Foundation

@MainActor
enum DiagnosticSnapshotCollector {
    static func collect(
        runtime: AppRuntime, orchestrator: TaskbarScreenOrchestrator?, store: AppSettingsStore,
        kept: KeptAppStore, drawer: DrawerStore, messaging: MessagingAppStore, folders: PinnedFolderStore,
        appVersion: String?, includeTitles: Bool, completion: @escaping (String) -> Void
    ) {
        let at = Date()
        let tracked = runtime.diagnosticApps()
        let admissions = runtime.diagnosticAdmissions
        var apps = tracked
        let trackedPIDs = Set(tracked.map(\.pid))
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && app.bundleIdentifier != DockWindowEligibilityPolicy.selfBundleIdentifier
            && !trackedPIDs.contains(app.processIdentifier) {
            apps.append(AppEntry(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                                 appName: app.localizedName ?? "?", activationPolicy: app.activationPolicy,
                                 executablePath: app.executableURL?.path, windowsByID: [:], windowOrder: [], isHidden: app.isHidden))
        }
        let cg = AppTrackerCGWindowSnapshot.capture(includeDiagnosticDetails: true)
        let projections = StripProjectionRegistry.shared.snapshot()
        let history = DiagnosticVisibilityRecorder.shared.history.changes
        let basic = DiagnosticReport.collect(appVersion: appVersion).text
        let placement: String
        switch store.taskbarScreenPlacement {
        case .followMouse: placement = "followMouse"
        case .pinned: placement = "pinned"
        case .allScreens: placement = "allScreens"
        case .allScreensPerDisplay: placement = "allScreensPerDisplay"
        }
        let settingLines = [
            "placement=\(placement) autoHide=\(store.edgeAutoHideEnabled) wakeDelay=\(store.edgeAutoHideDelay)",
            "height=\(store.dockPanelHeight) shelf=\(store.showShelf) trash=\(store.showTrash) hover=\(store.hoverStyle)",
            "windowLift=\(store.windowLiftEnabled) fullscreenIntent=\(store.fullscreenIntentEnabled) frontWindow=\(store.frontWindowBar) scrollReverse=\(store.scrollReverserEnabled)",
            "language=\(DiagnosticText.clean(Bundle.main.preferredLocalizations.first ?? "en")) selection=\(DiagnosticText.clean((CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesCurrentApplication) as? [String])?.joined(separator: ",") ?? "system"))",
            "kept=\(kept.bundleIDs.count) drawer=\(drawer.bundleIDs.count) pinnedFolders=\(folders.folderPaths.count)"
        ]
        var panelLines = (orchestrator?.units ?? []).map { unit in
            let panel = unit.coordinator
            let screen = panel.currentScreen
            let size = screen.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) main=\($0 == NSScreen.screens.first)" } ?? "?"
            return "unit=\(panel.stripSurfaceID) screen=\(screen.flatMap(DisplayIdentity.uuidString(for:)) ?? "?") \(size) visible=\(panel.panelsAreVisible) reasons=\(DiagnosticVisibilityHistory.reasonNames(panel.visibilityState.hideReasons)) fullscreen=\(DiagnosticText.flag(panel.diagnosticFullscreenVerdict)) source=\(panel.diagnosticFullscreenSource)"
        }
        panelLines.append("Recent visibility changes (last 40):")
        panelLines += history.map {
            "  at=\($0.at.timeIntervalSince1970) unit=\($0.unit) screen=\($0.screen) visible=\($0.visible) reasons=\($0.reasons) source=\($0.source)"
        }
        let keptIDs = Set(kept.bundleIDs)
        let messagingIDs = Set(messaging.bundleIDs)
        let capturedApps = apps
        let capturedPanels = panelLines
        AppRuntime.actionQueue.async {
            let permissionLines = ["accessibility=\(AXIsProcessTrusted())",
                                   "finderAutomation=\(FinderAutomationPermission.status(askUserIfNeeded: false)) (read-only)"]
            let reader = AXWindowReader()
            let rereads = capturedApps.map { app in
                (app.pid, Date(), reader.inventoryWindows(forPID: app.pid, messagingTimeout: 0.1))
            }
            DispatchQueue.main.async {
                let after = Dictionary(uniqueKeysWithValues: runtime.diagnosticApps().map { ($0.pid, $0) })
                var blocks: [DiagnosticApplicationBlock] = []
                var extras: [String] = []
                var entriesByPID: [pid_t: [String]] = [:]
                var representedByPID: [pid_t: [String: [String]]] = [:]
                var duplicatesByPID: [pid_t: Set<UInt32>] = [:]
                for (surface, record) in projections.sorted(by: { $0.key < $1.key }) {
                    extras.append("unit=\(surface) display=\(record.displayUUID ?? "?")")
                    var positionsByID: [String: Int] = [:]
                    for (position, entry) in record.projection.entries.enumerated() {
                        let prefix = "unit=\(surface) position=\(String(format: "%04d", position))"
                        let item: StripItem?
                        let kind: String
                        let bid: String?
                        switch entry {
                        case .window(let window): item = window; kind = "window"; bid = window.bundleIdentifier
                        case .messagingApp(let bundleID, let main): item = main; kind = "messagingApp"; bid = bundleID
                        case .keptApp(let bundleID): item = nil; kind = "keptApp"; bid = bundleID
                        case .pinnedFolder: extras.append(prefix + " kind=pinnedFolder"); continue
                        case .shelf: extras.append(prefix + " kind=shelf"); continue
                        case .trash: extras.append(prefix + " kind=trash"); continue
                        case .divider, .externalDropGhost: continue
                        }
                        let pid = item?.pid ?? capturedApps.first(where: { $0.bundleIdentifier == bid })?.pid
                        let line = "\(prefix) kind=\(kind) bundle=\(DiagnosticText.clean(bid ?? "?")) token=\(item?.id ?? "?") cgID=\(item?.cgWindowID.map(String.init) ?? "?") min=\(item.map { DiagnosticText.flag($0.status == WindowStatus.minimized.rawValue) } ?? "?")"
                        if let pid {
                            entriesByPID[pid, default: []].append(line)
                            if let item {
                                representedByPID[pid, default: [:]][item.id, default: []].append("\(surface):\(position)")
                                if let id = item.cgWindowID {
                                    let key = "\(pid):\(id)"
                                    if positionsByID[key] != nil { duplicatesByPID[pid, default: []].insert(id) }
                                    positionsByID[key] = position
                                }
                            }
                        } else { extras.append(line) }
                    }
                }
                for app in capturedApps {
                    let bid = app.bundleIdentifier
                    let reread = rereads.first { $0.0 == app.pid }!
                    let result = reread.2
                    let windows = result.windowsOrEmpty
                    let admission = admissions[app.pid].map { "\($0.verdict) source=\($0.source) at=\($0.at.timeIntervalSince1970)" } ?? "not recorded"
                    let header = "app=\(DiagnosticText.clean(app.appName)) bundle=\(DiagnosticText.clean(bid ?? "?")) pid=\(app.pid) policy=\(policyName(app.activationPolicy)) hidden=\(app.isHidden) messaging=\(bid.map(messagingIDs.contains) ?? false) finder=\(FinderWindowRules.isFinder(bundleIdentifier: bid)) kept=\(bid.map(keptIDs.contains) ?? false) admission: \(admission) F1 sampledAt=\(at.timeIntervalSince1970)"
                    let seats = app.windowOrder.compactMap { app.windowsByID[$0] }.map { seat in
                        let location = representedByPID[app.pid]?[seat.token]?.joined(separator: ",")
                            ?? projections.sorted(by: { $0.key < $1.key }).map { surface, record in
                                surface + ":" + StripProjectionRegistry.exclusion(token: seat.token, cgID: seat.cgWindowID, bundleID: bid, in: record.projection)
                            }.joined(separator: ",")
                        let presence: Bool? = cg.captureFailed ? nil : cg.layerByWindowID[seat.cgWindowID] != nil
                        return DiagnosticInventorySeat(identity: identity(seat), title: seat.title,
                            retention: "everSeenVisible=\(seat.everSeenVisible) minAbsentAge=\(seat.minAbsentSince.map { String(at.timeIntervalSince($0)) } ?? "none") absentProbe=\(seat.absentProbe != nil) display=\(seat.displayUUID.map { String($0.prefix(8)) } ?? "?") age=\(at.timeIntervalSince(seat.createdAt)) CGpresent=\(DiagnosticText.flag(presence)) onScreen=\(DiagnosticText.flag(cg.captureFailed ? nil : cg.diagnosticOnScreenWindowIDs.contains(seat.cgWindowID))) shadowPool=\(app.shadowTabCgIDs.contains(seat.cgWindowID))",
                            placement: location.isEmpty ? "unknown" : location,
                            titleRules: titleRules(seat.title, bid: bid, messagingIDs: messagingIDs)
                                + " messagingAbsorbed=\(projections.values.contains { $0.projection.messagingAbsorbedIDs.contains(seat.token) })")
                    }
                    let eligibilityApp = AppTrackerWindowEligibility.Application(bundleIdentifier: bid, appName: app.appName,
                        activationPolicy: app.activationPolicy, executablePath: app.executablePath)
                    let readWindows = windows.map { window in
                        DiagnosticReadWindow(cgID: window.cgWindowID, title: window.titleRead == .empty ? "" : window.title,
                            role: window.role, subrole: window.subrole,
                            size: window.bounds.map { "\($0.width)x\($0.height)" },
                            onScreen: cg.captureFailed ? nil : window.cgWindowID.map(cg.diagnosticOnScreenWindowIDs.contains),
                            layer: window.cgWindowID.flatMap { cg.layerByWindowID[$0] }, minimized: window.isMinimizedRead,
                            verdict: AppTrackerWindowEligibility().verdict(title: window.title, role: window.role,
                                subrole: window.subrole, bounds: window.bounds,
                                alpha: window.cgWindowID.flatMap { cg.alphaByWindowID[$0] }, isMinimized: window.isMinimized,
                                isBelowNormalLayer: window.cgWindowID.map(cg.belowNormalLayerWindowIDs.contains) ?? false,
                                application: eligibilityApp).rawValue,
                            titleRules: titleRules(window.title, bid: bid, messagingIDs: messagingIDs))
                    }
                    let error: Int32?
                    if case .unread(let code) = result { error = code.rawValue } else { error = nil }
                    blocks.append(DiagnosticInventoryApplication(header: header, seats: seats,
                        after: after[app.pid]?.windowOrder.compactMap { after[app.pid]?.windowsByID[$0] }.map(identity) ?? [],
                        readAt: reread.1, readError: error, windows: readWindows,
                        cgOnlyIDs: (cg.windowIDsByPID[app.pid] ?? []).subtracting(windows.compactMap(\.cgWindowID)).sorted(),
                        stripEntries: entriesByPID[app.pid] ?? [], duplicateStripIDs: (duplicatesByPID[app.pid] ?? []).sorted(),
                        cgReadFailed: cg.captureFailed)
                        .block(includeTitles: includeTitles))
                }
                let report = DiagnosticSnapshotReport(basic: basic, permissions: permissionLines, settings: settingLines,
                    panels: capturedPanels, applications: blocks, stripExtras: extras)
                AppRuntime.actionQueue.async {
                    let text = report.text
                    DispatchQueue.main.async { completion(text) }
                }
            }
        }
    }

    private static func identity(_ seat: WindowEntry) -> DiagnosticSeatIdentity {
        DiagnosticSeatIdentity(token: seat.token, cgID: seat.cgWindowID, formerCgIDs: seat.formerCgIDs, minimized: seat.isMinimized)
    }

    private static func policyName(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "?"
        }
    }

    private static func titleRules(_ title: String?, bid: String?, messagingIDs: Set<String>) -> String {
        guard let title else { return "titleRules messagingMainTitle=? finderGeneric=? filtered=?" }
        return "titleRules messagingMainTitle=\(bid.map { messagingIDs.contains($0) && AppDisplayNameResolver.titleMatchesAppName(title, bundleID: $0) } ?? false) finderGeneric=\(FinderWindowRules.matchesGenericTitle(title)) filtered=\(DockWindowEligibilityPolicy.matchesFilteredTitle(title))"
    }
}
