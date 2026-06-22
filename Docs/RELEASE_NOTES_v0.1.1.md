# Tungsten Edge 钨极 · v0.1.1

Compatibility release: **now runs on macOS 12 (Monterey) and later** (was 14+). Same features as v0.1.0.

## 🔧 What changed

- **Lowered the minimum macOS from 14.0 (Sonoma) to 12.0 (Monterey).** Replaced the macOS-14-only SwiftUI APIs (`defaultScrollAnchor`, the two-parameter `onChange`) and macOS-13-only `Task.sleep(for:)` with back-compatible equivalents. No feature or behavior change intended.

> If you're on macOS 14+, there's no functional difference from v0.1.0 — you only need this if you (or your users) are on Monterey/Ventura.

## 💻 Requirements

- macOS 12.0 (Monterey) or later
- Intel and Apple Silicon (universal binary)

## 📦 Install

1. Download `Tungsten-Edge-0.1.1.dmg`, open it, drag **Tungsten Edge** into Applications.
2. **First launch:** right-click (Control-click) → **Open** → Open again (it's not yet notarized).
3. Grant **System Settings → Privacy & Security → Accessibility**.

## ⚠️ Known limitations

- Not signed/notarized → first launch needs right-click → Open.
- Chinese-only UI for now; localization is on the roadmap.
- The macOS 12 build is compile-verified but not yet hardware-tested on every old OS — feedback from Monterey/Ventura users especially welcome.

---

# 中文

兼容性更新：**现在支持 macOS 12 (Monterey) 及以上**（原先要求 14+）。功能与 v0.1.0 相同。

## 🔧 改了什么

- **把最低系统从 macOS 14 (Sonoma) 降到 12 (Monterey)。** 把几处只有 macOS 14 才有的 SwiftUI 功能（`defaultScrollAnchor`、新版 `onChange`）和 macOS 13 才有的 `Task.sleep(for:)` 换成了老系统也支持的等价写法。功能和行为不变。

> 如果你已经是 macOS 14 以上，这版和 v0.1.0 没有功能差别——只有你（或你的用户）在 Monterey/Ventura 上才需要它。

## 💻 系统要求

- macOS 12.0 (Monterey) 及以上
- Intel 与 Apple 芯片均可（通用二进制）

## 📦 安装

1. 下载 `Tungsten-Edge-0.1.1.dmg`，打开后把 **Tungsten Edge** 拖进「应用程序」。
2. **首次打开请右键**：右键（或 Control+点击）→ **打开** → 再点一次「打开」。
3. 按提示在「系统设置 → 隐私与安全性 → 辅助功能」给它打开开关。

## ⚠️ 已知限制

- 未签名公证 → 首次打开需「右键 → 打开」。
- 界面暂为纯中文，多语言在计划内。
- macOS 12 版本已通过编译验证，但还没在每个旧系统上实机测过——尤其欢迎 Monterey/Ventura 用户反馈。
</content>
