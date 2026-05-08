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

当前状态：inventory-first 入口已在 2026-05-08 接入，下一步需要真实桌面手测验收。

- 正常用户 App 窗口应能进入任务条，不应回到 `已跟踪 3` / `可见 2` 这种明显漏收状态。
- `Software Cursor`、系统小组件、Notification Center、Control Center、app extension/helper 窗口不得进入任务条。
- 有 Accessibility 权限时，普通孤儿 `CG` / `.accessibility` 候选不得单独创建新条目。
- 缺少 Accessibility 权限时，`CG` fallback 仍可提供降级可用的窗口列表。
- 某个 App 连续 unread 后进入 degraded 状态时，`CG` 只能作为该 App 的降级存在性证据，不得重新打开裸扫描准入。
- 同标题多窗口如果 frame 无法唯一匹配，不得乱猜 `cgWindowID` 绑定；允许暂时显示无 `cgWindowID` 的条目，等待后续轮次确认。
