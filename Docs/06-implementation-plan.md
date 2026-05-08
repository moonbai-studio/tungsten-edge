# v2 重做架构最终定稿

## 摘要

- v2 使用**新仓库**，目的不是整理旧目录，而是切断对 v1 解法的心理连续性。
- 新仓库使用**一个 Xcode 工程、两个构建目标**：
  - `window-lab`：命令行认窗实验台
  - `macos-dock-cc-v2`：正式 macOS app
- 第一阶段只做**认窗稳定**，UI 不是第一交付物。
- 顶层结构为 `App / Core / Platform / UI / Resources / Tools / Tests / Scripts / Docs`。
- `Lifecycle/` 保留，但内部拆成 `Transitions/` 与 `ActionPlanning/`。
- `State/` 是单一真相仓，状态落地由 `App/Composition` **一次原子写入**。

## 目录结构

```text
macos-dock-cc-v2/
├── App/
│   ├── Entry/
│   ├── Composition/
│   │   ├── ObservationPipeline/
│   │   └── IntentPipeline/
│   └── Scenes/
├── Core/
│   ├── Model/
│   ├── State/
│   ├── Identity/
│   │   └── Rules/
│   ├── Placement/
│   │   └── Rules/
│   └── Lifecycle/
│       ├── Transitions/
│       └── ActionPlanning/
├── Platform/
│   ├── Accessibility/
│   ├── CoreGraphics/
│   ├── Workspace/
│   ├── Finder/
│   └── Permissions/
├── UI/
│   ├── ReadModel/
│   ├── MainStrip/
│   ├── CollapsedDrawer/
│   ├── Menu/
│   ├── Components/
│   └── Style/
├── Resources/
├── Tools/
│   └── WindowLab/
│       ├── Entry/
│       ├── Formatting/
│       └── Scenarios/
├── Tests/
│   ├── Unit/
│   ├── Integration/
│   └── Fixtures/
├── Scripts/
└── Docs/
```

## 顶层边界

- `App/`
  - 只负责入口、依赖装配、场景和两条管线的组装。
  - 不写可测试业务判断。
- `Core/`
  - 程序脑子。
  - 不直接碰 `AXUIElement`、`CGWindowID`、`NSWorkspace` 等系统 API。
- `Platform/`
  - 只负责观察系统、翻译系统事件、执行系统动作。
  - 不做身份判断，不做排位，不直接改状态。
- `UI/`
  - 只消费 `State` 暴露的 UI 读模型。
  - 不直接决定身份、排位、生命周期状态。
- `Tools/WindowLab/`
  - 只有实验台自己的入口、输出格式化、预设场景。
  - 与正式 app **共享同一套 `Core/` 和 `Platform/` 正式代码路径**。
- `Shared/`
  - **不建立**。
  - 替代规则：每个文件必须能用一句不含“工具 / 通用 / 辅助”的话说明职责。

## Core 定稿

### `Model/`

- `Model/` 的含义固定为：
  - **跨模块边界传递的数据形状**
- `Model/` 里的类型**不得 import 任何 `Core/` 子模块**。
- `Identity / Lifecycle / Placement` 只负责生产这些类型，不负责定义它们。
- 放这里的典型类型：
  - `WindowID`
  - `AppID`
  - `WindowRecord`
  - `WindowStatus`
  - `SystemObservation`
  - `PlatformActionRequest`
  - `IdentityDecision`
  - `LifecycleDecision`
  - `PlacementResult`
  - `StateUpdate`
- **不放这里的类型**：
  - `StripItem`
  - 其他 UI 读模型
  - 它们属于 `UI/ReadModel/`

### `State/`

- **单一真相仓**，是 UI 和 App 可观察的唯一运行时状态出口。
- 只存当前快照和最终结果，不存认窗历史、时序推理过程。
- 不包含业务判断逻辑。
- 只依赖 `Core/Model/`，不依赖 `Identity / Placement / Lifecycle` 模块。
- `StateUpdate` 是 `Model/` 中定义的类型，不是 `State/` 内部类型。
- `State` 不负责从 Decision/Result 做转换，只接受 `Composition` 组装完成的完整 `StateUpdate`。

### `Identity/`

