import AppKit
import SwiftUI

struct ContentView: View {
    let snapshot: DockSnapshot
    let hasRequiredPermissions: Bool
    let observationStatusText: String
    let feedbackEntriesByWindowID: [String: IntentFeedbackState.Entry]
    let onToggle: (String) -> Void
    let onActivate: (String) -> Void
    let onMinimize: (String) -> Void
    let onHide: (String) -> Void
    let onClose: (String) -> Void

    private var stripItems: [StripItem] {
        StripItem.items(from: snapshot)
    }

    private var visibleStatusCount: Int {
        stripItems.filter { $0.status != WindowStatus.disappeared.rawValue }.count
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.12, blue: 0.16),
                    Color(red: 0.14, green: 0.17, blue: 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                Text("任务条调试台")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("底部任务条现在由真实窗口观察链路驱动。飞书在窗口级信息不可靠时，会退回为一个稳定的应用级条目。")
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 18) {
                    summaryPill(label: "已跟踪", value: "\(stripItems.count)")
                    summaryPill(label: "可见", value: "\(visibleStatusCount)")
                    summaryPill(label: "权限", value: hasRequiredPermissions ? "辅助权限已就绪" : "仅窗口列表可用")
                    summaryPill(label: "启动", value: observationStatusText)
                }

                if hasRequiredPermissions == false {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("尚未授予辅助功能权限。")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("任务条仍可通过系统窗口列表显示部分窗口，但在权限开启前，窗口标题、最小化状态和位置侧证据会不完整。")
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
                }

                Spacer(minLength: 0)

