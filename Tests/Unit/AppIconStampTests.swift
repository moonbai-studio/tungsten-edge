import XCTest

final class AppIconStampTests: XCTestCase {
    private var directory: URL!
    private var app: URL!
    private var infoPlist: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        app = directory.appendingPathComponent("X.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        infoPlist = contents.appendingPathComponent("Info.plist")
        try writeInfoPlist(version: "1")
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testUnchangedDirectoryHasEqualStamps() throws {
        let first = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        XCTAssertTrue(first.infoPlistExists)
        XCTAssertEqual(first, AppIconStamp.stamp(atPath: app.path))
    }

    func testCreatingAndRemovingCustomIconChangesStamp() throws {
        let original = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        let icon = app.appendingPathComponent("Icon\r")
        // Keep the mutations on distinct filesystem clock ticks.
        Thread.sleep(forTimeInterval: 0.01)
        try Data([1, 2, 3]).write(to: icon)
        let customized = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        XCTAssertNotEqual(original, customized)
        XCTAssertEqual(original.bundleInode, customized.bundleInode)

        Thread.sleep(forTimeInterval: 0.01)
        try FileManager.default.removeItem(at: icon)
        let restored = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        XCTAssertNotEqual(customized, restored)
        XCTAssertEqual(customized.bundleInode, restored.bundleInode)
    }

    func testRewritingInfoPlistChangesStamp() throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: infoPlist.path
        )
        let original = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        try writeInfoPlist(version: "2")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)], ofItemAtPath: infoPlist.path
        )
        let updated = try XCTUnwrap(AppIconStamp.stamp(atPath: app.path))
        XCTAssertNotEqual(original, updated)
        XCTAssertEqual(original.bundleInode, updated.bundleInode)
        XCTAssertEqual(original.bundleChangeSeconds, updated.bundleChangeSeconds)
        XCTAssertEqual(original.bundleChangeNanoseconds, updated.bundleChangeNanoseconds)
    }

    func testMissingDirectoryHasNoStamp() {
        XCTAssertNil(AppIconStamp.stamp(atPath: directory.appendingPathComponent("Missing.app").path))
    }

    private func writeInfoPlist(version: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.app-icon-stamp", "CFBundleVersion": version],
            format: .xml, options: 0
        )
        try data.write(to: infoPlist)
    }
}
