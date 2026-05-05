# Data Flow

## 正向观察流

Platform -> Identity -> Lifecycle/Transitions -> Placement(按需) -> StateUpdate -> State -> UI

规则：每个系统事件只原子写入 State 一次。

## 反向命令流

UI -> IntentPipeline -> Lifecycle/ActionPlanning -> Platform -> 系统事件回流 -> 正向观察流

规则：执行结果不能直接写回 State，必须等待系统事件回流。
