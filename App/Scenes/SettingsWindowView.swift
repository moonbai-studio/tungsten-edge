import AppKit
import SwiftUI

struct SettingsWindowView: View {
    static let contentWidth: CGFloat = 560

    /// 公开仓库主页。**只给「求 Star」用**——用户可见的「去下载」永远指向官网
    /// （2026-08-13 起 GitHub release 页不再附安装包，指过去是个空页面），
    /// 别顺手把下载入口也改到 GitHub 来。
    static let repositoryURL = URL(string: "https://github.com/moonbai-studio/tungsten-edge")!

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
            settingsSection(String(localized: "General")) {
                launchAtLoginRow
            }

            Divider()

            settingsSection(String(localized: "Taskbar")) {
                settingRow(note: String(localized: "Adds a spot on the taskbar for parking files. Dropping a file there doesn’t move or copy it — Tungsten Edge just remembers where it lives.")) {
                    Toggle("Show Shelf", isOn: binding(get: { store.showShelf }, set: store.setShowShelf))
                }

                settingRow(note: String(localized: "When off, moving the pointer across the taskbar no longer shows app names.")) {
                    Toggle(
                        "Show app name on hover",
                        isOn: binding(get: { store.hoverStyle.isExpressive }) {
                            store.setHoverStyle($0 ? .standard : .quiet)
                        }
                    )
                }

                settingRow(note: String(localized: "Lifts the bottom edge of a screen-filling window above the taskbar. This resizes other apps’ windows, so it is off by default.")) {
                    Toggle(
                        "Keep maximized windows above the taskbar",
                        isOn: binding(get: { store.windowLiftEnabled }, set: store.setWindowLiftEnabled)
                    )
                }

                settingRow(note: String(localized: "When off, Finder no longer stays in the taskbar: once every Finder window is closed, it disappears from the taskbar like any other app. Clicking a windowless Finder card to open your home folder is disabled as well.")) {
                    Toggle(
                        "Keep Finder in the taskbar",
                        isOn: binding(get: { store.finderAlwaysInDock }, set: store.setFinderAlwaysInDock)
                    )
                }

                Picker("Taskbar Size", selection: binding(get: { store.dockSize }, set: store.setDockSize)) {
                    ForEach(DockSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            // 「高级」= 需要额外能力、默认就对、基本不用碰的开关。放这里不是为了藏，
            // 而是让主设置面只留日常会调的东西；真想拒绝这个能力的人找得到（owner 2026-08-09）。
            settingsSection(String(localized: "Advanced")) {
                settingRow(
                    note: String(localized: "To keep the taskbar from flashing when you switch into full screen, Tungsten Edge has to hide it before your input reaches the app. It therefore watches global left-clicks, key presses and trackpad gestures, and recognizes only four of them: the window’s green button, Control-Command-F, Control-Left/Right arrow, and a three-finger horizontal swipe. What you type is never recorded, logged, or sent anywhere. Turning this off disables the watching completely.")
                ) {
                    Toggle(
                        "Predict full-screen transitions to prevent taskbar flicker",
                        isOn: binding(
                            get: { store.fullscreenIntentEnabled },
                            set: store.setFullscreenIntentEnabled
                        )
                    )
                }
            }

            Divider()

            settingsSection(String(localized: "About")) {
                aboutRow
                subscriptionRow
                githubStarRow
            }
        }
        .padding(28)
        .frame(width: SettingsWindowView.contentWidth, alignment: .leading)
        .alert(item: $presentedAlert) { alert in
            guard let openButtonTitle = alert.openButtonTitle, let openURL = alert.openURL else {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text(openButtonTitle)) { NSWorkspace.shared.open(openURL) },
                secondaryButton: .cancel(Text("Later"))
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
                            title: String(localized: "Couldn’t Change Open at Login"),
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
                Label("Open Login Items Settings…", systemImage: "arrow.up.forward.app")
            }
        }
    }

    @ViewBuilder
    private var aboutRow: some View {
        HStack(spacing: 12) {
            if let versionTitle = coordinator.versionTitle {
                Text(versionTitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Sparkle 自带结果界面（有新版 / 已是最新 / 查不到），所以这里不再接
            // `SettingsAlert`——原来那条「去官网手动下载」的提示随之删掉了。
            Button("Check for Updates…") {
                coordinator.checkForUpdates()
            }
            .disabled(!coordinator.canCheckForUpdates)
        }

        // 自动检查默认是开的（`SUEnableAutomaticChecks`）。**必须给关的入口**：
        // 一个用户关不掉的后台定期联网检查，比多一个勾选项糟糕得多。
        // 真值在 Sparkle 那边，这里不做镜像。
        Toggle(
            "Check for updates automatically",
            isOn: Binding(
                get: { coordinator.automaticallyChecksForUpdates },
                set: { coordinator.automaticallyChecksForUpdates = $0 }
            )
        )
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
            Text("You’re subscribed. When licensing arrives, it will be sent straight to your inbox.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Founding Users · Free Forever")
                    .font(.callout.weight(.medium))
                Text("Leave your email address and your license will be sent directly to you. It survives switching devices or reinstalling macOS.")
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
                Text("Only your email address and first-launch date are sent, to confirm you as a founding user. No marketing email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// GitHub 的 Star 请求。**常驻**，和有没有订阅过无关——所以它是 `subscriptionRow` 的
    /// 同级兄弟，不塞进那个 if/else 里。
    ///
    /// ⚠️ 调子沿用官网 tungstenedge.app 订阅区那段（`index.html` 里的 `.sub-star`）已经定死的
    /// 三条规矩，别在这里重新发挥：
    /// 1. **常驻**，不是订阅成功之后才冒出来——用户得先在视野里见过它，回头点起来才顺理成章。
    /// 2. **比订阅正文更淡**。它是"顺手帮个忙"，不能压过留邮箱的真实理由。官网用
    ///    `opacity .5 / font-weight 300 / 12.5px`；这里对应 `.caption`，而订阅正文是 `.callout`。
    /// 3. **只说这一次**。订阅结果的 `SettingsAlert` 里不要再提 Star——它一直在视野里，
    ///    重复只会变吵，还会跟"去邮箱点确认"抢注意力（那一步不点就进不了名单，是承重的）。
    ///
    /// ⚠️ 链接用 `Button` 而不是 SwiftUI 的 `Link`：`Scripts/check_localization.py` 的正则
    /// 不扫 `Link(...)`，改成 `Link` 会让这条文案悄悄绕过本地化检查、在中文系统上露出英文。
    ///
    /// ⚠️ 整句是**一个**本地化条目，不要拆成「前半句 + GitHub 按钮 + 后半句」：
    /// 中英文里 GitHub 出现的位置不一样，拆开就没法翻译了。
    private var githubStarRow: some View {
        Button {
            NSWorkspace.shared.open(SettingsWindowView.repositoryURL)
        } label: {
            Text("Star Tungsten Edge on GitHub — a free way to help it get better.")
        }
        .buttonStyle(.link)
        .font(.caption)
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

    init(_ content: SubscriptionAlertContent) {
        self.init(title: content.title, message: content.message)
    }
}
