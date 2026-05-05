# AGENTS

## Purpose

This repo is `v2` of a macOS window-oriented bottom taskbar experiment.

The current phase prioritizes:

1. stable window identity
2. stable placement behavior
3. a minimal usable bottom strip in the app shell

Current checkpoint: Finder P0 window-level identity foundation was accepted on 2026-05-05.

Next-thread focus should start from the post-Finder-P0 state, not from rebuilding the Finder foundation.

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

### Finder

- Finder is **not** an app-level fallback target for this phase.
- Finder process existence does not mean there is a Finder window.
- Concrete Finder folder windows should remain window-level items when titles / frames are available.
- Do not fall back to activating the whole Finder app when a specific Finder window target cannot be captured; that can bring forward the wrong Finder window or multiple windows.
- Finder P0 implementation details are documented in `Docs/17-finder-p0-implementation.md`.
- Finder real sample findings are documented in `Docs/18-real-sample-finder-findings.md`.
- Finder minimize feedback treats either `minimized` or temporary `disappeared` observation as success, because macOS can report a minimized concrete Finder window through either path.

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

## Current App State

- The app already renders a minimal bottom task strip.
- Strip items can activate / hide / minimize / close.
- Strip item labels can toggle: inactive/minimized concrete windows activate, active concrete windows minimize.
- Strip actions now surface user-facing feedback and temporarily lock repeated clicks while work is pending.
- The action path is `UI -> IntentPipeline -> PlatformActionExecutor`.

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
