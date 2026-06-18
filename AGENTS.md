# AGENTS

> **📍 New agent: read this first.**
> The source of truth for current product state, roadmap, and design decisions is the owner's Obsidian vault — **not** this file or `Docs/`:
> `/Users/caye/Documents/Obsidian Vault/Projects/macos-dock-cc-v2/` — entry note: `00 macos-dock-cc-v2 总览.md`. Follow its own links for what's current; don't hardcode a sub-note list here, it drifts as the vault grows.
> This `AGENTS.md` and most of `Docs/` are scoped to the **foundation engine** (window identity / placement / taskbar trust) and **dated historical findings**. They do **not** track the UX feature layer (message chips, badges, drawer, native-tab merge…), which lives only in Obsidian. Treat dated `Docs/*` as historical records, not live status — except `Docs/05-known-platform-quirks.md`, which is kept current as repo-local engineering reference.

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

### Ghost Tab Seats (AX-absent window reaping)

- Some apps stop exposing background tabs as AX windows once tabs collapse into one window. Observed 2026-06-17: Ghostty exposes only the **active** tab as an AX window, and that window's `CGWindowID` changes as you switch tabs. The abandoned tabs vanish from AX but their real NSWindows linger off-screen in the full CG list — so the "still in CG → keep as minimized" veto retained them forever as phantom chips (one Ghostty window showed 5–6 chips).
- Reliable "is it really gone" signal is **AX-absence, not CG**: genuinely minimized / hidden / cross-Space / occluded windows all STAY in AX enumeration (minimized ones report `isMinimized=true`). Only permanently-gone seats vanish from AX entirely. Verified 2026-06-17: a window dragged to another Space stays in AX → never reaped.
- Rule: a tracked window absent from AX but still in CG is reaped after a short grace (`AppTracker.absentReapGrace`, ~1.5s), timestamped via `WindowEntry.absentSince` and reset the instant AX sees it again. The 0.5s frontmost poll reaps fast for the app in use; the 5s reconcile is the backstop.
- This is **not** the forbidden held-slot TTL (see Placement): that warned against expiring *real* minimized/hidden/CG-disappeared windows. This only reaps seats AX has permanently dropped — real windows never reach it because they stay in AX. Do not widen it to reap on CG-absence, and do not expire AX-present windows.

## Collaboration Rule

The project owner directs the product but does not read code, and does not read English comfortably — reply in Chinese.

- Write every status update, plan, and result so it's fully understandable with no engineering background: lead with what changed, what it means for how the app behaves, and what's next, in everyday language.
- Technical detail (file names, APIs, mechanisms) is a supplement that comes after the plain explanation, never the only way to follow the message. Don't make the owner decode jargon to understand what you did or why.
- When a choice needs the owner's input, frame it as product behavior and trade-offs they can weigh, not as implementation details.

