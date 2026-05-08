import Foundation

struct AppFallbackRetentionPolicy {
    static func shouldRetainMissingFallback(record: WindowRecord, isProcessAlive: Bool) -> Bool {
        guard isProcessAlive else { return false }
        return isFeishuAppFallback(record)
    }

    private static func isFeishuAppFallback(_ record: WindowRecord) -> Bool {
        guard record.id.rawValue.hasPrefix("app-") else { return false }
        return record.bundleIdentifier == "com.electron.lark"
            || record.bundleIdentifier == "com.feishu.app"
            || record.bundleIdentifier == "com.bytedance.lark"
            || record.id.rawValue == "app-com.electron.lark"
            || record.id.rawValue == "app-com.feishu.app"
            || record.id.rawValue == "app-com.bytedance.lark"
    }
}
