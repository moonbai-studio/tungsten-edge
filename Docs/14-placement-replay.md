# Placement Replay

> Added: 2026-05-03

## Purpose

`placementReplay` is the repeatable validation path for shared `PlacementEngine` rules.

It exists so we can change placement logic without going back to one-off local scripts.

## Commands

- `./Scripts/build_and_run.sh --lab-placement placement-permanent-hold-replay`
- `./Scripts/build_and_run.sh --lab-placement placement-close-release-replay`

## Current Scenarios

### `placement-permanent-hold-replay`

- Initial order: `A,B,C`
- `B` is minimized
- `B` is hidden
- `B` temporarily disappears
- `B` returns later
- Expected final order: `A,B,C`

### `placement-close-release-replay`

- Initial order: `A,B,C`
- `B` truly closes
- `B` later comes back as a new window
- Expected final order: `A,C,B`

## Why It Matters

- Verifies that minimize / hide / temporary disappearance do not release a slot.
- Verifies that only close releases a slot.
- Keeps `Placement` validation on the same shared code path used by the app.