- 只回答“这是不是原来那个窗”。
- `WindowIdentityEngine` 是**有状态对象**。
- 它内部私有持有 `IdentityMemory`，不暴露给外部。
- 由 `App/Composition` 在启动时创建并持有，贯穿 app 生命周期。
- 特殊应用识别与过滤规则放 `Identity/Rules/`。
- 对飞书的当前阶段产品规则固定为：
  - **窗口级识别是 opportunistic**
  - **拿不到可靠前台 AX 窗口或标题不稳定时，允许退化为稳定应用级条目**

### `Placement/`

- 只回答“它该站哪、是否保位、何时释放位置”。
- “最小化后是否保位、何时释放位置、是否进抽屉”都归这里。
- 特殊显示与排位规则放 `Placement/Rules/`。
- 当前主线产品规则固定为：
  - **最小化 / 隐藏 / 临时消失都不释放位置**
  - **只有真正关闭才释放位置**

### `Lifecycle/`

- 保留独立目录，但内部拆成两块：
  - `Transitions/`
    - 处理 **Identity 产出的 `IdentityDecision`** 与生命周期观察事件，给出状态转移建议
  - `ActionPlanning/`
    - 处理用户意图 + 当前状态，产出应执行的系统动作请求
- 总边界固定如下：
  - 输入：
    - `IdentityDecision`
    - 生命周期相关观察事件
    - 当前 `State` 快照
    - 用户意图
  - 输出：
    - `LifecycleDecision`
    - `PlatformActionRequest`
- 明确禁止：
  - 不存状态
  - 不做身份判断
  - 不直接调系统 API
  - 不自己决定主栏排位
- 分界原则：
  - **系统事实**归 `Lifecycle`
    - 例如窗口现在是 minimized / active / hidden
  - **产品决策**归 `Placement`
    - 例如 minimized 后永久保位、关闭后释放位置、是否进抽屉

## UI 读模型

- `UI/ReadModel/` 是 UI 层统一消费的投影类型目录。
- `StripItem`、抽屉条目、菜单展示模型都放这里。
- `State` 不负责把 `Core/Model` 转成 UI 模型。
- 采用固定规则：
  - **`UI/ReadModel` 类型自己接受 `Core/Model` 类型作为构造参数，完成投影转换**
- 这样依赖方向保持为：
  - `UI` 依赖 `Core`
  - `Core` 不依赖 `UI`

## Composition 定稿

- `App/Composition` 不做成一个总协调器，改为**两条明确管线**：
  - `ObservationPipeline/`
  - `IntentPipeline/`

### `ObservationPipeline`

- 处理正向观察流。
- 顺序：
  - `Platform` 观察事件
  - `Identity` 身份判断
  - `Lifecycle/Transitions` 状态转移建议
  - 按需触发 `Placement`
  - 组装完整 `StateUpdate`
  - **一次性原子写入 `State`**
- 硬规则：
  - 每处理一个系统事件，对 `State` **只有一次写入**
  - 不允许先写入“半成品状态”，再补写 `Placement` 结果
  - UI 只能看到完整快照
- `Placement` 触发条件固定为：
  - **只有排位相关变化才触发重算**
  - 例如：
    - `WindowStatus` 变化
    - 主栏成员集合变化
    - 明确影响顺序的事件
  - 普通 frame 变化默认跳过 `Placement`，直接组装 `StateUpdate`

### `IntentPipeline`

- 处理用户意图流。
- 顺序：
  - UI 发出用户意图
  - 读取当前 `State` 快照
  - `Lifecycle/ActionPlanning` 将“用户意图 + 当前状态”翻译成 `PlatformActionRequest`
  - `Platform` 执行系统调用
  - 等待系统事件回流
- 硬规则：
  - 执行结果**不能直接写回 `State`**
  - 必须等系统事件回流，再通过 `ObservationPipeline` 更新状态

## 数据流

### 正向观察流

```text
macOS 系统事件
    ↓
Platform
    ↓
Identity
    ↓
Lifecycle/Transitions
    ↓
(仅在排位相关变化时) Placement
    ↓
ObservationPipeline 组装完整 StateUpdate
    ↓
一次性写入 State
    ↓
UI
```

### 反向命令流

