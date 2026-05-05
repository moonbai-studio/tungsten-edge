# v2 完成度看板

> Last Updated: 2026-05-05

## 总体判断

- 当前状态：**Finder P0 窗口级认窗地基已验收通过，v2 仍处在第一阶段收口中**
- 已完成的是：
  - 新仓库
  - 双目标工程
  - 目录骨架
  - 第一批架构文档
  - `window-lab` 双路最小真实观察通路
  - `cgWindowID` 直连式最简认窗闭环
  - `AX` 最小侧证据通路
  - Finder 窗口级观察、身份、toggle 和动作保护
  - Finder P0 用户验收与最小化反馈误报修复
- 还没完成的是：
  - 时序推断与置信度累积
  - 更完整的 `UI/ReadModel` 投影
  - 完整任务栏交互与抽屉策略
  - 浏览器窗口粒度判断
  - Feishu 真实前台 AX 窗口样本
  - 全量生产级验收

## 已完成

### 0. 新仓库起盘

- [x] 新仓库 `macos-dock-cc-v2` 已创建
- [x] 新 Git 仓库已初始化
- [x] 新 Xcode 工程已建立
- [x] 双目标已建立：
  - [x] `macos-dock-cc-v2`
  - [x] `window-lab`

### 1. 结构骨架

- [x] 顶层目录已建立：
  - [x] `App/`
  - [x] `Core/`
  - [x] `Platform/`
  - [x] `UI/`
  - [x] `Resources/`
  - [x] `Tools/`
  - [x] `Docs/`
  - [x] `Scripts/`
- [x] `Shared/` 未建立
- [x] `Lifecycle/` 已拆成：
  - [x] `Transitions/`
  - [x] `ActionPlanning/`

### 2. 第一批文档

- [x] `Docs/00-why-v2.md`
- [x] `Docs/01-boundaries.md`
- [x] `Docs/02-data-flow.md`
- [x] `Docs/03-window-lab-output.md`
- [x] `Docs/04-acceptance.md`
- [x] `Docs/05-known-platform-quirks.md`
- [x] `Docs/06-implementation-plan.md`
- [x] 当前完成度看板

### 3. 运行入口

- [x] `Scripts/build_and_run.sh`
- [x] Codex Run 按钮环境文件
- [x] app 目标可构建并启动
- [x] `window-lab` 可构建并运行

### 4. 认窗第一阶段：已起步部分

- [x] `Platform/CoreGraphics` 最小真实观察通路
- [x] `Platform/Accessibility` 最小真实观察通路
- [x] `window-lab` 结构化输出格式已跑通
- [x] `Identity` 最简版已落地
- [x] 同一个 `cgWindowID` 在后续轮次可输出 `KNOWNWINDOW`
- [x] `AX` 标题 / frame / minimized 侧证据已进入实验台日志
- [x] 第一版跨源接回已落地：
  - [x] `CG` 继续按 `cgWindowID`
  - [x] `AX` 先按 `pid + 标题 + frame` 签名接回

## 进行中

### 5. 认窗第一阶段主线

- [x] `CGWindowID` 消失场景下的第一版接回策略
- [x] 最小化再恢复不漂 ID
- [x] 标题变化不误判 `NEW_WINDOW`
- [x] Hide / Unhide 不漂 ID
- [x] 第一版时序门槛（bridge TTL）
- [x] 第一版置信度规则
- [x] 第一版特殊应用识别规则

#### Finder 专项补口

- [x] Finder 窗口级观察源补完
- [x] Finder 必须持续进入 AX 观察范围，不能因运行应用排序靠后被漏扫
- [x] Finder 多窗口最小化 / 恢复不串窗
- [x] Finder Hide / Unhide 不串窗
- [x] Finder activate 不退化为粗暴激活整个 Finder app
- [x] Finder 真实样本沉淀为可复盘文档
- [x] Finder P0 用户验收通过
- [x] Finder 最小化成功但提示失败的反馈误报已修正

## 主线状态

### 6. Lifecycle 与 Placement

- [x] `Lifecycle/Transitions` 真正接入真实观察事件
- [x] `Lifecycle/ActionPlanning` 第一版已接入真实用户意图
- [x] `Placement` 的保位 / 释放位规则
- [x] `ObservationPipeline` 的“按需重排”细化
- [x] 原子 `StateUpdate` 的完整组装链路

