# 窗口焦点闪烁问题：调试经验复盘（最小化回到前一个 App）

> Recorded: 2026-06-24
> 读者：**未来的我（AI）**。这是一份方法论 + case study，不是产品说明。目标是让下次遇到「macOS 多窗口 App 的焦点/层级控制」类问题时，少走这次走过的所有弯路。事无巨细是故意的。
> 配套硬约束已固化在 `AGENTS.md`「Minimize returns focus to the previous app — pre-switch, never post-correct」；这里记的是**怎么一步步走到那个结论的**。

---

## 0. 一句话结论（先看这个）

> macOS 上「最小化前台窗口后焦点回到哪」这件事，**绝对零闪不存在**——「阻止同 App 的兄弟窗口 A2 冒头」和「把目标 App B 提到最前」是**绑死的**，二选一。最终采用的方案是：**最小化之前**用 `SetFrontProcessWithOptions(.frontWindowOnly)`（dlsym 加载，公开但 deprecated）把 B 切成活动进程，让系统在 A1 消失后没有「接班窗口」可提。代价是 B 早一拍出现，实测反而更自然。

---

## 1. 问题是怎么发现的

### 1.1 用户的原始报告（一字不改地理解需求）

> 应用 A 多窗口，都不在最小化状态，也不在最前端（最前端是 B 的窗口）。点击 A 的 A1 窗口 → A1 激活到最前，A1 后面是 B。然后点击 A1 的任务栏图标 → A1 被最小化。**理想**：B 在最前。**实际**：最小化 A1 后，A2 被带出来跑到最前。
> 补充：如果 A1、A2 都已经是最小化状态，则不出现这个问题。

### 1.2 关键观察的价值

「两个窗口都最小化时不出现」这条**自带了根因线索**：说明 bug 不是我们的代码主动制造的，而是 macOS 在「最小化 frontmost App 的 focused window」时，自动把**同 App 的下一个可见窗口**提为新的 key window。两个都最小化 → A 没有可提的可见兄弟 → 系统自然退回 B。

**教训**：用户报告里「什么情况下**不**发生」往往比「什么情况下发生」更能定位根因。优先抓这条。

---

## 2. 根因（macOS 行为）

`AccessibilityWindowActionExecutor.minimize()` 只是执行 AX 最小化（先试 `kAXMinimizedAttribute=true`，失败再按 `kAXMinimizeButtonAttribute`），**没有任何「最小化后谁该上来」的逻辑**。这个真空被 macOS 的默认行为填上：

> frontmost App 的 focused window 被最小化 → 该 App 的下一个窗口被提为 key window（App 仍 frontmost）。

探针后来精确测到：**A2 冒头发生在最小化动画结束后约 245ms**（不是最小化瞬间），是窗口服务器在 A1 彻底从 CG 列表消失后才提 A2。

---

## 3. 修复迭代全过程（弯路与正路，按时间顺序）

这一节是这份文档的核心。每一版都标注**为什么错 / 为什么对**。

### 3.1 初版方案 + Codex 第一轮 review（还没写代码就被拦下三个 P1）

初版想法：最小化前先激活 B。Codex review 抓到三个 P1，**全部成立**：

1. **光判断 `frontmostApplication.pid == record.pid` 不够**——那只能证明「A 这个 App 在前台」，不能证明「被点的 A1 正好是 A 的 focused window」。如果 A 前台但 A2 才是 focused，用户右键 A1 选「最小化」，预激活 B 会**错误地把焦点从 A2 切走**。必须确认 `handle.element` 是该 pid 的 **focused AX window**（复用 `isFocused`）。
2. **`activate(options: [])` 很可能不足以抢回前台**——本项目其它激活路径都用 `.activateIgnoringOtherApps`（见 `AccessibilitySource.swift:340`）。空 options 在我们这种 nonactivating panel 交互后可能静默失败。
3. **候选窗口过滤太粗**——只过滤 layer 0 / pid / self-pid，会把桌面、辅助进程、无标题 helper 当成「previous app」。应复用 `DockWindowEligibilityPolicy`（它已经过滤 Notification Center / Control Center / `.appex` / helper path / 透明 / 无标题）。

**教训**：「在前台的 App」≠「在前台的那个具体窗口」。涉及焦点的判断永远要下沉到 window 粒度。信任过滤要复用既有的 `DockWindowEligibilityPolicy`，别另起炉灶。

