# Feishu Current Observation

> Recorded: 2026-05-03

## Runtime Snapshot

- Process:
  - name: `飞书`
  - bundle id: `com.electron.lark`
  - pid: `779`

## Observed State

- `CGWindowListCopyWindowInfo(.optionAll, ...)` returned multiple Feishu windows.
- Most visible `layer=0` Feishu windows currently had empty titles.
- `AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, ...)` returned success, but the resulting `AXWindows` array was empty at the moment we sampled it.

## Why This Matters

- A direct real minimize/restore run is not useful when the target app exposes:
  - titleless `CG` windows
  - no currently capturable `AX` windows
- That combination blocks the current real-sample executor from selecting a trustworthy AX target window.

## What We Added Instead

- A Feishu fallback strategy that accepts app-level handling when window-level AX detail is unreliable.
- Replay:
  - [feishu-app-fallback-replay.json](/Users/caye/Projects/macos-dock-cc-v2/Tools/WindowLab/Scenarios/feishu-app-fallback-replay.json:1)

## Current Takeaway

- We now have a defined product fallback for this Feishu-like path.
- We still need a later real sample when Feishu exposes an actual frontmost AX window that the lab can operate on.
