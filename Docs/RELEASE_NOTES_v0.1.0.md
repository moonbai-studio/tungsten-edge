# Tungsten Edge 钨极 · v0.1.0

The first public early-access build. A window-oriented bottom taskbar for macOS that replaces the system Dock.

> **Note:** the app UI is currently **Chinese only**; an English/localized UI is planned. The README is available in [English](https://github.com/moonbai-studio/tungsten-edge/blob/master/README.md) and [中文](https://github.com/moonbai-studio/tungsten-edge/blob/master/README.zh-CN.md).

## ✨ Highlights

- **Window-level taskbar** — one card per window; multi-window apps split into multiple cards; click to switch, click again to minimize.
- **Smart native-tab merging** — Ghostty / Finder tab groups keep a stable card across tab switches and minimize.
- **Pinned messaging apps + unread badges** mirroring the Dock.
- **App drawer** — stash rarely-used apps; pin favorites as a launcher.
- **Drag to organize** — reorder, stash into the drawer, and drag back to a precise spot.
- **Frosted-glass look + multi-display follow.**

## 💻 Requirements

- macOS 14.0 (Sonoma) or later
- Intel and Apple Silicon (universal binary)

## 📦 Install

1. Download `Tungsten-Edge-0.1.0.dmg`, open it, drag **Tungsten Edge** into Applications.
2. **First launch:** right-click (Control-click) → **Open** → Open again (it's not yet notarized).
3. Grant **System Settings → Privacy & Security → Accessibility**.

> The `.zip` is for the Homebrew cask; regular users want the `.dmg`.

## ⚠️ Known limitations

- **Not signed/notarized** → first launch needs right-click → Open. A signed build is planned.
- **Chinese-only UI** for now; localization is on the roadmap.
- The WeChat document-window card may briefly flash as an icon before its title loads.
- Apple **Messages** can't be minimized by clicking its icon yet (other apps are fine).

---

# 中文

第一个公开的早期试用版本。一个以「窗口」为单位的 macOS 底部任务条，用来替代系统程序坞。

> **说明**：app 界面目前为**纯中文**，英文/多语言界面在计划中。README 提供 [English](https://github.com/moonbai-studio/tungsten-edge/blob/master/README.md) 和 [中文](https://github.com/moonbai-studio/tungsten-edge/blob/master/README.zh-CN.md) 两版。

## ✨ 亮点

- **窗口级任务条**：每个打开的窗口一张卡片，点一下切到那个窗口、再点最小化。多窗口应用拆成多张卡片，开了什么一眼看清。
- **原生标签智能合并**：Ghostty、访达这类「标签即窗口」的应用，切标签时卡片不乱跳、不分裂；最小化也不丢卡。
- **消息应用常驻 + 红圈角标**（镜像系统 Dock）。
- **应用抽屉**：不常用的应用收进抽屉，还能固定常用应用当启动器。
- **拖拽整理**：拖动排序、拖进抽屉收纳、从抽屉拖回任务条并落在松手的精确位置。
- **磨砂玻璃质感 + 多屏跟随**。

## 💻 系统要求

- macOS 14.0 (Sonoma) 及以上
- Intel 与 Apple 芯片均可（通用二进制）

## 📦 安装

1. 下载 `Tungsten-Edge-0.1.0.dmg`，打开后把 **Tungsten Edge** 拖进「应用程序」。
2. **首次打开请右键**：在「应用程序」里右键（或 Control+点击）→ **打开** → 再点一次「打开」。
3. 按提示在「系统设置 → 隐私与安全性 → 辅助功能」给它打开开关。

> `.zip` 为 Homebrew cask 使用，普通用户用 `.dmg` 即可。

## ⚠️ 已知限制

- **未签名公证**：早期版本，首次打开需「右键 → 打开」放行。后续会发签名版。
- 界面**暂为纯中文**，多语言在计划内。
- **微信文档窗口** 的卡片刚出现时偶发闪一下（短暂显示为图标、随后补上标题）。
- 苹果「**信息**」app 暂时无法通过点击图标最小化（其它应用正常）。
</content>
