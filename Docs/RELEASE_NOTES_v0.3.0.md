# Tungsten Edge 钨极 · v0.3.0

**Window feel and edge control release.** This version makes Tungsten Edge feel closer to a complete everyday taskbar: window switching and minimizing are smoother, and the new menu bar controls let you tune launch, native Dock wake, and Tungsten Edge edge wake behavior in one place.

## What changed

- **Better window switching feel** — clicking a card now targets the concrete window more directly, reducing cases where a sibling or previously focused window briefly flashes in front.
- **Smarter minimize focus return** — minimizing the current focused window of a multi-window app now returns focus to the previous app instead of letting macOS promote another window from the same app.
- **Menu bar controls** — the status menu now includes launch at login, native Dock wake timing, and Tungsten Edge wake timing.
- **Edge auto-hide** — Tungsten Edge can stay visible, wake from the bottom edge after a selected delay, or hide without bottom-edge wake.
- **Richer right-click menus** — native menus now include quit / force quit, Finder actions, and recent files or folders where available.
- **Drawer polish** — drawer interactions close at more natural moments, and dragging apps between the strip and drawer keeps the landing behavior stable.
- **Stability fixes** — improved Finder hide / show behavior, Ghostty native-tab minimize handling after moving windows, multi-display shared-edge placement, badge positioning, and horizontal mouse-wheel scrolling in the strip.

## Requirements

- macOS 12.0 (Monterey) or later
- Intel and Apple Silicon (universal binary)
- Accessibility permission is required to read and manage windows.

## Install

### Homebrew

```bash
brew tap moonbai-studio/tungsten-edge
brew trust moonbai-studio/tungsten-edge
brew install --cask tungsten-edge
```

### Direct download

1. Download `Tungsten-Edge-0.3.0.dmg`, open it, and drag **Tungsten Edge** into Applications.
2. **First launch:** because this is still an unsigned / unnotarized early build, macOS may block it once. Right-click → Open on macOS 14 and earlier, or use System Settings → Privacy & Security → Open Anyway on macOS 15 and later.
3. Grant **System Settings → Privacy & Security → Accessibility**.

## Known limitations

- Not signed / notarized yet, so first launch still needs the macOS allow step.
- The UI is currently Chinese only.
- A small residual cross-app activation flash can still happen in some macOS WindowServer transitions. The window target and focus are correct; this is accepted for this early build.

---

# 中文

## 改了什么

这一版是 **窗口手感与边缘控制版**。钨极更接近一个可以日常使用的完整底部任务条：窗口切换和最小化后的焦点回归更顺，状态栏菜单也补上了登录启动、系统 Dock 唤醒、钨极底边唤醒等核心设置。

- **窗口切换手感优化**：点击任务条卡片时更直接地锁定你点的那个具体窗口，减少兄弟窗口或旧窗口短暂抢前的闪动。
- **最小化后回到上一个 App**：多窗口 App 里最小化当前前台窗口时，焦点回到上一个 App，而不是同 App 的另一个窗口突然冒出来。
- **状态栏菜单**：新增登录时启动、系统 Dock 唤醒时间、钨极自己的底边唤醒时间。
- **边缘自动隐藏**：支持常驻、延迟唤醒、以及“不唤醒但自动隐藏”。
- **右键菜单增强**：原生菜单里加入退出 / 强制退出、Finder 操作、最近文件或文件夹。
- **抽屉体验打磨**：抽屉操作后的关闭时机更自然，任务条和抽屉之间拖动的落点更稳定。
- **稳定性修复**：改善 Finder 隐藏 / 唤回、Ghostty 原生标签移动后最小化、三屏共享边落点、角标位置，以及任务条鼠标滚轮横向滚动。

## 系统要求

- macOS 12.0 (Monterey) 及以上
- Intel 与 Apple 芯片均可（通用二进制）
- 需要辅助功能权限来读取和管理窗口。

## 安装

### Homebrew

```bash
brew tap moonbai-studio/tungsten-edge
brew trust moonbai-studio/tungsten-edge
brew install --cask tungsten-edge
```

### 直接下载

1. 下载 `Tungsten-Edge-0.3.0.dmg`，打开后把 **Tungsten Edge** 拖进「应用程序」。
2. **首次打开**：因为这仍然是未签名 / 未公证的早期版本，macOS 可能会拦截一次。macOS 14 及更早版本请右键 → 打开；macOS 15 及更新版本请到「系统设置 → 隐私与安全性」里点「仍要打开」。
3. 在「系统设置 → 隐私与安全性 → 辅助功能」里给 Tungsten Edge 打开权限。

## 已知限制

- 还没有签名 / 公证，首次打开仍需要 macOS 放行步骤。
- 界面目前仍是中文。
- 少数跨 App 切换场景仍可能出现一下 macOS WindowServer 造成的残留闪动；窗口目标和焦点是正确的，本早期版本接受这个限制。
