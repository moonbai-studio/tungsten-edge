# Finder P0 Implementation

> Added: 2026-05-05
> Accepted: 2026-05-05

## Product Meaning

Finder taskbar items now represent concrete folder windows for the P0 path, not the Finder app as a whole.

The intended click behavior is:

- click a non-front Finder item to activate that exact window
- click the already-front Finder item to minimize that exact window
- keep the taskbar slot while minimized, hidden, or temporarily disappeared
- fail visibly rather than activating the whole Finder app when the exact window cannot be captured
- show successful minimize feedback when macOS reports either `minimized` or temporary `disappeared`

## Implementation Notes

- `AccessibilitySource` skips `com.apple.finder`; Finder AX windows are owned by `FinderSource`.
- Finder identity stays anchored on `CGWindowID` when visible.
- Finder AX title/frame observations are used as side evidence to reconnect minimized or hidden windows.
- Finder does not use `app-com.apple.finder` fallback.
- Finder activate/minimize/close require a concrete AX handle. Activate retries briefly and confirms focus.
- Finder close release waits for the window to be absent from both live observations and AX capture for about two seconds while the Finder app is not hidden.
- Intent feedback now treats Finder minimize as successful if the observed record is either `.minimized` or `.disappeared`.

## Validation

- Pure logic XCTest target: `macos-dock-cc-v2Tests`
- Finder title/tab replay:
  - `./Scripts/build_and_run.sh --lab-replay finder-title-tab-replay`
- Real double-Finder-window minimize / restore sample:
  - [18-real-sample-finder-findings.md](/Users/caye/Projects/macos-dock-cc-v2/Docs/18-real-sample-finder-findings.md:1)
- Unit coverage includes signature merge rules, toggle planning, Finder filtering, and minimize feedback accepting temporary disappearance.
- User acceptance:
  - the project owner tested the Finder P0 app path and accepted this stage on 2026-05-05
  - a post-acceptance feedback bug was fixed where minimize succeeded but the app showed "没能最小化这个窗口"
