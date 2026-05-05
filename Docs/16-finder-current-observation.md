# Finder Current Observation

> Recorded: 2026-05-05

## Product Takeaway

Finder must be treated as a window-level identity target in this phase.

It should not be treated like Feishu app-level fallback. A Finder process can live forever without implying that there is a usable Finder window, and activating the Finder app is not equivalent to activating a specific folder window.

## Current Runtime Facts

- Finder window titles are available from the system.
- Local sampling read concrete Finder titles such as:
  - `macos-dock-cc-v2`
  - `cpa`
  - `海龟汤`
  - `Core`
- Temporary test windows also exposed concrete names:
  - `codex-finder-test-alpha-20260505`
  - `codex-finder-test-beta-20260505`
- `CGWindowList` can report visible Finder windows with titles and frames.
- `AXWindows` can report Finder windows with titles and frames.

## Current Implementation Gap

- `FinderIdentityRule` exists only as a title-normalization entry.
- `Platform/Finder/FinderSource` currently returns no observations.
- `AccessibilitySource` currently scans only a small prefix of running apps; in one local sample Finder was much later in the running-app list, so it could be missed by steady-state AX observation.
- `PlatformActionExecutor` may fall back to activating the whole app when it cannot capture a concrete AX window handle. For Finder, that can bring forward the wrong folder window or multiple Finder windows.

## Verification So Far

- A targeted `window-lab` run passed when explicitly selecting a temporary Finder test window:
  - command: `./Scripts/build_and_run.sh --lab-minimize "codex-finder-test-alpha-20260505"`
  - result: the restored identity stayed stable as the same `cg-61049`
- This does **not** prove the formal app UI path is healthy.
- Formal app sampling showed an observation-loop risk:
  - `AccessibilitySource.observe()` was sampled around the `Dictionary(uniqueKeysWithValues:)` construction path.
  - If duplicate AX signatures occur in one observation round, the current unique-key dictionary construction can enter a Swift assertion / failure path.

## Next Thread Focus

The next thread should focus on Finder identity foundation before drawer strategy or UI expansion:

- Fix `AccessibilitySource` duplicate-signature handling so observation cannot stall or crash.
- Ensure Finder is always included in AX observation when Finder windows are present or tracked.
- Complete Finder window-level observation instead of relying on a blank `FinderSource`.
- Prevent Finder activate from falling back to coarse app activation when a concrete target window cannot be found.
- Add a Finder real-sample finding document once the double-window scenario is validated.

## Acceptance Target

Use two Finder folder windows with distinct names and frames.

The taskbar should keep each window distinct across:

- minimize -> restore
- Cmd+H hide -> unhide
- activate from inactive / disappeared-looking state
- repeated activate clicks while feedback is pending

Passing behavior:

- no title collapsing to generic `访达` when concrete window title exists
- no A-window click restoring B window
- no activate action bringing multiple Finder windows forward
- no long yellow pending state caused by missing observation feedback
