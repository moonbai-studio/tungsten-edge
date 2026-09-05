import Foundation

/// 点击 → 窗口真的动起来，这中间的时间花在哪。默认关闭，`DOCK_CLICK_TRACE=1` 打开。
///
/// **为什么要有它**：仓库已经吃过好几次「照代码里的常量推算延迟、然后照着推算拍板」的亏
/// （`Docs/27`《这个判断有多硬：不太硬》、`Docs/28`）。2026-08-11 这一轮要动最小化恢复的
/// 句柄捕获，改前改后必须有同一把尺子量。`Docs/22` §12 记着：当年正是给 slps 落地时刻打上
/// 时间戳，才一眼看清「闪的 case 落在 +400~900ms、干净的 case 在 +220ms 以内」——
/// 只验证末端状态是看不出来的。
///
/// 按 `windowID` 配对，不改任何既有函数签名（执行在另一个线程上，串不了 task-local）。
/// 同一张卡连点两下会重叠，诊断场景可接受：`end` 按发生顺序成对刷出。
enum ClickLatencyTrace {
    static let isEnabled = DebugSwitch.clickTrace.isEnabled(in: ProcessInfo.processInfo.environment)

    /// 一次点击的开始。`kind` = 规划出来的动作，`status` = 快照里的窗口状态（分类用）。
    static func begin(windowID: String, kind: String, status: String, bundleID: String?) {
        guard isEnabled else { return }
        runtime.begin(windowID: windowID, kind: kind, status: status, bundleID: bundleID,
                      at: ProcessInfo.processInfo.systemUptime)
    }

    /// 中间里程碑。`detail` 用来记「句柄命中的是哪一档」这类分支信息。
    static func mark(windowID: String?, _ stage: String, detail: String? = nil) {
        guard isEnabled, let windowID else { return }
        runtime.mark(windowID: windowID, stage: stage, detail: detail,
                     at: ProcessInfo.processInfo.systemUptime)
    }

    static func end(windowID: String?, success: Bool) {
        guard isEnabled, let windowID else { return }
        runtime.end(windowID: windowID, success: success,
                    at: ProcessInfo.processInfo.systemUptime)
    }

    private static let runtime = Runtime()

    private final class Runtime: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.caye.macosdockcc.v2.click-latency-trace")
        private var sessions: [String: Session] = [:]

        private struct Session {
            let windowID: String
            let kind: String
            let status: String
            let bundleID: String?
            let startedAt: TimeInterval
            var stages: [(String, TimeInterval, String?)] = []
        }

        func begin(windowID: String, kind: String, status: String, bundleID: String?, at: TimeInterval) {
            queue.async { [self] in
                sessions[windowID] = Session(windowID: windowID, kind: kind, status: status,
                                             bundleID: bundleID, startedAt: at)
            }
        }

        func mark(windowID: String, stage: String, detail: String?, at: TimeInterval) {
            queue.async { [self] in
                sessions[windowID]?.stages.append((stage, at, detail))
            }
        }

        func end(windowID: String, success: Bool, at: TimeInterval) {
            queue.async { [self] in
                guard let session = sessions.removeValue(forKey: windowID) else { return }
                append(line: line(for: session, success: success, endedAt: at))
            }
        }

        /// 毫秒，相对 `t_tap`。写成扁平 JSON 一行一次点击，直接 `jq` 得出分位数。
        private func line(for session: Session, success: Bool, endedAt: TimeInterval) -> String {
            func ms(_ t: TimeInterval) -> Double { ((t - session.startedAt) * 1000 * 100).rounded() / 100 }
            var fields: [String] = [
                "\"kind\":\(quote(session.kind))",
                "\"status\":\(quote(session.status))",
                "\"bundleID\":\(session.bundleID.map(quote) ?? "null")",
                "\"success\":\(success)",
                "\"totalMs\":\(ms(endedAt))"
            ]
            for (stage, at, detail) in session.stages {
                fields.append("\"\(stage)Ms\":\(ms(at))")
                if let detail { fields.append("\"\(stage)Detail\":\(quote(detail))") }
            }
            return "{\(fields.joined(separator: ","))}"
        }

        private func quote(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }

        private lazy var fileURL: URL? = {
            let fm = FileManager.default
            guard let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
            let dir = base.appendingPathComponent("Logs/com.caye.macosdockcc.v2", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("click-latency.jsonl")
        }()

        private func append(line: String) {
            guard let fileURL, let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
