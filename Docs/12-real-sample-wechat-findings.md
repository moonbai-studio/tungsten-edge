# Real Sample: WeChat Windows

> Recorded: 2026-05-03

## Sample A

- Command:
  - `./Scripts/build_and_run.sh --lab-minimize "微信 (窗口)"`
- Target at runtime:
  - app: `WeChat`
  - bundle id: `com.tencent.xinWeChat`
  - pid: `769`
  - baseline identity: `cg-54053`
  - baseline `CGWindowID`: `54053`

### Key Output

```text
# minimize action: mechanism=press-minimize-button verified_minimized=Optional(true) success=true
# target diagnostics (minimized):
  CG: kind=disappeared identity=cg-54053 cg_id=54053 minimized=false title="微信 (窗口)" frame=352:134:1147:848
  AX: kind=minimized identity=cg-54053 cg_id=0 minimized=true title="微信 (窗口)" frame=352:134:1147:848
# acceptance passed: true
```

## Sample B

- Command:
  - `./Scripts/build_and_run.sh --lab-minimize "新线程开始时："`
- Target at runtime:
  - app: `WeChat`
  - bundle id: `com.tencent.xinWeChat`
  - pid: `769`
  - baseline identity: `cg-17981`
  - baseline `CGWindowID`: `17981`

### Key Output

```text
# minimize action: mechanism=press-minimize-button verified_minimized=Optional(true) success=true
# target diagnostics (minimized):
  CG: kind=disappeared identity=cg-17981 cg_id=17981 minimized=false title="新线程开始时：" frame=1090:236:700:640
  AX: kind=minimized identity=cg-17981 cg_id=0 minimized=true title="新线程开始时：" frame=1090:236:700:640
# acceptance passed: true
```

## Conclusion

- Both real WeChat samples passed.
- This gives us real-window evidence that the current identity path can hold across minimize/restore on WeChat windows, not only synthetic replay.

## Notes

- These samples are especially useful because WeChat was already treated as a special-case app in `Identity/Rules`.
- We still have not validated every WeChat content-type window in real usage, especially windows that are intentionally filtered by rule.