### 7. UI 主线

- [x] 最简任务栏 UI
- [ ] `UI/ReadModel` 完整投影
- [x] 主栏条目真实接线
- [x] 主栏条目已可交互
- [x] UI 消费 State 完整快照

### 8. 测试与验收

- [x] Finder P0 最小 XCTest target
- [ ] `Identity` 全量单元测试集
- [ ] `Placement` 单元测试集
- [x] 预设场景驱动的 `window-lab` 对比框架
- [x] 第一条自动合成 replay 验证
- [x] 第一条真实验收场景（`minimize-restore`）已落地
- [x] Finder P0 行为验收通过
- [ ] 第一阶段全量行为验收通过

## 当前下一步

- P0：Finder P0 已收口并打检查点
- P1：继续真实 close / activate 的边界样本，确认不会残留 stale 条目
- P2：回到浏览器窗口粒度判断与抽屉策略，不把 Finder 地基当作未完成 blocker

## 本轮 Finder P0 推进

- [x] `AccessibilitySource` 已跳过 Finder，避免和 Finder 专用 AX 观察重复产出
- [x] `FinderSource` 已补为 Finder 专用窗口级观察源
- [x] 主标签点击已接入 toggle：前台窗口最小化，非前台窗口激活
- [x] Finder activate / minimize / close 已禁止退回粗暴 app-level fallback
- [x] 新增最小 XCTest target 覆盖 signature 合并、toggle、Finder 过滤规则
- [x] 新增 `finder-title-tab-replay` 验证 Finder 同一窗口标题变化不漂 identity
- [x] 新增双 Finder 窗口真实样本记录：`Docs/18-real-sample-finder-findings.md`
- [x] Finder P0 正式 app 路径经项目 owner 手测验收通过
- [x] 修正 Finder 最小化成功但提示“没能最小化这个窗口”的反馈误报

## 本轮新增完成

- [x] `Platform/Accessibility` 已从“只枚举标题”推进到：
  - [x] 标题
  - [x] 最小化状态
  - [x] frame
- [x] `window-lab` 已同时输出两路真实观察：
  - [x] `CG`
  - [x] `AX`
- [x] 第一版跨源 identity 接回已能在部分窗口上发生：
  - [x] `AX` 侧证据可把同标题同 frame 的窗口接回到现有 `CG` identity
- [x] `minimize-restore` 场景已从占位文件推进到可运行的第一版工具：
  - [x] 基线 before/after 采集
  - [x] 候选窗口关键字选择
  - [x] tracked target 的 identity 对照输出
- [x] `minimize-restore` 场景已推进到三段式观察：
  - [x] before
  - [x] minimized
  - [x] restored
- [x] 第一条自动合成 replay 场景已通过：
  - [x] 最小化后 `CGWindowID` 消失
  - [x] 恢复后出现新的 `CGWindowID`
  - [x] 仍接回原 identity
- [x] 第二条自动合成 replay 场景已通过：
  - [x] 标题变化
  - [x] `CGWindowID` 不变
  - [x] 不误判为 `NEW_WINDOW`
- [x] 第三条自动合成 replay 场景已通过：
  - [x] hidden
  - [x] unhidden
  - [x] 仍接回原 identity
- [x] 第四条自动合成 replay 场景已通过：
  - [x] bridge 过期
  - [x] 不应再接回旧 identity
  - [x] 应视为新的 `CGWindowID` 窗口
- [x] 第一版置信度分层已落地并通过现有 replay 验证：
  - [x] `cg-window-id` -> `HIGH`
  - [x] `restored-via-bridge` -> `MEDIUM`
  - [x] `minimized-side-evidence` -> `MEDIUM`
  - [x] 无桥接的新 AX title fallback -> `LOW`
- [x] 第一版特殊应用规则已接入 `Identity/Rules` 并通过 replay：
  - [x] Finder 标题归一化入口
  - [x] 微信内容窗过滤
  - [x] 飞书标题归一化入口
- [x] Finder 风险已重新定位：
  - [x] Finder 不是拿不到窗口名；`CG` / `AX` / AppleScript 都能读到具体文件夹窗口名
  - [x] P0 前 `Platform/Finder/FinderSource` 是空实现；现已补为 Finder 专用观察源
  - [x] P0 前正式 app 采样显示 `AccessibilitySource.observe()` 可能在重复 signature 字典构造处进入断言/异常路径；现已改为按优先级合并
  - [x] 实验台明确选中单个 Finder 测试窗口时，`--lab-minimize` 可通过；P0 后正式 app UI 路径也已通过项目 owner 手测验收
