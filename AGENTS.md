# AGENTS

> **📍 New agent: read this first.**
> The source of truth for current product state, roadmap, and design decisions is the owner's Obsidian vault — **not** this file or `Docs/`:
> `/Users/caye/Documents/Obsidian Vault/Projects/macos-dock-cc-v2/` — entry note: `00 macos-dock-cc-v2 总览.md`. Follow its own links for what's current; don't hardcode a sub-note list here, it drifts as the vault grows.
> **Division of labor:** `AGENTS.md` holds engineering **do-not-revisit guardrails** — the hard constraints touching window identity, placement, taskbar trust, card identity, and input mechanism. A UX feature earns a section here **only once it hardens into such a constraint** (e.g. native-tab single-seat, strip drag-reorder); each entry stays terse and points to Obsidian for the full rationale + reversal log. Pure product surface with no engine-level constraint (badge styling, drawer copy, hover labels) stays **Obsidian-only**. Obsidian remains the source of truth for product state, decisions, and roadmap. Dated `Docs/*` are historical records, not live status — except `Docs/05-known-platform-quirks.md`, kept current as repo-local engineering reference.

## Purpose

This repo is `v2` of a macOS window-oriented bottom taskbar experiment. The foundation-engine phase is done; current work is in the UX feature layer tracked in Obsidian (see top of file). Do not rebuild the Finder foundation or return to bottom-up "every CG/AX window-like surface" discovery — these were deliberately replaced by the inventory-first model in Taskbar Trust and should not be reintroduced.

## Product Rules

### Placement

- Minimize does **not** release a slot.
- Hide does **not** release a slot.
- Temporary `CG` disappearance does **not** release a slot.
- Only true close releases a slot.

Do not reintroduce held-slot TTL or "expire then return to tail" as the default placement rule.

### Feishu

- Feishu window-level handling is opportunistic.
- If frontmost AX windows are unreliable, titles are generic, or titles are missing, Feishu may fall back to a single stable app-level item.
- Do not block the taskbar mainline on perfect Feishu per-window fidelity.
- For current V2 validation, a stable app-level Feishu fallback is sufficient; real frontmost AX samples are future window-level enhancement evidence, not a blocker.

### Finder

- Finder always has a persistent slot in the taskbar: `seedRunningApps` adds Finder unconditionally so its chip survives even when all windows are closed.
- When all Finder windows are closed the slot shows as an `app-com.apple.finder` chip. Clicking it opens the home directory in a new Finder window (mirrors system Dock behavior). This is intentional app-level persistence, not an AX fallback.
- Do not plan a `hideApp`/minimize action for the Finder persistent (`app-*`) chip on toggle — always plan activate/open, even when Finder is still frontmost right after its last window closes.
- Do not let the dead-process reconcile sweep remove Finder's app entry — `handleAppTerminated` clears its windows but keeps the slot, and reconcile must skip Finder when sweeping dead pids.

Both fixed 2026-06-16; full rationale documented in Obsidian `03 设计决策` ("Finder 持久图标").
- Finder process existence alone does **not** mean there is a Finder window.
- Concrete Finder folder windows should remain window-level items when titles / frames are available.
- Do not fall back to activating the whole Finder app when a specific Finder window target cannot be captured; that can bring forward the wrong Finder window or multiple windows.
- Finder P0 implementation details are documented in `Docs/17-finder-p0-implementation.md`.
- Finder real sample findings are documented in `Docs/18-real-sample-finder-findings.md`.
- Finder minimize feedback treats either `minimized` or temporary `disappeared` observation as success, because macOS can report a minimized concrete Finder window through either path.

### Taskbar Trust

- Only trusted, user-operable windows should enter the bottom strip.
- System internals, widgets, app extensions, transparent windows, and other fake window-like surfaces must be filtered before they can benefit from keep-slot or `disappeared` retention.
- Do not widen `AX` sampling again without strict window-type filtering and an observation-count guardrail.
- The current trust model starts from app-level window inventory: `WorkspaceSource` enumerates normal user apps through `NSWorkspace`, reads their `AXWindows`, and emits `.appWindowInventory` observations.
- Inventory reads use a 100ms per-app AX messaging timeout, up to 12 concurrent app reads, and a 30-round unread degradation threshold. Once an app is degraded, `CG` may help decide whether its windows still exist.
- `CG` and generic `.accessibility` observations should not create ordinary new strip entries while inventory-first is available. They should prove or enrich entries from inventory, except for documented Finder and Feishu rules.
- If AX permission is unavailable, `CG` fallback may still create entries so the app remains useful in reduced-permission mode.
- Debug rollback flags exist for local diagnosis: `DOCK_INVENTORY_FIRST_ENABLED=0` or `DOCK_AX_ADMISSION_MODE=legacy`.
- The 2026-05-07 trust incident is documented in `Docs/19-taskbar-trust-incident.md`.
- The inventory-first implementation is documented in `Docs/20-inventory-first-taskbar-trust.md`.

