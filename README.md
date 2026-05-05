# macos-dock-cc-v2

v2 of the macOS window-oriented bottom taskbar experiment.

## Current State

- Identity and placement are the current core.
- The app now renders a minimal usable bottom task strip.
- Strip actions now include activate / hide / minimize / close, with user-facing feedback.
- Placement mainline is:
  - minimize / hide / temporary disappearance keep the slot
  - only true close releases the slot
- Feishu may fall back to a single stable app-level item when window-level AX detail is unreliable.
- Finder window-level identity is the next P0 focus: concrete folder windows must not collapse into a generic Finder app item.

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
- Finder next-thread sample:
  - `./Scripts/build_and_run.sh --lab-minimize "<unique Finder folder title>"`

## Targets

- `window-lab`: CLI identity lab
- `macos-dock-cc-v2`: macOS app shell with minimal bottom strip
