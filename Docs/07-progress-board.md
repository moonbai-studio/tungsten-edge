# v2 完成度看板

> Last Updated: 2026-05-13

## 当前一句话

- Finder P0 窗口级认窗地基已在 2026-05-05 验收通过。
- 任务条可信度主线已在 2026-05-08 改成 inventory-first：先看正常用户 App 窗口，再用 `CG` / `AX` 补证据。
- 真实桌面验收已经开始，并在 2026-05-13 抓到一次长时间断档后的真实重复卡片问题。
- 第一层长时间断档重复卡片根因已修：重新上报前会先和任务条现有座位对账，再决定是否创建新卡片。
- 当前整体完成度估算约 70%-75%；长时间实机回归稳定后，可进入约 75%-80% 的阶段。

## 当前产品状态

- 正式 app 已有最小可用底部任务条。
- 条目已支持 activate / hide / minimize / close，并带用户反馈。
- 主标签 toggle 已接上主线：
  - 非前台或最小化窗口 -> activate
  - 当前前台具体窗口 -> minimize
- 排位规则已经固定：
  - minimize 不释放位
  - hide 不释放位
  - 临时 `disappeared` 不释放位
  - 只有 true close 才释放位
- Finder 保持具体窗口级，不退回粗暴 app-level fallback。
- Feishu 允许稳定 app-level fallback，不阻塞主线。
- 任务条候选现在先来自正常用户 App 窗口清单；裸 `CG` / 普通 `.accessibility` 候选在主线可用时不再单独进条。
- 任务条已具备只读调试快照导出入口，可在不操作窗口的情况下导出内部 `DockSnapshot`，用于判断重复卡、旧卡片残留和正常最小化保留。
- 长时间断档后重新上报的窗口会先匹配现有任务条座位：
  - 最小化 / 隐藏 / 暂时消失的旧座位
  - 仍处于 active / inactive 的旧座位
  - 只在同进程、同应用且标题/位置唯一可信时合并
  - 候选不唯一时不猜

## 已完成里程碑

### 1. 工程骨架

- 新仓库 `macos-dock-cc-v2` 已建立。
- 双目标已建立：
  - `macos-dock-cc-v2`
  - `window-lab`
- 顶层目录和第一批架构文档已落地。
- `State`、`ObservationPipeline`、`IntentPipeline` 主结构已接通。

### 2. 认窗主线

- `CGWindowID` 直连式 identity 闭环已跑通。
- `AX` 标题 / frame / minimized 侧证据已进入主线。
- 第一版 bridge TTL、置信度、stale/conflict 保护已落地。
- Chromium 标题归一化已接入。
- 同标题窗口冲突时不再默认乱接回旧 identity。

### 3. Finder P0

- `FinderSource` 已补为 Finder 专用窗口级观察源。
- Finder 已从通用 `AccessibilitySource` 路径中单独分流。
- Finder activate / minimize / close 已禁止退回粗暴 app-level fallback。
- 双 Finder 窗口真实样本已通过。
- Finder P0 正式 app 路径已由项目 owner 验收通过。
- Finder 最小化成功但提示失败的反馈误报已修正。

参考文档：

- [17-finder-p0-implementation.md](/Users/caye/Projects/macos-dock-cc-v2/Docs/17-finder-p0-implementation.md)
- [18-real-sample-finder-findings.md](/Users/caye/Projects/macos-dock-cc-v2/Docs/18-real-sample-finder-findings.md)

### 4. 任务条可信度收口

- 假窗口 / 系统内部窗口 / helper / extension 过滤已集中到 policy 层。
- round-level anomaly fuse 已接入；异常爆量观察轮会被整轮拒收。
- 激活反馈已修正，不再因观察延迟误报失败。
- 飞书 app-level fallback 保位已收口为“进程活着就保留，不因短暂观察缺口提前删除”。
- 一次真实运行中，任务条已从异常污染恢复到合理数量。
- 调试壳自家窗口已被排除在任务条准入外，避免 `任务条调试台` 自我复制式污染 strip。

参考文档：

- [19-taskbar-trust-incident.md](/Users/caye/Projects/macos-dock-cc-v2/Docs/19-taskbar-trust-incident.md)

### 5. Inventory-First 主线

- `WorkspaceSource` 已进入正式 app 主线。
- 新增 `.appWindowInventory` 来源，语义是“正常 App 自己报出来的窗口”。
- inventory 读取策略已固定：
  - 100ms per-app AX messaging timeout
  - 并发上限 12
  - 连续 unread 30 轮后进入 degraded fallback
- Finder 和 Feishu 在 inventory 阶段跳过，继续走各自例外路径。
- 主线可用时：
  - inventory 可准入普通新条目
  - 裸 `CG` orphan 不可单独准入
  - 普通 `.accessibility` orphan 不可单独准入
- 缺少 AX 权限时，`CG` fallback 仍可提供降级可用列表。
- inventory 条目和后续 `CG` 已能做第一版绑定；同标题歧义时不猜。

参考文档：

- [20-inventory-first-taskbar-trust.md](/Users/caye/Projects/macos-dock-cc-v2/Docs/20-inventory-first-taskbar-trust.md)

### 6. 长时间断档重复卡片修复

- 2026-05-13 真实桌面快照确认：任务条内部状态从正常十来张增长到 `35` 张，并出现 `8` 组明确重复。
- 重复不是 UI 辅助树误报，而是 `DockSnapshot` 内部真实重复。
- 根因是：6 秒短记忆过期后，身份识别只会认回最小化 / 隐藏 / 暂时消失的旧座位，没有认回仍然活着的 active / inactive 旧座位。
- 修复后，发新身份前会先按当前快照对账；标题 + frame 优先，标题变化用唯一 frame，frame 变化用唯一标题，歧义时不合并。
- 修复是通用规则，不为 Chrome、Illustrator、WeChat 等应用写白名单。
- 修复版重启后基线快照：`trackedCount = 12`、`visibleCount = 12`、`duplicateGroups = 0`。