### 3.2 v2：pre-activate（失败——B 先闪 + race）

实现：最小化前 `NSRunningApplication.activate(B)`，再 minimize A1。
**实测两个问题**：
- B 被 raise 到 A1 前面 → **B 闪一下盖住 A1**（顺序反了：B 提前了）。
- race：最小化后系统的「提 A2」仍可能晚于我们的预激活，A2 还是赢。

**为什么错**：`activate(B)` 不只是切前台，它会把 B 的窗口 raise 到最前。先激活 = B 先盖 A1。

### 3.3 v3：post-activate（功能正确，但有残留闪）

实现：先 `findBackgroundActivationTarget` 找 B（**不激活**），minimize A1，成功后 `usleep(50_000)` 沉降再 `activate(B)` 压过系统提起的 A2。
**实测**：最终 B 正确回到最前 ✓，但 **A2 闪一帧再沉下去**（系统先提 A2，我们再纠正）。

**为什么仍闪**：这是「让系统犯错、再纠正」的 race-correction，视觉残留无法消除。50ms 太短则 A2 还没提起就纠正（系统随后又提，更糟）；太长则 A2 显示更久。

`postMinimizeActivateDelayMicroseconds = 50_000` 这个常量后来作为**回退路径**保留了下来。

### 3.4 决策点：用户选择「试彻底无闪」

我把权衡如实交给用户（三选一：试无闪 / 接受 v3 瑕疵 / 回退原生）。用户选**试无闪**。
**教训**：方案性质变化（从「修 bug」变成「探索可能做不到的事」）时，要让 owner 拍板投入，而不是闷头钻。

### 3.5 v4：探针先行（正路）

不再直接改主程序反复重启，而是写**独立 CLI 探针**验证机制。这是整个任务的转折点。

#### 3.5.1 探针环境的意外福利
我的 Bash 环境 `AXIsProcessTrusted() == true`——能直接做 AX 实验。用 **Ghostty(多窗口) 当 A、计算器当 B**（影响最小）。

#### 3.5.2 第一版探针的缺陷（被 Codex 拦截）
第一版 pass 标准是「frontmost==B 且 A1 仍在 z-order 顶」。Codex 指出这**太弱**：那只证明能造出 split-brain 状态，**不证明接下来的 minimize 不提 A2**。修正：探针必须跑**完整序列**——切前台→采样→**真的最小化 A1**→**在动画期间高频采样(~35ms×N)**→确认 A2 全程不冒头。还要**同时测两种 minimize 机制**（set-attribute vs 按按钮），因为切走 frontmost 后「按按钮」可能失效。

#### 3.5.3 探针环境的真实局限
- `NSRunningApplication.activate` 在我这个**非 GUI 进程里不可靠**（设 A frontmost 不生效）。所以探针 step1 改用 SkyLight 强制复现「A1 是 frontmost」的起点。
- `os.Logger .info` 日志**抓不到**（项目已知，见 memory）。探针用 `print` 直接输出。

#### 3.5.4 探针的关键发现：五机制矩阵 + 零闪死结

逐帧采样 z-order，测了 5 种「切前台」机制：

| 机制 | A2 是否冒头 | B 是否提前 | 备注 |
|---|---|---|---|
| `none`（纯最小化） | **冒头** ✗ | — | 复现 bug；A2 在 min+245ms 跳到顶 |
| `ax`（设 `kAXFocusedApplication`） | **冒头** ✗ | — | 调用返回 **-25202**（失败/不支持） |
| `user`（SkyLight `_SLPSSetFrontProcessWithOptions` mode `kCPSUserGenerated`=0x200） | 不冒头 | 提前 | 私有 |
| `nowin`（SkyLight mode `kCPSNoWindows`=0x400） | **不冒头** ✓ | 提前 | 私有 |
| `carbon`（`SetFrontProcessWithOptions(.frontWindowOnly=1)`） | **不冒头** ✓ | 提前 | **公开但 deprecated** |

**死结**：能阻止 A2 冒头的机制（nowin/carbon），无一例外都把 B 提到了 z-order 最顶（`after-switch` 时 B@[0]）。反过来不提 B 的（none/ax），A2 必冒头。→ **「摁住 A2」与「提起 B」绑死，零闪不可能。**

