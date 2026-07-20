# AGENTS

> **New agent: read this first.**
>
> **What this app is**: Tungsten Edge 钨极 is a window-oriented bottom taskbar for macOS, designed to replace the system Dock. Multi-window apps normally split into separate window chips, with deliberate app-level entries for Finder, messaging apps, kept apps (user-chosen「在程序坞中保留」), and compatibility fallbacks. It also includes a drawer for stashed apps and a pinned-folder zone. Minimum deployment target: macOS 12.
>
> Product state and decisions live in the owner's Obsidian vault:
> `/Users/caye/Documents/Obsidian Vault/Projects/macos-dock-cc-v2/`, entry note (homepage) `00 当前进度.md` — the checkpoint map with clickable todo nodes; todo cards live in `03 待办与想法/待办/`.
>
> This file is only for engineering guardrails that should not be rediscovered or reverted. Active repo-local references live in `Docs/`; historical notes live in `Docs/Archive/`.

## Source Of Truth

- Product state / decisions: Obsidian entry note.
- Engineering hard constraints: this file.
- Platform quirks: `Docs/05-known-platform-quirks.md`.
- Rollback ledger (executable revert commands + verification state): `Docs/23-rollback-ledger.md`; keep it updated alongside the Obsidian checkpoint map.
- Trust model history: `Docs/Archive/Engineering/19-taskbar-trust-incident.md`, `Docs/Archive/Engineering/20-inventory-first-taskbar-trust.md`.
- Focus debug history: `Docs/22-window-focus-flicker-debugging.md`.
- Finder P0 records: `Docs/Archive/Engineering/17-finder-p0-implementation.md`, `Docs/Archive/Engineering/18-real-sample-finder-findings.md`.

## Taskbar Trust And Placement

- This app is an inventory-first bottom taskbar for real user-operable windows. Do not return to broad bottom-up CG/AX admission.
- Minimize, hide, and temporary CG disappearance do not release a strip slot. Only true close releases it.
- Do not reintroduce held-slot TTL or "expire then return to tail" as the default placement rule.
- Filter system internals, widgets, app extensions, transparent/fake surfaces before any keep-slot or disappeared retention.
- `AppTracker` is the sole window-inventory authority: it seeds from `NSWorkspace` regular apps, reads `AXWindows` per app, and owns seat state. The old `WorkspaceSource` / observation-pipeline inventory path was replaced by `AppTracker + AppWindowObserver` (ef50008, 2026-05-31); `WorkspaceSource` is deleted. The remaining old pipeline types (`ObservationPipeline`, `WindowIdentityEngine`, `LifecycleTransitionEngine`, `ObservationAdmissionGate`) are not instantiated by the app — only WindowLab and legacy tests use them (removal is 方案 A step 2, pending).
- Inventory reads keep the 100ms per-app AX messaging timeout (seed probes and `scanNonAdmittedApps`). Slow/hung apps are skipped at seed and picked up by the post-launch scan rounds; CG full-list presence — not AX absence — decides whether a window still exists.
- `seedRunningApps` subscribes workspace notifications **before** seeding so launch/exit events during seed are not lost. Seed probes use `inventoryWindows(forPID:messagingTimeout:)` with env `DOCK_SEED_AX_TIMEOUT_MS` (0 = legacy no-timeout, other = ms override). Probed windows are admitted directly via `reconcileSeats(preloadedEligible:)` without a second untimed AX read. Keep kill switch `DOCK_SEED_AX_TIMEOUT_MS=0`.
- `start()` schedules four rounds of `scanNonAdmittedApps()` at 0.5/1/2/4s post-launch to catch apps that were slow to respond during seed.
- CG signals (full window list, on-screen set) may prove, retain, or veto seats but must never create them; seats are created only from eligible AX windows.
- The old rollback flags `DOCK_INVENTORY_FIRST_ENABLED` / `DOCK_AX_ADMISSION_MODE` are defunct: their only reader is the un-instantiated legacy gate. Do not promise or rely on them. Working kill switches: `DOCK_SEED_AX_TIMEOUT_MS=0`, `DOCK_SKYLIGHT_FOCUS=0`.
- Long-gap duplicate prevention: before creating a new identity, conservatively match same process/app against current seats by title + nearby frame; ambiguous candidates do not merge. Details: `Docs/Archive/Engineering/21-long-gap-duplicate-card-fix.md`.

## App Rules

