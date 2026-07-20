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

final class BackgroundActivationDecisionTests: XCTestCase {
    func testSelectsFirstEligibleOtherRegularLayerZeroWindowWithID() {
        let candidates = [
            candidate(pid: 10, windowID: 101),
            candidate(pid: 20, windowID: 201),
            candidate(pid: 30, windowID: 301, layer: 1),
            candidate(pid: 31, windowID: 311, isRegular: false),
            candidate(pid: 32, windowID: 321, isTrusted: false),
            candidate(pid: 33, windowID: nil),
            candidate(pid: 34, windowID: 0),
            candidate(pid: 40, windowID: 401),
            candidate(pid: 41, windowID: 411)
        ]

        XCTAssertEqual(
            BackgroundActivationDecision.target(
                frontToBack: candidates,
                excludingPID: 10,
                dockPID: 20
            ),
            BackgroundActivationTarget(pid: 40, cgWindowID: 401)
        )
    }

    func testReturnsNilWhenThereIsNoEligibleBackgroundWindow() {
        let candidates = [
            candidate(pid: 10, windowID: 101),
            candidate(pid: 20, windowID: 201),
            candidate(pid: 30, windowID: 301, isRegular: false),
            candidate(pid: 31, windowID: 311, isTrusted: false),
            candidate(pid: 32, windowID: nil),
            candidate(pid: 33, windowID: 0)
        ]

        XCTAssertNil(
            BackgroundActivationDecision.target(
                frontToBack: candidates,
                excludingPID: 10,
                dockPID: 20
            )
        )
    }

    func testFocusedIdentityUsesMatchingWindowIDsBeforeElementEquality() {
        XCTAssertTrue(
            BackgroundActivationDecision.targetWindowIsFocused(
                isTargetAppActive: true,
                targetWindowID: 101,
                focusedWindowID: 101,
                elementsEqual: false
            )
        )
        XCTAssertFalse(
            BackgroundActivationDecision.targetWindowIsFocused(
                isTargetAppActive: true,
                targetWindowID: 101,
                focusedWindowID: 102,
                elementsEqual: true
            )
        )
    }

    func testFocusedIdentityFallsBackToElementEqualityWhenAnIDIsUnavailable() {
        XCTAssertTrue(
            BackgroundActivationDecision.targetWindowIsFocused(
                isTargetAppActive: true,
                targetWindowID: 101,
                focusedWindowID: nil,
                elementsEqual: true
            )
        )
        XCTAssertFalse(
            BackgroundActivationDecision.targetWindowIsFocused(
                isTargetAppActive: true,
                targetWindowID: nil,
                focusedWindowID: nil,
                elementsEqual: false
            )
        )
    }

    func testInactiveTargetAppNeverHandsOffFocus() {
        XCTAssertFalse(
            BackgroundActivationDecision.targetWindowIsFocused(
                isTargetAppActive: false,
                targetWindowID: 101,
                focusedWindowID: 101,
                elementsEqual: true
            )
        )
    }

    func testTrustedWindowIdentitiesUsesOrderedConcreteRecordsRegardlessOfStaleStatus() {
        let active = record(id: "active", pid: 40, windowID: 401, status: .active)
        let inactive = record(id: "inactive", pid: 41, windowID: 411, status: .inactive)
        let minimized = record(id: "minimized", pid: 42, windowID: 421, status: .minimized)
        let hidden = record(id: "hidden", pid: 43, windowID: 431, status: .hidden)
        let disappeared = record(id: "disappeared", pid: 44, windowID: 441, status: .disappeared)
        let closed = record(id: "closed", pid: 45, windowID: 451, status: .closedPending)
        let fallback = record(id: "fallback", pid: 46, windowID: nil, status: .inactive)
        let zero = record(id: "zero", pid: 47, windowID: 0, status: .inactive)
        let unordered = record(id: "unordered", pid: 48, windowID: 481, status: .inactive)
        let snapshot = DockSnapshot(
            windows: [
                active.id: active,
                inactive.id: inactive,
                minimized.id: minimized,
                hidden.id: hidden,
                disappeared.id: disappeared,
                closed.id: closed,
                fallback.id: fallback,
                zero.id: zero,
                unordered.id: unordered
            ],
            orderedWindowIDs: [
                active.id,
                inactive.id,
                minimized.id,
                hidden.id,
                disappeared.id,
                closed.id,
                fallback.id,
                zero.id
            ]
        )

        XCTAssertEqual(
            BackgroundActivationDecision.trustedWindowIdentities(in: snapshot),
            [
                BackgroundWindowIdentity(pid: 40, cgWindowID: 401),
                BackgroundWindowIdentity(pid: 41, cgWindowID: 411),
                BackgroundWindowIdentity(pid: 42, cgWindowID: 421),
                BackgroundWindowIdentity(pid: 43, cgWindowID: 431),
                BackgroundWindowIdentity(pid: 44, cgWindowID: 441)
            ]
        )
    }

