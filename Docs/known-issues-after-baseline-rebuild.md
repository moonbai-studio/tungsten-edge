# Known Issues After Baseline Rebuild

> Recorded: 2026-05-26

## Context

The current baseline is `9d6382e` plus two rebuilt stages:

- Stage 1: AX taskbar window prefilter.
- Stage 2: single-app icon-only taskbar chips.

Multi-day real desktop use did not reproduce the click-disappears issue in this baseline. The issues below are tracked separately from that investigation.

## Finder Multi-Window Identity Mismatch

Status: open, independently tracked.

Plain-language symptom: multiple real Finder windows can be present, but the taskbar may show the wrong Finder card count or bind actions to a different Finder window than the one the user expects.

Classification from captured evidence: B, identity / multi-window aggregation mismatch.

Evidence:

- `/tmp/finder-multi-window-issue-20260523/`
- `/tmp/finder-stage2-replay-20260523/`

Known reproduction shape:

1. Open three Finder windows with distinct titles, for example Downloads, Documents, and Desktop.
2. Confirm the taskbar shows Finder cards for the open windows.
3. Close Finder windows one by one while watching the remaining taskbar cards and their bound titles.
4. If the taskbar count, title, or action target diverges from the visible Finder windows, capture the timestamp and export a debug snapshot before changing the window state.

## Occasional Taskbar Label Position Change

Status: weak signal, needs a stable reproducing sample.

Plain-language symptom: a taskbar item label or position may occasionally change unexpectedly during real use. One Photoshop minimize run was suspected, but the controlled replay did not reproduce the shift.

Evidence:

- `/tmp/ps-icon-shift-20260523/`
- `/tmp/baseline-stage12-runtime-trace/`

Known reproduction shape:

1. Keep the baseline app running with runtime trace enabled.
2. Use normal desktop workflows and watch for taskbar order or label-position changes.
3. If the issue appears, record the exact timestamp and avoid changing the window state before trace review or snapshot export.