```text
UI 用户操作
    ↓
IntentPipeline
    ↓
Lifecycle/ActionPlanning（基于当前状态规划动作）
    ↓
Platform（执行系统调用）
    ↓
macOS 系统事件回流
    ↓
走正向观察流更新 State
```

## `window-lab` 规则

- `window-lab` 和正式 app **共享** `Core/` 与 `Platform/` 的所有正式代码。
- 它只有自己的：
  - `Entry/`
  - `Formatting/`
  - `Scenarios/`
- 第一阶段第一天就固定结构化输出格式：

```text
[TIME] [EVENT_TYPE] identity=<id> confidence=<HIGH|MEDIUM|LOW>
  signals: pid=<pid> cg_id=<id> title="<title>" frame=<frame>
  decision: <KNOWN_WINDOW|NEW_WINDOW|AMBIGUOUS> (<reason>)
  prev_state: <old> -> new_state: <new>
```

- `Scenarios/` 的定义写死：
  - 存放预设的观察序列文件
  - 每个文件描述一个典型场景（如“最小化再恢复”）
  - 用于在没有真实系统事件时复现状态转移路径，对比 `window-lab` 输出是否符合预期

## 已知平台怪癖文档

- 新增：
  - `Docs/05-known-platform-quirks.md`
- 第一批已知行为至少写入：
  - `CGWindowID` 在最小化后会从默认窗口列表里消失
  - Accessibility 通知在某些应用里不可靠（尤其微信、飞书）
  - Finder 进程长期存在，不等价于“有 Finder 窗口”
  - 某些 app 创建窗口时标题先为空，延迟后才填入真实标题
- 目的：
  - 让 Platform / Identity 实现者知道这是系统特性，不是第一反应就当成自己代码 bug

## 实施顺序（最终版）

1. 新仓库与双目标工程骨架
2. `Platform` 最小观察事件通路
3. `Identity` 最简版
   - 先只做 `cgID` 直接匹配，跑通主路径
4. `window-lab` 结构化输出
   - 此时 `identity` 字段已有真实值
   - `decision` 先只有 `KNOWN_WINDOW` 和 `NEW_WINDOW`
   - `confidence` 第一版可先固定为 `HIGH`
5. `Identity` 完整版
   - 时序推断
   - 置信度累积
   - 特殊应用识别规则
6. `State` 单一真相仓
7. `Lifecycle/Transitions`
8. `Placement` 保位与顺序逻辑
9. `Lifecycle/ActionPlanning`
10. 最后接最简 app UI

## 2026-05-07 任务条可信度执行计划

### 目标

- 这轮不是重做 Finder 地基，而是把任务条可信度收口到“正式 app 可构建、异常爆量不会污染主快照、飞书 fallback 不会被观察缺口误删”。
- 本轮完成标准只有三个：
  - `macos-dock-cc-v2` 正式 app target 重新 build 通过
  - 单轮异常爆量会被整轮拒收，UI 继续显示上一份可信快照
  - 飞书 app-level fallback 只因进程退出而释放，不因短时采样缺口释放

### 执行顺序

1. **先恢复 target wiring**
   - 把 `ObservationAdmissionGate.swift` 接入 `macos-dock-cc-v2` target。
   - 把 `AXWindowMatchPolicy.swift` 与 `WindowFrameMatchPolicy.swift` 接入所有实际引用它们的 target。
   - 以 `xcodebuild build -project macos-dock-cc-v2.xcodeproj -scheme macos-dock-cc-v2 -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS'` 通过为硬门槛。

2. **保留 source hardening，但明确它不是最终保险**
   - `DockWindowEligibilityPolicy` 继续负责“这个候选看起来像不像真实可操作窗口”。
   - `ObservationAdmissionGate` 继续负责“陌生 AX-only 候选不要第一轮就进入正式状态”。
   - 当前 gate 的职责固定为“预热闸门”，不再承担“整轮异常爆量保护”。