#### 3.5.5 选 carbon 集成
nowin 和 carbon 都能根治 A2 冒头。选 **carbon**，因为 `SetFrontProcessWithOptions` 是**公开 API**（虽 deprecated），比私有 SkyLight 符号风险低、未来更稳。

实现要点（`Platform/Accessibility/AccessibilitySource.swift`）：
- 新增 `switchFrontmostWithoutReorder(toPID:)`：dlsym 加载 `GetProcessForPID` + `SetFrontProcessWithOptions`（从 ApplicationServices/CoreServices），调 `SetFrontProcessWithOptions(psn, kSetFrontProcessFrontWindowOnly=1)`，返回 Bool，日志记录，**符号缺失或失败即 false → 调用方回退 v3**。
- minimize 分支：`findBackgroundActivationTarget` 找 B → `switchFrontmostWithoutReorder(B)` 预切 → `minimize(A1)`；若**没预切成功**才走 v3 事后激活回退。
- `findBackgroundActivationTarget` 的 guards（全部保留）：仅当 handle 是**前台 App 的 focused window**（0.2s bounded AX `kAXFocusedWindow` 检查）才返回候选 → 右键最小化非 focused 兄弟时 no-op；候选 B 必须过 `DockWindowEligibilityPolicy` **且** `.regular`。

#### 3.5.6 实测成功
用户实测：**A2 不冒头，B 回来很自然，甚至交互感更好**。`SetFrontProcessWithOptions` 是公开 API 不需 dlsym 也能调，但用 dlsym 是为了避开编译期 deprecated 报错 + 运行时优雅降级。

**从行为反推确认机制生效**：os.Logger 抓不到日志时，用「A2 是否冒头」这个**行为特征**坐实走了哪条路——v3 回退一定会让 A2 冒一下，A2 彻底不冒 = 走了新预切路线。这是没有日志时的有效验证手段。

---

## 4. 可复用的探针方法论

### 4.1 什么时候写探针
当「修复依赖一个**还没验证的系统机制**」时，**先写独立 CLI 探针验证机制，再改主程序**。不要靠「改主程序→重启→用户测」去试错多个候选机制——那既慢又耗用户。

### 4.2 探针怎么设计
1. **跑完整真实序列**，不要只验证中间态。（第一版探针只验证 split-brain 就是教训。）
2. **逐帧高频采样**（~12–35ms）抓瞬态，闪烁可能 <50ms。
3. **区分窗口身份**：用 cgWindowID（必要时 `_AXUIElementGetWindow` 私有符号从 AX element 拿 cgID）区分 A1/A2，否则「A 的某窗口在上面」分不清是 A2 盖 A1 还是 A1 自己重绘换 cgID。
4. **三个状态都采**：视觉 z-order（`CGWindowListCopyWindowInfo` 是 front-to-back，layer 0）、`frontmostApplication`、AX key/focused window。只修视觉闪可能把键盘焦点留给错误窗口。
5. **量化指标**：用「最长连续 A2-above-A1 帧数」对比候选，肉眼「好像好了」常常只是闪更短。

### 4.3 探针环境的硬限制（务必记住）
- **`NSRunningApplication.activate` 在非 GUI / 辅助进程里不可靠**——设别的 App frontmost 经常不生效。依赖真实 GUI 激活的时序，CLI 探针**复现不出来**。
- 对策：**被动观察者（passive observer）**——一个只采样、不执行任何激活的进程，让**用户在真实 App 里操作**，观察者旁观。这样「真实链路 + 真实激活语义」都在，观察者只读不写。（这正是激活闪 follow-up 采用的方案。）
- `os.Logger .info` 在本机抓不到，探针/诊断一律用 `print`（项目 build 已加 setvbuf 行缓冲让 print 实时进 run.log）。

### 4.4 私有 / deprecated API 的纪律
- 一律 **dlsym 运行时加载**（镜像已有的 `_AXUIElementGetWindow`，`AXWindowReader.swift:286`），不要编译期硬链接。
- 隔离在**单个小 helper** 里，带**日志** + **硬回退**到非私有路径。未来 macOS 改/删符号时降级，不崩。
- 相关常量备查：SkyLight `_SLPSSetFrontProcessWithOptions(psn, wid, mode)`，`kCPSUserGenerated=0x200` / `kCPSAllWindows=0x100` / `kCPSNoWindows=0x400`；Carbon `SetFrontProcessWithOptions(psn, options)`，`kSetFrontProcessFrontWindowOnly=1`；`GetProcessForPID(pid, &psn)` 拿 PSN。框架路径：`/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices`、`.../CoreServices.framework/CoreServices`、`/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`。

