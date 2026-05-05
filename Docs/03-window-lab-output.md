# Window Lab Output

```text
[TIME] [EVENT_TYPE] identity=<id> confidence=<HIGH|MEDIUM|LOW>
  signals: pid=<pid> cg_id=<id> title="<title>" frame=<frame>
  decision: <KNOWN_WINDOW|NEW_WINDOW|AMBIGUOUS> (<reason>)
  prev_state: <old> -> new_state: <new>
```

## Scenarios

`Tools/WindowLab/Scenarios/` 存放预设观察序列文件，用于复现典型路径并比对输出。

## Placement Replay

- `./Scripts/build_and_run.sh --lab-placement placement-permanent-hold-replay`
- `./Scripts/build_and_run.sh --lab-placement placement-close-release-replay`

`placementReplay` 直接驱动共享的 `PlacementEngine`，用于验证“最小化/隐藏后永久保位，只有关闭才释放位”这条主线规则。

## Transition Replay

- `./Scripts/build_and_run.sh --lab-transition focused-active-replay`
- `./Scripts/build_and_run.sh --lab-transition close-timeout-replay`

`transitionReplay` 直接驱动共享的 `ObservationPipeline` / `LifecycleTransitionEngine`，用于验证：

- focused AX 观察可以把窗口提升到 `active`
- close 超时不会被误判成 `closedPending`

## Real Close Sample

- `./Scripts/build_and_run.sh --lab-close "<keyword>"`

`closeTarget` 会选定一个真实窗口，通过 AX 触发 close，然后检查它是否仍残留在后续 live observations 中。
