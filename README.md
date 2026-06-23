<div align="center">

<img src="assets/icon.png" width="128" alt="Tungsten Edge" />

# Tungsten Edge

**The ultra-lightweight, unprecedented ultimate window management solution for macOS.**

English · [中文](README.zh-CN.md)

</div>

---

## What it is

The macOS Dock is organized by **app**: one icon per app, no matter how many windows it has open. To switch to a specific window you first click the app, then hunt through its window list.

**Tungsten Edge organizes the taskbar by _window_ instead.** Every open window gets its own card at the bottom of the screen — click it to jump straight to that window, click again to minimize. Multi-window apps split into multiple cards, so you can see at a glance exactly what you have open and what each one is.

## Features

- **Window-level taskbar** — one card per window; multi-window apps split into multiple cards; click to switch / minimize.
- **Smart native-tab merging** — apps where "tabs are windows" (Ghostty, Finder) keep a stable card while you switch tabs: it won't jump around or split.
- **Pinned messaging apps + badges** — messaging apps (WeChat, Feishu, …) get a persistent pinned entry and mirror the Dock's red unread badge.
- **App drawer** — stash rarely-used apps into a drawer on the right to keep the strip clean; pin favorites in the drawer to use it as a launcher.
- **Drag to organize** — reorder cards by dragging; drag a card into the drawer to stash it; drag it back out and it lands exactly where you drop it.
- **Frosted-glass look** — native-grade translucency that blends into the desktop.
- **Multi-display follow** — the taskbar follows your cursor to whichever screen it's on.

> **Note:** the app's interface is currently **Chinese only**. An English/localized UI is planned but not yet available — see [Roadmap](#roadmap).

## Requirements

- macOS 12.0 (Monterey) or later
- Intel and Apple Silicon (universal binary)
- On first launch you'll be asked to grant **Accessibility** permission (used to read and manage windows; the app guides you through it).

## Install

### Option 1 — download the installer (recommended)

1. Download the latest `.dmg` from [Releases](../../releases).
2. Open it and drag **Tungsten Edge** into your **Applications** folder.
3. **First launch needs to be allowed once** (this is an early, unsigned build, so macOS blocks it by default — it's not malware) — follow [First launch](#first-launch) below, then grant Accessibility permission.

### Option 2 — Homebrew (for technical users)

```bash
brew tap moonbai-studio/tungsten-edge
brew trust moonbai-studio/tungsten-edge
brew install --cask tungsten-edge
```

> The `brew trust` step is required for any third-party tap. If the first launch is blocked by macOS, allow it as described in [First launch](#first-launch) below.

## First launch

Because this is an early build that isn't Apple-notarized yet, macOS blocks it the first time with a message like "cannot be opened because it is from an unidentified developer". **This isn't malware — it's macOS's default block for any unsigned app.** Allow it once and double-clicking works normally afterward. Pick the method for your macOS version:

### Method A — right-click to open (macOS 14 and earlier)

1. Open your **Applications** folder and find **Tungsten Edge**.
2. **Right-click its icon** (or Control-click it) and choose **Open** from the menu.
3. The dialog this time has an extra **Open** button — click it.
4. Done. Double-click works from now on.

> The trick is to go through **right-click → Open**, not a plain double-click — a plain double-click only gets blocked, with no allow button.

### Method B — allow it in System Settings (macOS 15 Sequoia and newer)

Newer macOS removed right-click-to-open, so do this instead:

1. **Double-click** Tungsten Edge once; when it's blocked, **click "Done"** to dismiss the prompt (this lets the system record the attempt).
2. Open **System Settings → Privacy & Security** and scroll down to the **Security** section.
3. You'll see a line saying "Tungsten Edge was blocked…" with an **"Open Anyway"** button next to it — click it.
4. Confirm once more (you may need your login password or Touch ID). Done — double-click works from now on.

### One more step after opening: grant Accessibility permission

Tungsten Edge needs **Accessibility** permission to read and manage your windows; it guides you through this on first run:

- Open **System Settings → Privacy & Security → Accessibility**, find **Tungsten Edge**, and **turn on its switch**.

## Recommended setup (align the minimize animation to the bottom)

If your native Dock lives on the **side or top** of the screen, minimizing a window flies the animation toward the native Dock — out of sync with this bottom taskbar. Move the native Dock back to the **bottom** and set it to auto-hide; the minimize animation will then shrink toward the bottom, matching Tungsten Edge:

- **System Settings → Desktop & Dock → Position on screen → Bottom**, and turn on **Automatically hide and show the Dock**.

## Roadmap

This is an early public build (v0.1). Known limitations and what's next:

- **Not yet signed/notarized** → first launch needs right-click → Open (above). A signed build is planned.
- **Chinese-only UI** → localization is on the roadmap. A Chinese version of this README is available at [README.zh-CN.md](README.zh-CN.md).
- Feedback and issues are very welcome.

---

## Developers

The authoritative record of engineering hand-off, design decisions, and current status lives in [`AGENTS.md`](AGENTS.md) and the author's Obsidian vault. Files under `Docs/` are dated historical findings and platform-quirk references (not a live status board).

Build & run:

```bash
./Scripts/build_and_run.sh
```
</content>
