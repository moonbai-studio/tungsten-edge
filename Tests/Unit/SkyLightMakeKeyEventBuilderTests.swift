import CoreGraphics
import XCTest

/// SLPS make-key 事件记录布局（SkyLightMakeKeyEventBuilder）。
/// 布局来源：yabai window_manager_make_key_window（v3.3.10–v7.1.25 稳定）。
/// 背景：曾把 focus_window_without_raise 的辅助切窗事件（[0x08]=0x0d + [0x8a]）误当
/// make-key 使用，造成键盘焦点悬空（Docs/22 §14）——此布局是护栏，不可回退。
final class SkyLightMakeKeyEventBuilderTests: XCTestCase {
    private let windowID: CGWindowID = 0x0403_0201

    func testRecordLength() {
        let records = SkyLightMakeKeyEventBuilder.makeKeyRecords(windowID: windowID)
        XCTAssertEqual(records.first.count, 0xf8)
        XCTAssertEqual(records.second.count, 0xf8)
        XCTAssertEqual(SkyLightMakeKeyEventBuilder.recordLength, 0xf8)
    }

    func testFixedHeaderBytes() {
        let records = SkyLightMakeKeyEventBuilder.makeKeyRecords(windowID: windowID)
        XCTAssertEqual(records.first[0x04], 0xf8)
        XCTAssertEqual(records.second[0x04], 0xf8)
        XCTAssertEqual(records.first[0x08], 0x01)
        XCTAssertEqual(records.second[0x08], 0x02)
        XCTAssertEqual(records.first[0x3a], 0x10)
        XCTAssertEqual(records.second[0x3a], 0x10)
    }

    func testFFBlock() {
        let records = SkyLightMakeKeyEventBuilder.makeKeyRecords(windowID: windowID)
        for index in 0x20..<0x30 {
            XCTAssertEqual(records.first[index], 0xff, "first[\(index)]")
            XCTAssertEqual(records.second[index], 0xff, "second[\(index)]")
        }
    }

    func testWindowIDLittleEndianAt0x3C() {
        let records = SkyLightMakeKeyEventBuilder.makeKeyRecords(windowID: windowID)
        for record in [records.first, records.second] {
            XCTAssertEqual(record[0x3c], 0x01)
            XCTAssertEqual(record[0x3d], 0x02)
            XCTAssertEqual(record[0x3e], 0x03)
            XCTAssertEqual(record[0x3f], 0x04)
        }
    }

    func testNo0x8AAndAllOtherBytesZero() {
        let records = SkyLightMakeKeyEventBuilder.makeKeyRecords(windowID: windowID)
        let specified: Set<Int> = {
            var indices: Set<Int> = [0x04, 0x08, 0x3a]
            indices.formUnion(0x20..<0x30)
            indices.formUnion(0x3c..<0x40)
            return indices
        }()
        for record in [records.first, records.second] {
            XCTAssertEqual(record[0x8a], 0x00)
            for index in record.indices where !specified.contains(index) {
                XCTAssertEqual(record[index], 0x00, "unexpected nonzero byte at 0x\(String(index, radix: 16))")
            }
        }
    }
}
