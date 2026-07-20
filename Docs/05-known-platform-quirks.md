# Known Platform Quirks

## Accessibility TCC 身份与发布签名（2026-07-19）

- macOS 的辅助功能开关绑定的是应用代码身份，不只看显示名称或 bundle ID。ad-hoc 签名的 designated requirement 会绑定当前二进制的 `cdhash`；每次重新构建都可能成为一个新身份。
- v0.6.5 及更早公开包曾在 `Scripts/package_release.sh` 中移除原签名并重新 ad-hoc 签名。覆盖升级后，系统设置可能保留一个仍显示开启的旧条目，但当前进程的 `AXIsProcessTrusted()` 仍返回 `false`。
- 从旧 ad-hoc 包迁移到首个 Developer ID 包时需要删除旧辅助功能条目并重新授权一次。之后必须保持 bundle ID、Team ID 和 Developer ID 身份稳定，跨版本验收要验证授权不会再次丢失。
- 正式公开发布脚本必须 fail closed：缺少 Developer ID 或 notarization 凭据时不得生成稳定版 ZIP/DMG，也不得回退到 ad-hoc 或本机自签名。
- 在所有者明确要求证书到位前开放试用时，只能走单独的 GitHub Pre-release：使用长期固定的自签证书、验证 DR 不含 `cdhash`、不更新 Homebrew/稳定版入口，并明确提示 Gatekeeper 手动放行及未来 Developer ID 迁移仍需重新授权一次。正式发布链不得因此放宽。
- 不要从 DMG 或 App Translocation 临时路径请求辅助功能权限。应先移入 `/Applications` 再注册，避免 TCC 记录指向临时副本。
- Gatekeeper 放行、公证状态与 Accessibility 授权是两套独立机制；清除 quarantine 不能修复旧 TCC 身份。

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

## 状态栏菜单与 macOS 集成限制（2026-06-30）

- `SMAppService.mainApp` 登录项接入只在 macOS 13+ 可用；macOS 12 菜单里应显示为不支持，不要无保护调用 13+ API。
- 登录项状态不是二态。除了 `unsupported` / `off` / `on`，还必须处理 `requiresApproval`：注册成功但仍需用户到系统设置批准，这不是失败。
- 本机 SDK 已确认 `SMAppService.openSystemSettingsLoginItems()` 标注 `macOS 13.0+`，仍必须用 `#available(macOS 13.0, *)` 包住，因为项目最低部署目标是 macOS 12。
- 沙箱 App 不能直接修改系统 Dock 偏好或重启 Dock。`NativeDockPreferencesService` 必须通过 `SecTaskCopyValueForEntitlement("com.apple.security.app-sandbox")` 检测沙箱；沙箱为 true 时不要执行 `defaults write com.apple.dock` 或 `killall Dock`。
- 当前系统 Dock 写入面向非沙箱 GitHub/Homebrew 分发。菜单里的系统 Dock 滑杆只在鼠标松手且数值实际变化后应用，不能在拖动过程中连续写系统 Dock 或连续重启 Dock。

## 面板几何与 `visibleFrame`（2026-07-01）

- `NSScreen.visibleFrame` 会随系统 UI 可用区变化：底部 Dock 显示/隐藏会改变底部可用区；左/右 Dock 常驻会改变 `visibleFrame.minX` / `visibleFrame.maxX`。
- Cmd+Opt+D 显示或隐藏系统 Dock 时也会触发 `visibleFrame` 变化。底部任务条、胶囊、抽屉如果用 `visibleFrame` 贴底或横向 clamp，会出现原生 Dock 一唤醒就上移/变窄的错觉。
- 底部三面板和跨面板拖动载体应锚定到物理屏幕 `screen.frame`：底边用 `screen.frame.minY`，横向 clamp 也按 `screen.frame`。这套 UI 有意贴屏幕物理底边，不避让系统 Dock 常驻占位。
- `visibleFrame` 仍适合表达菜单栏/可用区上限。抽屉最大高度继续受 `visibleFrame.maxY` 与 `screen.frame.maxY - safeAreaInsets.top` 的较小值限制，避免顶到菜单栏或刘海安全区。
- 菜单栏自动隐藏会让 `visibleFrame.maxY` 改变；在无刘海外接屏上，抽屉最大高度仍可能随菜单栏显隐跳变。这是已知边界，不等同于底部 Dock 显隐导致面板整体移动的问题。

