# Tungsten Edge 钨极 · v0.3.1

**Menu bar icon polish release.** This patch updates the Tungsten Edge menu bar icon so the app reads more cleanly in the macOS status area while keeping the v0.3.0 behavior unchanged.

## What changed

- **Updated menu bar icon** — refreshed the template PDF used by the macOS status item.
- **No behavior changes** — window handling, edge wake, drawer behavior, and settings remain the same as v0.3.0.

## Requirements

- macOS 12.0 (Monterey) or later
- Intel and Apple Silicon (universal binary)
- Accessibility permission is required to read and manage windows.

## Install

1. Download `Tungsten-Edge-0.3.1.dmg` or `Tungsten-Edge-0.3.1.zip`.
2. Open the `.dmg` and drag **Tungsten Edge** into Applications, or unzip the `.zip` and move the app manually.
3. **First launch:** because this is still an unsigned / unnotarized early build, macOS may block it once. Right-click -> Open on macOS 14 and earlier, or use System Settings -> Privacy & Security -> Open Anyway on macOS 15 and later.
4. Grant **System Settings -> Privacy & Security -> Accessibility**.

## Known limitations

- Not signed / notarized yet, so first launch still needs the macOS allow step.
- The UI is currently Chinese only.
- A small residual cross-app activation flash can still happen in some macOS WindowServer transitions. The window target and focus are correct; this is accepted for this early build.

---

# 中文

## 改了什么

这一版是 **菜单栏图标打磨版**。它只更新钨极在 macOS 菜单栏里的模板图标，让状态栏里的品牌识别更清晰；v0.3.0 的功能行为保持不变。

- **更新菜单栏图标**：替换 macOS 状态栏使用的模板 PDF 图标。
- **无行为变化**：窗口处理、底边唤醒、抽屉行为和设置项都与 v0.3.0 保持一致。

## 系统要求

- macOS 12.0 (Monterey) 及以上
- Intel 与 Apple 芯片均可（通用二进制）
- 需要辅助功能权限来读取和管理窗口。

## 安装

1. 下载 `Tungsten-Edge-0.3.1.dmg` 或 `Tungsten-Edge-0.3.1.zip`。
2. 打开 `.dmg` 后把 **Tungsten Edge** 拖进「应用程序」，或解压 `.zip` 后手动移动 app。
3. **首次打开**：因为这仍然是未签名 / 未公证的早期版本，macOS 可能会拦截一次。macOS 14 及更早版本请右键 -> 打开；macOS 15 及更新版本请到「系统设置 -> 隐私与安全性」里点「仍要打开」。
4. 在「系统设置 -> 隐私与安全性 -> 辅助功能」里给 Tungsten Edge 打开权限。

## 已知限制

- 还没有签名 / 公证，首次打开仍需要 macOS 放行步骤。
- 界面目前仍是中文。
- 少数跨 App 切换场景仍可能出现一下 macOS WindowServer 造成的残留闪动；窗口目标和焦点是正确的，本早期版本接受这个限制。
