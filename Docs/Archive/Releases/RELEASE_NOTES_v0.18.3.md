## Fixed

- Taskbar icons did not update after an app’s icon was changed in Finder’s Get Info window.
- Pinned folder icons flickered while being reordered by dragging.
- Shortcut recording in Settings did not end after switching to another app and back, so ⌘W was recorded as the shortcut.
- The window resize pointer stayed on the taskbar after the pointer moved onto it from a window edge.
- Further addressed the app drawer icon looking milky white on some Macs running macOS 26.

## Installing

**Already on 0.9.0 or later?** Do nothing — the update will find you, or use *Check for Updates…* in **Settings → About**. Your Accessibility permission carries over.

**New install:** grab the `.dmg` from the [official website](https://tungstenedge.app) and drag it into Applications, or:

```bash
brew install --cask tungsten-edge
```

Requires macOS 12 or newer. Universal — Apple silicon and Intel.

---

## 修复

- 在访达「显示简介」中更换应用图标后，Dock 栏上的图标不随之更新。
- 拖动排序时固定文件夹图标闪烁。
- 设置中录制快捷键时切换到其他应用再返回，录制未结束、⌘W 被录为快捷键。
- 指针从窗口边缘移入 Dock 栏后，调整窗口大小的光标仍留在 Dock 栏上。
- 进一步改善部分 macOS 26 机器上应用抽屉图标显示为乳白色的问题。

## 安装

**已经装了 0.9.0 或更新的版本？** 什么都不用做——更新会自己找上门，也可以在「设置 → 关于」里点「检查更新…」。辅助功能授权不用重新给。

**新装：** 到[官网](https://tungstenedge.app)下 `.dmg` 拖进「应用程序」，或者：

```bash
brew install --cask tungsten-edge
```

需要 macOS 12 或更新版本。通用架构——Apple 芯片与 Intel 都可以。
