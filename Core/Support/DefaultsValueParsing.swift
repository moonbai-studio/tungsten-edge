import Foundation

/// UserDefaults 里读回的 `Any?` 的类型收口。两条规则两处都踩过（`AppSettingsStore` /
/// `NativeDockPreferencesService`），所以收成一份：
/// - `Bool` / `CFBoolean` 能桥接成 `NSNumber`，不先按 CF 类型排除，`true` 会被读成 1.0；
/// - NaN / ±inf 穿到下游 `Int(...)` 直接 crash（NaN 的比较全为 false，clamp 不生效），非有限值一律当缺失。
enum DefaultsValueParsing {
    /// 真正的数值对象且有限；布尔、字符串、缺失、NaN / inf → nil。
    nonisolated static func finiteNumericValue(_ value: Any?) -> Double? {
        guard let value,
              CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    /// 只认真正的布尔对象（`CFBoolean`）；数字 0 / 1 不算布尔。
    nonisolated static func strictBooleanValue(_ value: Any?) -> Bool? {
        guard let value,
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }
}
