# AGENTS

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

Next-thread focus should start from the post-Finder-P0, post-inventory-first, and post-long-gap-duplicate-fix state. Do not rebuild the Finder foundation or return to bottom-up "every CG/AX window-like surface" discovery. The next most important task is continued real desktop validation: confirm the strip admits normal user App windows, rejects fake/system/helper surfaces, keeps Finder / Feishu exceptions stable, and does not recreate duplicate cards after long idle/sleep/overnight gaps.

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

- Finder is **not** an app-level fallback target for this phase.
- Finder process existence does not mean there is a Finder window.
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
- Strip actions are interruptible (2026-06-13): show/hide-class actions (toggle / activate / minimize / hide) never lock clicks. At tap time the runtime writes an optimistic per-window state (`OptimisticWindowState` overlay in `AppRuntime`); chip rendering and the next toggle plan read the overlay first, so rapid re-clicks strictly alternate (minimize → restore → …) without waiting for the snapshot round-trip. The overlay clears when the real snapshot confirms the prediction, or silently rolls back after a 4s timeout. The pending spinner UI was removed entirely. Only close / quit (windows that disappear) still lock until confirmed, guarded inside `AppRuntime.trigger`, not in the UI.
- The action path is `UI -> IntentPipeline -> PlatformActionExecutor`.
- Current discovery is inventory-first when AX permission is available: normal App windows are the entry point, `CG` enriches them with visible-window evidence, Finder remains window-level, and Feishu may remain app-level fallback.
- Current identity now also uses the existing taskbar snapshot as a long-term seat map, so long-idle windows can be recognized after the short 6-second memory expires.
- The app has a read-only debug snapshot exporter for duplicate-card diagnosis.

## Collaboration Rule

- Every status update or result summary must start with a plain-language explanation first.
- In that plain-language explanation, say what changed, what it means for the product, and what happens next.
- When reporting progress, plans, risks, or results to the project owner, always explain it once in plain non-technical language.
- Assume the project owner is non-technical unless they explicitly ask for the engineering version.
- Do not only describe architecture, APIs, state machines, or pipelines; also explain the user-visible meaning, current impact, and next step in human terms.

## Important Non-Goals For This Phase

- No drawer strategy is final yet.
- Feishu real frontmost AX samples are useful but not blocking.
- Finder P0 acceptance does not mean the full taskbar is production-ready.
