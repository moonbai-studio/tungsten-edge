# AGENTS

> **📍 New agent: read this first.**
> The source of truth for current product state, roadmap, and design decisions is the owner's Obsidian vault — **not** this file or `Docs/`:
> `/Users/caye/Documents/Obsidian Vault/Projects/macos-dock-cc-v2/` — entry note: `00 macos-dock-cc-v2 总览.md`. Follow its own links for what's current; don't hardcode a sub-note list here, it drifts as the vault grows.
> This `AGENTS.md` and most of `Docs/` are scoped to the **foundation engine** (window identity / placement / taskbar trust) and **dated historical findings**. They do **not** track the UX feature layer (message chips, badges, drawer, native-tab merge…), which lives only in Obsidian. Treat dated `Docs/*` as historical records, not live status — except `Docs/05-known-platform-quirks.md`, which is kept current as repo-local engineering reference.

## Purpose

This repo is `v2` of a macOS window-oriented bottom taskbar experiment.

The current phase prioritizes:

1. stable window identity
2. stable placement behavior
3. a minimal usable bottom strip in the app shell
4. taskbar trust hardening so only real user-operable windows enter the strip

Current checkpoints:

- Finder P0 window-level identity foundation was accepted on 2026-05-05.
- Taskbar trust hardening moved to inventory-first discovery on 2026-05-08.
- Long-gap duplicate card root cause was captured and fixed on 2026-05-13.
- Real desktop validation (normal App windows admitted, fake/system surfaces rejected, Finder/Feishu exceptions stable, no duplicate cards after long idle/sleep/overnight gaps) is complete as of 2026-06-16.

The foundation-engine phase above is done; current work is in the UX feature layer tracked in Obsidian (see top of file). Do not rebuild the Finder foundation or return to bottom-up "every CG/AX window-like surface" discovery — these were deliberately replaced by the inventory-first model in Taskbar Trust below and should not be reintroduced.

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

- The 2026-05-13 duplicate-card incident is documented in `Docs/21-long-gap-duplicate-card-fix.md`.
- A running app snapshot showed real internal duplication: `trackedCount = 35`, `duplicateGroups = 8`.
- This was not a SwiftUI accessibility-tree illusion.
- Root cause: after long observation gaps, short identity memory expired while old taskbar cards still existed; identity matching only reused minimized/hidden/disappeared retained seats, not active/inactive existing seats.
- Current fix: before creating a new identity, match against the current `DockSnapshot` seats when the candidate is same process and same app.
- Matching is conservative:
  - title + nearby frame is preferred
  - unique nearby frame can survive title drift
  - unique title can survive frame movement
  - ambiguous candidates do not merge
  - app-level fallback IDs (`app-*`) are not treated as concrete window seats
  - `closedPending` records are never revived
- Chrome, Illustrator, WeChat, Finder, Terminal, Codex, Photoshop, and Wanlian SD-WAN are validation samples only, not app-specific rule targets.

### Ghost Tab Seats (AX-absent window reaping)

- Some apps stop exposing background tabs as AX windows once tabs collapse into one window. Observed 2026-06-17: Ghostty exposes only the **active** tab as an AX window, and that window's `CGWindowID` changes as you switch tabs. The abandoned tabs vanish from AX but their real NSWindows linger off-screen in the full CG list — so the "still in CG → keep as minimized" veto retained them forever as phantom chips (one Ghostty window showed 5–6 chips).
- Reliable "is it really gone" signal is **AX-absence, not CG**: genuinely minimized / hidden / cross-Space / occluded windows all STAY in AX enumeration (minimized ones report `isMinimized=true`). Only permanently-gone seats vanish from AX entirely. Verified 2026-06-17: a window dragged to another Space stays in AX → never reaped.
- Rule: a tracked window absent from AX but still in CG is reaped after a short grace (`AppTracker.absentReapGrace`, ~1.5s), timestamped via `WindowEntry.absentSince` and reset the instant AX sees it again. The 0.5s frontmost poll reaps fast for the app in use; the 5s reconcile is the backstop.
- This is **not** the forbidden held-slot TTL (see Placement): that warned against expiring *real* minimized/hidden/CG-disappeared windows. This only reaps seats AX has permanently dropped — real windows never reach it because they stay in AX. Do not widen it to reap on CG-absence, and do not expire AX-present windows.

