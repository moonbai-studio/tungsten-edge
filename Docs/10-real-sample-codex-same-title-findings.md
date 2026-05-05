# Real Sample: Codex Same-Title Windows

> Recorded: 2026-05-03

## Sample

- Command:
  - `./Scripts/build_and_run.sh --lab-minimize "index:14"`
- Target at runtime:
  - app: `Codex`
  - pid: `42222`
  - baseline identity: `cg-56532`
  - baseline `CGWindowID`: `56532`
- Risk profile:
  - another visible window had the same title `Codex`

## Key Output

```text
# target keyword: index:14
# selected target: Codex
# baseline identity: cg-56532
# baseline cg id: 56532
# minimize action: mechanism=press-minimize-button verified_minimized=Optional(true) success=true
# target diagnostics (minimized):
  CG: kind=disappeared identity=cg-56532 cg_id=56532 minimized=false title="Codex" frame=277:178:1501:751
  AX: kind=minimized identity=cg-56532 cg_id=0 minimized=true title="Codex" frame=277:178:1501:751
# baseline cg id disappeared: true
# restore action: mechanism=clear-minimized-attribute verified_minimized=Optional(false) success=true
# target diagnostics (restored):
  CG: kind=appeared identity=cg-56532 cg_id=56532 minimized=false title="Codex" frame=277:178:1501:751
  AX: kind=unchanged identity=cg-56532 cg_id=0 minimized=false title="Codex" frame=277:178:1501:751
# acceptance passed: true
```

## Conclusion

- This real sample passes even with another same-title window from the same app still visible.
- The current lab path can disambiguate the target when we choose it explicitly by index or `cg:` selector.

## Notes

- This is a useful same-title regression sample because it proves the acceptance flow is not limited to unique titles.
- It also validates that the target-specific diagnostics stay focused on the chosen window rather than conflating both `Codex` windows.
