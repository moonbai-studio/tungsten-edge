import XCTest

final class StripSharedAffixTrimTests: XCTestCase {
    func testSharedProfilePrefixIsRemoved() {
        XCTAssertEqual(
            StripSharedAffixTrim.trimmingSharedAffixes(["个人 — 起始页", "个人 — 哔哩哔哩"]),
            ["起始页", "哔哩哔哩"]
        )
    }

    /// 关键用例：原始公共前缀是「mio: N」（两个词都以 N 开头），必须回退到冒号那个边界，
    /// 否则会切出「otifications」/「ew Tab」。
    func testPrefixIsCutBackToASeparatorBoundary() {
        XCTAssertEqual(
            StripSharedAffixTrim.trimmingSharedAffixes(["mio: Notifications", "mio: New Tab"]),
            ["Notifications", "New Tab"]
        )
    }

    func testSharedSuffixIsRemoved() {
        XCTAssertEqual(
            StripSharedAffixTrim.trimmingSharedAffixes(["文档 - Pages", "简历 - Pages"]),
            ["文档", "简历"]
        )
    }

    /// 一旦有第二种配置，那一段就开始能区分窗口了——整组保持原样（owner 2026-09-04 拍板的动态行为）。
    func testAPrefixThatNoLongerMatchesEveryCardIsKept() {
        let titles = ["个人 — 起始页", "个人 — 哔哩哔哩", "工作 — 文档"]
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(titles), titles)
    }

    func testIdenticalTitlesAreKept() {
        let titles = ["New Tab", "New Tab"]
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(titles), titles)
    }

    /// 截完会让某一条变空 → 整组不动，绝不能只截一部分。
    func testGroupIsKeptWhenAnyTitleWouldBecomeEmpty() {
        let titles = ["个人 — 起始页", "个人 — "]
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(titles), titles)
    }

    func testSingleTitleIsUntouched() {
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(["个人 — 起始页"]), ["个人 — 起始页"])
    }

    /// 共同开头不落在分隔符边界上（非结构化重复）→ 不动。
    func testUnstructuredSharedPrefixIsKept() {
        let titles = ["Report 2026 A", "Report 2026 B"]
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(titles), titles)
    }

    func testTitlesWithNothingInCommonAreUntouched() {
        let titles = ["起始页", "哔哩哔哩"]
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes(titles), titles)
    }

    func testEmptyInputIsUntouched() {
        XCTAssertEqual(StripSharedAffixTrim.trimmingSharedAffixes([]), [])
    }

    func testPrefixAndSuffixCanBothGo() {
        XCTAssertEqual(
            StripSharedAffixTrim.trimmingSharedAffixes(["个人 — 起始页 - Safari", "个人 — 哔哩哔哩 - Safari"]),
            ["起始页", "哔哩哔哩"]
        )
    }
}
