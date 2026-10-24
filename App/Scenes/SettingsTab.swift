import Combine
import Foundation

/// 设置窗口的五个标签页（2026-08-24 分页、同日反馈拎出为独立标签；「Dock 栏」页 2026-09-01
/// 整页搬进状态栏菜单，见 `Docs/27`）。标题复用原分区标题的
/// 本地化 key；图标全部 macOS 11 起可用（对照 CoreGlyphs name_availability 核过）。
/// 纯 Foundation/Combine——测试 target 也编译它，别引 AppKit。
enum SettingsTab: String, CaseIterable {
    case general
    case advanced
    case license
    case feedback
    case diagnostics
    case about

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .advanced: return String(localized: "Advanced")
        case .license: return String(localized: "License")
        case .feedback: return String(localized: "Feedback")
        case .diagnostics: return String(localized: "Diagnostics")
        case .about: return String(localized: "About")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .advanced: return "wrench.and.screwdriver"
        case .license: return "key"
        case .feedback: return "paperplane"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

/// controller → SwiftUI 的选中页桥。controller 持有唯一一份 = 会话内记住所选标签；
/// **不落 UserDefaults**（与「设置窗口不跨重启记位置」同一条规矩）。
/// 量高探针必须共享这同一个实例，否则量的是别的页。
@MainActor
final class SettingsTabState: ObservableObject {
    @Published var selected: SettingsTab = .general
}

@MainActor
final class DiagnosticsSession: ObservableObject {
    struct Request: Equatable {
        let generation: UInt64
        let includesTitles: Bool
    }

    @Published private(set) var includesTitles = false
    @Published private(set) var isCollecting = false
    @Published private(set) var report: String?
    @Published private(set) var collectedAt: Date?
    @Published private(set) var showsCopied = false
    private var generation: UInt64 = 0
    private var copiedToken: UInt64 = 0
    private var isOpen = true

    func setIncludesTitles(_ value: Bool) {
        guard value != includesTitles else { return }
        includesTitles = value
        invalidate()
    }

    func begin() -> Request? {
        guard isOpen, !isCollecting else { return nil }
        generation &+= 1
        copiedToken &+= 1
        report = nil
        collectedAt = nil
        showsCopied = false
        isCollecting = true
        return Request(generation: generation, includesTitles: includesTitles)
    }

    @discardableResult
    func complete(_ request: Request, text: String) -> Bool {
        guard isOpen, isCollecting, request.generation == generation, request.includesTitles == includesTitles else { return false }
        isCollecting = false
        report = text
        collectedAt = Date()
        return true
    }

    /// Flips the copy button to its confirmation for two seconds; a later copy restarts the clock.
    func markCopied() {
        copiedToken &+= 1
        let token = copiedToken
        showsCopied = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.copiedToken == token else { return }
            self.showsCopied = false
        }
    }

    func close() {
        isOpen = false
        includesTitles = false
        invalidate()
    }

    private func invalidate() {
        generation &+= 1
        copiedToken &+= 1
        isCollecting = false
        report = nil
        collectedAt = nil
        showsCopied = false
    }
}

/// The feedback pane's four drafts. Owned by the controller, like `SettingsTabState`, because
/// closing the window drops the whole SwiftUI tree — `@State` on the root dies with it and the
/// user reopens to an empty form. Lives until the process exits; never written to UserDefaults.
/// The height probe shares this instance too.
@MainActor
final class FeedbackDraftState: ObservableObject {
    @Published var message = ""
    @Published var contact = ""
    @Published var category: FeedbackCategory = .bug
    @Published var attachments: [FeedbackAttachment] = []

    /// After a successful send only: a failed one keeps everything, attachments included.
    func clear() {
        message = ""
        contact = ""
        category = .bug
        attachments = []
    }
}