## Validation Entrypoints

### Identity / real samples

- `./Scripts/build_and_run.sh --lab-minimize "<keyword>"`
- `./Scripts/build_and_run.sh --lab-close "<keyword>"`
- `./Scripts/build_and_run.sh --lab-replay <scenario-name>`

Finder P0 sample:

- Create two Finder folders with unique names and run `./Scripts/build_and_run.sh --lab-minimize "<unique Finder folder title>"`
- Formal app UI path has been user-accepted for the Finder P0 stage.

### Placement

- `./Scripts/build_and_run.sh --lab-placement placement-permanent-hold-replay`
- `./Scripts/build_and_run.sh --lab-placement placement-close-release-replay`

### Transition / feedback

- `./Scripts/build_and_run.sh --lab-transition focused-active-replay`
- `./Scripts/build_and_run.sh --lab-transition close-timeout-replay`

### Runtime debug snapshot

- Trigger: status bar menu → `导出任务条快照` (the only trigger).
- A global `Cmd+Shift+D` shortcut and a `SIGUSR2` signal path were attempted on 2026-06-12 but reverted: the global key monitor / signal handler introduced an intermittent main-thread hang, and the menu already covers the need. Do not re-add without a clear plan that keeps the export off the main thread.
- Latest file usually lives at:
  - `$(getconf DARWIN_USER_TEMP_DIR)macos-dock-cc-v2-debug-snapshot-latest.json`
- The snapshot is read-only: it lists cards and live AX/CG samples but does not activate, hide, minimize, close, or clear windows.

## Current App State

- The app already renders a minimal bottom task strip.
- Strip items can activate / hide / minimize / close.
- Strip item labels can toggle: inactive/minimized concrete windows activate, active concrete windows minimize.
- Strip actions are interruptible: show/hide-class actions (toggle / activate / minimize / hide) never lock clicks; only close/quit locks until confirmed. Implementation detail (optimistic overlay, timeout/rollback) is UX-layer and tracked in Obsidian `02 当前进度`, not duplicated here.
- The action path is `UI -> IntentPipeline -> PlatformActionExecutor`.
- Current discovery is inventory-first when AX permission is available: normal App windows are the entry point, `CG` enriches them with visible-window evidence, Finder remains window-level, and Feishu may remain app-level fallback.
- Current identity now also uses the existing taskbar snapshot as a long-term seat map, so long-idle windows can be recognized after the short 6-second memory expires.
- The app has a read-only debug snapshot exporter for duplicate-card diagnosis.
- Swift 6 concurrency compliance landed 2026-06-14 (`6233111`): AX C callbacks use `[weak obs]` + `MainActor.assumeIsolated`, `@unchecked Sendable` is gone from the observation path. Store-level `@MainActor` isolation (Drawer/Launch/Messaging stores) is UX-layer hygiene tracked in Obsidian `02 当前进度`, not detailed here.

## Collaboration Rule

The project owner directs the product but does not read code, and does not read English comfortably — reply in Chinese.

- Write every status update, plan, and result so it's fully understandable with no engineering background: lead with what changed, what it means for how the app behaves, and what's next, in everyday language.
- Technical detail (file names, APIs, mechanisms) is a supplement that comes after the plain explanation, never the only way to follow the message. Don't make the owner decode jargon to understand what you did or why.
- When a choice needs the owner's input, frame it as product behavior and trade-offs they can weigh, not as implementation details.

## Important Non-Goals For This Phase

- Feishu real frontmost AX samples are useful but not blocking.
- Finder P0 acceptance does not mean the full taskbar is production-ready.