## Tungsten Edge 自动隐藏与多屏底边探测（2026-06-30）

- Tungsten Edge 的自动隐藏滑杆语义是“底边唤醒等待时间”，不是“鼠标离开后多久隐藏”。有限值范围为 `0.1s...3.0s`；`不唤醒` 表示会隐藏，但底边不启动唤醒计时。
- 鼠标离开 Dock / 胶囊 / 抽屉后，idle hide 延迟固定为 `0.2s`。不要把它重新绑回滑杆值。
- 隐藏态也必须持续做底边探测；不能依赖 Dock 面板可见或鼠标进入面板区域才启动唤醒。
- 底边热区与多屏切换共用同一探测入口：当前屏底边直接走唤醒逻辑；另一块屏幕底边先经过约 `0.35s` 驻留切屏，切屏后再从 0 开始计算唤醒延迟。
- 多显示器策略 UI 已移除，运行时固定为多屏自动切换语义。不要重新读取旧的 `displayMode` defaults key 来决定底边行为。

## 原生标签组（NSWindow tabbing）与“哪个标签可见”的判定（2026-06-14 实测，Ghostty）

> 这是“同 app 多标签合并”功能里反复踩坑后挖出来的平台事实。Obsidian 那份是产品/设计视角，这份是工程视角，写代码时按这条来。

- **原生 NSWindow tabbing（Finder / Ghostty 类）= N 个真实 NSWindow**：同 `pid` + 逐像素相同 frame，各有独立 `cgWindowID`、各 `AXStandardWindow`。浏览器标签则是 1 个 NSWindow 自绘，天然就一个窗口。要合并的是前者。
- **非当前标签在 AX 里报告为“最小化”（`min=1`）**：一个标签组里同一时刻只有当前可见标签 `min=0`，其余后台标签全报 `min=1`。这不是真的最小化，是 tabbing 的实现细节。
- **切标签时 AX 的状态严重滞后/不可靠，不能用它判可见标签**：实测 ① 切走的老标签 `min` 会被 AX **持续误报为 0 长达 ~4 秒**（AX 自身就报错，不是轮询慢）；② 老标签的 `Miniaturized` 通知**根本不发**；③ 新标签的 `Deminiaturized` 通知**时有时无**（赌它做事件驱动会出 bug）。过渡期“两标签同时 `min=0` / `foc=1`”，**没有任何瞬时 AX 字段能区分谁可见**。
- **可靠信号 = `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`**：后台标签是被 order-out 的独立 NSWindow，**不在 on-screen 列表**；每个标签组恰好留 **1 个**在屏 = 当前可见标签。实测 Ghostty 38 窗 → on-screen 仅 2（两组各 1）。合成层真相，切标签即时更新，无 AX 滞后。判“标签组里谁可见”用它。
- **CG bounds 与 AX bounds 可能不同**：实测同一 Ghostty 标签，CG 报宽 1005/874，AX 报 1191。所以**分组用 AX bounds**（与 `StripItem.tabGroupKey` 一致），**只用 CG 判 `cgWindowID` 是否在屏**——两者别混用。
- 当前实现：`AppTracker.rebuildSnapshot` 对“同 frame ≥2 成员”的标签组改用 on-screen 判可见性（不在屏即视为最小化），普通单窗口仍走 AX；前台 0.5s 轮询比对 on-screen 集合发现切标签（AX 完全不报时的即时触发）。`CGWindowListCopyWindowInfo` 在无屏幕录制权限时拿不到标题，但 `pid` / `number` / `bounds` / `layer` / on-screen 都可用，足够本判定。