- Finder always keeps a persistent strip slot. `seedRunningApps` adds Finder even when all Finder windows are closed.
- Closed-window Finder uses `app-com.apple.finder`; clicking it opens the home directory. Never plan hide/minimize for this persistent `app-*` chip.
- Process-death reconcile must not remove Finder's app entry. Finder process existence alone does not imply a concrete Finder window.
- Concrete Finder folder windows remain window-level items when title/frame are available. If a specific Finder target cannot be captured, do not fall back to whole-app activation.
- Finder minimize feedback accepts either `minimized` or temporary `disappeared`.
- Finder window content preview must not rely on AX folder-path attributes. Treat AX document/URL as opportunistic only; current reliable path is AppleEvents enumeration matched by Finder window title + frame, and ambiguous/no matches must fail.
- Finder AppleEvents parsing and title+frame matching live in `FinderAppleEventMatcher` with unit coverage. `FinderWindowContentsReader` should stay the I/O layer for AX lookup, Automation permission, and AppleScript execution.
- Feishu window-level handling is opportunistic. If samples are weak, titles generic, or frontmost AX unreliable, fall back to one stable app-level item.
- Messaging identity is a **zone label only** (owner 2026-07-18 unified model): it decides an app shows in the messaging zone; post-exit visibility is decided by kept, unified with every other app. Messaging and kept coexist — first mark (manual `markMessaging` or auto `autoRegisterMessaging`) seeds kept so the default look is unchanged, but the user may un-check keep to let a messaging app vanish on exit and reappear when it runs. `AppMembershipProjection.visibleMessagingIDs = (messaging − drawer) ∩ (running ∪ kept)` (`partitioned()` uses it; the old "persistent, no running/snapshot gate" rule is gone). **Drawer still wins** (priority `drawer > messaging > live`): a messaging app stashed in the drawer hides from the zone (shows in the drawer); dragging it back restores the zone. mark / unmark / auto-register **never change drawer placement** — position changes only by drag. The `.messagingApp` no-main-window branch handles running-no-window (`isRunning:true`, tap → `reopenMainWindow`) and not-running (`isRunning:false`, `onLaunch: runtime.beginLaunch`, never `reopenMainWindow`); its menu now carries 在程序坞中保留 alongside 取消标记消息应用.

## Window Identity And Actions

- Native tabs use a **single-seat** model: one physical window = one seat = one chip. Background native tabs are not separate strip items.
- Seat identity is `tabgrp-<pid>-s<serial>` from a monotonic counter. Never derive stable identity from `cgWindowID`.
- `WindowRecord.id` may be `cgw-<activeCgID>`, but chip identity is `groupID = seat.token`; action target is the current active cgID.
- Tab switch may adopt a new active cgID into the same seat only when exactly one seat claims the same frame.
- Tear-out keeps the old-frame seat for the new active tab; the moved old active cgID becomes a fresh seat.
- Minimized multi-tab windows may expose all tabs as eligible AX windows. Fold decision lives in pure `TabFoldDecision` (unit-tested), four levels: seat membership history (`formerCgIDs`), then shadow-tab pool, then exact frame, then `min=true` + off-screen + same size. Do not make geometry or the placed seat's min flag a hard precondition again.
- `formerCgIDs` membership is **session-local** (wiped on every dock restart) — never rely on it alone for fold correctness; the shadow pool is the restart-safe layer. Hygiene is load-bearing against cgID reuse: record on tab-switch adoption only (tear-out expulsion must NOT record), purge on window destroy (`purgeFromSeatHistories`) and by intersection with the CG full list on every reconcile.
- Shadow-tab pool (`AppEntry.shadowTabCgIDs`): ids present in the CG layer-0 list for the pid but absent from AXWindows — the unique signature of order-out background tabs (real windows stay in AXWindows whether visible, minimized, hidden, or on another Space; verified live against ChatGPT/Finder/Ghostty 2026-07-13). Verdicts must use the **previous** round's pool (the minimize burst floods AX in the current round); ids leave the pool on true close or on appearing in AX with `min=false` (never on `min=true` appearance); pool update is skipped when AX returned zero windows while CG still has some (hung app); pool folding needs ≥1 placed seat and a `min=true` candidate (tear-out landing must still split a card).
- Phantom-seat healing (`PhantomSeatDecision`, unit-tested): a seat may be released from the min/hidden retention branch only when ALL five gates pass — never seen `min=false` in AX this session (`everSeenVisible`, protects Safari-style windows that leave AX when minimized), AX-absent ≥ `phantomReapGrace` (10s), cgID still in CG, the AX read saw windows, and ≥1 sibling seat currently AX-present (a lone seat never heals). Do not loosen these gates; healing exists because seed-time minimized tab groups can split (no history, no pool) and the phantoms are otherwise held forever by min retention.
- The `[tabfold]` split-point and `[tabheal]` prints are permanent anomaly-path diagnostics (zero output on normal paths). Do not remove them as "诊断遗留" — the 871305d cleanup left the 2026-07-13 recurrence with no forensic evidence.
- Persistent window-inventory diagnostics are compiled in but default **off**. Enable persistently with `defaults write com.caye.macosdockcc.v2 InventoryLog -bool YES`; `DOCK_INVENTORY_LOG=1/0` overrides UserDefaults. Logs stay local at `~/Library/Logs/com.caye.macosdockcc.v2/window-inventory.jsonl`. Seat lineage must use stable `pid + seatToken`, never active cgID. `absenceEpisodeID` is diagnostic-only and must begin/clear exactly with `minAbsentSince`; `phantomHeld` deduplicates by `pid + seatToken + absenceEpisodeID`, writing again only when hold reasons change or a new episode begins.
- A strip chip id is a stable identity token, not necessarily actionable. All strip show/hide/minimize/toggle calls must use `item.actionWindowID`.
- `StripItem.pid`, `StripItem.cgWindowID`, and `StripItem.bounds` are current representative live facts for action/preview targeting only. Never use them as chip identity or persistent order keys.
- Drawer actions are app-centric and must not use strip chip ids for window-level toggle.