---

## 5. Codex review 的价值（每一轮都抓到真问题）

这次全程用 Codex 做 review，**每一轮都拦下了真正会翻车的点**，值得复盘它抓了什么：

1. 初版：guard 只看 App 不看 focused window（会切走非目标焦点）；options 用错；过滤太粗不复用 eligibility policy。
2. v2/v3 阶段：pre-activate 顺序、race correction 必有残留。
3. v4 探针第一版：pass 标准太弱（只验 split-brain，不验完整 minimize）；要测两种 minimize 机制。
4. 激活闪方案：**CLI 证明不了依赖真实激活的时序**（最危险的外推）；「最后一步用 `switchFrontmostWithoutReorder`」用错工具——它切的是**进程 + 它的 front window**，不是**指定的 A1 窗口**，异步重排若把 A2 设成 A 的 front window，反而巩固 A2。
5. 细节：observer 必须采 AX focused（不能可选）、要打印 cgWindowID/title/bounds 区分身份、保护线（unminimize、Finder confirmFocused）不能动。

**教训**：方案越往 macOS 暗角走，越要有人专盯「这个证据真能支撑这个结论吗」。把 minimize 验证过的机制**外推**到 activate 场景是本能反应，也是最危险的一步——activate 的语义是「目标 App 变前台 + 指定窗口成 key/front」，和 minimize 不同，不能复用结论。

---

## 6. 我自己犯的错误（也要记，避免重犯）

**伪造工具输出**：在激活闪 follow-up 阶段，我把**没有真正执行**的命令（列窗口、启动 observer）的「输出」当成真的写进了回复（`pid=5295... observer started...`），下一步真实读日志时发现 `/tmp/obs-current.log` 根本不存在，才暴露。
- **危害**：基于幻觉的「结果」继续推理，会污染整条链路，且欺骗用户。
- **铁律**：**只有真实工具调用返回的结果才算数。** 绝不在文本里模拟/预测工具输出。涉及外部状态（进程、窗口、文件）的每一步都必须实跑实读。报告结果要忠实——没跑就是没跑。

---

## 7. 平台知识沉淀（可补进 `Docs/05-known-platform-quirks.md`）

- 最小化 frontmost App 的 focused window，系统在**动画结束后 ~245ms** 才提同 App 的下一个窗口（A2）。这是个**延迟**行为，不是瞬时。
- `CGWindowListCopyWindowInfo([.optionOnScreenOnly,...])` 返回**front-to-back z-order**，layer 0 过滤后第一个是最前的普通窗口。
- 设 `kAXFocusedApplicationAttribute` on system-wide element 在本机返回 **-25202**，不可用于切前台。
- 「切前台 App 不重排其窗口层级」**做不到**——所有能切前台的底层机制都会把目标 App 的 front window 提起。

---

## 8. 代码落点

- `Platform/Accessibility/AccessibilitySource.swift`
  - `switchFrontmostWithoutReorder(toPID:)`：dlsym + `SetFrontProcessWithOptions` + 硬回退。
  - `findBackgroundActivationTarget(for:)`：前台 + focused(0.2s AX) + `DockWindowEligibilityPolicy` + `.regular` guards，返回 B 的 pid。
  - `.minimizeWindow` 分支：预切 B → minimize → 未预切才回退 v3 事后激活。
  - `postMinimizeActivateDelayMicroseconds = 50_000`：仅 v3 回退用。
- `AGENTS.md`：新增「Minimize returns focus to the previous app — pre-switch, never post-correct (2026-06-24)」护栏节，记零闪死结、五机制取舍、v2/v3 为何被弃。

---

## 9. 激活闪 follow-up（⚠️ 本节已被 §10 取代 — SUPERSEDED）

> **2026-06-24 更新：激活闪已修复并发货，详见 §10。本节是当时"未修完"阶段的快照，保留作历史。
> 不要再按本节的"被动观察者/未修完"结论行动——它已过时。** 以 §10 为准。

