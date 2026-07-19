<div align="center">

<img src="assets/icon.png" width="128" alt="Tungsten Edge" />

# Tungsten Edge

**A per-window taskbar for macOS — switch to any window in one click, Windows-style clarity without the clutter.**

English · [中文](README.zh-CN.md)

</div>

---

## Demo

**Multi-window management**

<img src="assets/multi-window.gif" alt="Multi-window management" width="100%" />

<table>
  <tr>
    <td align="center"><b>App drawer &amp; launcher</b></td>
    <td align="center"><b>Drag to organize</b></td>
  </tr>
  <tr>
    <td><img src="assets/launcher.gif" alt="App drawer &amp; launcher" /></td>
    <td><img src="assets/drag-reorder.gif" alt="Drag to organize" /></td>
  </tr>
</table>

---

## What it is

Tungsten Edge puts a **per-window taskbar** at the bottom of your screen. Every open window gets its own card — just like a Windows taskbar — so you can switch directly to any window with a single click. No more hunting through stacked windows, no Mission Control, no extra gestures.

Unlike a plain Windows-style task switcher, single-window apps stay collapsed as compact icons, so the strip never gets cluttered. Multi-window apps (four Finder folders, multiple browser windows) expand into individual labeled cards. The result: the compactness of the macOS Dock combined with the per-window clarity of a Windows taskbar — without inheriting its problems.

## Features

- **Window-level taskbar** — one card per window; multi-window apps split into multiple cards; click to switch / minimize.
- **Smart native-tab merging** — apps where "tabs are windows" (Ghostty, Finder) keep a stable card while you switch tabs: it won't jump around or split.
- **Pinned messaging apps + badges** — messaging apps (WeChat, Feishu, …) get a persistent pinned entry and mirror the Dock's red unread badge.
- **App drawer** — stash rarely-used apps into a drawer on the right to keep the strip clean; pin favorites in the drawer to use it as a launcher.
- **Drag to organize** — reorder cards by dragging; drag a card into the drawer to stash it; drag it back out and it lands exactly where you drop it.
- **Menu bar controls** — the status menu controls launch at login, native Dock visibility, and Tungsten Edge wake timing.
- **Edge auto-hide** — Tungsten Edge can hide itself and wake from the bottom edge after the delay you choose; moving away hides it again after about 0.2s.
- **Frosted-glass look** — native-grade translucency that blends into the desktop.
- **Multi-display follow** — resting the pointer on another screen's bottom edge moves the taskbar there automatically.

> **Note:** the app's interface is currently **Chinese only**. An English/localized UI is planned but not yet available — see [Roadmap](#roadmap).

## Requirements

- macOS 12.0 (Monterey) or later
- Intel and Apple Silicon (universal binary)
- On first launch you'll be asked to grant **Accessibility** permission (used to read and manage windows; the app guides you through it).

## Install

### Option 1 — download the installer (recommended)

1. Download the latest `.dmg` from [Releases](../../releases).
2. Open it and drag **Tungsten Edge** into your **Applications** folder.
3. Launch Tungsten Edge from **Applications** and grant Accessibility permission when prompted. Do not run the temporary copy inside the DMG.

### Option 2 — Homebrew (for technical users)

```bash
brew tap moonbai-studio/tungsten-edge
brew trust moonbai-studio/tungsten-edge
brew install --cask tungsten-edge
```

> The `brew trust` step is required for any third-party tap.

## First launch and Accessibility permission

Starting with v0.6.6, public packages are signed with Developer ID and notarized by Apple. After moving the app into Applications, it opens normally without right-clicking or using Open Anyway.

Tungsten Edge needs Accessibility permission to read and manage windows. On first launch it opens **System Settings → Privacy & Security → Accessibility**:

On macOS 12 Monterey, the same pane is under **System Preferences → Security & Privacy → Privacy → Accessibility**.

1. Find **Tungsten Edge** and turn on its switch.
2. The onboarding window closes automatically and the taskbar finishes starting.
3. If the app is running from a DMG or App Translocation path, onboarding first asks you to move it into Applications and relaunch, avoiding permission for a temporary copy.

### Upgrading from v0.6.5 or earlier

Earlier public builds used ad-hoc signatures. After an upgrade, the old switch may still look enabled even though macOS has not granted the current build access. The first move to the Developer ID-signed v0.6.6 requires one final permission reset:

1. Quit every Tungsten Edge copy, eject the DMG, and keep only `/Applications/Tungsten Edge.app`.
2. Select the old Tungsten Edge entry in Accessibility settings and remove it with the minus button; toggling the old switch is not enough.
3. Relaunch from Applications and enable the newly registered entry.

If permission still does not take effect, reset this app's Accessibility record and try again:

```bash
tccutil reset Accessibility com.caye.macosdockcc.v2
```

If a clean reauthorization still fails, include the actual app launch path, any duplicate copies, macOS version, Mac architecture, and recent `tccd` log lines in the bug report. Avoid posting unrelated private paths publicly.

After this one-time identity migration, later releases signed by the same Developer ID retain the permission.

## Status menu

Tungsten Edge lives in the macOS menu bar. Its menu currently includes:

- **Launch at login** — available on macOS 13 and later. If macOS asks for approval, open Login Items in System Settings and approve Tungsten Edge there.
- **隐藏/显示系统 Dock** — a dynamic command that follows the native Dock's real auto-hide state. Clicking it changes only visibility and restarts Dock; it does not overwrite the system's wake delay. The `⌥⌘D` shown on the right is macOS's own shortcut.
- **隐藏/显示 Tungsten Edge 钨极** — switches between always visible and your last auto-hide wake delay. The compact slider immediately below it controls the wake delay: `常驻`, `0.1s`–`3.0s`, or `不唤醒`. When the status menu is closed, the global `⌥⌘E` shortcut performs the same switch; if registration fails, the menu hides its key hint but the command remains clickable. Tungsten Edge claims `⌥⌘E` exclusively while running, shadowing Safari's Develop → Empty Caches and Finder's File → Eject All shortcuts; the owner accepts these low-frequency conflicts for the memorable default.
- **检查更新…** — manually checks the latest stable GitHub release. When an update is available, Tungsten Edge opens that release page for you to download and install it.

The native Dock setting requires a non-sandboxed build because macOS sandboxed apps cannot directly write the system Dock preferences or restart Dock.

## Recommended setup (align the minimize animation to the bottom)

If your native Dock lives on the **side or top** of the screen, minimizing a window flies the animation toward the native Dock — out of sync with this bottom taskbar. Move the native Dock back to the **bottom** and set it to auto-hide; the minimize animation will then shrink toward the bottom, matching Tungsten Edge:

- **System Settings → Desktop & Dock → Position on screen → Bottom**, and turn on **Automatically hide and show the Dock**.

Use System Settings for the native Dock's own wake behavior; Tungsten Edge's status menu only hides or shows it.

## Roadmap

Known limitations and what's next:

- **Chinese-only UI** → localization is on the roadmap. A Chinese version of this README is available at [README.zh-CN.md](README.zh-CN.md).
- Feedback and issues are very welcome.

---

## Developers

Engineering guardrails live in [`AGENTS.md`](AGENTS.md); product state, roadmap, and decisions live in the author's Obsidian vault. `Docs/` keeps only active platform/focus references at the root, with historical notes under `Docs/Archive/`.

Build & run:

```bash
./Scripts/build_and_run.sh
```
</content>
