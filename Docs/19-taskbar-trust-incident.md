# Taskbar Trust Incident

> Recorded: 2026-05-07

## Product Summary

The taskbar briefly became untrustworthy: it showed many items that did not feel like real running app windows. In one debugging pass the visible/tracked count reached `103`, and later an over-collected state reached roughly `298/292`.

The user-visible meaning is simple: the strip was no longer showing "my real windows"; it was showing every window-like thing the system exposed.

## What Happened

- The app broadened `AX` observation so it could see more real windows.
- That also admitted too many internal/system surfaces.
- Once fake candidates entered the state flow, the product's correct keep-slot rule amplified the mistake:
  - minimize keeps a slot
  - hide keeps a slot
  - temporary `CG` disappearance keeps a slot
  - only true close releases a slot
- Those rules are still correct for real windows, but dangerous for untrusted candidates.

## Root Cause

The issue was not that keep-slot is wrong. The issue was that some candidates were trusted too early.

In plain language: we let strangers into the taskbar, then gave them the same "reserved seat" privilege as real windows.

## Fixes Already In Place

- A centralized eligibility policy filters fake/system candidates before they become strip items.
- `CoreGraphicsSource` and `AccessibilitySource` now use the eligibility policy.
- `AccessibilitySource` is stricter about window roles and standard window subroles.
- Process / path based filtering handles known system internals and app-extension windows.
- Activate feedback now trusts the immediate system execution result, so a successful activation does not flip into a false failure just because observation arrives late.
- A verified clean run showed a plausible state again: `已跟踪 11` / `可见 11`.

## Guardrail In Place

The anomaly-count fuse is now in place before a new observation round can replace the current snapshot.

Expected behavior:

- If the last trusted round had a plausible count and the next round suddenly jumps to dozens or hundreds, reject that round.
- Keep showing the last trusted snapshot.
- Log the rejected round for debugging.
- Tests simulate AX over-collection and prove the official taskbar does not accept the bad round.

This guardrail is important because future bugs should degrade into "we kept the last good view" instead of "the taskbar exploded into a hundred items."

## Root Fix Now In Place

The count fuse is a seatbelt, not the steering wheel.

The product-level fix is now in place: discovery changed from "bottom-up every CG/AX window-like surface" to "user app window inventory first".

- `WorkspaceSource` starts from normal user apps and their `AXWindows`, similar to what `System Events` reported in the 2026-05-07 diagnostic sample.
- Inventory observations enter as `.appWindowInventory`.
- `CG` proves visible windows, `cgWindowID`, frame, and screen presence.
- `AX` enriches minimized / hidden / focus state and supplies operation handles.
- Finder P0 and Feishu app-level fallback remain documented exceptions.
- Raw `CG` / `.accessibility` bottom-up candidates no longer decide ordinary strip membership while inventory-first is available.
- If Accessibility permission is unavailable, `CG` fallback remains allowed so the app still has a reduced-permission window list.
- If one App is unread for 30 consecutive inventory rounds, that PID becomes degraded and `CG` evidence can help decide whether it still exists.

## Rules For Future Work

- Do not widen `AX` sampling without a matching eligibility policy update.
- Do not let untrusted candidates benefit from keep-slot or `disappeared` retention.
- Keep user-app inventory as the strip entry point; use `CG` / `AX` as evidence, not as unrestricted admission sources.
- Treat Finder P0 as accepted; do not rebuild Finder foundations while fixing taskbar trust.
- Feishu may still use app-level fallback when per-window evidence is unreliable.

## Remaining Validation

The code path is implemented and unit/build validation passed for the checkpoint. The remaining work is real desktop validation:

- launch the formal app with Accessibility permission
- confirm normal user windows enter the strip
- confirm fake/system/helper surfaces stay out
- confirm Finder concrete windows and Feishu app-level fallback still behave as documented