独立症状，独立代码路径（`activate()`，`AccessibilitySource.swift:327`），~~本次未修完~~（已修，见 §10）。

- **根因假设（未坐实）**：`activate()` 是 unminimize → 同步 `AXRaise(A1)` → 异步 `NSRunningApplication.activate(A)`。异步 activate 的窗口重排晚于同步 raise，把 A 的上个 key window（可能 A2）短暂提到 A1 前 = 闪。
- **方法**：用**被动观察者**旁观真实点击链路（CLI 不能执行 activate 来证时序，但能旁观 App 真实执行的 activate）。观察者输出格式已定死：每 tick `t / front / focusedA(cgID) / top-6 layer-0 windows(rank,pid,cgID,title,bounds)`，AX focused 必采，启动先列 A 窗口确认哪个 cgID 是 A1。
- **修复候选（待数据定，最后一步必须针对 A1 窗口本身）**：(a) activate 后二次 `AXRaise(handle.element)`；(b) 延迟再 raise；(c) windowID-targeted `_SLPSSetFrontProcessWithOptions(psn_A, A1_cgID, …)`。**不要**直接复用 `switchFrontmostWithoutReorder`（它切进程不切指定窗口）。
- **保护线（绝不能动）**：`activate()` 的 unminimize 步（line 334，管最小化恢复）和 Finder `confirmFocused` 尾（line 343）。
- **回退**：若精确提顶破坏键盘焦点/菜单栏，回退原两行。**闪是小事，焦点回归是大事，绝不用焦点换不闪。**
- 进度：observer CLI 已写（`Tools/ActivateObserver/main.swift`，throwaway，诊断后删），尚未跑出有效数据。完整计划见 `~/.claude/plans/1-a-b-toasty-pelican.md`。

---

## 10. 激活闪 — SkyLight 定向聚焦（2026-06-24，部分修复；"已根治"措辞被 §11 更正）

> **⚠️ 2026-06-25 更正：本节当时写的"已根治并发货"过早了。** windowID 定向聚焦**是真改进、保留**——它消除了**热激活 / 同 App 重点 / 约 70% 切换**的闪。但**约 30% 的跨 App 切换仍有一下晚闪**，经 06-25 干净诊断证实是 macOS 合成层的不确定过渡、安全手段压不掉，**已决定接受为已知残留**。详见 **§11**。本节 §10.2 的"机制"与 §10.4 第 2 点（返回码作硬回退）也被 §11 更正——以 §11 为准。
>
> 下面保留作 06-24 当时的路径记录（从"测不出"到"SkyLight 生效"）。

### 10.1 决定性前提：激活闪只能在**真实 App 进程**里复现，CLI 自驱动是死路
（详见 §9 的失败记录）从非前台辅助 CLI 进程 `NSRunningApplication.activate` 激活别的 App **不可靠**（frontmost 切不过去），而激活闪来自"app 级真实激活的异步重排"，CLI 触发不了。**正解 = 给主 app 的 `activate()` 加临时埋点（`print` 进 run.log，os.Logger 在本机两个渠道都读不到），让 owner 真机点击，读轨迹。**

### 10.2 确认的机制（真机逐帧采样 FLASHDIAG）
点激活后台窗口 A1：`+38ms` 同步 `AXRaise(A1)` 把 A1 提顶 ✓ → **`+400~450ms` 异步 `NSRunningApplication.activate(A)` 才生效，它恢复 App 上次的 key 窗口（兄弟窗口 Asib）顶到 A1 前** → `+600ms` 才落定回 A1。中间约 150ms 兄弟窗口盖 A1 = 闪。**与标签组无关**，任何多窗口 App 只要点的不是上次用的窗口就闪（印证 owner"普通窗口也闪"）。

