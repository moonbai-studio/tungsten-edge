# Tungsten Edge v0.6.6 - Release preparation

> Do not publish these artifacts until Developer ID signing, notarization, stapling, and Gatekeeper validation all pass.
> This document covers the final v0.6.6 release, not the separately labeled self-signed beta.

## What changed

- Fixed an upgrade failure where Accessibility settings could show Tungsten Edge as enabled while macOS still rejected the current app identity.
- Added a recovery state that explains how to remove an obsolete Accessibility entry and register the copy in Applications.
- Prevented temporary DMG and App Translocation copies from requesting Accessibility permission.
- Replaced public ad-hoc packaging with a fail-closed Developer ID signing and notarization pipeline.

## Upgrade note

v0.6.5 and earlier public builds used ad-hoc signatures. The first upgrade to v0.6.6 therefore requires one final Accessibility reauthorization: remove the old Tungsten Edge entry with the minus button, relaunch `/Applications/Tungsten Edge.app`, and enable the new entry. Later releases signed by the same Developer ID retain permission.

---

# 中文

> Developer ID 签名、公证、装订票据和 Gatekeeper 验证全部通过前，不得发布本版本产物。
> 本文描述正式 v0.6.6，不适用于单独标记的自签名 beta 试用包。

## 改了什么

- 修复升级后“辅助功能开关已经打开，但 macOS 仍拒绝当前应用身份”的启动卡死问题。
- 权限引导新增旧条目恢复状态，明确要求删除失效条目并给「应用程序」中的当前副本重新授权。
- 从 DMG 或 App Translocation 临时路径运行时不再请求辅助功能权限。
- 公开打包链改为 Developer ID 签名与 Apple 公证，任何凭据或验证缺失都会直接停止，不再回退到临时签名。

## 升级说明

v0.6.5 及更早公开包使用临时签名，因此第一次升级到 v0.6.6 时需要最后重新授权一次：在辅助功能列表中用减号删除旧 Tungsten Edge，从 `/Applications/Tungsten Edge.app` 重新启动，再打开新条目的开关。以后使用同一 Developer ID 的版本会保持授权。