## Focus And Action Planning

- Minimizing the frontmost focused window A1 of multi-window app A should return focus to the previous other app B, not sibling A2.
- Only fire that background activation path when the target is the frontmost app's focused AX window. Right-click-minimizing a non-focused sibling must not steal focus.
- `postSkyLightWindowFocus` is the shared focus core; do not gate fallback on nonzero private return codes. The two SLPS records must be the **real make-key pair** built by `SkyLightMakeKeyEventBuilder` (unit-tested; yabai `window_manager_make_key_window` layout: `[0x04]=0xf8`, `[0x08]=0x01/0x02`, `[0x3a]=0x10`, `[0x20..<0x30]=0xff`, wid little-endian at `[0x3c..<0x40]`, no `0x8a`). Call order: `_SLPSSetFrontProcessWithOptions` → make-key record 1 → record 2 → `AXRaise`. The old `[0x08]=0x0d` + `[0x8a]` pair is yabai's `focus_window_without_raise` auxiliary switch notification, **not** make-key — posting only it leaves the process frontmost with no key window anywhere (keyboard limbo, Docs/22 §14); never reintroduce it as the make-key pair.
- Early focus applies only to `.activateWindow`, cross-app, visible active/inactive windows, using snapshot `record.cgWindowID` before handle capture.
- Minimized restore is restore-then-switch, never switch-early. Exclude `.minimized` from early focus; after restore, immediately call `postSkyLightWindowFocus` with the snapshot wid, then set `kAXMainAttribute=true`.
- Action-decision paths must not use `NSWorkspace.frontmostApplication`; read `NSRunningApplication(processIdentifier:)?.isActive` fresh.
- Keep kill switch `DOCK_SKYLIGHT_FOCUS=0`.
- 2026-07-20 的「reinforceFocus 延迟双管补强 + `--activate-helper`」方案已实机证伪并整体移除（Docs/22 §14）；不要重新发明延迟补强或延迟激活任务——键盘落位靠正确的 make-key 事件本身。刚发过 `_SLPS` 的进程读一切焦点信号（系统级 kAXFocusedApplication、NSWorkspace、isActive、目标 focusedWindow）都可能朝目标方向假阳性，「是否落位」在本进程内不可作为判据。
- Optimistic state predicts **status only** for show/hide style actions and clears on snapshot confirmation or timeout. Do not re-add predicted `isAppFrontmost`.
- The chip tap pulse is view-local acknowledgment only. It must not feed planner state or any frontmost decision.

## Window Lift Avoidance (最大化避让)