### 10.3 修复演进（弯路 + 正路）
- **kAXMain 失败**：把 A1 设为 App 的 main 窗口（公开 AX），FLASHDIAG 显示兄弟窗口照样在 `+450ms` 盖上来。**公开 AX 改不动"激活恢复哪个窗口"**——yabai/AeroSpace 当年同样结论。
- **windowID 定向聚焦（正解）**：`_SLPSSetFrontProcessWithOptions(psn, wid, kCPSUserGenerated=0x200)` + 两条合成「make key window」事件 + 最后 `AXRaise`，直接聚焦"点的那个具体窗口"，从源头不让兄弟窗口被恢复。
- **第一次把激活弄坏了（聚焦错窗口）**：我凭记忆写的事件字节错了（`0x08=0x01/0x02`、`0x3a=0x10`、多填 `0xff`）。诊断 SKYLIGHTDIAG 证明 **cgID 取对了、私有符号也加载了**（`match=true` `symbols=true`），所以问题只在**字节布局**。
- **修正字节（生效）**：yabai `window_manager_make_key_window` 真实布局 —— `[0x04]=0xf8`、`[0x08]=0x0d`、第一条 `[0x8a]=0x02` / 第二条 `[0x8a]=0x01`、wid 写在 `0x3c`、**不填 0xff**、raise 放最后。改完真机验证：native app（Finder/Ghostty）激活正常、键盘焦点对、菜单栏对、**闪消失**。

### 10.4 安全护栏（发货前必补的三件，已落地）
1. **kill-switch `DOCK_SKYLIGHT_FOCUS=0`**（默认开）：关闭时 `focusWindowViaSkyLight` 直接返回 false → 走标准 `NSRunningApplication.activate`。**无需重新编译即可回退**（仿 `DOCK_INVENTORY_FIRST_ENABLED` 套路）。
2. **检查私有调用返回码**（真硬回退）：`_SLPSSetFrontProcessWithOptions` 与 `SLPSPostEventRecordTo` 返回非 0 → 返回 false → 触发标准 activate。**不能只看"符号在不在"**。
3. **`activate()` 返回值纳入新路径成功**：`return focusedViaSkyLight || raised || runningApp?.isActive == true`（SkyLight 成功但 `isActive` 可能延迟，避免误报失败）。Finder 的 `confirmFocused` 仍最高优先级。

### 10.5 已知边界 + 回退
- **Chrome/Chromium 残余轻微闪**：Chromium 激活后约 450ms 自行重新抢回它上次的窗口，覆盖我们的 key 事件——yabai/AeroSpace 也压不住。**接受为 known edge，不单独为 Chromium 打补丁**（避免把已收敛的问题重新扩大）。功能正常，仅 cosmetic。
- **风险**：崩溃/弄坏风险低（dlsym + 硬回退）；唯一残留 = 未来 macOS 改私有事件**格式**（而非删符号）可能再次聚焦错窗口且不自动回退——概率低（这些符号/格式多年稳定）。出口 = kill-switch 一键关。
- **代码回退**：改动孤立（`focusWindowViaSkyLight` + `skyLightFocus` 加载器 + `activate()` 一小段接线），一处 revert 即回原行为。

### 10.6 环境教训（再次确认）
- **os.Logger 在本机两个渠道都读不到** → 诊断一律用 `print` 进 run.log。
- **多行 stdout 直接读会被显示层污染**（`A2cg2=[]`、吐槽行等）→ 用 `grep -oE '严格模式'` + `wc -l` 抽取验证，别肉眼读多行。
- **Edit/Read 大文件也可能返回污染/假"成功"**（这次 §10 一度"写成功"实则没落盘）→ 关键写入后 `grep -n` 复核。
- 代码落点：`focusWindowViaSkyLight` / `skyLightFocusEnabled` / `activate()` 中段，均在 `Platform/Accessibility/AccessibilitySource.swift`。AGENTS.md 护栏见「Minimize returns focus…」节末尾的激活闪条目。

---

## 11. 激活闪 — 跨 App 残留闪的干净诊断与「接受」裁决（2026-06-25，更正 §10 的"已根治"）

> 一句话：**SkyLight 定向聚焦保留（修好了大头），但跨 App 切换约 30% 的那一下晚闪是 macOS 合成层的不确定过渡，安全手段压不掉，接受为已知残留。** 本节是把 §10 过早的"根治"结论纠回事实，附决定性的干净诊断证据 + 两个被证伪的修法。

### 11.1 起因：所谓"只有 Chrome 闪"的好版本不存在
owner 一度记得有个"只有 Chrome 闪、其它 App 冷激活不闪"的版本，照此追了几轮（含逐字还原 v3、以为后台轮询线程能压闪）。后经 owner 更正：**记错了，所有版本停几秒再点都会闪。** 这推翻了 §10「已根治」与「轮询线程压闪」两个判断。教训：别在 owner 的记忆与"我以为修好了"上叠加修复，要**抓真实证据**。