3. **新增 round-level anomaly fuse**
   - 新 guard 放在 `AppComposition.applyObservations` 的 round 入口，先看整轮候选规模，再决定是否允许这轮进入正式状态流。
   - 这层 guard 在任何 `State`、`IdentityMemory`、close tracker 被修改之前执行；如果整轮拒收，就直接返回当前快照，不做回滚逻辑。
   - 判断口径固定为：
     - 基线使用当前可信快照里的非 `disappeared` 条目数
     - 本轮规模使用去掉 `disappeared` 后、按 `pid + bundle/app + normalizedTitle + frame bucket` 粗去重的候选数
     - 当基线大于 `0`，且本轮候选数同时满足 `>= 48` 且 `>= 基线 * 3` 时，判定为异常爆量
   - 爆量时行为固定为：
     - 拒收整轮
     - 保留上一份可信快照
     - 记录一条带基线数量、本轮数量、主要来源分布的日志

4. **修正飞书 fallback retention**
   - 这轮先不做飞书从 app-level fallback 自动晋升回 window-level 的复杂迁移设计。
   - 对 `app-com.electron.lark` / `app-com.feishu.app` / `app-com.bytedance.lark`：
     - 只要进程仍存活，就继续保留条目
     - 不再使用“缺少 live observation 达 5 秒就删掉”的时间窗策略
     - 只有进程退出，或已有更明确的退出确认，才释放条目
   - 这条规则优先级高于“观察缺口 -> 视为外部关闭”的通用兜底。

5. **最后补回归验证**
   - 单元测试新增一组任务条可信度测试，独立覆盖：
     - source eligibility 过滤
     - AX-only 预热 gate
     - round-level anomaly fuse
     - 飞书 fallback retention
   - 命令级验证固定为：
     - `xcodebuild build -project macos-dock-cc-v2.xcodeproj -scheme macos-dock-cc-v2 -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS'`
     - `xcodebuild test -project macos-dock-cc-v2.xcodeproj -scheme macos-dock-cc-v2Tests -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS'`

### 本轮明确不做

- 不重开 Finder P0 地基，不把 Finder 再退回 app-level fallback。
- 不把 `ObservationAdmissionGate` 扩成唯一总保险。
- 不在这一轮解决飞书完整窗口级保真或 app-level / window-level 双向迁移。

## 2026-05-08 用户 App 窗口清单准入实现收口

> Status: implemented in the formal app mainline.

### 目标

- 这轮不是继续把过滤名单越补越长，而是把任务条发现入口从“底层窗口扫描”改成“用户 App 窗口清单优先”。
- 产品效果：Finder、Chrome、微信、Photoshop、Terminal、Illustrator、Codex、飞书等真实用户窗口应能被纳入任务条；`Software Cursor`、helper、系统内部面板不应进入。
- 改动复杂度评估为中等：不推翻 `Core` / `State` / `Placement`，但会新增一个更靠近产品语义的候选入口，并调整 `CG` / `AX` 在准入中的职责。

### 实现结果

- 新增 `.appWindowInventory` 来源，语义是“正常 App 自己报出来的窗口”。
- `WorkspaceSource` 通过 `NSWorkspace.shared.runningApplications` 枚举用户 App，再用 `AXWindowReader` 读取每个 App 的 `AXWindows`。
- inventory 读取配置固定为：
  - per-app AX messaging timeout: `100ms`
  - 并发上限: `12`
  - 连续 unread 降级阈值: `30` 轮
- inventory 跳过 Finder 和 Feishu：
  - Finder 继续由 `FinderSource` 负责具体窗口
  - Feishu 继续走 app-level fallback 例外
- 有 AX 权限时，普通任务条新条目必须来自 inventory、Finder 或 Feishu 例外；裸 `CG` / `.accessibility` 不再单独准入。
- 缺 AX 权限时，`CG` fallback 仍可创建条目，保证降级可用。
- 如果某个 App 连续 unread 后进入 degraded 状态，`CG` 可作为这个 PID 的存在性降级证据。
- 新 App 补轮询已接入：
  - launch 后约 `200ms` 和 `700ms`
  - activate 后约 `200ms`
- Debug rollback flag 已接入：
  - `DOCK_INVENTORY_FIRST_ENABLED=0`
  - `DOCK_AX_ADMISSION_MODE=legacy`

### 原计划与当前对应