                if stripItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有跟踪到窗口")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("保持应用打开，然后切换或移动几个窗口。观察链路写入快照后，底部任务条会自动出现条目。")
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("任务条")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(stripItems, id: \.id) { item in
                                taskStripChip(item)
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.black.opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            }
            .padding(24)
        }
    }

    private func summaryPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    @ViewBuilder
    private func taskStripChip(_ item: StripItem) -> some View {
        let feedback = feedbackEntriesByWindowID[item.id]
        let isPending = feedback?.phase == .pending

        Group {
            if item.showsTitle {
                expandedTaskStripChip(item, feedback: feedback, isPending: isPending)
            } else {
                compactTaskStripChip(item, feedback: feedback, isPending: isPending)
            }
        }
        .help(localizedTitle(item))
        .contextMenu {
            taskStripContextMenu(item, isDisabled: isPending)
        }
        .animation(.easeInOut(duration: 0.18), value: item.showsTitle)
    }

    private func expandedTaskStripChip(
        _ item: StripItem,
        feedback: IntentFeedbackState.Entry?,
        isPending: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                appIcon(for: item)
                Text(localizedTitle(item))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            HStack(spacing: 8) {
                Text(localizedStatus(item.status))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                if item.isAppLevelFallback {
                    Text("应用")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.17, green: 0.22, blue: 0.18))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.77, green: 0.91, blue: 0.68), in: Capsule())
                }
            }

            if let feedback {
                HStack(spacing: 6) {
                    Circle()
                        .fill(feedbackColor(feedback))
                        .frame(width: 7, height: 7)
                    Text(feedbackText(feedback))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(feedbackColor(feedback))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(feedbackColor(feedback).opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 8) {
                actionButton(label: "激活", isDisabled: isPending) {
                    onActivate(item.id)
                }

                if item.canHide {
                    actionButton(label: "隐藏", isDisabled: isPending) {
                        onHide(item.id)
                    }
                }

                if item.canMinimize {
                    actionButton(label: "最小化", isDisabled: isPending) {
                        onMinimize(item.id)
                    }
                }

                if item.canClose {
                    actionButton(label: "关闭", isDisabled: isPending) {
                        onClose(item.id)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .overlay(alignment: .topTrailing) {
            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.8))
                    .padding(12)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            guard isPending == false else { return }
            onToggle(item.id)
        }
    }

    private func compactTaskStripChip(
        _ item: StripItem,
        feedback: IntentFeedbackState.Entry?,
        isPending: Bool
    ) -> some View {
        let borderColor = feedback.map { feedbackColor($0).opacity(0.36) } ?? Color.white.opacity(0.08)

        return ZStack {
            appIcon(for: item)

            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.88))
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.36), in: Circle())
                    .offset(x: 17, y: -17)
            }
        }
        .padding(12)
        .frame(width: 58, height: 58)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .onTapGesture {
            guard isPending == false else { return }
            onToggle(item.id)
        }
    }

    @ViewBuilder
    private func taskStripContextMenu(_ item: StripItem, isDisabled: Bool) -> some View {
        Button("激活") {
            onActivate(item.id)
        }
        .disabled(isDisabled)

        if item.canHide {
            Button("隐藏") {
                onHide(item.id)
            }
            .disabled(isDisabled)
        }

        if item.canMinimize {
            Button("最小化") {
                onMinimize(item.id)
            }
            .disabled(isDisabled)
        }

        if item.canClose {
            Divider()
            Button("关闭") {
                onClose(item.id)
            }
            .disabled(isDisabled)
        }
    }

    private func appIcon(for item: StripItem) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: AppIconResolver.icon(for: item.bundleIdentifier ?? item.appID))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)

            Circle()
                .fill(statusColor(item.status))
                .frame(width: 9, height: 9)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.46), lineWidth: 1)
                )
                .offset(x: 2, y: 2)
        }
        .frame(width: 32, height: 32)
        .accessibilityLabel("\(localizedTitle(item)) 应用图标")
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case WindowStatus.minimized.rawValue:
            return Color(red: 0.95, green: 0.74, blue: 0.21)
        case WindowStatus.hidden.rawValue:
            return Color(red: 0.85, green: 0.48, blue: 0.24)
        case WindowStatus.disappeared.rawValue:
            return Color(red: 0.64, green: 0.66, blue: 0.70)
        case WindowStatus.active.rawValue:
            return Color(red: 0.35, green: 0.82, blue: 0.56)
        default:
            return Color(red: 0.43, green: 0.66, blue: 1.0)
        }
    }

    private func actionButton(label: String, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isDisabled ? Color.white.opacity(0.05) : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? .white.opacity(0.34) : .white.opacity(0.82))
        .disabled(isDisabled)
    }

    private func feedbackText(_ feedback: IntentFeedbackState.Entry) -> String {
        switch feedback.phase {
        case .pending:
            switch feedback.action {
            case .toggle:
                return "正在尝试切换这个窗口"
            case .activate:
                return "正在尝试把这个窗口带到前台"
            case .minimize:
                return "正在尝试最小化这个窗口"
            case .hide:
                return "正在尝试隐藏这个应用"
            case .close:
                return "正在尝试关闭这个窗口"
            }
        case .success:
            switch feedback.action {
            case .toggle:
                return "这个窗口已切换"
            case .activate:
                return "这个窗口已带到前台"
            case .minimize:
                return "这个窗口已最小化"
            case .hide:
                return "这个应用已隐藏"
            case .close:
                return "这个窗口已关闭"
            }
        case .failure:
            switch feedback.action {
            case .toggle:
                return "没能切换这个窗口"
            case .activate:
                return "没能把这个窗口带到前台"
            case .minimize:
                return "没能最小化这个窗口"
            case .hide:
                return "没能隐藏这个应用"
            case .close:
                return "没能关闭这个窗口"
            }
        }
    }

    private func localizedTitle(_ item: StripItem) -> String {
        switch item.title {
        case "macos-dock-cc-v2":
            return "任务条调试台"
        default:
            return item.title
        }
    }

    private func localizedStatus(_ status: String) -> String {
        switch status {
        case WindowStatus.active.rawValue:
            return "活跃"
        case WindowStatus.inactive.rawValue:
            return "未激活"
        case WindowStatus.minimized.rawValue:
            return "已最小化"
        case WindowStatus.hidden.rawValue:
            return "已隐藏"
        case WindowStatus.closedPending.rawValue:
            return "关闭确认中"
        case WindowStatus.disappeared.rawValue:
            return "暂时消失"
        default:
            return status
        }
    }

    private func feedbackColor(_ feedback: IntentFeedbackState.Entry) -> Color {
        switch feedback.phase {
        case .pending:
            return Color(red: 0.95, green: 0.74, blue: 0.21)
        case .success:
            return Color(red: 0.35, green: 0.82, blue: 0.56)
        case .failure:
            return Color(red: 0.95, green: 0.43, blue: 0.40)
        }
    }
}

private enum AppIconResolver {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleIdentifier: String) -> NSImage {
        if let cached = cache[bundleIdentifier] {
            return cached
        }

        let icon: NSImage
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }

        icon.size = NSSize(width: 32, height: 32)
        cache[bundleIdentifier] = icon
        return icon
    }
}
