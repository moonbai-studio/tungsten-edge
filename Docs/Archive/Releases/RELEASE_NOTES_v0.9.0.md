Tungsten Edge v0.9.0 is a large release — everything accumulated since 0.8.0. It is now **signed and notarized by Apple**, the whole surface moved to **macOS 26 Liquid Glass and was aligned pixel-by-pixel with the real Dock**, **dragging was rebuilt**, the **UI ships in English and Simplified Chinese**, and there is now **automatic updating** and a **first-run guide**.

---

## ⚠️ Read this first if you are upgrading

v0.9.0 switches to a proper Apple Developer ID signature. As far as macOS is concerned a changed signature means a different app, so **the Accessibility permission you previously granted no longer applies** — you will see an empty taskbar, or none at all.

**How to fix it** (once only; future updates will not need this):

1. **Quit Tungsten Edge** (status menu → Quit).
2. Open **System Settings → Privacy & Security → Accessibility**.
3. Find the old **Tungsten Edge** entry, **select it and remove it with the「−」button**. Toggling the switch off and on is not enough — the entry has to go.
4. Reopen Tungsten Edge and grant it again when prompted.

The upside: from this version on, a plain double-click opens it. No more right-click-to-open.

---

## Appearance: Liquid Glass, aligned pixel-by-pixel with the Dock

All five floating surfaces — taskbar, drawer, capsule and both popups — now use **macOS 26 Liquid Glass** (macOS 12–25 keep the previous frosted material). This round was derived by measuring the real Dock:

- **Bar height 52 → 54, icons 36 → 40, icon pitch matched to the Dock.** Tungsten Edge used to sit slightly shorter and tighter than the system Dock; side by side they now match.
- **The rim highlight is modulated around the corners.** The Dock's bright edge is not uniform — one diagonal reads noticeably brighter than the other. That variation is reproduced.
- **The shelf tile is now opaque, self-drawn art.** It is the only chip on the bar that is not an app icon; as a translucent plate it disappeared entirely over a dark wallpaper.
- **Icons no longer carry a drop shadow**, matching the Dock — on the bar and on the card you drag.

## Hover: the app-name bubble now matches the Dock

- The **name bubble was rebuilt** one-to-one against the system Dock's: capsule shape, tail, font size and padding are all measured, and it sits on Liquid Glass. It now shows **only the app name**, as the Dock does; the full window title is still available through the system tooltip.
- **Sweeping quickly across a row no longer skips chips.** Each chip used to track the pointer on its own, so a fast sweep missed several; the whole strip is now one tracking area and the switch boundary is the geometric midpoint, with no stickiness when you move back and forth.
- **The quiet tier (app names off) now has feedback too**: icons lift slightly on hover. Previously, turning names off meant no hover feedback at all.
- Fixed the bubble popping up on the wrong display in multi-monitor setups.

## Dragging: rebuilt

Dragging a chip now moves a **bitmap carrier** — the same approach the Dock and BestDock take — which clears a batch of long-standing problems at once:

- No more double image when you pick a chip up, no more occasional disappearance when you fling it, no more ghosting or jitter on landing.
- **The return flight can be interrupted**: grab the icon mid-flight and it continues from wherever it is; click it and that counts as clicking the chip (wake / minimize) while it flies home.
- **Stashing into the drawer capsule now sucks the icon in** instead of drifting toward the taskbar and vanishing; dragging into the drawer body immediately swaps to the small drawer icon under your pointer.
- **The running dot hides while dragging** and returns on landing, matching the Dock.
- The return flight is faster overall (0.60/0.90s → 0.32/0.50s).

## Automatic updates

Until now a new version meant going to the website, downloading a disk image and dragging it across by hand. Tungsten Edge now checks on its own, shows you an update window when there is one, and a single click downloads, installs and relaunches it — the browser never enters the picture.