## 激活/前台切换的时序陷阱（2026-07-03 实测，激活闪根治过程沉淀）

> 完整调试过程见 `Docs/22` §12；硬护栏见 AGENTS.md「Minimize returns focus…」激活闪条目。

- **`NSWorkspace.frontmostApplication` 是通知驱动缓存，SkyLight（`_SLPSSetFrontProcessWithOptions`）切前台后滞后 0.4–1.5s**。动作决策路径（toggle 规划、最小化预切 guard）读它会误判；**新建 `NSRunningApplication(processIdentifier:)` 实例读 `isActive` 是即时的**，决策一律用后者。
- **对打盹（App Nap）App 的任何 AX 问询可阻塞 400–900ms**：`inventoryWindows`（0.5s messaging timeout）、`kAXMinimizedAttribute` 读取、`_AXUIElementGetWindow` 都会卡。凡在用户点击的即时路径上，能用快照 / CG 数据就不要现场问 AX——这条空窗曾是激活闪的根因。
- **打盹 App 的窗口会从 `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 临时消失**（连"当前前台 App 刚激活的窗口"都可能缺席几秒）。按 on-screen 列表反查 cgWindowID 不可靠；快照里的 `record.cgWindowID` 才是稳定来源。
- **抢顶型 App（Ghostty、Chromium 系：Chrome/Dia）在自己仍是活跃 App 期间，若别的窗口被 AXRaise 盖到它上面，会在 ~+450ms 把自己的窗口浮回顶层**；良性 App（Finder/Safari/微信/飞书/PS/AI…）不会。这就是为什么"闪不闪取决于从哪个 App 切走"。
- **对仍最小化的窗口发 SkyLight make-key 事件，App 会把键盘焦点落到它的可见兄弟窗口上**（Chrome/访达实测）。最小化恢复后必须对目标窗口 `kAXMainAttribute=true` 纠正 App 内部焦点，否则输入焦点和 AX `kAXFocusedWindow` 都停在兄弟窗口。
- **App 被切成前台进程时若没有 key 窗口（目标窗口仍 order-out/最小化），AppKit 会自动把该 App 最上面的可见窗口提为 key 并持久抬到旧前台之上**（2026-07-05 探针，访达/微信/Dia 一致）。裸 psn 切换（不发 make-key）拦不住，`kCPSNoWindows (0x400)` 也拦不住——提拔发生在 App 侧而非 WindowServer 侧。要恢复最小化窗口且不带起兄弟：**先 unminimize、后切前台，两步微秒级相邻、中间零 AX 问询**（wid 用快照值）；对刚 unminimize 的窗口立即发 make-key 会正确落在它身上，不再错落兄弟。见 `Docs/22` §13。

## SLPS make-key 事件格式（2026-07-20）

- `SLPSPostEventRecordTo` 的 `[0x08]=0x0d` + `[0x8a]=0x02/0x01` 事件对**不是完整的 make-key**——它只是 yabai `focus_window_without_raise` 中的辅助切窗通知。只发它会得到「进程已前台、窗口已抬起、但全系统无 key window」的键盘悬空态（打字无处可去，系统级 kAXFocusedApplication 读不到任何 App）。
- 真正的 make-key 记录对（yabai `window_manager_make_key_window`，v3.3.10–v7.1.25 稳定）：每条 0xf8 字节，`[0x04]=0xf8`，`[0x08]=0x01`/`0x02`，`[0x3a]=0x10`，`[0x20..<0x30]` 全 `0xff`，cgWindowID 小端写入 `[0x3c..<0x40]`，其余为零。本仓库唯一实现在 `SkyLightMakeKeyEventBuilder`（单元测试锁定）。
- 附带教训：非应用形态的 CLI 进程仅靠 `_SLPSSetFrontProcessWithOptions(wid)` 就能完成含 key window 的切换，会掩盖 make-key 字节错误；用 CLI 探针验证此类机制时结论不能直接外推到已注册 NSApplication 的进程。
