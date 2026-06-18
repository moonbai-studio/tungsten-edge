# Neo 坞

> 一个替代 macOS 系统 Dock 的任务条 App，以窗口为单位显示，多窗口 app 拆成多张卡片。

---

*以下为内部开发文档。*

> **📍 Source of truth = Obsidian, not this repo's prose.**
> Current product state, roadmap, and design decisions live in the owner's Obsidian vault:
> `/Users/caye/Documents/Obsidian Vault/Projects/macos-dock-cc-v2/` — key notes: `02 当前进度`, `03 设计决策`, `05 待办与想法/Backlog`.
> Files under `Docs/` are **dated historical findings, incident reports, and timeless macOS platform quirks** — accurate as of their dates, **not a live status board**; don't infer current features from them (`Docs/05-known-platform-quirks.md` is the exception worth keeping current — repo-local engineering reference).
> The "Current State" list below covers only the **foundation engine** (identity / placement / trust) and intentionally lags the UX feature layer (message chips, badges, drawer, native-tab merge…), which is tracked only in Obsidian.

## Current State

- Finder P0 window-level identity foundation was accepted on 2026-05-05.
- Identity and placement remain the current core.
- The app now renders a minimal usable bottom task strip.
- Strip actions now include activate / hide / minimize / close, with user-facing feedback.
- Main strip labels now toggle: click an inactive/minimized concrete window to activate it, and click the active concrete window to minimize it.
- Strip actions are interruptible (2026-06-13): no pending spinner, no click lock for show/hide-class actions; an optimistic per-window state overlay keeps rapid re-clicks strictly alternating. Only close / quit stay locked until confirmed.
- Technical quality fixes landed (2026-06-14, `6233111`): all major ObservableObject stores and pipeline classes are `@MainActor`; `DockBadgeReader` is a pure `Sendable` struct; `AppWindowObserver` AX callback uses `[weak obs]` + `MainActor.assumeIsolated`; all 6 timers have `.tolerance`; `hoverPollTimer` skipped on single-display machines; `AppIconResolver` uses `NSCache`; `NSVisualEffectView.state` is `.followsWindowActiveState`.
- Strip chips are drag-reorderable (2026-06-15, slices `e47146d`→`f248585`): drag a live window chip to reorder; the others slide aside live and the drop lands left/right of a target by which half the pointer is over. Order is session-internal (anti-scramble — existing chips keep position, new windows append at tail, only true-close drops them) and survives the taskbar app's own restart via `cgWindowID` + `kern.boottime` (deliberately not a cross-reboot layout). The pinned messaging zone keeps its own order, so reordering stays within-zone. Implemented with the system drag (cross-panel-ready for a future drag-chip-into-drawer); a minor system drag-image release fade remains, deferred to that work.
  - minimize / hide / temporary disappearance keep the slot
  - only true close releases the slot
- Feishu may fall back to a single stable app-level item when window-level AX detail is unreliable.
- Finder concrete folder windows are handled as window-level items and must not collapse into a generic Finder app item.
- A Finder minimize feedback bug was fixed: minimized or temporarily disappeared observations both count as successful minimize feedback.
- Taskbar trust hardening is now active: system/widget/internal windows are filtered before they can become strip items, and an anomaly-count fuse rejects obviously bad observation rounds before they mutate the trusted snapshot.
- Discovery is now inventory-first when Accessibility permission is available: the app starts from normal user App windows, then uses `CG` / `AX` evidence to enrich identity, frame, minimized, hidden, and focus state.
- The taskbar app now filters its own window from strip admission so the debug shell cannot self-pollute the taskbar.
- A long-gap duplicate-card issue was captured and fixed on 2026-05-13: before creating a new card, identity now checks the existing taskbar snapshot for a matching same-app, same-process seat.
- The app has a read-only debug snapshot exporter for duplicate-card diagnosis.
- `CG` fallback remains available when Accessibility permission is unavailable. Local rollback flags: `DOCK_INVENTORY_FIRST_ENABLED=0` or `DOCK_AX_ADMISSION_MODE=legacy`.
- Next product focus: keep running the fixed app on a real desktop, especially across long idle/sleep/overnight gaps, and confirm the strip shows normal user windows without fake/system/helper entries or duplicate cards.