- Maximized-window avoidance lifts the frontmost visibleFrame-filling window's bottom edge above the taskbar (clearance 2pt). Pure decisions live in `WindowLiftAvoidance` (unit-tested), I/O in `WindowLiftAvoidanceController`; AX geometry writes exist **only** in `AXWindowReader.setSize/setFrame` with settable checks, post-write verification, and rollback — do not simplify or add a second write path.
- Gating is 常驻 + visible (`!edgeAutoHideEnabled && visibilityState.isVisible`) and must not be loosened. Kill switches: `DOCK_WINDOW_LIFT=0` (feature off), `DOCK_WINDOW_LIFT_ANIM=0` (instant-write fallback), `DOCK_WINDOW_LIFT_TRACE=1` (session diagnostics).
- `reduce` stays pure; time enters only via event `at` parameters. The time-scale rule — maximized reappearing within `appReassertWindow` of settle = app reassert (one relift then abandon), later = a fresh user session — is the cure for the L↔M zoom-memory deadlock (our lift poisons the system zoom's remembered frame; the window then toggles native↔target and never produces an external frame). Do not remove it; `abandonedAt` must never be refreshed by observations or abandoned never expires.
- Stall ≠ failure in the write loop: a readback equal to the pre-write frame means the window has not caught up (1x external displays apply late; the first eased frame is ~2pt, right at the verification tolerance) — skip the frame and continue. Intermediate frames use integral sizes and no auto-rollback; the final write retries a bounded number of times. Removing this re-breaks non-Retina displays deterministically.
- Standoff protection: one relift per session, standoff rounds capped, capped sessions decay to a slow retry cadence (never a permanent lock), and rounds heal after the lift stays stable past the reassert window.
- Session key `pid + cgWindowID` is per-episode only (cgWindowID reuse); keep the CG full-list prune. Context switch (screen change / leaving 常驻) restores still-lifted unmodified windows to their native frame.
- Accepted boundaries: inactive with menu-bar auto-hide (window fills screen.frame → classified fullscreen → bar hidden); only the active app's frontmost window lifts; the first zoom click on a lifted window may bounce to full maximize once (system zoom memory, cannot intercept).

## Drag, Drawer, And Ordering

- Do not use SwiftUI `.onDrag` / `NSItemProvider` or AppKit `beginDraggingSession` for local strip, drawer, or folder chip drags. The visual carrier is owned by `DragController`.
- Real file drag-out/in is exempt: file grid cells may use system drag payloads, and SwiftUI file `.onDrop` destinations are allowed.
- Strip reorder uses one `"strip"` coordinate space for chip frames, cursor location, and floating copy.
- Chip frames are read via `.background` GeometryReader, not `.overlay`. Keep `grabOffset`, mouse-up fallback, and vanished-window cleanup.
- `DragController` remains the single authority for monitors, carrier `NSPanel`, coordinate conversion, drop decisions, and idempotent teardown.
- Carrier position and cross-panel hit testing use `NSEvent.mouseLocation` screen coordinates.
- Timers used during drag must be added to `.common` run-loop mode.
- Drawer is app-centric: one bundleID = one `LauncherChip`. Drawer click is app-level frontmost->hide, otherwise unhide/open; not-running->launch.
- Drawer visibility is the pure `AppMembershipProjection.visibleDrawerIDs` decision: drawer placement filtered by running **or** kept **or** messaging membership. An unchecked ordinary drawer app remains in placement and order while stopped, but is hidden until it runs again.
- Drawer two zones are partitioned by process state from `RunningApplicationStore`: upper zone = running visible entries (bright + white dot); lower zone = non-running kept or messaging entries (gray, no dot). `isLaunchingWithoutWindow` gating still applies.
- `DrawerOrderStore` is the persistent ordering layer keyed by bundleID and synced over the full `DrawerStore` placement set, including currently hidden members. Reorder follows `MessagingAppStore.reorder`: move visible ids in the full array so hidden members keep their relative order.
- Drawer reorder is same-zone only. Cross-divider drops are meaningless. Capsule preview must use the same visible-drawer projection followed by `DrawerOrderStore` order; never render raw `DrawerStore` order directly.
- `DragPayload` uses strip id = stable chip token, drawer id = bundleID, folder id = folder path, messaging id = bundleID.
- Messaging-zone chips are draggable: in-zone reorder persists to `MessagingAppStore.bundleIDs` (`reorder` operates on the full array so hidden members keep relative positions). Frames report into the separate `MessagingChipFramePreferenceKey` — never merge messaging ids into `chipFrames`.
- Messaging reorder (like drawer reorder) is driven by `onChange(globalLocation)` (`updateMessagingReorder`), never by the chip's own `DragGesture.onChanged` — SwiftUI cancels the gesture after the first reorder moves the chip.
- `.messaging` drop zones equal `.strip` (capsule + open drawer body). The strip itself is never a `.messaging` drop target; releases on shelf/folder zone/live zone/desktop are no-ops. Spring-load and `isOverStashZone` accept `.messaging` alongside `.strip`.

## Strip And Drawer Conversion

- `canStash` rejects only missing bundleID and `com.apple.finder`. App-level fallback chips can be stashed.
- Strip-to-drawer drop zone is visible capsule content plus small tolerance, and drawer content only while open. Do not use full shadow frame as the hit zone.
- Strip-into-open-drawer converts on enter, reverts on exit, and commits only on release inside. Keep enter/exit hysteresis; do not restore placeholder cells or resize-per-hover insertion.
- Drawer placement and 「在程序坞中保留」 are orthogonal. Dragging is the only placement change; the checked menu item only toggles `KeptAppStore` and must never move an app between the strip and drawer. 收进抽屉 / 移出抽屉 must not reappear in any menu.
- Cross-panel conversion state is the single `DragController.conversion: CrossPanelConversion?` enum (stripToDrawer / drawerToStrip / messagingToDrawer / drawerToMessaging) — original payload + rollback snapshot, no parallel boolean flags. Mutation order in every convert/revert: set `conversion` and flip/restore `draggingPayload` **before** touching stores, so member-vanish watchers exempt by payload source (no cancel race).
- Drag conversions are **symmetric placement transactions** and preserve kept state: strip→drawer adds drawer placement on convert and removes it on revert; capsule drop adds placement; drawer→strip removes placement on enter/release and restores it on revert. Messaging→drawer and drawer→messaging likewise mutate drawer placement only, leaving messaging identity untouched. `cancelDrag` must rollback any uncommitted transaction via the same revert paths before teardown.
- Drawer-to-strip modes come from pure `DragConversionPlan.drawerDragOutMode` (unit-tested; messaging check must precede the real-window check): Finder / not-running messaging → reject; running messaging → releaseToMessaging; running with real windows → unstash (existing precise landing); not-running/no-real-window → keepPlacement. `keepPlacement` means stage the stable app-level fallback / kept-placeholder id at the chosen strip position; it preserves the existing kept flag and never enables keep. Reject is the only branch that does nothing — a messaging member never takes the fallback unstash on strip drop (`DragConversionPlan.endAction` gates it).
- releaseToMessaging triggers on entering the **messaging-zone range** (union of messaging chip frames + 8pt enter / 24pt exit hysteresis; 56pt strip-head fallback when the zone is empty), not on leaving the drawer body. Leaving the range or entering a drop zone reverts to the drawer.
- One drawer icon represents the app's whole window-chip block; land all chips contiguously in current display order. `keepPlacement` uses a single-element block `["app-\(bundleID)"]` when no window cards exist.
- Drawer-to-strip landing goes through staged placement consumed inside `StripOrderStore.sync(current:appKeyOf:)`. The sync fallback resolves kept placeholder ids when no window cards match the bundleID.
- Freeze strip width during converted cross-panel drags and release the clamp only on commit or revert.

## Kept Apps

- A kept app does **not** absorb live windows: while running with real windows it shows ordinary window chips; only when exited (or running with no real window) does it collapse to a single app-level icon that stays in place (gray + click-to-relaunch when exited). The icon lives in the live zone and can be freely dragged/reordered like window chips.
- Finder must never enter kept state. Reject `com.apple.finder` both when loading `KeptAppStore` and when adding through any menu/action path.
- Kept state is an exit-retention flag, not placement. It may coexist with drawer placement **and with messaging identity** (owner 2026-07-18 unified model), and `AppMembershipController.setKept(_:enabled:)` mutates only `KeptAppStore` with no messaging guard. Messaging entries **do** expose the keep checkbox now; kept alone (not messaging) decides post-exit visibility in every zone. First messaging registration (manual or auto) seeds kept once; a later user un-check must not be reopened by rescans. Finder is still rejected from kept / drawer / messaging. Startup repair is `reconcileInvalidMemberships()` — it clears only Finder's illegal drawer/messaging memberships, no kept/messaging reconciliation.
- `KeptAppStore` migration is keyed only by existence of `keptAppBundleIDsV2`: fresh installs must write an empty V2 array, and an existing empty V2 array means migration already ran. First migration combines the old kept/pinned lists with non-messaging drawer placements, rejects Finder, and leaves the old key untouched for rollback compatibility.
- `.keptApp` projection has two sources, both rendered as `LauncherChip` with `RunningApplicationStore` running dot/gray/hidden state: (a) unrunning kept apps → placeholder injection by `DockStripView` (id `"app-\(bid)"`); (b) running kept apps whose only snapshot entry is `isAppLevelFallback` → that entry is re-typed to `.keptApp` in the strip projection (id unchanged from the snapshot's `app-*` fallback token). The id `"app-\(bid)"` matches `AppTracker.rebuildSnapshot()`'s no-window fallback token — this is the position-retention lifeline.
- Clicking a running kept app with no real non-fallback window must unhide/reopen it. Running kept apps with real windows use app-level frontmost->hide and background->show behavior.
- Kept-app actions do not write window-level optimistic state or predicted frontmost state. Any immediate acknowledgment stays view-local, and app-active decisions read a fresh `NSRunningApplication`.
- Messaging auto-registration filters kept apps on every snapshot update. Startup reconciliation and display projection remain defensive layers against conflicting persisted memberships; explicitly marking an app as messaging clears its kept state.
- Position retention: on app exit, window-card ids enter the 5s grace period in `StripOrderStore`; the `app-*` placeholder appears the same frame. `StripOrdering.reconcile` inserts the placeholder after the app's rightmost window card using sticky appKey memory. Sticky appKey is pruned to `current ∪ liveOrder` keys after each sync. `persistableLiveOrder` saves `tabgrp-*` + kept `app-*` only; `kern.boottime` guard discards the entire order on machine restart. Cold-start placeholders land at the live zone head.
- Messaging pop-out windows land at the **live-zone head** (owner 2026-07-12 #4): `StripOrdering.reconcile` takes `headPreferredKeys` — a new (unremembered) window with no live-zone sibling whose appKey is in that set inserts at head (after existing head-preferred windows, keeping their relative order) instead of the tail. `StripOrderStore.reconciled` and `sync` **must be fed the identical set** (`Set(messagingStore.bundleIDs)`) at both DockStripView call sites — a mismatch makes the window head on first frame then jump on sync. Only affects new ids; a dragged/remembered messaging window keeps its position.
- Kept app chips participate in the live-window drag/reorder and drawer-conversion paths. Drag conversions are symmetric transactions (see Strip And Drawer Conversion above).

## Pinned Folders And External File Drop

- Strip layout is `[messaging][divider][shelf + pinned folders][divider][live windows]` (kept-app placeholders live in the live zone, not the messaging zone); empty zones drop adjacent dividers, while shelf keeps the folder zone non-empty.
- Folder chips drag via `DragController` source `.folder`; keep it isolated from strip/drawer stash semantics.
- Fixed-folder primary click behavior must route through `FolderInteraction.primaryAction`; do not scatter left-click policy across views. Current default is preview toggle, with Finder open available from the menu.
- Folder reorder and popup anchoring use `folderChipFrames`. Never merge folder ids into `ChipFramePreferenceKey`/`chipFrames`.
- Per-folder sort persists in `PinnedFolderStore.sortOrders`; covers follow the current sort's first **file**.
- Fixed folder chips render as a flat single small cover with the folder name always visible below it. Do not restore hover-only names, 36/24 hover resizing, or stacked-paper layers.
- Folder-chip hover feedback (whole-chip scale-up anchored to the bottom) and the drop-target highlight are non-layout visual overlays only (`scaleEffect`): they must never change the chip's layout size or the reported drop-hit frame. The resident name row stays truncated; the full name comes from the `.help` tooltip, never by widening the chip or unclipping that row.
- Finder windows do not expose folder paths reliably through AX. Do not retry Finder-window-chip-to-pinned-folder via AX without an owner decision.
- `PinnedFolderCoverStore` must keep background enumeration and generation checks so stale async thumbnails cannot overwrite fresh covers.
- `FolderCover.isThumbnail` decides rendering: thumbnails get square-crop + border; icons render fit.
- `DirectoryWatcher.stop()` is idempotent; the fd closes only in the dispatch source cancel handler.
- The strip `.onDrop` for external files must stay on the same view level that declares the `"strip"` coordinate space, before shadow padding.
- External drop routing stays in unit-tested `StripDropRouting.route`: shelf hit -> stash, pinned-folder chip horizontal-band hit -> move into that folder, chip gaps / folder-zone tail slack -> pin, else reject.
- Only directories can pin; files dropped in chip gaps / folder-zone tail slack are a silent no-op. Re-dropping an already-pinned folder in a gap repositions it; dropping it on a folder chip moves it into that folder.
- Moving external files into a pinned folder never overwrites an existing destination. Move only when both volume identifiers are known and equal; otherwise copy through a hidden temporary item, preserve the source, and remove the temporary item on failure.
- External drop hover cleanup must not rely only on `performDrop` / `dropExited` or `folderPaths` changes. Keep `dropEntered` gating plus `.common` Timer watchdog for missing terminal callbacks and post-drop hover flicker.
- Middle-click / Force Click content-preview monitors must observe and return the original `NSEvent`. They must not consume left clicks, break folder drag, or feed planner/frontmost state.

## Shelf And Folder Popup

- Shelf stores references only, newest first. Never move/copy files implicitly. `ShelfStore.prune()` runs when opening the shelf popup.
- Shelf chip is a fixed head of the pinned-folder zone: click + drop target only, never draggable and never a `DragController` source.
- Folder and shelf share one popup panel through `PanelCoordinator.PopupContent`; preserve the one-popup-at-a-time invariant.
- Popup lifecycle stays in `PanelCoordinator`: plain `NSView` container, pinned `NSHostingView`, alpha fade, local/global left-mouse monitors.
- `dismissFolderPopupIfOutside` must exclude the anchor chip rect with tolerance so clicking the same chip does not close-then-reopen.
- Popup closes on dock target-frame change, screen-parameter change, hover screen switch, fullscreen, or panel hide. Do not chase an animating anchor.
- Popup layout mirrors native Stacks: no header row; Finder open is the grid tail cell; drill-in uses a floating back chip.
- Popup width is derived from `FolderPopupStyle`: column count = clamp(cell count, 3, 8). It is not measured feedback.
- Grid-cell menus are hand-built via `FileItemMenuBuilder`; no Quick Look, Get Info, or rename in the nonactivating panel.
- First frame must be complete before `orderFront`: preload folder contents, warm visible icons, use synchronous `fittingSize`, and avoid first-population insertion animation.
- Switching folders while popup is open is an in-place content/frame switch, not orderOut-then-reopen.
- Popup open/close animation uses `PopoverAnimation`; taskbar/drawer layout animation stays on `DrawerAnimation`.
- Edge auto-hide is inhibited while the popup is open via `EdgeAutoHideInhibitor.folderPopupOpen`.

## Menus, Panels, And Screens

- Strip and drawer chip menus are hand-built AppKit `NSMenu`, not SwiftUI `.contextMenu`.
- No menu anywhere exposes drawer placement actions (`收进抽屉` / `移出抽屉`); stashing and unstashing are drag-only. Every eligible non-Finder, non-messaging app menu shows `在程序坞中保留` as a native checked / unchecked `NSMenuItem`, regardless of running state or drawer placement; toggling it changes kept state only.
- `MenuHostNSView` claims only right-click / Control-click and returns `nil` from `hitTest` otherwise.
- Force Quit is a native alternate item after Quit, gated out for this app itself.
- `LauncherChip` menu running-state follows the passed-in `isRunning` (the displayed zone), never an independent `NSWorkspace` process query. A launch-zone icon whose process is still alive (window-closed / background) must not surface 显示/隐藏/退出. The pure decision is `LauncherMenuPlan.itemKinds` (unit-tested); `buildLauncherMenu` only renders it and queries `NSWorkspace` solely to obtain the app object for an action it already decided to show. Membership items come from the pure `AppMembershipMenuPlan` (unit-tested) via the shared `LauncherMembershipItem.items` factory — the four menu paths (strip window chip / kept icon / messaging chip / drawer icon) all consume it so the matrix stays consistent: strip-plain = 在程序坞中保留 + 标记为消息应用; strip/drawer messaging = 在程序坞中保留 + 取消标记消息应用; drawer-plain = 在程序坞中保留 only; Finder = none. Keep checkbox always precedes the messaging command. Messaging cards (main-window and pop-out) now expose 在程序坞中保留 together with 取消标记消息应用.
- Finder menu items apply to both persistent Finder chip and concrete Finder windows.
- SwiftUI shadow margin is `shadowPadding = 20pt`; floating panel shadows must fit within it.
- Coordinate math on `dockFrame` / `capsuleFrame` subtracts `shadowPadding` to reach visual content, and `fittingSize.width` subtracts `2 * shadowPadding`.
- Relayout is target-frame-driven. Do not position one panel from another panel's live `.frame` during animation.
- Drawer window content must be a plain `NSView` container with the `NSHostingView` pinned inside.
- Placement panels use `NonConstrainingPanel`, not plain `NSPanel`.
- Bottom-anchored panels use `screen.frame` for bottom Y and horizontal clamp; reserve `visibleFrame` for drawer top/menu-bar height cap.
- Hover screen switching uses dwell, not instant edge-trigger.
- Fullscreen hide hides capsule and closes drawer. `FullscreenWindowClassifier.isFullscreen` remains the single AX predicate, gated to real `AXWindow` roles.

## Settings And Compatibility

- Do not reintroduce the multi-display strategy menu; behavior is fixed to dwell hover-switch.
- Tungsten Edge slider controls wake delay, not hide delay. `不唤醒` still allows hide but disables bottom-edge wake.
- Hidden-state bottom-edge detection must keep probing while the dock panel is hidden.
- The bottom-edge wake hot zone (`hoverHotZone`, spans the full screen width) and the idle-hide "still interactive" check (dock/capsule panel rect, centered and narrower) are different-sized regions. Resting the mouse in the hot zone but outside the panel rect must count as "still interactive" (`EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide`), otherwise wake and idle-hide re-arm each other every cycle and the dock flickers forever (GitHub issue #2, fixed 2026-07-17). This suppression must stay gated to finite wake delays (0.1–3.0s) only — never apply it at `neverWakeDelay` (999, auto-hide without wake) or `neverHideDelay` (-1, always visible), or it silently changes those modes' behavior. Reproduction/regression diagnostic: `DOCK_EDGEHOVER_TRACE=1` prints one `[edgehover] SHOW/HIDE` line per actual visibility flip (mouse position, hot-zone/panel-rect flags, current delay) — default off, plain `print()` not `Logger` (some environments can't read the unified log back).
- The dynamic Tungsten Edge hide/show command toggles `edgeAutoHideDelay` between `neverHideDelay` and persisted `lastEnabledEdgeAutoHideDelay`; it reuses the wake-delay slider pipeline, never a separate visibility state. Remembered values must never be `-1`; seeding/sanitizing lives in `AppSettingsStore` (unit-tested, fallback 0.1). ⌥⌘E must not contain Control+Option (VoiceOver's VO modifier space) nor be Option-only/Option+Shift-only (macOS 15 bug FB15168205). It deliberately mirrors the system's ⌥⌘D and knowingly shadows Safari Develop → Empty Caches and Finder File → Eject All / 推出所有磁盘 while running; the owner accepted both low-frequency conflicts on 2026-07-17.
- The status menu has no native-Dock delay slider. Its dynamic hide/show command derives title and direction from the LIVE system `autohide` state (`NativeDockPreferencesService.currentAutohideState`; `CFPreferencesAppSynchronize` before every read), falling back to the store mirror only when unreadable. Mouse selection writes only the `autohide` boolean and restarts Dock — it must never overwrite `autohide-delay`. `menuWillOpen` may reconcile the local mirror to system truth but must never apply settings back.
- Global hot key rules (`GlobalHotKeyMonitor`, Carbon `RegisterEventHotKey`; exclusivity passes through the backend protocol so tests assert it): lifecycle is main-thread only; the callback may only toggle settings — it must not export debug snapshots or synchronously read cross-app AX/CG inventories. History (facts only, root cause unverifiable): `417d93d` added a SwiftUI-local ⌘⇧D + `SIGUSR2` debug-snapshot trigger, `ef50008` deleted it in the big pipeline rewrite without mentioning it, `1ed0e66` retroactively documented "间歇主线程卡死已回退". Menu `keyEquivalent` hints: ⌥⌘E shows only when Carbon registration succeeded (failure logs once, no dialog, no in-session retry; a deliberate `stop()` re-arms `start()` for a real re-registration); ⌥⌘D always shows (system-owned, no registration involved). Live-verified boundary (owner accepted 2026-07-17): with the menu closed, ⌥⌘E runs through Carbon and ⌥⌘D through macOS; while the menu is open, ⌥⌘E is unavailable under the current exclusive-Carbon/menu-tracking interaction, so use the Tungsten Edge menu item directly, whereas macOS's ⌥⌘D still executes and the native-Dock menu action must skip its exact keyDown. Native-Dock matching uses physical `keyCode`, never character (non-US layouts diverge); mouse click, Return selection, and accessibility activation must still execute both dynamic menu commands.
- Minimum deployment target is **macOS 12**. Guard newer APIs with availability checks and Monterey-compatible fallbacks.
- Old single-value `onChange` deprecation warnings are expected back-deployment noise.

## Collaboration Rule

The owner directs product, does not read code, and does not read English comfortably. Reply in Chinese.

- Explain behavior in plain Chinese first; add file/API details only when useful.
- Frame choices as product behavior and trade-offs, not implementation trivia.
- For coding tasks, read code first and follow existing repo patterns.
- For "打检查点", create a local git commit unless told otherwise; do not push or create PRs unless asked.
- For 收尾 / 整理文档, do not expand this file by default. Update `AGENTS.md` only for new hard engineering guardrails that would prevent code regressions. Product state, roadmap, release progress, decision history, and long handoff text belong in Obsidian; historical notes belong in `Docs/Archive/`.
