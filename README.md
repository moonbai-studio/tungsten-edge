<div align="center">

<img src="assets/icon.png" width="128" alt="Tungsten Edge 钨极" />

# Tungsten Edge 钨极

**A window-oriented bottom taskbar for macOS — a replacement for the system Dock.**

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
3. **First launch needs a right-click:** in Applications, **right-click (or Control-click) Tungsten Edge → Open**, then click **Open** again in the dialog.
   - Why: this is an early build that is not yet Apple notarized, so macOS blocks it by default. Right-click → Open is the system's one-time way to allow it; after that, double-click works normally.
4. Grant Accessibility permission when prompted (**System Settings → Privacy & Security → Accessibility**).

### Option 2 — Homebrew (for technical users)

```bash
brew tap moonbai-studio/tungsten-edge
brew install --cask tungsten-edge
```

> If Homebrew warns that the third-party tap is "untrusted", run the `brew trust ...` command it prints once to continue. If the first launch is blocked by macOS, use right-click → Open as above.

## Recommended setup (align the minimize animation to the bottom)

If your native Dock lives on the **side or top** of the screen, minimizing a window flies the animation toward the native Dock — out of sync with this bottom taskbar. Move the native Dock back to the **bottom** and set it to auto-hide; the minimize animation will then shrink toward the bottom, matching Tungsten Edge:

- **System Settings → Desktop & Dock → Position on screen → Bottom**, and turn on **Automatically hide and show the Dock**.

## Roadmap

This is an early public build (v0.1). Known limitations and what's next:

- **Not yet signed/notarized** → first launch needs right-click → Open (above). A signed build is planned.
- **Chinese-only UI** → localization is on the roadmap; the README is bilingual in the meantime.
- Feedback and issues are very welcome.

---

## Developers

The authoritative record of engineering hand-off, design decisions, and current status lives in [`AGENTS.md`](AGENTS.md) and the author's Obsidian vault. Files under `Docs/` are dated historical findings and platform-quirk references (not a live status board).

Build & run:

```bash
./Scripts/build_and_run.sh
```
</content>