## Docs

- [Agent Handoff](AGENTS.md)
- [Implementation Plan](Docs/06-implementation-plan.md)
- [Progress Board](Docs/07-progress-board.md)
- [Boundaries](Docs/01-boundaries.md)
- [Data Flow](Docs/02-data-flow.md)
- [Window Lab Output](Docs/03-window-lab-output.md)
- [Acceptance](Docs/04-acceptance.md)
- [Known Platform Quirks](Docs/05-known-platform-quirks.md)
- [Real Sample Findings](Docs/08-real-sample-minimize-restore-findings.md)
- [Calendar Sample Findings](Docs/09-real-sample-calendar-findings.md)
- [Codex Same-Title Findings](Docs/10-real-sample-codex-same-title-findings.md)
- [Browser Sample Findings](Docs/11-real-sample-browser-findings.md)
- [WeChat Sample Findings](Docs/12-real-sample-wechat-findings.md)
- [Feishu Current Observation](Docs/13-feishu-current-observation.md)
- [Placement Replay](Docs/14-placement-replay.md)
- [Feishu Fallback Strategy](Docs/15-feishu-fallback-strategy.md)
- [Finder Current Observation](Docs/16-finder-current-observation.md)
- [Finder P0 Implementation](Docs/17-finder-p0-implementation.md)
- [Finder Real Sample Findings](Docs/18-real-sample-finder-findings.md)
- [Taskbar Trust Incident](Docs/19-taskbar-trust-incident.md)
- [Inventory-First Taskbar Trust](Docs/20-inventory-first-taskbar-trust.md)
- [Long-Gap Duplicate Card Fix](Docs/21-long-gap-duplicate-card-fix.md)

## Build & Run

- `./Scripts/build_and_run.sh`
- `./Scripts/build_and_run.sh --verify`
- `./Scripts/build_and_run.sh --lab-replay <scenario-name>`
- `./Scripts/build_and_run.sh --lab-placement <scenario-name>`
- `./Scripts/build_and_run.sh --lab-transition <scenario-name>`
- `./Scripts/build_and_run.sh --lab-close "<keyword>"`

## Most Useful Checks

- Identity replay:
  - `./Scripts/build_and_run.sh --lab-replay minimize-restore-replay`
- Placement replay:
  - `./Scripts/build_and_run.sh --lab-placement placement-permanent-hold-replay`
- Transition replay:
  - `./Scripts/build_and_run.sh --lab-transition focused-active-replay`
  - `./Scripts/build_and_run.sh --lab-transition close-timeout-replay`
- Real close sample:
  - `./Scripts/build_and_run.sh --lab-close "<keyword>"`
- Real sample:
  - `./Scripts/build_and_run.sh --lab-minimize "日历"`
- Finder P0 sample:
  - `./Scripts/build_and_run.sh --lab-minimize "<unique Finder folder title>"`
- Finder title/tab replay:
  - `./Scripts/build_and_run.sh --lab-replay finder-title-tab-replay`
- Unit tests:
  - `xcodebuild test -project macos-dock-cc-v2.xcodeproj -scheme macos-dock-cc-v2Tests -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS'`
- Runtime taskbar snapshot:
  - Debug menu `导出任务条快照`（the only trigger; `Cmd+Shift+D` / `SIGUSR2` were attempted on 2026-06-12 and reverted — see `AGENTS.md`）
  - latest file: `$(getconf DARWIN_USER_TEMP_DIR)macos-dock-cc-v2-debug-snapshot-latest.json`

## Targets

- `window-lab`: CLI identity lab
- `macos-dock-cc-v2`: macOS app shell with minimal bottom strip
