# Real Sample: Calendar Minimize / Restore

> Recorded: 2026-05-03

## Sample

- Command:
  - `./Scripts/build_and_run.sh --lab-minimize "日历"`
- Target at runtime:
  - app: `Calendar`
  - pid: `20288`
  - baseline identity: `cg-34875`
  - baseline `CGWindowID`: `34875`

## Key Output

```text
# minimize action: mechanism=press-minimize-button verified_minimized=Optional(true) success=true
# target diagnostics (minimized):
  CG: kind=disappeared identity=cg-34875 cg_id=34875 minimized=false title="日历" frame=475:306:935:598
  AX: kind=minimized identity=cg-34875 cg_id=0 minimized=true title="日历" frame=475:306:935:598
# baseline cg id disappeared: true
# restore action: mechanism=clear-minimized-attribute verified_minimized=Optional(false) success=true
# target diagnostics (restored):
  CG: kind=appeared identity=cg-34875 cg_id=34875 minimized=false title="日历" frame=475:306:935:598
  AX: kind=unchanged identity=cg-34875 cg_id=0 minimized=false title="日历" frame=475:306:935:598
# acceptance passed: true
```

## Conclusion

- This second real sample also passes.
- The same end-to-end path now works on a non-SwiftUI app window:
  - minimize by AX
  - `CG` disappearance during minimize
  - restore by AX
  - stable identity after restore

## Why This Matters

- The real-sample path is no longer validated on only one app class.
- We now have evidence that the current acceptance tool works on:
  - the local `macos-dock-cc-v2` SwiftUI shell
  - Calendar