### Long-Gap Duplicate Cards

Root cause and full fix documented in `Docs/21-long-gap-duplicate-card-fix.md`. Current fix: before creating a new identity, match against the current `DockSnapshot` seats when the candidate is same process and same app. Matching is conservative — title + nearby frame preferred; ambiguous candidates do not merge; `app-*` IDs and `closedPending` records are never revived.

### Native Tab Groups & Stable Card Identity — single-seat model (Ghostty 根治)

> Empirically grounded (2026-06-19 spike): Finder **and** Ghostty native tab groups expose **only the active tab** as an eligible AX window; all tabs of one window share a pixel-identical frame; switching tabs **atomically swaps** which single cgID is AX-visible (no overlap, no gap). Safari "tabs" are in-app (one NSWindow per window). Ghostty minimized windows stay in AX (`min=true`); Safari minimized windows **leave AX entirely**.

- **Model: one physical window = one seat = one chip.** A `WindowEntry` is a **physical-window seat** with a stable `token` (`tabgrp-<pid>-s<serial>`, from a monotonic counter — **never derived from a cgID**, which gets reused and would collide) plus a current `cgWindowID` = the **active tab** (the action target, swaps as you switch tabs). Background tabs are **not** separate seats. `WindowRecord.id` is `cgw-<activeCgID>` but the chip's stable identity is `groupID = seat.token`; everything is contained in `AppTracker` — the external `DockSnapshot`/`WindowRecord` shape is unchanged.
- **Seat reconciliation (`AppTracker.reconcileSeats`)** maps each app's current eligible AX windows onto seats, frame-anchored, with these cases:
  - *Tab switch*: a seat's active cgID leaves AX and a new cgID appears at the **same frame** → seat adopts it in place (token unchanged → chip never jumps). Guarded: only if exactly one seat claims that frame (overlap ambiguity → don't adopt).
  - *Tear out the current tab*: the active cgID is still visible but moved to a **new** frame while another tab took its old frame → seat stays at the old frame and adopts the new tab; the moved cgID is **evicted** to a fresh seat (so the torn-out window gets its own chip).
  - *New window / torn-out background tab*: an eligible cgID matching no seat → new seat, new token.
  - *Minimize a multi-tab window*: minimizing makes Ghostty expose **all** the window's tabs as eligible AX windows at once (all `min=true`, **pixel-identical frame** — verified 2026-06-20), unlike the active-only exposure when not minimized. A `min=true` eligible window whose frame matches an already-placed seat is **folded** into that seat (background tab of the minimized window), not given its own seat — otherwise the chip splits into one-per-tab on minimize. A non-`min` same-frame window is instead two overlapping separate windows → kept separate.
- **Seat removal — minimize vs close (the hard distinction; both are "AX-absent + still in CG").** When a seat's active cgID leaves AX with no takeover:
  - If it was **minimized** (`seat.isMinimized`, latched via `kAXWindowMiniaturizedNotification`) **or** the app is hidden → keep the seat. This is why Safari-minimize (leaves AX) keeps its chip.
  - Else (a normal window that left AX) → it's a **close** whose NSWindow lingers in the CG list (Ghostty does this); keep for a short `closedReapGrace` (~1.5s, absorbs AX read misses) then drop. Do **not** force `isMinimized` while in this grace, or the close would masquerade as a minimize and never reap.
  - If the cgID is gone from the full CG list (or freshly `destroyed`) → drop immediately.
