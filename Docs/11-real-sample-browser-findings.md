# Real Sample: Browser Minimize / Restore

> Recorded: 2026-05-03

## Sample

- Command:
  - `./Scripts/build_and_run.sh --lab-minimize "CPA json 格式 - Google 搜索"`
- Target at runtime:
  - app: `Google Chrome Canary`
  - pid: `762`
  - bundle id: `com.google.Chrome.canary`
  - baseline identity: `cg-199`
  - baseline `CGWindowID`: `199`

## Key Output

```text
# minimize action: mechanism=press-minimize-button verified_minimized=Optional(true) success=true
# target diagnostics (minimized):
  CG: kind=disappeared identity=cg-199 cg_id=199 minimized=false title="CPA json 格式 - Google 搜索" frame=0:30:1858:988
  AX: kind=minimized identity=cg-199 cg_id=0 minimized=true title="CPA json 格式 - Google 搜索 - 属于“ai 文档”群组 - Google Chrome Canary" frame=0:30:1858:988
# baseline cg id disappeared: true
# restore action: mechanism=clear-minimized-attribute verified_minimized=Optional(false) success=true
# target diagnostics (restored):
  CG: kind=appeared identity=cg-199 cg_id=199 minimized=false title="CPA json 格式 - Google 搜索" frame=0:30:1858:988
  AX: kind=unchanged identity=cg-199 cg_id=0 minimized=false title="CPA json 格式 - Google 搜索 - 属于“ai 文档”群组 - Google Chrome Canary" frame=0:30:1858:988
# acceptance passed: true
```

## Conclusion

- This browser sample passes.
- The acceptance flow now handles the Chromium title mismatch between:
  - `CG`: shorter page title
  - `AX`: page title plus group/browser suffix

## Notes

- A Chromium-specific normalization rule now strips:
  - browser suffixes such as ` - Google Chrome Canary`
  - group suffixes such as ` - 属于“... ”群组`
- That normalization lets minimized AX observations reconnect to the original identity instead of falling back to transient AX ids.

## Follow-up Notes

> Updated: 2026-05-04

- A later real desktop check showed that seeing multiple Chrome-related strip items does **not** automatically mean tab-level duplication.
- In the sampled runtime, Chrome exposed two real windows at the same time:
  - `ChatGPT`
  - `CLI Proxy API Management Center`
- After switching tabs inside one real Chrome window, the strip title updated to the newly focused tab title, but did not add a third Chrome strip item in that sample.
- Current assessment:
  - Chromium title normalization is helping the identity path.
  - The remaining browser work is more about activate smoothness and making sure stale disappeared items are cleaned up, not a proven “every tab becomes a strip item” regression.
