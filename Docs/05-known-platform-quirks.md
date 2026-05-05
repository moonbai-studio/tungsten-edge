# Known Platform Quirks

- `CGWindowID` 在最小化后会从默认窗口列表里消失。
- Accessibility 通知在某些应用中不可靠，尤其微信、飞书。
- Finder 进程长期存在，不等价于“有 Finder 窗口”。
- Finder 具体窗口名可通过 `CG` / `AX` / AppleScript 取得；如果 UI 只显示 `访达`，优先怀疑当前观察链路丢了窗口级信息。
- Finder 激活不能轻易退回到 app-level activate，否则可能带出错误窗口或多个窗口。
- 某些 app 创建窗口时标题先为空，稍后才填入真实标题。
- `CG` 的 `disappeared` 事件会带着旧 `cgWindowID` 回流；验收逻辑不能把这类事件当成“当前仍可见窗口”。
- 当前采样里，飞书可能出现 `CG` 可见但标题为空、同时 `AXWindows` 为空的时刻。
