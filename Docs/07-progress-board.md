# v2 完成度看板

> Last Updated: 2026-05-08

## 当前一句话

- Finder P0 窗口级认窗地基已在 2026-05-05 验收通过。
- 任务条可信度主线已在 2026-05-08 改成 inventory-first：先看正常用户 App 窗口，再用 `CG` / `AX` 补证据。
- 当前下一步不是继续重写架构，而是真实桌面验收。

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

### 6. UI 与动作执行

- 最简底部 strip UI 已接线。
- 任务条已消费 live snapshot，而不是纯调试列表。
- `UI -> IntentPipeline -> PlatformActionExecutor` 动作路径已接通。
- 权限状态已进入正式 app；缺 AX 权限时 UI 会明确提示降级状态。

### 7. 验证资产

- `window-lab` replay / placement / transition 验证入口已建立。
- 真实 `minimize -> restore` 验证入口已建立。
- Finder、Calendar、Codex 同标题窗口、Chrome、WeChat 真实样本已积累。
- Feishu 当前已有 runtime 观察记录和 fallback replay，但还没有可靠 frontmost AX 真样本。

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
  - 确认正常用户窗口完整进入任务条
  - 确认 fake/system/helper 窗口不会进入
  - 确认 Finder 和 Feishu 例外路径在真实桌面上继续稳定
- `Identity` 全量单元测试集还没补完。
- `Placement` 全量单元测试集还没补完。
- `UI/ReadModel` 还不是完整投影版本。
- 浏览器窗口粒度判断还没最终定稿。
- 抽屉策略还没定稿。
- Feishu 真实 frontmost AX 窗口样本仍缺。
- 还不能宣称“生产可用”。

## 现在最应该做的事

1. 启动正式 app 做真实桌面验收。
2. 如果桌面表现仍不好诊断，补 runtime 日志：
   - inventory duration
   - unread / degraded PID 数
   - 准入拒收原因分布
3. 在真实桌面验收通过后，再决定是否继续补浏览器粒度和抽屉策略。

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

## 不允许误判的说法

- 允许说：
  - `Finder P0 窗口级认窗地基已经验收通过`
  - `inventory-first 任务条发现入口已经进入正式 app 主线`
  - `正式 app 已有最小可用底部任务条`
- 不允许说：
  - `v2 架构已经全部完成`
  - `完整任务栏已经生产可用`
  - `所有应用认窗问题已经解决`
  - `Feishu 已具备完整窗口级保真`
  - `inventory-first 已完成真实桌面验收`
