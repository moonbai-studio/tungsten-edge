import XCTest

final class DiagnosticReportTests: XCTestCase {
    private func report() -> DiagnosticReport {
        DiagnosticReport(
            appVersion: "0.13.3 (140)",
            systemVersion: "Version 27.0 (Build 26A428)",
            hardwareModel: "Mac17,9",
            language: "zh-Hans",
            appearance: "dark (follows system)",
            reduceTransparency: false,
            increaseContrast: true,
            displays: ["1512x982@2x", "2560x1440@1x"],
            glassPath: "variant 3",
            glassComposite: "up (1 background panel)",
            glassRefresh: "supported",
            glassTint: "0.4",
            glassVariants: [
                .init(label: "0", reading: "L0.85 N0.40 R-27.00 B5.00 K77"),
                .init(label: "3", reading: nil),
            ],
            glassPanels: [
                .init(label: "1512x94", reading: "L0.00 N0.00 R-29.88 B5.42 K77", state: .inactive),
                .init(label: "240x94 hidden", reading: "L0.00 N0.00 R-29.88 B5.42 K77"),
            ],
            glassPanelsAtFirstActivation: nil
        )
    }

    func testTextListsEveryFieldOnItsOwnLine() {
        XCTAssertEqual(report().text, """
        Tungsten Edge diagnostics
        app: 0.13.3 (140)
        macOS: Version 27.0 (Build 26A428) · Mac17,9
        language: zh-Hans
        appearance: dark (follows system)
        accessibility: reduceTransparency=0 increaseContrast=1
        displays: 1512x982@2x, 2560x1440@1x
        glass path: variant 3
        glass composite: up (1 background panel)
        glass refresh: supported
        glass tint: 0.4
        glass variants: 0=L0.85 N0.40 R-27.00 B5.00 K77 | 3=unreadable
        glass panels: 1512x94=L0.00 N0.00 R-29.88 B5.42 K77 [inactive] | 240x94 hidden=L0.00 N0.00 R-29.88 B5.42 K77
        glass panels at first activation: not captured
        """)
    }

    /// The pre-activation snapshot is its own line: opening Settings activates the app, which heals
    /// the inactive material before the user can copy, so the live line alone cannot show it.
    func testFirstActivationSnapshotIsListedLikeTheLivePanels() {
        var report = report()
        report.glassPanelsAtFirstActivation = [
            .init(label: "1512x94", reading: "L0.00 N0.00 R-29.88 B8.47 K77", state: .inactive),
        ]
        XCTAssertTrue(report.text.hasSuffix(
            "glass panels at first activation: 1512x94=L0.00 N0.00 R-29.88 B8.47 K77 [inactive]"))
    }

    /// References that read the same cannot decide anything; saying so beats a confident label.
    func testIdenticalReferencesAreUndecidable() {
        let same = "L? N? R-17.64 B5.42 S? O? K55"
        XCTAssertEqual(DiagnosticReport.classify(reading: "L? N? R-29.88 B5.42 S? O? K55",
                                                 inactive: same, active: same),
                       .undecidable(inactive: same, active: same))
        var report = report()
        report.glassPanels = [.init(label: "754x98", reading: "L? N? R-29.88 B5.42 S? O? K55",
                                    state: .undecidable(inactive: same, active: same))]
        XCTAssertTrue(report.text.contains(
            "754x98=L? N? R-29.88 B5.42 S? O? K55 [undecidable; inactive=\(same) active=\(same)]"))
    }

    /// Unreadable fields (`?`) compare as text, so a 26.x reading without L / N still decides on B / S / O.
    func testUnreadableFieldsStillDecideOnTheReadableOnes() {
        let inactive = "L? N? R-17.64 B8.47 S? O? K55"
        let active = "L? N? R-17.64 B1.30 S? O? K55"
        XCTAssertEqual(DiagnosticReport.classify(reading: "L? N? R-29.88 B1.30 S? O? K55",
                                                 inactive: inactive, active: active), .active)
    }

    /// The bar overwrites refraction (`R`) with the fixed Dock amount, so the state is decided on
    /// the remaining fields; a reading matching neither reference carries both so the paste still
    /// says what this machine's two states look like.
    func testStateIsDecidedWithoutRefraction() {
        let inactive = "L? N? R-17.64 B8.47 S1.00 O1.00 K55"
        let active = "L? N? R-17.64 B1.30 S1.25 O0.50 K55"
        XCTAssertEqual(DiagnosticReport.classify(reading: "L? N? R-29.88 B1.30 S1.25 O0.50 K55",
                                                 inactive: inactive, active: active), .active)
        XCTAssertEqual(DiagnosticReport.classify(reading: "L? N? R-29.88 B8.47 S1.00 O1.00 K55",
                                                 inactive: inactive, active: active), .inactive)
        XCTAssertEqual(DiagnosticReport.classify(reading: "L? N? R-29.88 B2.14 S1.00 O1.00 K55",
                                                 inactive: inactive, active: active),
                       .unmatched(inactive: inactive, active: active))
        XCTAssertNil(DiagnosticReport.classify(reading: nil, inactive: inactive, active: active))
        XCTAssertNil(DiagnosticReport.classify(reading: active, inactive: nil, active: nil))
        // One missing reference still decides against the other, and is spelled out when it fails.
        XCTAssertEqual(DiagnosticReport.classify(reading: active, inactive: inactive, active: nil),
                       .unmatched(inactive: inactive, active: nil))
    }

    func testUnmatchedStateSpellsOutBothReferences() {
        var report = report()
        report.glassPanels = [.init(label: "754x98", reading: "L? N? R-29.88 B2.14 K55",
                                    state: .unmatched(inactive: "L? N? R-17.64 B8.47 K55", active: nil))]
        XCTAssertTrue(report.text.contains(
            "glass panels: 754x98=L? N? R-29.88 B2.14 K55 [unmatched; inactive=L? N? R-17.64 B8.47 K55 active=unreadable]\n"))
    }

    /// A frosted (macOS 12–25) or unreadable system must still produce a complete report.
    func testMissingValuesAreSpelledOut() {
        var empty = report()
        empty.appVersion = nil
        empty.hardwareModel = nil
        empty.glassTint = nil
        empty.displays = []
        empty.glassVariants = []
        empty.glassPanels = []
        let lines = empty.text.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("app: unknown"))
        XCTAssertTrue(lines.contains("macOS: Version 27.0 (Build 26A428)"))
        XCTAssertTrue(lines.contains("displays: none"))
        XCTAssertTrue(lines.contains("glass tint: unset"))
        XCTAssertTrue(lines.contains("glass variants: none"))
        XCTAssertTrue(lines.contains("glass panels: none"))
    }
}
