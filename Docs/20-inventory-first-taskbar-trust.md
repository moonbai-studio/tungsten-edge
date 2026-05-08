# Inventory-First Taskbar Trust

> Added: 2026-05-08

## Product Meaning

The taskbar no longer starts by trusting every window-like object that `CG` or broad `AX` scans can see.

It now starts from a more human idea: "which normal Apps have real windows?" After that, lower-level system signals are used to fill in details such as visible frame, `CGWindowID`, minimized state, focus, and action handles.

The intended user-visible result is:

- fewer fake/system/helper entries
- fewer missing normal App windows after trust cleanup
- Finder still behaves as concrete folder windows
- Feishu can still fall back to one stable App item when window-level evidence is unreliable

## Current Implementation

- `WorkspaceSource` enumerates `NSWorkspace.shared.runningApplications`.
- It skips terminated apps, prohibited activation-policy apps, Finder, and Feishu.
- It reads each App's `AXWindows` through `AXWindowReader`.
- It emits `SystemObservation.source == .appWindowInventory`.
- Inventory windows must be real AX windows with standard window subrole and must pass `DockWindowEligibilityPolicy`.
- Inventory observations can represent unchanged, minimized, hidden, unhidden, and disappeared states.
- `ObservationCollector` uses inventory-first whenever Accessibility permission is available and inventory-first mode is enabled.
- `CoreGraphicsSource` still runs, but ordinary orphan `CG` candidates cannot create new strip entries while inventory-first is available.
- Generic orphan `.accessibility` candidates are rejected in steady state.
- `CG` may still create entries when Accessibility permission is unavailable, preserving a reduced-permission fallback.

## Timing And Failure Rules

- Per-App inventory AX messaging timeout: `100ms`.
- Concurrent inventory reads: `12`.
- Consecutive unread threshold: `30` rounds.
- If an App is unread for 30 consecutive rounds and the process is still alive, that PID is marked degraded.
- For degraded inventory PIDs, `CG` evidence may be accepted so a stuck App does not freeze forever as a ghost entry.
- App launch follow-up polls run after about `200ms` and `700ms`.
- App activation follow-up poll runs after about `200ms`.

## Matching Rules

- Inventory entries create the trusted ordinary taskbar candidates.
- Later `CG` observations bind to inventory identities by PID, normalized title, and a tight frame match.
- The inventory-to-`CG` frame tolerance is `12px`.
- If a same-title sibling set cannot be uniquely matched, the code does not guess a `cgWindowID`.
- A window without a confirmed `cgWindowID` may still remain as an inventory-backed strip item; screenshot/thumbnail-like features should treat that as a degraded visual state until a later round binds it.

## Exceptions

- Finder remains a dedicated window-level source. Do not collapse Finder into app-level fallback.
- Feishu remains opportunistic and may use app-level fallback for:
  - `com.electron.lark`
  - `com.feishu.app`
  - `com.bytedance.lark`
- The anomaly-count fuse still sits before state mutation. If a future bug produces a huge suspicious round, the app keeps the last trusted snapshot.

## Rollback Flags

For local diagnosis only:

- `DOCK_INVENTORY_FIRST_ENABLED=0`
- `DOCK_AX_ADMISSION_MODE=legacy`

Either flag returns admission behavior to the legacy path in debug builds.

## Validation Status

Automated validation for this checkpoint passed before this document was added:

- `xcodebuild build -project macos-dock-cc-v2.xcodeproj -scheme macos-dock-cc-v2 -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS'`
- `xcodebuild test -project macos-dock-cc-v2.xcodeproj -scheme macos-dock-cc-v2Tests -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS'`
- `xcodebuild build -project macos-dock-cc-v2.xcodeproj -scheme window-lab -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS'`

Next validation is real desktop behavior: launch the app with Accessibility permission, confirm the bottom strip contains normal user windows, and confirm fake/system/helper surfaces do not enter.
