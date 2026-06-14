# Known Platform Quirks

- `CGWindowID` 在最小化后会从默认窗口列表里消失。
- Accessibility 通知在某些应用中不可靠，尤其微信、飞书。
- Finder 进程长期存在，不等价于“有 Finder 窗口”。
- Finder 具体窗口名可通过 `CG` / `AX` / AppleScript 取得；如果 UI 只显示 `访达`，优先怀疑当前观察链路丢了窗口级信息。
- Finder 激活不能轻易退回到 app-level activate，否则可能带出错误窗口或多个窗口。
- 某些 app 创建窗口时标题先为空，稍后才填入真实标题。
- `CG` 的 `disappeared` 事件会带着旧 `cgWindowID` 回流；验收逻辑不能把这类事件当成“当前仍可见窗口”。
- 当前采样里，飞书可能出现 `CG` 可见但标题为空、同时 `AXWindows` 为空的时刻。
- `AX` 可能暴露系统内部窗口、小组件、扩展窗口或辅助进程窗口；这些对象看起来像窗口，但不一定是用户想在任务条里操作的窗口。
- 放宽 `AX` 采样范围时必须先经过窗口准入 policy。否则假窗口进入状态后，会被最小化 / 隐藏 / 临时消失保位规则放大，造成任务条突然出现几十或上百个条目。
- `System Events` / App 级窗口枚举更接近“用户正在使用哪些 app 窗口”的产品直觉；v2 当前正式实现不用 shell `osascript`，而是用 `NSWorkspace` + `AXWindowReader` 做同类 app-window inventory。
- 底层 `CG` / `AX` 扫描可能同时出现两种失败：放得太宽会收进假窗口，收得太紧会漏掉真实用户窗口。当前主线已改成用户 app 窗口清单优先，再用底层信号补证据。
- 透明窗口只应可靠过滤 `alpha == 0` 的情况；不要用“视觉上透明”这种不稳定判断做强过滤。
- 只有通过准入 policy 的可信窗口，才应该享受 keep-slot 和 `disappeared` retention。
- `AXUIElementCopyAttributeValue` 可能被单个 App 卡住；inventory 读取使用 100ms per-app messaging timeout 和 12 路并发，慢 App 连续 unread 30 轮后会进入 degraded fallback。
- 调试壳本身如果被准入任务条，会因为内容变化触发窗口尺寸或观察签名变化，造成同一自家窗口被误认成多个条目。当前主线已直接过滤 `com.caye.macosdockcc.v2`，避免任务条自我污染。
- 长时间空闲 / 睡眠 / 过夜后，6 秒身份记忆会自然过期。不能依赖短记忆认回窗口；必须把当前任务条 `DockSnapshot` 当作长期座位图来对账。
- 同一个真实窗口在恢复或跨屏状态变化后，frame 可能发生较大偏移；如果同进程同应用下标题唯一，可以用唯一标题认回旧座位。多个同名候选时不能猜。
- 浏览器、Illustrator、Photoshop、Finder、WeChat、Terminal、Codex 等应用会暴露不同粒度的标题或位置变化；这些应作为通用身份规则的验收样本，不应变成应用白名单。

## 原生标签组（NSWindow tabbing）与“哪个标签可见”的判定（2026-06-14 实测，Ghostty）

> 这是“同 app 多标签合并”功能里反复踩坑后挖出来的平台事实。Obsidian 那份是产品/设计视角，这份是工程视角，写代码时按这条来。

- **原生 NSWindow tabbing（Finder / Ghostty 类）= N 个真实 NSWindow**：同 `pid` + 逐像素相同 frame，各有独立 `cgWindowID`、各 `AXStandardWindow`。浏览器标签则是 1 个 NSWindow 自绘，天然就一个窗口。要合并的是前者。
- **非当前标签在 AX 里报告为“最小化”（`min=1`）**：一个标签组里同一时刻只有当前可见标签 `min=0`，其余后台标签全报 `min=1`。这不是真的最小化，是 tabbing 的实现细节。
- **切标签时 AX 的状态严重滞后/不可靠，不能用它判可见标签**：实测 ① 切走的老标签 `min` 会被 AX **持续误报为 0 长达 ~4 秒**（AX 自身就报错，不是轮询慢）；② 老标签的 `Miniaturized` 通知**根本不发**；③ 新标签的 `Deminiaturized` 通知**时有时无**（赌它做事件驱动会出 bug）。过渡期“两标签同时 `min=0` / `foc=1`”，**没有任何瞬时 AX 字段能区分谁可见**。
- **可靠信号 = `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`**：后台标签是被 order-out 的独立 NSWindow，**不在 on-screen 列表**；每个标签组恰好留 **1 个**在屏 = 当前可见标签。实测 Ghostty 38 窗 → on-screen 仅 2（两组各 1）。合成层真相，切标签即时更新，无 AX 滞后。判“标签组里谁可见”用它。
- **CG bounds 与 AX bounds 可能不同**：实测同一 Ghostty 标签，CG 报宽 1005/874，AX 报 1191。所以**分组用 AX bounds**（与 `StripItem.tabGroupKey` 一致），**只用 CG 判 `cgWindowID` 是否在屏**——两者别混用。
- 当前实现：`AppTracker.rebuildSnapshot` 对“同 frame ≥2 成员”的标签组改用 on-screen 判可见性（不在屏即视为最小化），普通单窗口仍走 AX；前台 0.5s 轮询比对 on-screen 集合发现切标签（AX 完全不报时的即时触发）。`CGWindowListCopyWindowInfo` 在无屏幕录制权限时拿不到标题，但 `pid` / `number` / `bounds` / `layer` / on-screen 都可用，足够本判定。
