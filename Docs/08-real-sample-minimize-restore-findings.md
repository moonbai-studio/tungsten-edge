# Real Sample: Minimize / Restore Findings

> Recorded: 2026-05-03

## Sample

- Command:
  - `./Scripts/build_and_run.sh --lab-minimize "index:18"`
- Target at runtime:
  - app: `macos-dock-cc-v2`
  - pid: `4992`
  - baseline identity: `cg-56795`
  - baseline `CGWindowID`: `56795`

## Key Output

```text
# minimize action: mechanism=press-minimize-button verified_minimized=Optional(true) success=true
# target diagnostics (minimized):
  CG: kind=disappeared identity=cg-56795 cg_id=56795 minimized=false title="macos-dock-cc-v2" frame=567:325:900:450
  AX: kind=minimized identity=cg-56795 cg_id=0 minimized=true title="macos-dock-cc-v2" frame=567:325:900:450
# baseline cg id disappeared: true
# restore action: mechanism=clear-minimized-attribute verified_minimized=Optional(false) success=true
# target diagnostics (restored):
  CG: kind=appeared identity=cg-56795 cg_id=56795 minimized=false title="macos-dock-cc-v2" frame=567:325:900:450
  AX: kind=unchanged identity=cg-56795 cg_id=0 minimized=false title="macos-dock-cc-v2" frame=567:325:900:450
# acceptance passed: true
```

## Conclusion

- This real sample now passes.
- The earlier failure was caused by the lab counting `CG` `disappeared` events as if they were still visible current windows.
- After correcting that acceptance logic, the same SwiftUI shell sample shows the expected path:
  - AX minimize succeeded.
  - `CG` emitted a `disappeared` event for the target.
  - AX reported the target as minimized.
  - Restore returned the same stable identity.

## Notes

- This sample does **not** prove every app class is stable yet.
- It does prove the current lab can:
  - select a real target window
  - minimize and restore it automatically through AX
  - distinguish current visible `CG` windows from `disappeared` events
  - validate identity stability end-to-end on at least one real SwiftUI shell window
