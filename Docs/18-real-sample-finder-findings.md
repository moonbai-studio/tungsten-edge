# Real Sample: Finder Windows

> Recorded: 2026-05-05

## Product Result

Two concrete Finder folder windows with unique names were validated independently.

Each Finder folder window minimized and restored with its own stable identity. The sibling Finder window stayed separate and was not mistaken for the target.

## Sample Windows

- `codex-finder-test-alpha-20260505082841`
  - baseline identity: `cg-61692`
  - baseline `CGWindowID`: `61692`
  - acceptance: passed
- `codex-finder-test-beta-20260505082841`
  - baseline identity: `cg-61693`
  - baseline `CGWindowID`: `61693`
  - acceptance: passed

## Key Evidence

- Alpha minimized:
  - target `CGWindowID` disappeared from the visible CG list
  - restored target came back as `cg-61692`
  - beta remained present as `cg-61693`
- Beta minimized:
  - target `CGWindowID` disappeared from the visible CG list
  - restored target came back as `cg-61693`
  - alpha remained present as `cg-61692`

## Current Takeaway

This validates the first real double-Finder-window minimize / restore path.

Finder P0 was later accepted through the formal app UI path on 2026-05-05.

Accepted UI behavior:

- click active Finder label -> minimize that same window
- click inactive Finder label -> activate that same window
- Cmd+H Hide / Unhide should keep identities and taskbar positions stable
- strict hidden Finder toggle should fail rather than unhide the whole Finder app when single-window restore cannot be confirmed

Post-acceptance fix:

- If the Finder window really minimized but the observation record is temporarily `disappeared`, minimize feedback now reports success instead of "没能最小化这个窗口".
