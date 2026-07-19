# Tungsten Edge v0.6.6-beta.1

> 公开试用预发布版。它使用稳定的自签名证书，不是 Developer ID，也没有经过 Apple 公证。

## 本次修复

- 修复辅助功能开关看似已开启、当前应用却仍无法启动的问题。
- 从 DMG 或 App Translocation 临时路径运行时，不再注册错误副本的辅助功能权限。
- 等待授权 8 秒仍未生效时，会明确提示删除旧条目并重新添加当前副本。
- 同一张预览证书签出的后续 beta 不再使用随构建变化的 CDHash 身份。

## 安装与首次打开

1. 建议下载 ZIP，解压后把 Tungsten Edge 拖入「应用程序」。
2. 也可以使用 DMG；若 DMG 自身被拦截，先对 DMG 执行下一步的 Gatekeeper 放行，再把 App 拖入「应用程序」。不要直接运行 DMG 内的副本。
3. macOS 14 及更早版本：在被拦截的 DMG 或「应用程序」中的 Tungsten Edge 上右键，选择「打开」。
4. macOS 15 及更新版本：先尝试打开被拦截的 DMG 或 App，再到「系统设置 → 隐私与安全性」点击「仍要打开」。DMG 和复制后的 App 若分别提示，需要分别放行。
5. 进入「辅助功能」后打开 Tungsten Edge 的开关，应用会自动继续启动。

从 v0.6.5 升级时，请先在辅助功能列表中用减号删除旧条目，再给 `/Applications/Tungsten Edge.app` 重新授权。只关闭再打开旧开关通常无效。

## 试用版边界

- Gatekeeper 会显示未识别开发者警告，这是因为试用包没有 Developer ID；不要对来源不明的同名 App 使用「仍要打开」。
- 本预发布不更新 Homebrew，也不标记为正式稳定版。
- 未来迁移到 Developer ID 正式版时，代码身份会再次变化，因此需要最后重新授权一次辅助功能权限。

## SHA256

```text
1d3580bcfcde8434b0c5f9b77af21144c6b967e1d9f14105ae2a11c283ebbd7b  Tungsten-Edge-0.6.6-beta.1.dmg
ed1a492d31f00777018543b65eea82f634b036e494dd6a460f38ea42381de494  Tungsten-Edge-0.6.6-beta.1.zip
```

预览签名证书 requirement 哈希：`520de050f4ea495c166ec7b3447b327bf88a55df`。

---

> Public testing pre-release. It uses a stable self-signed certificate and is not Developer ID signed or Apple-notarized.

## Fixes

- Adds recovery guidance when Accessibility appears enabled but the current app identity is still rejected.
- Prevents DMG and App Translocation copies from registering temporary Accessibility entries.
- Shows stale-entry recovery steps after eight seconds without a valid grant.
- Later beta builds signed by the same preview certificate no longer use build-specific CDHash identities.

## Installation

The ZIP is the recommended download: extract it and move the app into Applications before launching. If you use the DMG and Gatekeeper blocks the disk image itself, allow the DMG first; the copied App may require a separate approval. Use Right-click → Open on macOS 14 and earlier, or Privacy & Security → Open Anyway on newer macOS. Upgrading from v0.6.5 requires removing the old Accessibility entry with the minus button and granting `/Applications/Tungsten Edge.app` again.

This pre-release is not distributed through Homebrew. Moving to the future Developer ID build changes code identity once more and requires one final Accessibility reauthorization.
