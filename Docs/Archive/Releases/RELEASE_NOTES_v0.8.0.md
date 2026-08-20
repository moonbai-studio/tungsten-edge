# Tungsten Edge v0.8.0

One thing first: **builds now live on the official website, not on GitHub Releases.** Beyond that, this release is five fixes, all clustered around the moment you click — stuttering animations, a sticky-feeling press, the messaging zone getting shoved sideways, and cards that duplicated or vanished.

## ⚠️ Downloads moved to the website

From this release on, compiled builds are published only on the website:

**<https://tungstenedge.app>**

The GitHub repository stays open source and keeps taking issues, but it now holds **source code only** — release pages no longer carry `.dmg` or `.zip` attachments.

What this means for you:

- **If you already have it installed, nothing changes.** Keep using it; there is nothing to do.
- **The in-app "Check for Updates" has been updated accordingly** — when a new version exists it now takes you to the website instead of a page with no download on it. That alone made this release urgent.
- **Homebrew users are unaffected.** `brew upgrade --cask tungsten-edge` works as before; only the source of the package changed.
- **v0.7.7 and earlier stay on GitHub**, so existing links keep working.

If you have posted a download link somewhere, please use this permanent address from now on: **<https://tungstenedge.app/download/latest>** — it always points at the newest build, so old posts will not go stale.

For the record: Tungsten Edge remains GPL-3.0 open source and anyone can build it themselves. What the website provides is the signed, maintained, ready-to-run build.

## Fixed: animations stuttered when you moved the pointer away right after clicking

Click a card and immediately move the pointer away, and both the press rebound and the hover-exit animation would hitch at the start.

The taskbar asks the system which app is frontmost twice a second, and that question was being asked on the main thread — where **an app that looks perfectly healthy can still block it for 200–400 ms**. The animation queued up behind it, so a rebound that should finish in 90 ms was taking 320–405 ms.

That question now runs on a background thread and no longer sits in front of the animation. **The taskbar's refresh rate is unchanged**; it simply stopped occupying the channel that draws.

## Fixed: pressing a card felt sticky

The small scale-down you get when pressing a card used to play on **mouse-up** — meaning the whole animation happened after the click was already over. What you felt was "nothing happens when I press, it moves only when I let go."

It now starts the instant you press. While we were there, three places that had **no press feedback at all** — messaging icons with no main window, icons for apps you have kept in the Dock, and drawer icons — got the same treatment, so all four surfaces now behave alike.

## Improved: minimized windows come back faster

A minimized app is often dozing, and waking it means getting a handle on its window first — which in the slow case waits for the system to enumerate everything. Handles are now cached, so a hit skips that whole round.

## Fixed: the messaging zone got shoved right when clicking a window icon

Clicking a window icon would push everything right of the messaging zone sideways, sometimes producing a second Feishu or WeChat card — the same app appearing in both the messaging zone and the window area at once. The amount of shove varied.

Deciding whether a window belongs to a messaging app needs the app's localized name, and the system call that returns it **occasionally returns empty even for a live process**. Feishu's and WeChat's Chinese names happen to be available only through that call, so the two failed together; QQ, whose name contains `qq`, takes a different path and was never affected — that asymmetry is what led to the cause.

Names now come from a local registry that only ever grows: looked up once, remembered for good.

## Fixed: messaging apps occasionally showed two cards

When reading a window title failed, "could not read" was being treated as "the title is empty", so the same window was taken for a new one and given a second card. Those two states are now distinct.

## Fixed: window cards occasionally vanished

The system sometimes returns an empty window list. That used to read as "every window was closed", so the taskbar released the matching cards — while the windows were in fact still there. An empty list is no longer grounds for releasing anything.

## Install

Download `Tungsten-Edge-0.8.0.dmg` from the website and drag it into Applications: **<https://tungstenedge.app>**

Or use Homebrew:

```
brew install --cask moonbai-studio/tungsten-edge/tungsten-edge
```

**On first launch**: this build is not notarized by Apple yet, so macOS will stop it once. Right-click the icon and choose Open (macOS 14 and earlier), or go to System Settings ▸ Privacy & Security and click "Open Anyway" (macOS 15 and later). The website's download section has the full walkthrough with screenshots.

**Accessibility permission is required**: the taskbar reads and manages your windows, and it guides you through granting it on first launch.

---

# Tungsten Edge 钨极 v0.8.0

