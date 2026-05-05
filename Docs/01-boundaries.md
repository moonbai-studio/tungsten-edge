# Boundaries

## Top-level

- `App/`: 入口、装配、场景。
- `Core/`: 业务脑子，不碰系统 API。
- `Platform/`: 观察系统、执行系统动作，不做业务判断。
- `UI/`: 消费 UI 读模型，不做业务判断。

## Core

- `Model/`: 跨模块边界传递的数据形状，不 import 任何 Core 子模块。
- `State/`: 单一真相仓，只存当前快照和最终结果。
- `Identity/`: 认窗。
- `Placement/`: 排位与保位。
- `Lifecycle/Transitions`: 系统事实驱动的状态转移建议。
- `Lifecycle/ActionPlanning`: 用户意图到系统动作请求的规划。

## UI ReadModel

- `UI/ReadModel` 自己接受 `Core/Model` 类型构造自己。
- `State/` 不负责投影转换。
