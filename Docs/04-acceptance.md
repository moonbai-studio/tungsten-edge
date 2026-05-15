# Acceptance

## 第一阶段行为验收

同一窗口在以下场景不得发生 identity 漂移：

- 最小化再恢复
- 移动窗口位置
- 改变窗口大小
- 标题变化
- Cmd+H Hide 再 Unhide

## Finder 专项验收

访达必须按具体文件夹窗口验收，而不是按 `访达` 应用总项验收。

当前状态：Finder P0 已在 2026-05-05 通过项目 owner 手测验收。最小化成功但提示失败的问题已修正为反馈判断问题：`minimized` 和临时 `disappeared` 都算作最小化成功。

- 两个不同 Finder 文件夹窗口同时存在时，任务条必须保持两个独立条目。
- 最小化 / 恢复其中一个 Finder 窗口时，不得恢复成另一个 Finder 窗口。
- Hide / Unhide 后，Finder 窗口身份和位置不得漂移。
- 激活某个 Finder 条目时，不得粗暴拉起整个 Finder app 导致多个 Finder 窗口一起出现。
- 当具体 Finder 标题存在时，任务条不应退回只显示通用 `访达`。

## Placement 验收

- 窗口最小化后，恢复时必须回到原来的位置。
- 窗口隐藏后，恢复时必须回到原来的位置。
- 临时 `CG` 消失不应释放位置。
- 只有真正关闭，才释放这个位置。

## 任务条可信度验收

当前状态：inventory-first 入口已在 2026-05-08 接入。真实桌面手测已开始，并在 2026-05-13 抓到且修复了一类长时间断档后的重复卡片问题。

- 正常用户 App 窗口应能进入任务条，不应回到 `已跟踪 3` / `可见 2` 这种明显漏收状态。
- `Software Cursor`、系统小组件、Notification Center、Control Center、app extension/helper 窗口不得进入任务条。
- 有 Accessibility 权限时，普通孤儿 `CG` / `.accessibility` 候选不得单独创建新条目。
- 缺少 Accessibility 权限时，`CG` fallback 仍可提供降级可用的窗口列表。
- 某个 App 连续 unread 后进入 degraded 状态时，`CG` 只能作为该 App 的降级存在性证据，不得重新打开裸扫描准入。
- 同标题多窗口如果 frame 无法唯一匹配，不得乱猜 `cgWindowID` 绑定；允许暂时显示无 `cgWindowID` 的条目，等待后续轮次确认。

## 长时间断档重复卡片验收

- App 长时间运行、睡眠、过夜或观察断档后，同一个真实窗口重新上报时，不得新建重复卡片。
- 重新上报前，身份识别必须先和当前任务条旧座位对账。
- 活窗口和保留窗口都要能被认回：
  - active / inactive
  - minimized / hidden / disappeared
- 同进程、同应用、标题和位置可信时应认回旧卡片。
- 标题变化时，可以用唯一位置认回。
- 位置变化时，可以用唯一标题认回。
- 候选不唯一时，宁可新建/等待后续证据，也不得误合并。
- app-level fallback 条目不得被当成具体窗口座位。
- 若再出现重复卡片，先导出只读调试快照，不要先重启或清空现场。
