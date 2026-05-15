# Long-Gap Duplicate Card Fix

> Recorded: 2026-05-13

## Product Summary

The taskbar really did create duplicate cards after a long desktop observation gap.

This was not only a SwiftUI display issue. A debug snapshot exported from the running app showed the internal taskbar state had grown to `35` tracked cards, with clear duplicate groups for Chrome Canary, Codex, Terminal, WeChat, Illustrator, Finder, and Wanlian SD-WAN.

The user-visible bug was simple: the same real window could appear multiple times in the strip after the app had been left running for a long time.

## Evidence

The debug snapshot export was triggered without restarting or clearing state:

- running app process before fix: `57544`
- snapshot time: `2026-05-13 11:08:00 +0800`
- snapshot path pattern:
  - `$(getconf DARWIN_USER_TEMP_DIR)macos-dock-cc-v2-debug-snapshot-latest.json`
- internal result:
  - `trackedCount = 35`
  - `visibleCount = 35`
  - `duplicateGroups = 8`

Duplicate groups included:

- `com.google.Chrome.canary`
- `com.openai.codex`
- `com.apple.Terminal`
- `com.tencent.xinWeChat`
- `com.adobe.illustrator`
- `com.apple.finder`
- `com.digiflow.wanflow`

## Root Cause

The 6-second identity memory was doing what it was designed to do: it only handled short-term observation jitter.

After a long gap, that short memory had expired. The taskbar still had old cards in `DockSnapshot`, but identity matching only used retained seats for minimized, hidden, or temporarily disappeared windows. It did not use active or inactive existing cards as long-term identity anchors.

So when the same still-live window reported again after the gap, the identity engine could fail to recognize it as the old card and create a fresh transient card instead.

In plain language: the app forgot the short-term memory, but it did not check the seating chart it was still holding.

## Fix

`WindowIdentityEngine` now checks the current snapshot before issuing a new identity.

The matching rules are deliberately conservative:

- same process
- same app / bundle
- never match app-level fallback IDs such as `app-*`
- never match `closedPending`
- prefer title + nearby frame
- if title changed, allow unique nearby frame
- if frame moved, allow unique title
- if more than one candidate looks plausible, do not guess

This applies to both:

- retained seats: minimized, hidden, disappeared
- existing live seats: active, inactive

The fix is app-agnostic. Chrome, Illustrator, WeChat, Finder, Terminal, Codex, Photoshop, and Wanlian are validation samples, not special-case code paths.

## Validation

Automated validation after the fix:

- `git diff --check`
- `xcodebuild test -project macos-dock-cc-v2.xcodeproj -scheme macos-dock-cc-v2Tests -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS'`
- `xcodebuild build -project macos-dock-cc-v2.xcodeproj -scheme macos-dock-cc-v2 -configuration Debug -derivedDataPath build/DerivedData`

Added unit coverage includes:

- retained minimized window returns after long gap
- retained window with changed title returns by unique frame
- retained window with moved frame returns by unique title
- active/inactive window returns after long gap
- active/inactive window with changed title returns by unique frame
- active/inactive window with moved frame returns by unique title
- CG observation can bind to an existing active snapshot seat after long gap
- ambiguous title/frame candidates do not merge
- app-level fallback IDs are not treated as concrete window seats
- closed-pending records are not revived

Runtime after restarting into the fix:

- new app process: `8556`
- restart time: `2026-05-13 11:25:33 +0800`
- baseline snapshot time: `2026-05-13 11:27:37 +0800`
- `trackedCount = 12`
- `visibleCount = 12`
- `duplicateGroups = 0`

## Current Status

The first confirmed long-gap duplicate-card root cause is fixed.

This does not prove the entire taskbar is production-ready. The next validation step is to keep using the app on the real desktop, especially across long idle/sleep/overnight gaps, and export a debug snapshot immediately if duplicates reappear.