- [x] `ObservationPipeline` 现在负责组装完整 `StateUpdate`：
  - [x] `State` 不再从 decision 反推 `WindowRecord`
  - [x] 窗口标题 / appID / status 在进入 `State` 前已组装完成
- [x] `Placement` 最小规则已收口到更稳定版本：
  - [x] 已跟踪窗口在普通轮询下不再反复改序
  - [x] 最小化 / 隐藏 / 临时 `disappeared` 不再默认释放位
  - [x] 只有 `closedPending` 会释放位
- [x] 正式 app 已接上 v2 观察链路：
  - [x] `AppComposition` 会轮询真实 `CoreGraphics` / `Accessibility` 观察源
  - [x] 观察结果会流经 `ObservationPipeline -> Lifecycle -> Placement -> State`
  - [x] SwiftUI shell 已显示 live snapshot 中的 tracked windows
- [x] 权限状态已进入正式 app：
  - [x] `PermissionService` 不再固定返回 `true`
  - [x] 缺少 AX 权限时 UI 会明确提示“只有部分侧证据可用”
- [x] `window-lab minimizeRestore` 已升级为第一条真实验收场景：
  - [x] 支持按关键字或序号选定真实目标窗
  - [x] 最小化后会显式检查 baseline `CGWindowID` 是否消失
  - [x] 恢复后会显式比较 restored identity 与 baseline identity
  - [x] 通过返回 `0`，失败返回 `1`
- [x] `Scripts/build_and_run.sh --lab-minimize <keyword>` 已支持把目标关键字透传给实验台
- [x] 真实验收样本已开始积累：
  - [x] 当前实验台已支持 `index:` / `cg:` 选择器，避免同名窗口歧义
  - [x] 实验台现已可通过 AX 自动最小化 / 自动恢复目标窗，不再依赖手工点按
  - [x] 当前 `macos-dock-cc-v2` SwiftUI shell 真实样本已通过
  - [x] `日历` 真实样本已通过
  - [x] `Codex` 同标题多窗口真实样本已通过
  - [x] `Google Chrome Canary` 浏览器真实样本已通过
  - [x] `WeChat` 真实样本已通过：
    - [x] `微信 (窗口)`
    - [x] `新线程开始时：`
- [x] 飞书方向已补第一阶段支持：
  - [x] `feishu-app-fallback-replay` 已通过
  - [x] 已记录当前 runtime 形态：`CG` 有无标题窗，但 `AXWindows` 为空
  - [x] 飞书窗口级已降级为 opportunistic，应用级 fallback 已成正式策略
  - [x] 之前的失败结论已定位为实验台判定口径 bug：
    - [x] `CG` `disappeared` 事件被误算成“当前仍在列表中的窗口”
    - [x] 修正后，同一真实样本通过了 `minimize -> restore` 验收
  - [x] 已新增可复盘记录：
    - [x] `Docs/08-real-sample-minimize-restore-findings.md`
    - [x] `Docs/09-real-sample-calendar-findings.md`
    - [x] `Docs/10-real-sample-codex-same-title-findings.md`
    - [x] `Docs/11-real-sample-browser-findings.md`
    - [x] `Docs/12-real-sample-wechat-findings.md`
    - [x] `Docs/13-feishu-current-observation.md`
    - [x] `Docs/15-feishu-fallback-strategy.md`
- [x] `ObservationPipeline` 已收口到“按需重排”版本：
  - [x] 新窗口进入有序列表时才触发成员级重排
  - [x] `disappeared` / `hidden` / `minimized` / `restored` 等状态变化会触发排位决策
  - [x] 普通 `titleChanged` / `unchanged` 不再每轮都重算 `Placement`
- [x] `Identity` 已进入第一版“连续观察累计”阶段：
  - [x] 同一 AX signature 连续稳定出现时，confidence 会从 `LOW -> MEDIUM -> HIGH`
  - [x] `window-lab replay` 已支持 `expectedConfidence` 断言
  - [x] 新增 `accessibility-streak-replay` 用于锁定这条时序累计行为
