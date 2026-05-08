# Feishu Fallback Strategy

> Added: 2026-05-03

## Product Rule

Feishu is no longer a window-level must-have in this phase.

The rule is:

- If a Feishu window can be recognized reliably, we may keep handling it at window level.
- If frontmost AX windows are unreliable, titles are missing, or titles collapse to a generic app title, Feishu may fall back to a single stable app-level item.

## Why

- Current runtime sampling already showed that Feishu can expose:
  - visible `CG` windows with empty titles
  - no usable `AXWindows` at the same moment
- Chasing perfect per-window Feishu fidelity would stall the mainline.

## Current Implementation

- Untitled or generic Feishu observations now fall back to:
  - `app-com.electron.lark`
  - or `app-com.feishu.app`
  - or `app-com.bytedance.lark`
- Supported Feishu / Lark bundle identifiers:
  - `com.electron.lark`
  - `com.feishu.app`
  - `com.bytedance.lark`
- That fallback is treated as a stable app item rather than a broken transient window item.
- The inventory-first path intentionally skips Feishu. Feishu remains on the documented fallback path because current runtime samples can expose empty `CG` titles and empty `AXWindows`.
- A running Feishu app-level fallback is retained while the process is alive; short observation gaps no longer delete it.

## Validation

- Replay:
  - [feishu-app-fallback-replay.json](/Users/caye/Projects/macos-dock-cc-v2/Tools/WindowLab/Scenarios/feishu-app-fallback-replay.json:1)
- Runtime observation record:
  - [13-feishu-current-observation.md](/Users/caye/Projects/macos-dock-cc-v2/Docs/13-feishu-current-observation.md:1)

## Non-Goals For This Phase

- We are not blocking the taskbar mainline on perfect Feishu per-window labels.
- If a reliable real Feishu frontmost AX window naturally appears later, we can add a real sample then.
