## New and improved

- Updates now download automatically in the background; clicking Install and Relaunch completes the update, and an update not installed manually is installed when Tungsten Edge quits. Download and install updates automatically in Settings → About turns this off.
- Added an option to mark the active window’s card with a bar beneath it, in Settings → General.
- Added an Event Log to Settings → Diagnostics, listing anomalies Tungsten Edge detected on its own over the past two weeks; the log stays on this Mac.
- In-app feedback can now include the diagnostic report through the Attach Diagnostics checkbox.

## Installing

**Already on 0.9.0 or later?** Do nothing — the update will find you, or use *Check for Updates…* in **Settings → About**. Your Accessibility permission carries over.

**New install:** grab the `.dmg` from the [official website](https://tungstenedge.app) and drag it into Applications, or:

```bash
brew install --cask tungsten-edge
```

Requires macOS 12 or newer. Universal — Apple silicon and Intel.

---

## 新增与改进

- 新版本改为在后台自动下载，下载完成后点击「安装并重启应用」即可完成更新；未手动安装的，将在退出钨极时自动安装。可在「设置 → 关于」中关闭「自动下载并安装更新」。
- 新增「焦点横条」：在当前窗口的卡片下方显示一道横条，可在「设置 → 通用」中开启。
- 「设置 → 诊断」新增「运行记录」，列出钨极近两周自动发现的异常，记录仅保存在本机。
- 应用内反馈可勾选「附上诊断信息」，随反馈一并发送诊断报告。

## 安装

**已经装了 0.9.0 或更新的版本？** 什么都不用做——更新会自己找上门，也可以在「设置 → 关于」里点「检查更新…」。辅助功能授权不用重新给。

**新装：** 到[官网](https://tungstenedge.app)下 `.dmg` 拖进「应用程序」，或者：

```bash
brew install --cask tungsten-edge
```

需要 macOS 12 或更新版本。通用架构——Apple 芯片与 Intel 都可以。