- [x] `Identity` 已补上第一版 stale / conflict 保护：
  - [x] 记忆中的 AX signature 超过窗口期后不再继续接回旧 identity
  - [x] 同 pid 同标题但不同 frame 的冲突窗不会再直接吃掉已有 coarse signature
  - [x] 新增 transient AX identity，避免 stale fallback 复用旧 AX id
  - [x] 新增 `stale-ax-signature-replay` 与 `coarse-conflict-replay`
- [x] Chromium 标题归一化第一版已落地：
  - [x] 已处理 `Google Chrome Canary` 标题后缀
  - [x] 已处理 `属于“... ”群组` 这类群组后缀
  - [x] `chromium-group-title-replay` 已通过
- [x] Feishu 式“无标题 -> 后续补标题”接回已落地：
  - [x] 已新增 frame-only 兜底接回
  - [x] 飞书应用级 fallback 已落地
  - [x] `feishu-app-fallback-replay` 已通过
- [x] 飞书 fallback 已进入正式代码主线：
  - [x] 无标题 / 通用标题 / AX 不可靠时会落成稳定应用级 identity
  - [x] UI 已能把这类条目标记成 `APP`
- [x] 正式 app 已进入最小可用任务栏阶段：
  - [x] task strip 已改成底部横向条带，而不是调试列表
  - [x] 主栏条目已显示真实 title / status
  - [x] 飞书 fallback 策略已进入 UI 文案和任务条模型
  - [x] activate / minimize 已接上 `IntentPipeline -> PlatformActionExecutor`
- [x] `Placement` 第一版保位 / 释放位规则已落地：
  - [x] 最小化后永久保位
  - [x] 隐藏后永久保位
  - [x] 临时 `disappeared` 后永久保位
  - [x] 只有真正关闭才释放位
- [x] `Placement` 已有可重复验证入口：
  - [x] `./Scripts/build_and_run.sh --lab-placement placement-permanent-hold-replay`
  - [x] `./Scripts/build_and_run.sh --lab-placement placement-close-release-replay`
  - [x] `window-lab` 现已直接驱动共享 `PlacementEngine`
  - [x] 验证结果：
    - [x] `placement-permanent-hold-replay` -> `A,B,C`
    - [x] `placement-close-release-replay` -> `A,C,B`
- [x] `Lifecycle`/交互反馈 已补可重复验证入口：
  - [x] `./Scripts/build_and_run.sh --lab-transition focused-active-replay`
  - [x] `./Scripts/build_and_run.sh --lab-transition close-timeout-replay`
  - [x] 已验证 focused AX 观察可把窗口提升到 `active`
  - [x] 已验证超时后的 close 不会误判成 `closedPending`
- [x] 已补真实 close 验证入口：
  - [x] `./Scripts/build_and_run.sh --lab-close "<keyword>"`
  - [x] 用于验证真实窗口关闭后是否仍残留在观察结果里
- [x] 真实 close 样本已开始积累：
  - [x] `OpenAI Platform` 真实关闭后不再残留
  - [x] `Tailscale` 真实关闭后不再残留
  - [x] 之前的 `CLI Proxy API Management Center` 失败样本已失效，不能再作为当前 blocker
- [x] activate / close 收口已推进：
  - [x] activate 成功提示不再在动作发出瞬间就提前报成功
  - [x] 真实 close 前会额外确认窗口是否仍可被 AX 捕获，降低误删风险
- [x] 浏览器当前判断已更新：
  - [x] 多个 Chrome strip item 不等于 tab duplication
  - [x] 在最新真实样本里，Chrome 同时暴露了两个真实窗口
  - [x] 同一真实窗口切 tab 时，本轮未复现“凭空新增第三个 strip item”
- [x] 旧实验规则已退役：
  - [x] held-slot TTL 不再作为默认产品规则
  - [x] “过期后回末尾”不再作为最小化 / 隐藏主线方案

## 不允许误判的说法

- 允许说：
  - `v2 新仓库和双目标骨架已经落地`
  - `window-lab 双路最小真实观察通路已跑通`
  - `认窗第一阶段已经开始`
  - `Finder P0 窗口级认窗地基已经验收通过`
  - `Finder concrete window toggle 已进入正式 app 路径`
- 不允许说：
  - `v2 架构已经完成`
  - `完整任务栏已经生产可用`
  - `所有应用的认窗问题已经解决`
  - `Feishu 已经具备完整窗口级保真`
  - `抽屉策略已经定稿`
