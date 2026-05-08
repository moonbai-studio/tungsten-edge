# Data Flow

## 正向观察流

Platform -> Identity -> Lifecycle/Transitions -> Placement(按需) -> StateUpdate -> State -> UI

规则：每个系统事件只原子写入 State 一次。

## 任务条发现流

当前正式 app 在有 Accessibility 权限时走 inventory-first：

```text
NSWorkspace normal user apps
    ↓
WorkspaceSource reads AXWindows as appWindowInventory
    ↓
CG enriches visible window id / frame evidence
    ↓
ObservationAdmissionGate rejects orphan CG / AX ordinary candidates
    ↓
Identity / Lifecycle / Placement / State
```

Finder 和 Feishu 是记录过的例外：Finder 继续走专用窗口级路径，Feishu 可在窗口证据不可靠时保持 app-level fallback。

## 反向命令流

UI -> IntentPipeline -> Lifecycle/ActionPlanning -> Platform -> 系统事件回流 -> 正向观察流

规则：执行结果不能直接写回 State，必须等待系统事件回流。