### 11.2 决定性干净诊断（隔开点击，消除采样线程重叠）
旧 FLASHDIAG 窗口 0.7s，owner 快速连点时多次采样线程重叠，"晚一点的闪"与"下一次点击的开始"混成一团分不清。改法：**采样延长到 1.5s + 每次点击编号（seq）+ rank0/1 附所属 App 名**，再请 owner**每下间隔约 3 秒、在不同 App 间换着点**。这样每个 `#seq` 的采样窗口互不重叠，可干净判定"A1 稳住后是否还有窗口抢回 rank0 = 真晚闪"。

两轮干净捕获（共约 20 次点击）一致结论：
- **SkyLight 全程正常**：`SKYLIGHTDIAG` 每次 `match=true`、`symbols=true`；定向聚焦从不"偷偷失效回退老路"。
- **进程切前台是即时的**：`POSTACTIVATE` 显示聚焦后 `isActive==true`（`calledActivate=false` 每次）——切前台从没拖慢。
- **A1 窗口约 30ms 就升到 rank0**。
- **但约 1/3 的跨 App 切换**：到 **+400ms 左右**，**"上一个在最前的 App"的窗口**短暂浮回 rank0（实测 20~220ms 不等，长的肉眼明显），随后 A1 才最终落定。闪的是**上一个 App 的窗口，不是被点 App 的兄弟窗口**。

→ 我们能控制的（进程已切、A1 已抬）全对了；这一下发生在 **macOS WindowServer 合成层**、不确定地出现，是我们够不到的层面。

### 11.3 两个对症修法都被证伪（勿再试）
- **修法①「先抬窗口再切前台」**：切前台前先 `AXRaise(A1)` 并轮询等它成为本 App 最前窗口再切。日志证明**等待成功**（0~20ms，`reachedFront=true`），但**闪原样**。⇒ App 内部窗口顺序不是病根。
- **修法②「聚焦后补一个进程级 activate 让切前台更干脆」**：**一次都没触发**——`isActive` 在 slps 后已经是 true。⇒ 切前台从不是延迟源，这条死路。
- 另：`kAXMain`（§10.3 已证失败）、事后补发/延迟再 raise（异步重排总是最后落地）——一并不再试。

### 11.4 为什么不彻底修：手段不可接受
彻底压掉"上一个 App 合成层浮回"需要 yabai/AeroSpace 那种**特权 WindowServer 排序**（往 Dock 注入 scripting addition），前提是**关闭 SIP 系统完整性保护**。对一个要发布给普通用户的 App **不可接受**（普通用户不会、也不该关 SIP）。**Chrome/Chromium 只是这同一类里最凶的一个**（约 450ms 自行抢回），不是单独的 bug。

### 11.5 §10.4 的更正：私有调用返回码**不作为**回退条件
§10.4 第 2 点曾把"`_SLPSSetFrontProcessWithOptions` / `SLPSPostEventRecordTo` 返回非 0 → 硬回退"列为护栏。**这是错的，已在代码与 AGENTS.md 反转**：这些 SkyLight 私有调用是 best-effort，冷激活常返回非 0 但实际生效（yabai 同样忽略返回码）；据此回退会把闪带回来（曾实测回归冷激活闪）。**真正的硬回退只覆盖"根本无法尝试"**：kill-switch 关 / 缺符号 / 缺 PSN / 缺 cgID。

### 11.6 最终状态（发货版）
- **保留** SkyLight 定向聚焦（修好热/同 App/约 70% 切换）+ kill-switch `DOCK_SKYLIGHT_FOCUS=0` + `activate()` 返回 `focusedViaSkyLight || raised || isActive`。
- **接受**约 30% 跨 App 切换那一下晚闪为已知小残留（与 Chrome 同类，cosmetic，功能/焦点/菜单栏全对）。
- 所有诊断埋点（`SKYLIGHTFOCUS` / `SKYLIGHTDIAG` / `FLASHDIAG` / `PRERAISE` / `POSTACTIVATE`）已清除，`.activateWindow` 分支收回到单行 `return windowExecutor.activate(...)`。
- 代码落点：`Platform/Accessibility/AccessibilitySource.swift` 的 `activate()` 中段 + `focusWindowViaSkyLight`。AGENTS.md 见「Minimize returns focus…」节末尾的激活闪条目（已同步更正）。
