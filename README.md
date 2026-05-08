# macos-dock-cc-v2

v2 of the macOS window-oriented bottom taskbar experiment.

## Current State

- Finder P0 window-level identity foundation was accepted on 2026-05-05.
- Identity and placement remain the current core.
- The app now renders a minimal usable bottom task strip.
- Strip actions now include activate / hide / minimize / close, with user-facing feedback.
- Main strip labels now toggle: click an inactive/minimized concrete window to activate it, and click the active concrete window to minimize it.
- Placement mainline is:
  - minimize / hide / temporary disappearance keep the slot
  - only true close releases the slot
- Feishu may fall back to a single stable app-level item when window-level AX detail is unreliable.
- Finder concrete folder windows are handled as window-level items and must not collapse into a generic Finder app item.
- A Finder minimize feedback bug was fixed: minimized or temporarily disappeared observations both count as successful minimize feedback.
- Taskbar trust hardening is now active: system/widget/internal windows are filtered before they can become strip items, and an anomaly-count fuse rejects obviously bad observation rounds before they mutate the trusted snapshot.
- Discovery is now inventory-first when Accessibility permission is available: the app starts from normal user App windows, then uses `CG` / `AX` evidence to enrich identity, frame, minimized, hidden, and focus state.
- The taskbar app now filters its own window from strip admission so the debug shell cannot self-pollute the taskbar.
- `CG` fallback remains available when Accessibility permission is unavailable. Local rollback flags: `DOCK_INVENTORY_FIRST_ENABLED=0` or `DOCK_AX_ADMISSION_MODE=legacy`.
- Next product focus: run the app on a real desktop and confirm the strip shows normal user windows without fake/system/helper entries.

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

## Targets

- `window-lab`: CLI identity lab
- `macos-dock-cc-v2`: macOS app shell with minimal bottom strip
