import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsWindowView: View {
    static let contentWidth: CGFloat = 560

    /// 公开仓库主页。**只给「求 Star」用**——用户可见的「去下载」永远指向官网
    /// （2026-08-13 起 GitHub release 页不再附安装包，指过去是个空页面），
    /// 别顺手把下载入口也改到 GitHub 来。
    static let repositoryURL = URL(string: "https://github.com/moonbai-studio/tungsten-edge")!

    @ObservedObject var store: AppSettingsStore
    @ObservedObject var coordinator: SettingsCoordinator
    @ObservedObject var licenseStore: LicenseStore
    @ObservedObject var tabState: SettingsTabState
    let feedbackDraft: FeedbackDraftState
    @ObservedObject var diagnostics: DiagnosticsSession
    let collectDiagnostics: (Bool, @escaping (String) -> Void) -> Void
    /// 「通用」页那颗「重新打开新手引导」按钮的动作。**不给默认值**：这里没有任何测试
    /// 会检查 SwiftUI 调用点，给了默认值就等于让"漏传"编译通过（AGENTS.md 的 no-default 铁律）。
    let onShowWelcomeGuide: () -> Void

    var body: some View {
        // ScrollView 保留作小屏兜底：每页正常都短于一屏，量高把窗口撑到内容高度，滚动不出现。
        // **指示器必须关**：滚动条样式为「自动」且接了鼠标时是占位式的，出现时吃掉约 15pt 可视宽，
        // 切页动画那 0.2 秒内容溢出 → 滚动条在位 → 整页水平平移一下。内层也不许写死宽度（见下）。
        ScrollView(.vertical, showsIndicators: false) {
            SettingsWindowContent(
                store: store,
                coordinator: coordinator,
                licenseStore: licenseStore,
                tabState: tabState,
                feedbackDraft: feedbackDraft,
                diagnostics: diagnostics,
                collectDiagnostics: collectDiagnostics,
                onShowWelcomeGuide: onShowWelcomeGuide
            )
        }
        .frame(width: Self.contentWidth)
    }
}

struct SettingsWindowContent: View {
    @ObservedObject var store: AppSettingsStore
    @ObservedObject var coordinator: SettingsCoordinator
    @ObservedObject var licenseStore: LicenseStore
    @ObservedObject var tabState: SettingsTabState
    /// Feedback drafts live on the controller, not in `@State`: they must survive closing the
    /// window, which tears this whole tree down.
    @ObservedObject var feedbackDraft: FeedbackDraftState
    @ObservedObject var diagnostics: DiagnosticsSession
    let collectDiagnostics: (Bool, @escaping (String) -> Void) -> Void
    let onShowWelcomeGuide: () -> Void

    @State private var presentedAlert: SettingsAlert?
    @State private var showsScrollReverserHelp = false
    @State private var subscriptionEmail = ""
    @State private var licenseKeyInput = ""