- Automatic checking is on by default. If you would rather it did not reach the network on a schedule, uncheck **Check for updates automatically** in **Settings → About**; it will then only look when you click *Check for Updates…* yourself.
- Homebrew users are unaffected: the cask is now marked as self-updating, so `brew upgrade` will no longer reinstall an older build over the top of a newer one.

## First run: hiding the system Dock

Tungsten Edge and the system Dock both live along the bottom edge of the screen, so showing both means they cover each other up. On first run Tungsten Edge now asks, and **Hide the Dock** sets it up for you — hidden, and staying hidden even when the pointer reaches the bottom edge.

- The Dock restarts, so the screen flashes once. That is normal.
- **Want it back? Press ⌥⌘D at any time** — that is macOS's own shortcut for showing and hiding the Dock. You can also change it later from the Dock slider in the Tungsten Edge status menu.
- If you had already set the Dock to hide itself, the prompt does not appear at all.
- **Not Now** means it will not ask again; the status menu is always there if you change your mind.

## English and Simplified Chinese

All 166 strings in the UI **follow the system language**, so an English system gets English with no separate build. To pin one language, set it for Tungsten Edge under **System Settings → Language & Region → Applications**.

## Also

- **Settings → About** now has a **founding-user mailing list** signup. Tungsten Edge will eventually become a paid app, and everyone using it before that announcement stays free forever; leaving an email is the channel for reissuing that after a new machine or a clean install.
- **Settings → About** also carries a GitHub link. Tungsten Edge is free and open source — if it is useful to you, a Star is the easiest way to help.

---

## Installing