- **Superseded approaches — do not revisit:** (1) the 2026-06-17 "reap any AX-absent-but-CG-present seat after a grace" — falsified because Safari minimize leaves AX (killed real minimized windows). (2) the 2026-06-19 first cut "keep every tab as a seat + collapse by a stable token" — the token-inheritance/merge was fragile under tear-out (couldn't tell tear-out from switch/new-tab without guessing). The single-seat model removes the root (background-tab seats) instead of stitching grouping logic on top.
- **Order-layer stickiness (`StripOrderStore.rankRetentionGrace` ~5s)** stays: a chip id that briefly leaves the live set keeps its rank instead of being dropped-and-reappended.
- **Known step-1 edges (acceptable / future):** two genuinely separate windows at a pixel-identical frame won't be disambiguated by frame alone (rare); closing the active tab relies on a takeover tab appearing promptly. `Docs` not yet written; this section is the live reference.

### Strip Drag-Reorder Mechanism — self-drawn in-app drag (路线 A, 残影根治)

> 2026-06-20. The live-zone chip drag carries a **self-rendered floating copy** (`DockStripView.floatingDragCopy`), driven by an in-app `DragGesture(coordinateSpace: .named("strip"))` — **not** SwiftUI system drag. The reorder logic underneath (`StripOrdering` / `StripOrderStore`, seat-lifecycle ranks) is unchanged; only the *carried image* changed. Full rationale + reversal log: Obsidian `03 设计决策`「拖动载体改自绘（松手残影根治）」.

- **Do not reintroduce SwiftUI `.onDrag` / `NSItemProvider` for the strip.** The system snapshots the chip and fades that image **in place on release** — an un-suppressible "release ghost". That ghost is exactly the bug this mechanism replaced; the API gives no handle to stop the fade.
- **Do not switch to AppKit `beginDraggingSession` (路线 B) to gain cross-panel drag-into-drawer.** The cross-panel convenience and the ghost are the *same coin*: a system-owned drag image floats above all panels AND can't be suppressed. Route B keeps that image, so it can't guarantee a ghost-free release — it's the one path that would be wasted work.
- **Cross-panel endgame (C) = extend the self-drawn copy, not the system session.** Drag-into-drawer should grow the floating copy into a screen-spanning carrier (global mouse monitor + drop-into-drawer hit-test), keeping full ownership of the image. 路线 A is deliberately step 1 of this.
- **Implementation guardrails that must hold:** (1) one `"strip"` coordinate space shared by chip frames (`ChipFramePreferenceKey`, read via `.background` GeometryReader — never `.overlay`, which steals clicks), the finger location, and the floating copy — else horizontal scroll skews finger↔copy↔target. (2) `grabOffset` (chip center − press point) so an edge-grab doesn't snap the copy's center to the cursor. (3) a slim `watchDragEnd` mouse-up fallback (a `DragGesture` can cancel without `.onEnded`) plus a `liveOrderIDs` onChange that clears a stale drag if the dragged window vanishes mid-drag — together they stop a hidden chip's slot from sticking as a gap. (4) the floating copy forces the hovered visual (`ChipView.forceHover`, since it's `allowsHitTesting(false)`) so it doesn't pop size on grab.

### Optimistic Action State — interruptible interaction (去转圈 + 可打断)

> 2026-06-13. Deliberately relaxes the older "lock the chip while an action is in flight" rule — that rule is **superseded, do not reinstate**.

- Clicking a chip writes an **optimistic state** (predicted status + frontmost) immediately; UI render and toggle-planning read it first, cleared when the real snapshot confirms or after a ~4s timeout (silent rollback, no shake/red). This *is* the feedback — **no spinner**.
- **Scope = show/hide only** (toggle / activate / minimize / hide). **close / quit stay locked until confirmed** — making a chip vanish optimistically then bounce back on failure is worse than a brief wait. Re-entrancy guard lives in `AppRuntime.trigger`, not UI graying.
- Grounding diagnostic: a spinner (`pending`) ≠ "action running" — execution is a one-shot AX call, pending is just awaiting the snapshot. The real bug was `toggle` re-reading a not-yet-flipped snapshot → repeating one action instead of alternating; the optimistic state fixes both that and the interruptibility.
- Known accepted: `hideApp` only optimistically covers the clicked chip; other windows of the same app wait for the snapshot.

### Panel Layout — shadowPadding coordinate rule

> SwiftUI `.shadow()` draws the panel shadow, so each panel window reserves `shadowPadding = 20pt` of transparent margin on all sides (AppKit `NSWindow` shadow is off; `clipShape` does the rounding).

- **Any coordinate math on `dockFrame` / `capsuleFrame` must subtract `shadowPadding` first** to reach the visual content edge — forgetting this offsets placement (4 such bugs fixed 2026-06-19, `c44d17e`).
- **Reading `fittingSize.width` must subtract `2 × shadowPadding`**, else the panel sizes ~80pt too wide.

## Collaboration Rule

The project owner directs the product but does not read code, and does not read English comfortably — reply in Chinese.

- Write every status update, plan, and result so it's fully understandable with no engineering background: lead with what changed, what it means for how the app behaves, and what's next, in everyday language.
- Technical detail (file names, APIs, mechanisms) is a supplement that comes after the plain explanation, never the only way to follow the message. Don't make the owner decode jargon to understand what you did or why.
- When a choice needs the owner's input, frame it as product behavior and trade-offs they can weigh, not as implementation details.