    var body: some View {
        Group {
            switch tabState.selected {
            case .general: generalPane
            case .advanced: advancedPane
            case .license: licensePane
            case .feedback: feedbackPane
            case .diagnostics: diagnosticsPane
            case .about: aboutPane
            }
        }
        // No padding here: each pane brings its own, because the system form already insets
        // its boxes (`systemForm`) and the macOS 12 layouts pad by `Self.paneMargin`.
        // **不许写死宽度**：外面套着 ScrollView，刚性宽度在可视区变窄时会被居中 = 整页平移。
        // 弹性宽度下左边缘恒在 padding 处，最多重排换行。测高探针给的仍是 contentWidth 的提案。
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert(item: $presentedAlert) { alert in
            guard let actionTitle = alert.actionTitle, let action = alert.action else {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text(actionTitle), action: action),
                secondaryButton: .cancel(Text("Later"))
            )
        }
    }

    // 分区标题行随分页取消（窗口标题承担）。页体全部是**本根视图**的计算属性——
    // 草稿 @State（presentedAlert / 订阅邮箱 / 授权码）必须留在根上，
    // 下放进页级子视图 = 切页即清空（settings.md 有对应规则）。反馈的四份草稿在 `feedbackDraft`。
    /// Every pane is the system's own grouped `Form` on macOS 13+ (`systemForm`), so radius,
    /// fill and dividers follow each OS release; macOS 12 has no grouped form and keeps the
    /// hand-built layouts in the `else` branches.
    ///
    /// 「通用」页: one box — label leading, control trailing — with the setup-guide entry under
    /// it. Rows carry no grey note; the one disclosure this page owes (scroll reversal) sits
    /// behind that row's help button.
    @ViewBuilder
    private var generalPane: some View {
        if #available(macOS 13.0, *) {
            VStack(alignment: .trailing, spacing: 0) {
                systemForm {
                    languagePicker
                    // Plain stacks, not `LabeledContent`: that aligns on the text baseline, which
                    // an AppKit-backed control lacks — the recorder drops below its own label.
                    HStack {
                        Text("Appearance")
                        Spacer(minLength: 12)
                        appearanceCards
                    }
                    if Self.showsFrontWindowBarToggle {
                        frontWindowBarToggle
                            .toggleStyle(.switch)
                    }
                    HStack {
                        Text("Show/hide taskbar shortcut")
                        Spacer(minLength: 12)
                        hotKeyControls
                    }
                    HStack {
                        scrollReverserLabel
                        Spacer(minLength: 12)
                        scrollReverserToggle
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                welcomeGuideButton
                    .padding(.trailing, Self.paneMargin)
            }
            .padding(.bottom, Self.paneMargin)
        } else {
            settingsPane {
                settingsGroup {
                    groupRow {
                        Text("Language")
                    } control: {
                        languagePicker
                            .labelsHidden()
                            .fixedSize()
                    }
                    Divider().opacity(0.5)
                    groupRow {
                        Text("Appearance")
                    } control: {
                        appearanceCards
                    }
                    if Self.showsFrontWindowBarToggle {
                        Divider().opacity(0.5)
                        groupRow {
                            Text("Mark the active window with a bar")
                        } control: {
                            frontWindowBarToggle
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                    }
                    Divider().opacity(0.5)
                    groupRow {
                        Text("Show/hide taskbar shortcut")
                    } control: {
                        hotKeyControls
                    }
                    Divider().opacity(0.5)
                    groupRow {
                        scrollReverserLabel
                    } control: {
                        scrollReverserToggle
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }
                HStack {
                    Spacer()
                    welcomeGuideButton
                }
            }
            .padding(Self.paneMargin)
        }
    }

    /// Distance from the window edge to a pane's content, boxes included.
    private static let paneMargin: CGFloat = 28
    /// Margin a grouped `Form` keeps around its boxes.
    private static let systemFormMargin: CGFloat = 20

    /// A pane as the system's grouped form, its boxes `paneMargin` from the window's top and
    /// sides. The form's own bottom margin is left as is — what follows decides the rest.
    @available(macOS 13.0, *)
    private func systemForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            // The window is sized to its content and the page scrolls as a whole; a form that
            // scrolls by itself has no height to measure.
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .padding([.horizontal, .top], Self.paneMargin - Self.systemFormMargin)
    }

    /// Bottom padding for a pane that ends with its form.
    private static let afterFormMargin = paneMargin - systemFormMargin

    // 「高级」= 需要额外能力、默认就对、基本不用碰的开关。单独一页不是为了藏，
    // 而是让常用页只留日常会调的东西；真想拒绝这个能力的人找得到（owner 2026-08-09，
    // 2026-08-24 分页时 owner 确认保留「高级」这一页）。
    @ViewBuilder
    private var advancedPane: some View {
        if #available(macOS 13.0, *) {
            systemForm {
                Section {
                    fullscreenIntentToggle
                } footer: {
                    Text(fullscreenIntentNote)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, Self.afterFormMargin)
        } else {
            settingsPane {
                settingRow(note: fullscreenIntentNote) {
                    fullscreenIntentToggle
                }
            }
            .padding(Self.paneMargin)
        }
    }

    private var fullscreenIntentToggle: some View {
        Toggle(
            "Predict full-screen transitions to prevent taskbar flicker",
            isOn: binding(
                get: { store.fullscreenIntentEnabled },
                set: store.setFullscreenIntentEnabled
            )
        )
    }

    private var fullscreenIntentNote: String {
        String(localized: "To keep the taskbar from flashing when you switch into full screen, Tungsten Edge has to hide it before your input reaches the app. It therefore watches global left-clicks, key presses and trackpad gestures, and recognizes only four of them: the window’s green button, Control-Command-F, Control-Left/Right arrow, and a three-finger horizontal swipe. What you type is never recorded, logged, or sent anywhere. Turning this off disables the watching completely.")
    }

    @ViewBuilder
    private var licensePane: some View {
        if #available(macOS 13.0, *) {
            systemForm {
                Section {
                    licenseRow
                }
                Section {
                    subscriptionContent
                } footer: {
                    githubStarRow
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, Self.afterFormMargin)
        } else {
            settingsPane {
                licenseRow
                Divider()
                    .padding(.vertical, 2)
                subscriptionContent
                githubStarRow
            }
            .padding(Self.paneMargin)
        }
    }

    @ViewBuilder
    private var feedbackPane: some View {
        let presentation = coordinator.feedbackState.presentation
        if #available(macOS 13.0, *) {
            systemForm {
                Section {
                    feedbackTypePicker
                        .horizontalRadioGroupLayout()
                    feedbackEditor
                        .scrollContentBackground(.hidden)
                    feedbackAttachmentRow(isEnabled: presentation.isEnabled)
                    feedbackContactRow(presentation)
                } header: {
                    feedbackLeadIn
                } footer: {
                    feedbackDisclosure
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, Self.afterFormMargin)
        } else {
            settingsPane {
                VStack(alignment: .leading, spacing: 8) {
                    feedbackLeadIn
                    HStack(spacing: 10) {
                        Text("Type")
                            .font(.callout)
                        feedbackTypePicker
                            .horizontalRadioGroupLayout()
                            .labelsHidden()
                    }
                    feedbackEditor
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                    feedbackAttachmentRow(isEnabled: presentation.isEnabled)
                    feedbackContactRow(presentation)
                    feedbackDisclosure
                }
            }
            .padding(Self.paneMargin)
        }
    }

    @ViewBuilder
    private var aboutPane: some View {
        if #available(macOS 13.0, *) {
            systemForm {
                aboutVersionRow
                autoUpdateToggle
            }
            .padding(.bottom, Self.afterFormMargin)
        } else {
            settingsPane {
                aboutVersionRow
                autoUpdateToggle
            }
            .padding(Self.paneMargin)
        }
    }

    @ViewBuilder
    private var diagnosticsPane: some View {
        if #available(macOS 13.0, *) {
            systemForm { diagnosticsControls }
                .padding(.bottom, Self.afterFormMargin)
        } else {
            settingsPane { diagnosticsControls }
                .padding(Self.paneMargin)
        }
    }

    @ViewBuilder
    private var diagnosticsControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Diagnostic Report")
            Text("The windows, permissions and settings Tungsten Edge currently sees. Your home directory is shown as ~.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Toggle("Include Window Titles", isOn: Binding(
            get: { diagnostics.includesTitles },
            set: { diagnostics.setIncludesTitles($0); refreshDiagnostics() }
        ))
        VStack(alignment: .leading, spacing: 8) {
            DiagnosticsReportTextView(text: diagnostics.report ?? "")
                .frame(height: Self.diagnosticsReportHeight)
                .overlay {
                    if diagnostics.isCollecting {
                        ProgressView().controlSize(.small)
                    }
                }
            diagnosticsActionRow
        }
        .onAppear {
            if diagnostics.report == nil { refreshDiagnostics() }
        }
    }

    /// The report box keeps one height whether empty, collecting or full: content that grows
    /// after the window opens does not resize it, so a box sized to its text would be clipped.
    private static let diagnosticsReportHeight: CGFloat = 200

    private var diagnosticsActionRow: some View {
        HStack(spacing: 12) {
            Text(diagnosticsStatusText)
                .font(.caption).foregroundStyle(.secondary)
            Button("Collect Again", action: refreshDiagnostics)
                .disabled(diagnostics.isCollecting)
            Spacer()
            Button(action: copyDiagnostics) {
                if diagnostics.showsCopied {
                    Label("Copied", systemImage: "checkmark")
                } else {
                    Text("Copy Report")
                }
            }
            .disabled(diagnostics.report == nil)
        }
    }

    private var diagnosticsStatusText: String {
        guard !diagnostics.isCollecting, let collectedAt = diagnostics.collectedAt else {
            return String(localized: "Collecting…")
        }
        let time = DateFormatter.localizedString(from: collectedAt, dateStyle: .none, timeStyle: .short)
        return String(format: String(localized: "Collected at %@"), time)
    }

    private func refreshDiagnostics() {
        guard let request = diagnostics.begin() else { return }
        collectDiagnostics(request.includesTitles) { text in
            diagnostics.complete(request, text: text)
        }
    }

    private func copyDiagnostics() {
        guard let report = diagnostics.report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        diagnostics.markCopied()
    }

    // 登录时启动 2026-08-24 当天两度搬家：随去重进过设置窗口，owner 复议后定为
    // **只在状态栏菜单（第一项）**。这里不再放它，也不再需要 didBecomeActive 刷新。

    /// 界面语言（2026-08-24 加，2026-09-01 由三档收成两档、删掉「跟随系统」，见 `Docs/27`）。
    /// 写**应用自己域**的 `AppleLanguages`（与 macOS 13+ 逐 App 语言同一个键），重启生效。
    /// 读现状必须走 `CFPreferencesCopyAppValue`——`array(forKey:)` 会继承全局域，
    /// 分不清「没设过」和「显式设置」（`AppLanguageOption` 注释是权威）。
    ///
    /// ⚠️ 没设过语言的人键是不存在的，此时选单显示的是**推断值**（当前实际加载的那份
    /// `.lproj`）。**这条读取路径绝不许回写**：一回写就等于替所有从没选过的用户把语言钉死。
    private var languagePicker: some View {
        Picker(
            String(localized: "Language"),
            selection: Binding(
                get: { Self.currentLanguageOption() },
                set: { applyLanguage($0) }
            )
        ) {
            ForEach(AppLanguageOption.allCases, id: \.self) { option in
                Text(option.displayName).tag(option)
            }
        }
        .pickerStyle(.menu)
    }

    private static func currentLanguageOption() -> AppLanguageOption {
        let bundleID = (Bundle.main.bundleIdentifier ?? "") as CFString
        let value = CFPreferencesCopyAppValue("AppleLanguages" as CFString, bundleID) as? [String]
        return AppLanguageOption.current(
            appDomainValue: value,
            // 真正加载的那份 .lproj——比推断系统语言准：用户在系统设置里给钨极单独设了
            // 第三种语言时界面实际回落英文，这里就答 English。
            effectiveLocalization: Bundle.main.preferredLocalizations.first ?? "en"
        )
    }

    /// 选中的档**一律写键**，哪怕点的就是当前显示的那一档——那一档可能只是推断值（键不存在），
    /// 用户点它的意思是「固定成这个」，不写就还在跟着系统跑。但界面语言没真的变时**不弹重启提示**：
    /// 什么都没变还要人重启是打扰。
    private func applyLanguage(_ option: AppLanguageOption) {
        let previous = Self.currentLanguageOption()
        UserDefaults.standard.set(option.appleLanguagesValue, forKey: "AppleLanguages")
        guard option != previous else { return }
        presentedAlert = SettingsAlert(
            title: String(localized: "Language"),
            message: String(localized: "The language change takes effect after Tungsten Edge restarts."),
            actionTitle: String(localized: "Restart Tungsten Edge"),
            action: { Self.relaunch() }
        )
    }

    /// 分离一个「睡半秒再 open」的壳进程后自退。新实例启动时旧的已退干净，
    /// `terminateOtherInstances()` 不会反杀谁。环境无需再清——本进程入口处
    /// `ProcessEnvironmentScrub.apply()` 已经清过，子进程继承的就是干净环境。
    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// 显隐任务条快捷键：录制框 + 自定义过才出现的「恢复默认」。行高恒定
    ///（录制态只换文案不换尺寸，按钮出现在同一行内），所以不用给
    /// `SettingsWindowController.sessionSubscriptions` 加 sink。
    @ViewBuilder
    private var hotKeyControls: some View {
        HStack(spacing: 10) {
            if store.edgeToggleShortcut != nil {
                Button("Reset to Default") { applyShortcut(nil) }
            }
            HotKeyRecorder(
                currentGlyphs: store.edgeToggleShortcut?.glyphs
                    ?? GlobalHotKeyShortcut.edgeAutoHideMode.displayGlyphs,
                onRecord: { applyShortcut($0) },
                onRejectKey: {
                    presentedAlert = SettingsAlert(
                        title: String(localized: "Can’t Use This Shortcut"),
                        message: String(localized: "This key can’t be used as the shortcut key.")
                    )
                }
            )
            .fixedSize()
        }
    }

    /// App-wide appearance (`AppearanceMode`). The third option is `System`, never `Auto`:
    /// macOS's Auto switches by time of day, this one follows whatever macOS is showing.
    private var appearanceCards: some View {
        AppearanceModeCards(selection: store.appearanceMode, onSelect: store.setAppearanceMode)
    }

    /// 全局反转鼠标滚轮。作用于整个系统而不只是任务条，所以放「通用」。
    /// 说明必须写清「只改写方向值、不记录不发送」——这是全项目唯一改写别人输入事件的功能。
    /// It sits behind the help button beside the title, not under the toggle: the page shows
    /// no notes, but this disclosure must stay reachable in the app — and a hover tooltip is
    /// not reachable enough (it needs a still pointer and an active window).
    private var scrollReverserToggle: some View {
        Toggle(
            "Reverse mouse scroll direction",
            isOn: binding(get: { store.scrollReverserEnabled }, set: store.setScrollReverserEnabled)
        )
    }

    /// The front-window bar is held back from release: the row stays built (its strings stay referenced
    /// for check_localization) but is not shown, so `frontWindowBar` keeps its default off.
    private static let showsFrontWindowBarToggle = false

    private var frontWindowBarToggle: some View {
        Toggle(
            "Mark the active window with a bar",
            isOn: binding(get: { store.frontWindowBar }, set: store.setFrontWindowBar)
        )
    }

    private var scrollReverserLabel: some View {
        HStack(spacing: 6) {
            Text("Reverse mouse scroll direction")
            // A text-sized symbol, not the system help bezel: that one is as tall as the row.
            Button { showsScrollReverserHelp = true } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
                .buttonStyle(.plain)
                // A bare symbol reads as an unnamed button; say the disclosure itself.
                .accessibilityLabel(Text(scrollReverserHelp))
                .popover(isPresented: $showsScrollReverserHelp, arrowEdge: .bottom) {
                    Text(scrollReverserHelp)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 300, alignment: .leading)
                        .padding(14)
                }
        }
    }

    private var scrollReverserHelp: String {
        String(localized: "Flips mouse-wheel scrolling system-wide, like Scroll Reverser. Trackpads and Magic Mouse are not affected. Tungsten Edge only inverts the direction values of scroll-wheel events; nothing is recorded or sent anywhere. If Scroll Reverser or Mos is also running, the two cancel out — keep only one.")
    }

    /// 重开首次引导（那扇写系统 Dock 推荐设置的窗）。2026-09-01 从状态栏菜单搬来
    /// （owner 拍板）：它是"打开另一个界面"的入口，不是随手切的开关。
    /// 放「通用」页分组框下面——框里是设置，它是入口。
    ///
    /// ⚠️ 闭包直通 `AppDelegate.showWelcomeWindow()`，**绝不能改成走
    /// `presentWelcomeGuideIfNeeded()`、也不能靠删 `hasSeenWelcome`**：那条决策函数对
    /// 「系统 Dock 已自动隐藏」的存量用户恰好会跳过并把键写回，而存量用户正是这个入口的全部受众。
    private var welcomeGuideButton: some View {
        Button("Show Setup Guide Again") { onShowWelcomeGuide() }
    }

    private func applyShortcut(_ stored: StoredHotKeyShortcut?) {
        if case .failure(let error) = coordinator.applyEdgeToggleShortcut(stored) {
            presentedAlert = SettingsAlert(
                hotKeyError: error,
                attemptedGlyphs: stored?.glyphs ?? GlobalHotKeyShortcut.edgeAutoHideMode.displayGlyphs
            )
        }
    }

    /// 授权区块。离线验证：粘一条授权码进去，本地用内嵌公钥验签名，**不联网、不绑设备**
    ///（产品决策 `Docs/27`，格式契约 `Docs/31-licensing.md`）。
    ///
    /// ⚠️ 激活成功后输入框整行消失，区块高度会变。`SettingsWindowController` 只在 `present()`
    /// 和几个 `@Published` 的订阅里重新量高度，所以那边给 `licenseStore.$state` 加了一条
    /// `.sink`——删掉它的话，激活之后窗口不会收缩，只会变成可滚动。
    ///
    /// ⚠️ 失败提示走 `SettingsAlert`，不要改成在区块里就地长出一行红字（同上，高度不会跟着变）。
    @ViewBuilder
    private var licenseRow: some View {
        switch licenseStore.state {
        case .activated(let payload):
            Text(
                String(
                    format: String(localized: "Activated · %@ · %@"),
                    payload.kind.displayTitle,
                    payload.email
                )
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        case .unactivated:
            // ⚠️ 这一页说出口的每样东西都必须和「授权码到底发没发」对得上。2026-08-25 之前
            // 它既说「授权码在我们发给你的那封邮件里」，又摆着一个「粘贴授权码」输入框，
            // 而当时**一条授权码都没签发过**——文案和控件在说同一句假话，反馈里因此收到
            // 「邮箱并没有收到激活码」。发放没开始时这里只说明现状：没有状态行（没东西可
            // 激活时「未激活」只会让人以为该去激活点什么），没有输入框，没有按钮。
            //
            // 恢复方式：`LicenseStore.isIssuingLicenses` 翻成 true。**用 if 而不是注释掉，
            // 是为了让两个分支都参与编译**——注释掉的代码没人记得恢复，也会让
            // `activateLicense()` 变成无引用。
            VStack(alignment: .leading, spacing: 8) {
                if LicenseStore.isIssuingLicenses {
                    Text("Not activated")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        TextField(text: $licenseKeyInput, prompt: Text("Paste your license key")) {
                            Text("Paste your license key")
                        }
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { activateLicense() }
                        Button("Activate") { activateLicense() }
                            .disabled(licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                // 发放开始后它退回配角（输入框才是主角），所以字号跟着开关走。
                Text("Licensing opens with version 1.0. Tungsten Edge is completely free until then, and founding users who have confirmed their email will receive a permanent free license key.")
                    .font(LicenseStore.isIssuingLicenses ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activateLicense() {
        switch licenseStore.activate(code: licenseKeyInput) {
        case .success:
            licenseKeyInput = ""
        case .failure:
            // 八种错误对用户是同一件事：这串东西不能用。分门别类地解释只会让人以为
            // 换个写法就能过——真正的行动永远是「把邮件里那串完整复制一遍」。
            presentedAlert = SettingsAlert(
                title: String(localized: "Couldn’t Activate"),
                message: String(localized: "This license key isn’t valid. Copy the whole key from your email and paste it again.")
            )
        }
    }

    private var aboutVersionRow: some View {
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
    }

    private var autoUpdateToggle: some View {
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

    /// 应用内反馈表单（2026-08-24，同日拎成独立标签页）：类型三选一 + 随类型变的引导
    /// 文字 + 正文 + 选填联系方式 → 官网 `/api/feedback` → D1，owner 在本机控制台看。
    /// 为什么不是 GitHub / mailto：国内用户打不开 GitHub，mailto 依赖装好的邮件客户端。
    ///
    /// ⚠️ **所有高度固定**（TextEditor 定高 140pt；placeholder 是 overlay，不占布局；
    /// 附件区定高 44pt 且**始终渲染**，加到 3 个也不换行；发送后清空不改布局），
    /// 结果一律走 `SettingsAlert`——窗口只在 `present()`、license sink 和切页时量高度，
    /// 就地长出状态行或让附件把 pane 顶高，都只会变成可滚动。
    /// ⚠️ 披露行必须与实际发送的内容一致（六项：正文 / 联系方式 / 版本 / macOS / 语言 / 附件）；
    /// 类型并入 message（`FeedbackComposition` 是组装唯一入口），不是独立字段。
    private var feedbackLeadIn: some View {
        Text("Ran into a problem or have an idea? Write to us here.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var feedbackTypePicker: some View {
        Picker("Type", selection: $feedbackDraft.category) {
            ForEach(FeedbackCategory.allCases, id: \.self) { category in
                Text(category.displayName).tag(category)
            }
        }
        .pickerStyle(.radioGroup)
    }

    private var feedbackEditor: some View {
        TextEditor(text: $feedbackDraft.message)
            .font(.callout)
            .frame(height: 140)
            .overlay(alignment: .topLeading) {
                if feedbackDraft.message.isEmpty {
                    Text(feedbackDraft.category.placeholder)
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
    }

    private func feedbackContactRow(_ presentation: FeedbackSubmitPresentation) -> some View {
        HStack(spacing: 10) {
            // Prompt plus hidden label: inside a grouped form a bare title becomes a leading
            // label and the field itself shows empty.
            TextField(text: $feedbackDraft.contact, prompt: Text(String(localized: "Email or WeChat ID (optional)"))) {
                Text(String(localized: "Email or WeChat ID (optional)"))
            }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .disabled(!presentation.isEnabled)
            Button(presentation.title) { submitFeedback() }
                .disabled(
                    !presentation.isEnabled
                        || feedbackDraft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        }
    }

    private var feedbackDisclosure: some View {
        Text("Only your message, the contact you enter, the app version, your macOS version, the interface language and the attachments you add (kept for at most 90 days) are sent.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 附件区：一行，**定高 44pt，始终渲染**（一个都没加时也占着这行）。
    /// 高度绝不能随附件增减变化——设置窗口只在 present / 切页 / license sink 三处量高度，
    /// 就地长高只会让内容溢出成可滚动（`.claude/rules/settings.md` 是权威）。
    /// 因此：胶囊限宽、文件名中间截断、整行 `.frame(height:)` + `.clipped()` 兜底。
    @ViewBuilder
    private func feedbackAttachmentRow(isEnabled: Bool) -> some View {
        HStack(spacing: 8) {
            Button(String(localized: "Add Screenshot or Recording…")) { addFeedbackAttachments() }
                .disabled(!isEnabled || feedbackDraft.attachments.count >= FeedbackAttachmentCheck.maximumCount)
            ForEach(feedbackDraft.attachments) { attachment in
                feedbackAttachmentChip(attachment, isEnabled: isEnabled)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 44)
        .clipped()
    }

    private func feedbackAttachmentChip(_ attachment: FeedbackAttachment, isEnabled: Bool) -> some View {
        HStack(spacing: 4) {
            Text(attachment.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(attachment.sizeLabel)
                .foregroundStyle(.secondary)
            Button {
                feedbackDraft.attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(String(localized: "Remove Attachment"))
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 116)
        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
    }

    /// 选文件。可多选，逐个按同一套纯校验放行；**第一个被拒的就当场弹窗并停下**——
    /// 已经加进去的保留，用户看得见自己还剩几个名额。校验全在本地，40MB 传上去
    /// 再被服务端 400 拒回来，那几分钟是白等的。
    private func addFeedbackAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.feedbackAttachmentContentTypes
        panel.prompt = String(localized: "Attach")
        panel.message = String(localized: "Choose screenshots or screen recordings to send with your feedback.")
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            let name = url.lastPathComponent
            let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let rejection = FeedbackAttachmentCheck.validate(
                adding: name, byteCount: byteCount, to: feedbackDraft.attachments
            ) {
                presentedAlert = SettingsAlert(FeedbackAlertContent(attachmentRejection: rejection))
                return
            }
            guard let mimeType = FeedbackAttachmentCheck.mimeType(forFileName: name) else { return }
            feedbackDraft.attachments.append(FeedbackAttachment(
                url: url, name: name, byteCount: byteCount, mimeType: mimeType
            ))
        }
    }

    /// 与 `FeedbackAttachmentCheck` 的扩展名白名单一一对应。多放一种，服务端会 400。
    private static let feedbackAttachmentContentTypes: [UTType] = [
        .png, .jpeg, .gif, .heic, .quickTimeMovie, .mpeg4Movie
    ]

    private func submitFeedback() {
        // 先组装再上锁：空正文直接返回，不占 submitting 状态（按钮 disabled 已挡，这里兜底）。
        guard let composed = FeedbackComposition.compose(
            category: feedbackDraft.category, message: feedbackDraft.message
        ) else { return }
        guard coordinator.beginFeedback() else { return }
        let contact = feedbackDraft.contact
        let attachments = feedbackDraft.attachments
        Task {
            let content = await coordinator.performFeedback(
                message: composed, contact: contact, attachments: attachments
            )
            coordinator.finishFeedback()
            // 失败时草稿**全保留**（含附件列表）：40MB 重选一遍是很实在的惩罚。
            if content.didSend {
                feedbackDraft.clear()
            }
            presentedAlert = SettingsAlert(content)
        }
    }

    /// 「原始用户，永久免费」的留邮箱入口。住在「授权」页（2026-09-01 从「关于」搬来，
    /// owner 拍板）：紧挨着上面那句「1.0 才开放发放、原始用户届时收到永久免费授权码」。
    ///
    /// ⚠️ 标题和正文与官网 tungstenedge.app 的订阅区**逐字同源**（owner 逐句敲定的公开承诺），
    /// 不要在这里"改得更适合 App"——两处说法一旦分叉，将来兑现承诺时就会有人拿着不同的
    /// 版本来对质。
    ///
    /// ⚠️ 结果一律走 `SettingsAlert`，**不要**改成在区块里就地长出成功/失败文案：
    /// `SettingsWindowController.resizeToFitKeepingTopEdge()` 只在 `present()` 和几个
    /// `@Published` 订阅里重新量高度，就地加一行不会让窗口跟着变高，只会变成可滚动。
    @ViewBuilder
    private var subscriptionContent: some View {
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
                    TextField(text: $subscriptionEmail, prompt: Text("you@example.com")) {
                        Text("you@example.com")
                    }
                        .labelsHidden()
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
    /// 同级兄弟，不塞进那个 if/else 里。2026-09-01 跟着订阅块一起搬到「授权」页：
    /// 下面第 2 条那个"比订阅正文更淡"的调子是相对订阅块定的，两者必须相邻才成立。
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

    /// 一页的行容器。分区标题随 2026-08-24 分页取消（窗口标题承担），只剩统一行距。
    ///
    /// 行距 20 是和 `settingRow` 的 3 配对的：**20 : 3 的对比**才让「一行设置 + 它下面那句
    /// 灰色说明」读成一个整体。原先是 12 : 3，四段文字糊成一片（owner 2026-09-01）。
    private func settingsPane<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// macOS 12 stand-in for the grouped form's box: rows stacked edge to edge, a `Divider()`
    /// between them.
    private func settingsGroup<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// One row of a `settingsGroup`: label leading, control(s) pushed to the trailing edge.
    private func groupRow<Label: View, Control: View>(
        @ViewBuilder label: () -> Label,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 10) {
            label()
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
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

/// The three `AppearanceMode` choices as plain cards: a symbol over the name, the chosen one
/// tinted and ringed in the accent colour.
private struct AppearanceModeCards: View {
    let selection: AppearanceMode
    let onSelect: (AppearanceMode) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                let isSelected = mode == selection
                Button { onSelect(mode) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: Self.symbolName(for: mode))
                            .font(.system(size: 16))
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                            .frame(height: 18)
                        Text(mode.displayName)
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .frame(minWidth: 76, minHeight: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                            .opacity(isSelected ? 1 : 0)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private static func symbolName(for mode: AppearanceMode) -> String {
        switch mode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

private struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// 可选的第二个按钮（如语言切换的「立即重启」）。为 nil 时只有「好」。
    let actionTitle: String?
    let action: (() -> Void)?

    init(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    init(_ content: SubscriptionAlertContent) {
        self.init(title: content.title, message: content.message)
    }

    init(_ content: FeedbackAlertContent) {
        self.init(title: content.title, message: content.message)
    }

    /// 改键失败 → 一句能行动的人话。拒绝理由逐条给（每条的下一步动作不同）；
    /// 注册失败只有一种真实成因（组合被别的应用独占注册）。
    init(hotKeyError: HotKeyChangeError, attemptedGlyphs: String) {
        switch hotKeyError {
        case .rejected(.missingPrimaryModifier):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "Use at least one of Command, Control or Option.")
            )
        case .rejected(.unreliableModifiers):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "Option alone or Option-Shift is unreliable on macOS 15.")
            )
        case .rejected(.reservedBySystem):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "This combination belongs to macOS (⌥⌘D shows/hides the Dock; Control-Option is VoiceOver’s).")
            )
        case .rejected(.forbiddenKey):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "Escape and Delete can’t be the key.")
            )
        case .registrationFailed:
            self.init(
                title: String(localized: "Couldn’t Register the Shortcut"),
                message: String(
                    format: String(localized: "%@ is already taken by another app. The previous shortcut stays active."),
                    attemptedGlyphs
                )
            )
        }
    }
}

extension LicenseKind {
    /// 授权种类给用户看的名字。`LicenseVerifier` 那边是纯逻辑、不带文案，所以放在这里。
    /// 用词照 `Docs/30-i18n-glossary.md`：founding = 原始用户 / Founding User。
    var displayTitle: String {
        switch self {
        case .founding: return String(localized: "Founding User")
        case .paid: return String(localized: "Paid")
        }
    }
}

// App-only half of `DiagnosticReport`: the pure struct is also compiled into the test target,
// which has neither the glass bridge nor the panels.
extension DiagnosticReport {
    /// Variants read back for the report; the Dock's own material has been seen at 2 and at 3.
    static let reportedVariants = 0 ... 6

    /// Main thread, from a user action only — the variant read-back builds throwaway windows,
    /// which must not happen inside a SwiftUI update.
    static func collect(appVersion: String?) -> DiagnosticReport {
        let workspace = NSWorkspace.shared
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return DiagnosticReport(
            appVersion: appVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: hardwareModel(),
            language: Bundle.main.preferredLocalizations.first ?? "en",
            appearance: "\(isDark ? "dark" : "light") (\(NSApp.appearance == nil ? "follows system" : "fixed"))",
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            displays: NSScreen.screens.map {
                "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.backingScaleFactor))x"
            },
            glassPath: glassPath(),
            glassComposite: glassComposite(),
            glassRefresh: TEDockGlassSupportsWindowStateRefresh()
                ? "supported" : "unsupported (no _windowChangedKeyState)",
            glassTint: UserDefaults.standard.object(forKey: "NSGlassTintAmount").map { "\($0)" },
            glassVariants: glassVariantReadings(),
            glassPanels: livePanelReadings(),
            glassPanelsAtFirstActivation: panelsAtFirstActivation
        )
    }

    /// Hidden panels stay listed: an auto-hidden bar reads "none" otherwise, which looks like
    /// "no glass" — the very thing this line exists to tell apart.
    private static func livePanelReadings() -> [GlassReading] {
        NSApp.windows
            .filter { $0 is DockLiquidGlassPanel }
            .map { window in
                GlassReading(
                    label: "\(Int(window.frame.width))x\(Int(window.frame.height))"
                        + (window.isVisible ? "" : " hidden"),
                    reading: window.contentView?.layer.flatMap { TEDockGlassDescribeLayer($0) },
                    state: glassState(of: window)
                )
            }
    }

    private static var panelsAtFirstActivation: [GlassReading]?
    private static var firstActivationObserver: NSObjectProtocol?

    /// Records the live panels the first time the app becomes active with the bar up. AppKit posts
    /// `willBecomeActive` before it re-samples the window state into the glass (on 27.0 the
    /// re-sample lands after `didBecomeActive`; `scratch/order_probe.swift`), so this is a reading
    /// the activation has not touched yet. One shot, for those panels only — later faults and
    /// panels rebuilt after a display change are not covered. An activation before the bar
    /// exists (permission onboarding) is skipped, not consumed.
    static func armFirstActivationSnapshot() {
        guard firstActivationObserver == nil, panelsAtFirstActivation == nil else { return }
        firstActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            let panels = livePanelReadings()
            guard !panels.isEmpty else { return }
            panelsAtFirstActivation = panels
            if let observer = firstActivationObserver { NotificationCenter.default.removeObserver(observer) }
            firstActivationObserver = nil
        }
    }

    /// The window state baked into a system-variant plate, told apart by two never-shown windows
    /// of the plate's own size: a plain `NSWindow` (inactive) and a `DockLiquidGlassPanel` (its
    /// predicates answer active). Nil for panels on another material.
    private static func glassState(of window: NSWindow) -> GlassState? {
        guard let variant = DockGlassPresentation.activeSystemVariant,
              let plate = DockGlassPresentation.systemVariantGlassViews(in: window).first,
              let reading = plate.layer.flatMap({ TEDockGlassDescribeLayer($0) }) else { return nil }
        let size = plate.bounds.size
        return classify(
            reading: reading,
            inactive: referenceReading(variant: variant, size: size, activePredicates: false),
            active: referenceReading(variant: variant, size: size, activePredicates: true)
        )
    }

    /// `TEDockGlassDescribeVariant` at a chosen size and window class. Main thread, from a user
    /// action only: it builds a throwaway window.
    private static func referenceReading(variant: Int, size: NSSize, activePredicates: Bool) -> String? {
        guard #available(macOS 26.0, *), size.width > 0, size.height > 0 else { return nil }
        let frame = NSRect(origin: .zero, size: size)
        let window: NSWindow = activePredicates
            ? DockLiquidGlassPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
            : NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let glass = NSGlassEffectView(frame: frame)
        glass.contentView = NSView(frame: frame)
        guard TEDockGlassSetSystemVariant(glass, variant) else { return nil }
        window.contentView = NSView(frame: frame)
        window.contentView?.addSubview(glass)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // The live plate re-samples once after attach (`DockSystemGlassEffectView`); mirror it so
        // the reference is what that plate would read, not what a plain view reads.
        _ = TEDockGlassRefreshWindowState(glass)
        return glass.layer.flatMap { TEDockGlassDescribeLayer($0) }
    }

    /// `glassPath` is the configuration; this is what the running bar actually got. The glass
    /// composite exists exactly when its background panel does (`PanelCoordinator.usesLiquidGlass`),
    /// and that panel keeps its view for the bar's whole life, so counting those windows is the
    /// same answer every unit would give.
    private static func glassComposite() -> String {
        guard DockGlassPresentation.shouldAttemptTaskbarComposite else { return "off (frosted path)" }
        let backgrounds = NSApp.windows.filter { $0.contentView is DockTaskbarLiquidGlassBackgroundView }.count
        guard backgrounds > 0 else { return "down (bar on the frosted fallback)" }
        return "up (\(backgrounds) background panel\(backgrounds == 1 ? "" : "s"))"
    }

    private static func glassPath() -> String {
        guard DockGlassPresentation.shouldAttemptTaskbarComposite else { return "frosted" }
        if let variant = DockGlassPresentation.activeSystemVariant { return "variant \(variant)" }
        return DockGlassPresentation.configuration.systemVariant == nil
            ? "swiftui clear (variant switched off)"
            : "swiftui clear (no variant selector)"
    }

    private static func glassVariantReadings() -> [GlassReading] {
        guard TEDockGlassSupportsSystemVariant() else { return [] }
        return reportedVariants.map { GlassReading(label: "\($0)", reading: TEDockGlassDescribeVariant($0)) }
    }

    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Read-only, selectable report text. AppKit rather than a SwiftUI `Text`: a busy machine's
/// report runs to hundreds of lines, which a SwiftUI text view scrolls and selects poorly.
private struct DiagnosticsReportTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        // The factory sizes the document to its content and starts at the top; a hand-built
        // NSTextView in a scroll view opens scrolled one line down.
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textContainerInset = NSSize(width: 6, height: 6)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}