参考文档：

- [21-long-gap-duplicate-card-fix.md](/Users/caye/Projects/macos-dock-cc-v2/Docs/21-long-gap-duplicate-card-fix.md)

### 7. UI 与动作执行

- 最简底部 strip UI 已接线。
- 任务条已消费 live snapshot，而不是纯调试列表。
- `UI -> IntentPipeline -> PlatformActionExecutor` 动作路径已接通。
- 权限状态已进入正式 app；缺 AX 权限时 UI 会明确提示降级状态。
- Debug 菜单已提供“导出任务条快照”，快捷键 `Cmd+Shift+D`；Debug 构建也支持 `SIGUSR2` 触发导出。

### 8. 验证资产

- `window-lab` replay / placement / transition 验证入口已建立。
- 真实 `minimize -> restore` 验证入口已建立。
- Finder、Calendar、Codex 同标题窗口、Chrome、WeChat 真实样本已积累。
- Feishu 当前已有 runtime 观察记录和 fallback replay，但还没有可靠 frontmost AX 真样本。
- 当前真实桌面样本已覆盖一次长时间断档重复卡片问题，样本应用包括 Chrome Canary、Codex、Terminal、WeChat、Illustrator、Finder、Wanlian SD-WAN、Photoshop。

## 自动化验证现状

- 正式 app target build 已恢复为 green。
- `window-lab` target build 已通过。
- 已有回归覆盖：
  - count spike fuse
  - eligibility 过滤
  - Feishu fallback retention
  - inventory-first 准入
  - inventory-to-`CG` identity 绑定
  - 同标题多窗口歧义时不猜 `cgWindowID`
  - 长时间断档后 active / inactive 窗口重新上报时认回旧座位
  - 长时间断档后最小化 / 隐藏 / 暂时消失窗口重新上报时认回旧座位
  - 标题变动、位置变动时只在唯一候选下认回
  - app-level fallback 不被误当成具体窗口座位
  - Finder 相关 signature / toggle / feedback 规则
- 已有 replay 覆盖：
  - minimize / restore
  - title changed
  - hide / unhide
  - stale bridge
  - accessibility streak
  - coarse conflict
  - chromium group title
  - feishu app fallback

## 当前未完成

- 真实桌面验收：
  - 已开始，并已修复第一类长时间断档重复卡片问题
  - 还需要继续过夜 / 睡眠 / 长时间空闲回归
  - 继续确认正常用户窗口完整进入任务条
  - 继续确认 fake/system/helper 窗口不会进入
  - 继续确认 Finder 和 Feishu 例外路径在真实桌面上稳定
- `Identity` 全量单元测试集还没补完。
- `Placement` 全量单元测试集还没补完。
- `UI/ReadModel` 还不是完整投影版本。
- 浏览器窗口粒度判断还没最终定稿。
- 抽屉策略还没定稿。
- Feishu 真实 frontmost AX 窗口样本仍缺，但它只是未来窗口级增强项，不阻塞当前 V2 主线；当前按稳定 app-level fallback 验收。
- 还不能宣称“生产可用”。

## 现在最应该做的事

1. 继续运行修复版正式 app 做真实桌面回归，重点看长时间空闲 / 睡眠 / 过夜后是否还会出现重复卡片。
2. 如果再次出现重复，不要重启或清理，立即导出调试快照：
   - Debug 菜单：`导出任务条快照`
   - 快捷键：`Cmd+Shift+D`
   - 或 Debug 构建下对进程发送 `SIGUSR2`
3. 若长时间重复卡片问题不再复现，继续做 inventory-first 真实桌面可信度验收。
4. 真实桌面验收稳定后，再决定浏览器窗口粒度和抽屉策略。

## 常用入口

- 正式 app：
  - `./Scripts/build_and_run.sh`
- 全量验证：
  - `./Scripts/build_and_run.sh --verify`
- Finder P0 真样本：
  - `./Scripts/build_and_run.sh --lab-minimize "<unique Finder folder title>"`
- replay：
  - `./Scripts/build_and_run.sh --lab-replay <scenario-name>`
- placement：
  - `./Scripts/build_and_run.sh --lab-placement <scenario-name>`
- transition：
  - `./Scripts/build_and_run.sh --lab-transition <scenario-name>`
- unit tests：
  - `xcodebuild test -project macos-dock-cc-v2.xcodeproj -scheme macos-dock-cc-v2Tests -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS'`
- 导出任务条内部快照：
  - Debug 菜单 `导出任务条快照`
  - `kill -USR2 $(pgrep -x macos-dock-cc-v2)`
  - 最新文件通常在 `$(getconf DARWIN_USER_TEMP_DIR)macos-dock-cc-v2-debug-snapshot-latest.json`

## 不允许误判的说法

- 允许说：
  - `Finder P0 窗口级认窗地基已经验收通过`
  - `inventory-first 任务条发现入口已经进入正式 app 主线`
  - `正式 app 已有最小可用底部任务条`
  - `真实桌面验收已开始，并已修复一类长时间断档重复卡片问题`
- 不允许说：
  - `v2 架构已经全部完成`
  - `完整任务栏已经生产可用`
  - `所有应用认窗问题已经解决`
  - `Feishu 已具备完整窗口级保真`
  - `inventory-first 已完成真实桌面验收`
  - `长时间实机回归已经完全通过`
