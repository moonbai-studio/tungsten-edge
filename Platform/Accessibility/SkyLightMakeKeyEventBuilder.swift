import CoreGraphics
import Foundation

/// 真正的 SLPS make-key 事件对（yabai `window_manager_make_key_window`，v3.3.10–v7.1.25
/// 布局稳定）：每条 0xf8 字节，`[0x04]=0xf8`，`[0x08]=0x01`（第一条）/`0x02`（第二条），
/// `[0x3a]=0x10`，`[0x20..<0x30]` 全 `0xff`，cgWindowID 以小端写入 `[0x3c..<0x40]`，
/// 其余字节保持为零——**不写 `0x8a`**。
/// 曾经的 `[0x08]=0x0d` + `[0x8a]=0x02/0x01` 是 yabai `focus_window_without_raise`
/// 里的辅助切窗通知事件，不是 make-key；只发它们会造成「进程切前台但全系统无
/// key window」的键盘悬空（Docs/22 §14）。
enum SkyLightMakeKeyEventBuilder {
    static let recordLength = 0xf8

    static func makeKeyRecords(windowID: CGWindowID) -> (first: [UInt8], second: [UInt8]) {
        (record(windowID: windowID, eventType: 0x01), record(windowID: windowID, eventType: 0x02))
    }

    private static func record(windowID: CGWindowID, eventType: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: recordLength)
        bytes[0x04] = 0xf8
        bytes[0x08] = eventType
        bytes[0x3a] = 0x10
        for index in 0x20..<0x30 {
            bytes[index] = 0xff
        }
        withUnsafeBytes(of: windowID.littleEndian) { widBytes in
            for index in 0..<4 {
                bytes[0x3c + index] = widBytes[index]
            }
        }
        return bytes
    }
}
