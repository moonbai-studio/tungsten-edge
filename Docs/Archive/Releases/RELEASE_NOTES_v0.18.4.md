## New and improved

- Apps dragged onto the Trash are moved to the Trash, and disks dragged onto it are ejected.
- A new Diagnostics tab in Settings copies a diagnostic report in one click, for reporting problems.
- The app drawer and popups close on a click anywhere outside them, including the taskbar; the app drawer and folder popups no longer stay open at the same time.

## Fixed

- The settings path in the permission guide did not match the system on macOS 27.
- Pinned folder icons kept showing an app’s old icon after the app’s icon was changed.
- The bottom edge of maximized windows jittered continuously in Parallels Desktop Coherence mode.

## Installing

**Already on 0.9.0 or later?** Do nothing — the update will find you, or use *Check for Updates…* in **Settings → About**. Your Accessibility permission carries over.

**New install:** grab the `.dmg` from the [official website](https://tungstenedge.app) and drag it into Applications, or:

```bash
brew install --cask tungsten-edge
```

Requires macOS 12 or newer. Universal — Apple silicon and Intel.

---

## 新增与改进

- 将应用拖到废纸篓即移到废纸篓，将磁盘拖到废纸篓即推出。
- 设置中新增「诊断」页，可一键复制诊断报告，便于反馈问题。
- 点击应用抽屉或弹窗以外的任意位置（含 Dock 栏）即可将其收起；应用抽屉与文件夹弹窗不再同时打开。

## 修复

- macOS 27 上权限引导中的设置路径与系统不符。
- 固定文件夹中的应用更换图标后，文件夹图标仍显示旧图标。
- Parallels Desktop 融合模式下最大化窗口底边持续抖动。

## 安装

**已经装了 0.9.0 或更新的版本？** 什么都不用做——更新会自己找上门，也可以在「设置 → 关于」里点「检查更新…」。辅助功能授权不用重新给。

**新装：** 到[官网](https://tungstenedge.app)下 `.dmg` 拖进「应用程序」，或者：

```bash
brew install --cask tungsten-edge
```

需要 macOS 12 或更新版本。通用架构——Apple 芯片与 Intel 都可以。
