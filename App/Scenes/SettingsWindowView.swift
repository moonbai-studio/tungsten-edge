import AppKit
import SwiftUI

struct SettingsWindowView: View {
    static let contentWidth: CGFloat = 560

    @ObservedObject var store: AppSettingsStore
    @ObservedObject var coordinator: SettingsCoordinator

    var body: some View {
        ScrollView(.vertical) {
            SettingsWindowContent(store: store, coordinator: coordinator)
        }
        .frame(width: Self.contentWidth)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 用户去系统设置勾完登录项再切回来，状态得跟着变。
            Task { @MainActor in
                _ = await coordinator.refreshLaunchAtLoginState()
            }
        }
    }
}

struct SettingsWindowContent: View {
    @ObservedObject var store: AppSettingsStore
    @ObservedObject var coordinator: SettingsCoordinator

    @State private var presentedAlert: SettingsAlert?
    @State private var subscriptionEmail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsSection("通用") {
                launchAtLoginRow

                Picker("外观", selection: binding(get: { store.appearanceMode }, set: store.setAppearanceMode)) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            settingsSection("任务条") {
                settingRow(note: "任务条上多一个临时存放文件的格子。拖进去的文件不会被移动或复制，只是记住位置。") {
                    Toggle("显示中转站", isOn: binding(get: { store.showShelf }, set: store.setShowShelf))
                }

                settingRow(note: "关闭后，鼠标划过任务条不再有放大和名称提示。") {
                    Toggle(
                        "鼠标悬停显示应用名",
                        isOn: binding(get: { store.hoverStyle.isExpressive }) {
                            store.setHoverStyle($0 ? .standard : .quiet)
                        }
                    )
                }

                settingRow(note: "把铺满屏幕的窗口底边抬到任务条上方。这会改动其他应用的窗口尺寸，所以默认关闭。") {
                    Toggle(
                        "最大化窗口避开任务条",
                        isOn: binding(get: { store.windowLiftEnabled }, set: store.setWindowLiftEnabled)
                    )
                }

                settingRow(note: "关闭后，访达不再常驻任务条：没有打开任何访达窗口时，它会和普通应用一样从任务条上消失。\n点击无窗口的访达卡打开个人文件夹的行为也会一并取消。") {
                    Toggle(
                        "任务条常驻访达",
                        isOn: binding(get: { store.finderAlwaysInDock }, set: store.setFinderAlwaysInDock)
                    )
                }

                Picker("任务条大小", selection: binding(get: { store.dockSize }, set: store.setDockSize)) {
                    ForEach(DockSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            // 「高级」= 需要额外能力、默认就对、基本不用碰的开关。放这里不是为了藏，
            // 而是让主设置面只留日常会调的东西；真想拒绝这个能力的人找得到（owner 2026-08-09）。
            settingsSection("高级") {
                settingRow(
                    note: "为了不让任务条在切进全屏时闪一下，钨极需要在你的输入送到应用之前先把它藏起来。"
                        + "因此会监听全局的鼠标左键按下、键盘按下和触控板手势，只识别窗口绿灯、"
                        + "Control-Command-F、Control-左右方向键和三指水平滑动这四种；"
                        + "不记录输入内容，也不写日志、不发送到任何地方。关闭后这些监听会被完全停用。"
                ) {
                    Toggle(
                        "预测全屏切换，消除任务条闪烁",
                        isOn: binding(
                            get: { store.fullscreenIntentEnabled },
                            set: store.setFullscreenIntentEnabled
                        )
                    )
                }
            }

            Divider()

            settingsSection("关于") {
                aboutRow
                subscriptionRow
            }
        }
        .padding(28)
        .frame(width: SettingsWindowView.contentWidth, alignment: .leading)
        .alert(item: $presentedAlert) { alert in
            guard let openButtonTitle = alert.openButtonTitle, let openURL = alert.openURL else {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("好"))
                )
            }
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text(openButtonTitle)) { NSWorkspace.shared.open(openURL) },
                secondaryButton: .cancel(Text("稍后"))
            )
        }
    }

    @ViewBuilder
    private var launchAtLoginRow: some View {
        // 状态恒来自 `LaunchAtLoginService`，不读 `AppSettingsStore` 的镜像——
        // 用户随时可能在系统设置里改掉它。
        let presentation = LaunchAtLoginMenuPresentation(state: coordinator.launchAtLoginState)
        Toggle(
            presentation.title,
            isOn: Binding(
                get: { presentation.isChecked },
                // 走和菜单同一个纯决策，别让两处对四态各有一套理解。
                set: { _ in
                    guard let enable = LaunchAtLoginMenuModel.requestedEnabledValue(
                        afterSelecting: coordinator.launchAtLoginState
                    ) else { return }
                    if case .failure(let error) = coordinator.setLaunchAtLogin(enable) {
                        presentedAlert = SettingsAlert(
                            title: "登录时启动设置失败",
                            message: error.localizedDescription
                        )
                    }
                }
            )
        )
        .disabled(!presentation.isEnabled)

        if presentation.showsSettingsItem {
            Button {
                coordinator.openLoginItemsSettings()
            } label: {
                Label("打开登录项设置…", systemImage: "arrow.up.forward.app")
            }
        }
    }

    @ViewBuilder
    private var aboutRow: some View {
        let updatePresentation = coordinator.updateCheckState.presentation
        HStack(spacing: 12) {
            if let versionTitle = coordinator.versionTitle {
                Text(versionTitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(updatePresentation.title) {
                // 在飞守卫在共享层：菜单里那条「检查更新」用的是同一个。
                guard coordinator.beginUpdateCheck() else { return }
                Task {
                    let content = await coordinator.performUpdateCheck()
                    coordinator.finishUpdateCheck()
                    presentedAlert = SettingsAlert(content)
                }
            }
            .disabled(!updatePresentation.isEnabled)
        }
    }

    /// 「原始用户，永久免费」的留邮箱入口。
    ///
    /// ⚠️ 标题和正文与官网 tungstenedge.app 的订阅区**逐字同源**（owner 逐句敲定的公开承诺），
    /// 不要在这里"改得更适合 App"——两处说法一旦分叉，将来兑现承诺时就会有人拿着不同的
    /// 版本来对质。
    ///
    /// ⚠️ 结果一律走 `SettingsAlert`，**不要**改成在区块里就地长出成功/失败文案：
    /// `SettingsWindowController.resizeToFitKeepingTopEdge()` 只在 `present()` 和
    /// `launchAtLoginState` 变化时重新量高度，就地加一行不会让窗口跟着变高，只会变成可滚动。
    @ViewBuilder
    private var subscriptionRow: some View {
        Divider()
            .padding(.vertical, 2)

        if store.hasSubscribed {
            // 已经留过的人不该被同一段话反复看见。这只是本机的显示状态，
            // 不是「是否原始用户」的凭据。
            Text("已订阅。将来的授权会直接发送到你的邮箱。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("原始用户，永久免费")
                    .font(.callout.weight(.medium))
                Text("请留下邮箱地址，届时授权将直接发送给你，更换设备或重装系统均不会丢失。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                let presentation = coordinator.subscriptionState.presentation
                HStack(spacing: 10) {
                    TextField("you@example.com", text: $subscriptionEmail)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!presentation.isEnabled)
                        .onSubmit { submitSubscription() }
                    Button(presentation.title) { submitSubscription() }
                        .disabled(!presentation.isEnabled || subscriptionEmail.isEmpty)
                }

                // ⚠️ 上报首装日期这件事必须写在界面上。一个常驻工具偷偷上报安装日期
                // 被人发现，损失远大于这份名单的价值。
                Text("只发送邮箱地址与首次安装日期，用于确认你的原始用户身份。不发送营销邮件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submitSubscription() {
        // 在飞守卫在共享层，和检查更新同一套路。
        guard coordinator.beginSubscription() else { return }
        let email = subscriptionEmail
        Task {
            let content = await coordinator.performSubscription(email: email)
            coordinator.finishSubscription()
            if content.didSubscribe { subscriptionEmail = "" }
            presentedAlert = SettingsAlert(content)
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 开关 + 一行灰色说明。说明是给「不知道这个开关在干嘛」的人看的，
    /// 菜单里塞不下，设置窗口有的是地方。
    private func settingRow<Content: View>(
        note: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding<Value>(
        get: @escaping () -> Value,
        set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: set)
    }
}

private struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let openButtonTitle: String?
    let openURL: URL?

    init(title: String, message: String, openButtonTitle: String? = nil, openURL: URL? = nil) {
        self.title = title
        self.message = message
        self.openButtonTitle = openButtonTitle
        self.openURL = openURL
    }

    init(_ content: UpdateCheckAlertContent) {
        self.init(
            title: content.title,
            message: content.message,
            openButtonTitle: content.openButtonTitle,
            openURL: content.openURL
        )
    }

    init(_ content: SubscriptionAlertContent) {
        self.init(title: content.title, message: content.message)
    }
}