    private func candidate(
        pid: pid_t,
        windowID: CGWindowID?,
        layer: Int = 0,
        isRegular: Bool = true,
        isTrusted: Bool = true
    ) -> BackgroundWindowCandidate {
        BackgroundWindowCandidate(
            pid: pid,
            cgWindowID: windowID,
            layer: layer,
            isRegularApplication: isRegular,
            isTrustedWindow: isTrusted
        )
    }

    private func record(
        id rawID: String,
        pid: pid_t,
        windowID: CGWindowID?,
        status: WindowStatus
    ) -> WindowRecord {
        let id = WindowID(rawValue: rawID)
        return WindowRecord(
            id: id,
            appID: AppID(rawValue: "app-\(pid)"),
            pid: pid,
            bundleIdentifier: "example.\(pid)",
            title: rawID,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            status: status,
            cgWindowID: windowID
        )
    }
}

final class BackgroundFocusHandoffTests: XCTestCase {
    private let target = BackgroundActivationTarget(pid: 40, cgWindowID: 401)

    func testCarbonPreSwitchRunsBeforeSkyLightAndRaise() {
        var calls: [String] = []

        let outcome = BackgroundFocusHandoff.perform(
            target: target,
            skyLightFocus: { pid, windowID in
                calls.append("skylight:\(pid):\(windowID)")
                return true
            },
            axRaise: {
                calls.append("raise")
                return true
            },
            carbonSwitch: { pid in
                calls.append("carbon:\(pid)")
                return true
            }
        )

        XCTAssertEqual(
            outcome,
            BackgroundFocusHandoff.Outcome(
                carbonSubmitted: true,
                skyLightPosted: true,
                raise: .succeeded
            )
        )
        XCTAssertTrue(outcome.focusRequestSubmitted)
        XCTAssertEqual(calls, ["carbon:40", "skylight:40:401", "raise"])
    }

    func testRaiseFailureDoesNotDiscardEitherSubmittedFocusRequest() {
        var calls: [String] = []

        let outcome = BackgroundFocusHandoff.perform(
            target: target,
            skyLightFocus: { _, _ in
                calls.append("skylight")
                return true
            },
            axRaise: {
                calls.append("raise")
                return false
            },
            carbonSwitch: { _ in
                calls.append("carbon")
                return true
            }
        )

        XCTAssertEqual(
            outcome,
            BackgroundFocusHandoff.Outcome(
                carbonSubmitted: true,
                skyLightPosted: true,
                raise: .failed
            )
        )
        XCTAssertTrue(outcome.focusRequestSubmitted)
        XCTAssertEqual(calls, ["carbon", "skylight", "raise"])
    }

    func testMissingRaiseTargetDoesNotPreventSkyLightSubmission() {
        var calls: [String] = []

        let outcome = BackgroundFocusHandoff.perform(
            target: target,
            skyLightFocus: { _, _ in
                calls.append("skylight")
                return true
            },
            axRaise: nil,
            carbonSwitch: { _ in
                calls.append("carbon")
                return true
            }
        )

        XCTAssertEqual(
            outcome,
            BackgroundFocusHandoff.Outcome(
                carbonSubmitted: true,
                skyLightPosted: true,
                raise: .unavailable
            )
        )
        XCTAssertTrue(outcome.focusRequestSubmitted)
        XCTAssertEqual(calls, ["carbon", "skylight"])
    }

    func testSkyLightUnavailableKeepsCarbonPreSwitchResult() {
        var calls: [String] = []

        let outcome = BackgroundFocusHandoff.perform(
            target: target,
            skyLightFocus: { pid, windowID in
                calls.append("skylight:\(pid):\(windowID)")
                return false
            },
            axRaise: {
                calls.append("raise")
                return true
            },
            carbonSwitch: { pid in
                calls.append("carbon:\(pid)")
                return true
            }
        )

        XCTAssertEqual(
            outcome,
            BackgroundFocusHandoff.Outcome(
                carbonSubmitted: true,
                skyLightPosted: false,
                raise: .notAttempted
            )
        )
        XCTAssertTrue(outcome.focusRequestSubmitted)
        XCTAssertEqual(calls, ["carbon:40", "skylight:40:401"])
    }

    func testFailedCarbonStillUsesSkyLightWhenAvailable() {
        let outcome = BackgroundFocusHandoff.perform(
            target: target,
            skyLightFocus: { _, _ in true },
            axRaise: { false },
            carbonSwitch: { _ in false }
        )

        XCTAssertEqual(
            outcome,
            BackgroundFocusHandoff.Outcome(
                carbonSubmitted: false,
                skyLightPosted: true,
                raise: .failed
            )
        )
        XCTAssertTrue(outcome.focusRequestSubmitted)
    }

    func testBothUnavailableReportsNoSubmittedFocusRequest() {
        let outcome = BackgroundFocusHandoff.perform(
            target: target,
            skyLightFocus: { _, _ in false },
            axRaise: { true },
            carbonSwitch: { _ in false }
        )

        XCTAssertEqual(
            outcome,
            BackgroundFocusHandoff.Outcome(
                carbonSubmitted: false,
                skyLightPosted: false,
                raise: .notAttempted
            )
        )
        XCTAssertFalse(outcome.focusRequestSubmitted)
    }
}