**Download the installer**: grab the `.dmg` from the [official website](https://tungstenedge.app), drag it into Applications, and double-click.

**Homebrew**:

```bash
brew tap moonbai-studio/tungsten-edge
brew trust moonbai-studio/tungsten-edge
brew install --cask tungsten-edge
```

**Accessibility permission**: Tungsten Edge needs it to read and manage your windows, and it guides you through granting it on first run. If you are upgrading, remove the stale entry first as described above.

Requires macOS 12 or newer. Universal — Apple silicon and Intel.

---

钨极 v0.9.0 是自 0.8.0 以来积累的一大版：**通过了 Apple 签名与公证**、外观整体换成 **macOS 26 的液态玻璃并逐像素对齐原生程序坞**、**拖拽整个重做**、**界面支持中英双语**，并新增了**自动更新**和**首次运行引导**。

---

## ⚠️ 升级上来的用户请先看这一条

v0.9.0 换成了正式的 Apple 开发者签名。对 macOS 来说，签名变了就等于换了一个应用，**你之前给钨极开的「辅助功能」授权不再生效**——表现是升级后任务条空着、或者干脆不出来。

**怎么恢复**（只需要做这一次，以后升级不会再有）：

1. **退出钨极**（状态栏菜单 → 退出）。
2. 打开「系统设置 → 隐私与安全性 → 辅助功能」。
3. 在列表里找到旧的 **Tungsten Edge**，**选中它，点下面的「−」把它删掉**。直接关开关不管用，必须删掉这一条。
4. 重新打开钨极，按引导重新授权。

好消息是，从这一版开始双击就能打开，不用再右键放行了。

---

## 外观：液态玻璃，逐像素对齐原生程序坞

任务条、抽屉、胶囊和两个弹窗**五块面板全部换成 macOS 26 的液态玻璃**（macOS 12–25 继续用原来的毛玻璃）。这一轮是照着真实程序坞逐像素反推做的：

- **条高 52 → 54、图标 36 → 40、图标间距对齐原生**——之前一直比系统程序坞矮一点、密一点，现在两者并排看不出差别。
- **边缘高光按圆角调制**：原生程序坞的那圈亮边不是均匀的，两条对角明显更亮。这一版复现了这个明暗变化。
- **中转站图标改成实心自绘**：它是条上唯一不是应用图标的东西，原来做成半透明的，深色壁纸下会整个消失。
- **图标不再带外投影**（对齐原生）。条上四处加拎在手里的拖拽副本全部去掉。

## 悬停：应用名气泡对齐原生

- 鼠标停在图标上冒出的**应用名气泡整个重做**，照着系统程序坞的那颗一比一还原：胶囊形状、尾巴、字号、间距都是量出来的，底板也换成了液态玻璃。它现在**只写应用名**（和原生一致），完整窗口标题仍可从系统 tooltip 看到。
- **快速划过一整排图标不再漏格**。以前每个图标各自跟踪鼠标，划快了会跳过几个；现在整条任务条是一块跟踪区，切换边界变成几何中点，来回晃不再有粘滞感。
- **安静档（关掉应用名）也有反馈了**：悬停时图标轻微放大。之前关掉应用名等于完全没有反馈。
- 修掉多屏下气泡会弹到另一块屏的问题。

## 拖拽：整个重做

拖动图标改成**位图载体**（和原生程序坞、BestDock 同一个思路），一次性解决了一批老问题：

- 起拖不再有上下重影、拖快了不再偶发消失、落位不再重影或抖动。
- **归位飞行途中可以打断**：按住就能从它此刻的位置接着拖；点一下就等于点了这张卡（唤醒 / 最小化），图标照常飞回。
- **收进抽屉胶囊时是「吸进去」**，不再往任务条方向飘一段再消失；拖进抽屉体会立刻换成抽屉里的小图标贴在指针边上。
- **拖动时藏起运行小圆点**，落位才回来（对齐原生）。
- 归位速度整体调快（0.60/0.90 秒 → 0.32/0.50 秒）。

## 自动更新

以前发新版，你得自己去官网下 dmg、拖进「应用程序」。现在钨极会自己检查，有新版时弹一个窗口，点一下就下载、安装、重启，全程不用碰浏览器。

- 自动检查默认开着。不想让它定期联网的话，在「设置 → 关于」里把「自动检查更新」取消勾选即可——关掉之后只有你主动点「检查更新…」时才会去查。
- 用 Homebrew 装的用户不受影响：cask 已经标记成「应用自己会更新」，`brew upgrade` 不会再把你降级装回去。

## 首次运行：帮你收起系统 Dock

钨极和系统 Dock 都住在屏幕底边，同时显示会互相遮挡。所以第一次运行时它会问一句，点「帮我隐藏」就替你设好（自动隐藏，而且鼠标碰到底边也不会把它唤出来）。

- 系统 Dock 会闪一下重启，这是正常的。
- **想让它回来，随时按 ⌥⌘D**——那是 macOS 自带的 Dock 显隐快捷键。也可以之后从钨极状态栏菜单里的系统 Dock 滑杆改。
- 如果你早就把系统 Dock 设成自动隐藏了，这个提示不会出现，不会打扰你。
- 点了「以后再说」就不再问；想改随时走状态栏菜单。

## 界面中英双语

整个界面的 166 条文案**跟随系统语言**，英文系统下自动是英文，不需要装两个版本。想单独指定语言，可以在「系统设置 → 语言与地区 → 应用程序」里给钨极单独设。

## 其它

- 「设置 → 关于」新增**原始用户邮箱订阅**入口：钨极将来会转成买断收费，公告日之前就在用的人永久免费；留个邮箱是换机器/重装后补发的通道。
- 「设置 → 关于」加了一行 GitHub 链接。钨极是免费开源的，如果它帮到了你，去点个 Star 是最省事的支持方式。

---

## 安装

**下载安装包**：从[官网](https://tungstenedge.app)下载 `.dmg`，拖进「应用程序」，双击打开。

**Homebrew**：

```bash
brew tap moonbai-studio/tungsten-edge
brew trust moonbai-studio/tungsten-edge
brew install --cask tungsten-edge
```

**辅助功能权限**：钨极靠这个权限读取和管理你的窗口，第一次运行时会引导你开启。从旧版升级的用户请按上面那条先删掉旧记录。

需要 macOS 12 或更新版本，Apple 芯片与 Intel 通用。