1. **新增用户 App 窗口清单入口**
   - 已完成。正式实现复用 `NSRunningApplication` + `AXWindowReader` / Accessibility API，不把 shell 调用 `osascript` 作为主路径。
   - 输出仍使用 `SystemObservation`，并通过 `.appWindowInventory` 区分裸 `AX-only` 候选。

2. **调整准入模型**
   - 已完成。用户 App 窗口清单是普通任务条条目的候选入口。
   - `CG` 负责证明可见窗口、`cgWindowID`、frame 和当前屏幕存在。
   - `AX` 负责补充 minimized / hidden / focused 状态，以及执行窗口操作所需的 handle。
   - 裸 `CG` / `AX` 底层扫描不得单独决定一个新条目是否进入任务条，除非走 Finder / Feishu 已记录的例外规则，或 AX 权限不可用的 `CG` fallback。

3. **合并同一真实窗口**
   - 已完成第一版。`WindowIdentityEngine` 可把后续 `CG` 观察绑定到 inventory identity。
   - 同 PID / 标题 / frame 的匹配使用 `12px` 紧容差；同标题兄弟窗口无法唯一命中时不猜。
   - Chrome / Chromium 标题归一化继续保留，避免 `CG` 标题和 `AX` 标题后缀不同导致重复或漏收。
   - 最小化或隐藏窗口如果来自用户 App 窗口清单，可保留条目；helper / 工具光标仍需经过 eligibility policy。

4. **保留现有防线**
   - 已完成。`ObservationRoundAnomalyFuse` 继续保留，防止未来采样 bug 一次性污染快照。
   - `DockWindowEligibilityPolicy` 继续过滤明显系统 / helper / extension / transparent / tool cursor 类型。
   - Finder P0 不重做，Feishu 继续允许 app-level fallback。

### 下一步验收标准

- 当前真实桌面样本中，任务条不应只剩 3 个条目；应能纳入诊断采样确认的用户 app 窗口。
- `Software Cursor` / `com.openai.sky.CUAService` 不得进入任务条。
- 最小化或隐藏的真实用户窗口可被保留，但系统内部窗口不能享受 keep-slot。
- 正式 app build 和 `macos-dock-cc-v2Tests` 继续通过。

## 测试与验收

### 结构验收

- 没有 `DockStore.swift` 式超级总管文件
- 没有 `Shared/` 杂物间
- `window-lab` 和正式 app 共享同一套 `Core/`、`Platform/`
- `State` 是 UI 的唯一状态出口
- `Composition` 拆成两条管线，不存在一个万能协调器
- `ObservationPipeline` 每事件只原子写入 `State` 一次

### 行为验收

- 在以下场景里，同一个窗口必须保持同一个 identity，不允许 ID 漂移：
  - 最小化再恢复
  - 移动窗口位置
  - 改变窗口大小
  - 标题变化（例如浏览器切换标签页）
    - 预期行为：仍然是 `KNOWN_WINDOW`，不得误判为 `NEW_WINDOW`
  - `Cmd+H` Hide 再 Unhide
- 任一场景发生 ID 漂移，第二阶段 UI 主线不开始。

### 测试策略

- `Identity` 和 `Placement` 以单元测试为主，不依赖真实 macOS API。
- `window-lab` 用于人工观察与日志比对。
- `Platform` 用少量集成测试验证事件翻译，不承担主逻辑正确性验证。

## Docs 第一批内容

- `00-why-v2.md`
  - 为什么重做，v1 只保留什么资产
- `01-boundaries.md`
  - `App / Core / Platform / UI` 边界规则
- `02-data-flow.md`
  - 正向观察流与反向命令流两张图
- `03-window-lab-output.md`
  - `window-lab` 输出格式、字段说明、Scenarios 定义
- `04-acceptance.md`
  - 第一阶段行为验收场景
- `05-known-platform-quirks.md`
  - 已知平台怪癖

## 假设与默认

- 默认 v2 是彻底重启，不与 v1 长期并排主开发。
- 默认新仓库是为了切断旧思路惯性，而不只是重排目录。
- 默认 `Lifecycle/` 保留，但严格按上述输入输出边界执行。
- 默认 `Placement` 管保位与释放位，`Lifecycle` 只处理系统事实与动作规划。
- 默认第一阶段以认窗实验台为主，不提前进入任务栏 UI 打磨。