这一版有一件事必须先说：**安装包以后从官网下载，不再放在 GitHub 上**。除此之外是五处修复，全部集中在「点下去的那一刻」——动画卡顿、按压粘滞、消息区被推来推去、卡片重复或凭空消失。

## ⚠️ 下载入口搬到官网了

从这一版起，编译好的安装包只在官网发布：

**<https://tungstenedge.app>**

GitHub 仓库继续开源、继续接受 issue，但那边**只保留源码**，release 页面不再附带 `.dmg` 和 `.zip`。

对你意味着什么：

- **已经装好的用户不受影响**，照常用，不需要做任何事。
- **应用内的「检查更新」已经跟着改了**——发现新版本时它会带你去官网，不会再把你送到一个没有下载的页面。这也是这一版必须尽早发的原因之一。
- **Homebrew 用户不受影响**，`brew upgrade --cask tungsten-edge` 照常工作，只是包的来源换成了官网。
- **v0.7.7 及更早的版本仍然留在 GitHub 上**，旧链接不会失效。

如果你在小红书、B 站或别处贴过下载链接，以后请用这个长期有效的地址：**<https://tungstenedge.app/download/latest>** ——每次发新版它都会指向最新的包，旧帖子里的链接不会过期。

顺带说明：钨极的源码依然以 GPL-3.0 开源，任何人都可以自行编译。官网提供的是签好名、随时更新、有人维护的成品。

## 修复：点完卡片移开鼠标，动画会卡一下

点击卡片后立刻移开鼠标，按压回弹和悬停退出这两个动画的起点会有轻微卡顿。

原因是任务条每 0.5 秒会去问一次系统「现在哪个应用在前台」，而这个询问在主线程上进行——**一个看起来完全正常的应用，也可能让这次询问卡住 200 到 400 毫秒**。动画正好排在它后面，本该 90 毫秒完成的回弹被拖到了 320–405 毫秒。

这次把询问挪到后台线程去做，动画不再被它挡住。**任务条的信息更新频率没有变**，只是不再占用画面的那条通道。

## 修复：按下去有粘滞感

按下卡片时那一下轻微的缩放反馈，过去是在**松开鼠标**的瞬间才播放的——也就是说整个动画都发生在点击已经结束之后，手感上就成了「按下去没反应，松开才动一下」。

现在改成按下的瞬间就开始。同时，消息区里没有主窗口的图标、保留的应用图标、抽屉里的图标——这三处以前**完全没有按压反馈**，这次一并补齐，四个地方现在一致了。

## 优化：点最小化的窗口，恢复更快了

被最小化的应用常常处于"打盹"状态，唤醒它需要先拿到窗口的句柄，慢的时候要等系统枚举一整轮。这次给句柄加了一层缓存，命中时省掉整轮枚举。

## 修复：点窗口图标时，消息区整体被往右推

点窗口图标时消息区右侧会被整体推开，有时还会跳出两张飞书或微信的卡片——同一个应用同时出现在消息区和窗口区。推开的幅度时大时小。

原因是判断「这个窗口属不属于某个消息应用」时要用到应用的中文名，而取名字的那个系统接口**对活着的进程也会偶尔瞬时返回空**。飞书和微信的中文名恰好只能从这个接口拿到，所以它俩会同时失配；QQ 因为名字里带 `qq`，走的是另一条路，从来没受影响——这个不对称正是找到病根的线索。

现在名字改由一份只增不减的本地登记表提供，一次查到就永久记住。

## 修复：消息应用偶尔出现两张卡片

读取窗口标题失败时，"读不到"被当成了"标题是空的"，于是同一个窗口被当成新窗口又建了一张卡。现在这两种状态分开了。

## 修复：窗口卡片偶尔凭空消失

系统偶尔会返回一份空的窗口清单，过去这会被当成"窗口都关掉了"，于是任务条把对应的卡片释放掉——但窗口其实还在。现在空清单不再作为释放依据。

## 安装

从官网下载 `Tungsten-Edge-0.8.0.dmg`，拖进「应用程序」即可：**<https://tungstenedge.app>**

或用 Homebrew：

```
brew install --cask moonbai-studio/tungsten-edge/tungsten-edge
```

**首次打开**：这个包还没有完成 Apple 公证，macOS 会拦一下。右键点图标选「打开」（macOS 14 及更早），或到「系统设置 → 隐私与安全性」里点「仍要打开」（macOS 15 及更新）。官网下载区有带图的完整说明。

**需要辅助功能权限**：任务条要读取和操作窗口，第一次启动会引导你去授权。
