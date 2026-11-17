import XCTest
@testable import HoldSpeakCore

/// A device-level input mute is lifted for a hold (AirPods left muted after a call
/// recorded nothing), but not while another app is capturing from that device: the
/// user muted themselves in a meeting and the call must not hear the dictation.
final class MuteDecisionTests: XCTestCase {
    func testLiftsOnlyAMuteNobodyElseIsUsing() {
        XCTAssertTrue(InputDevice.shouldLiftMute(muted: true, capturingElsewhere: false))
        XCTAssertFalse(InputDevice.shouldLiftMute(muted: true, capturingElsewhere: true))
    }

    func testUnknownUseKeepsTheStaleMuteFix() {
        XCTAssertTrue(InputDevice.shouldLiftMute(muted: true, capturingElsewhere: nil))
    }

    func testNothingToLiftWhenNotMutedOrNoMuteControl() {
        for elsewhere: Bool? in [true, false, nil] {
            XCTAssertFalse(InputDevice.shouldLiftMute(muted: false, capturingElsewhere: elsewhere))
            XCTAssertFalse(InputDevice.shouldLiftMute(muted: nil, capturingElsewhere: elsewhere))
        }
    }

    // MARK: - Is another process capturing?

    private func elsewhere(process: Bool?, somewhere: Bool?, here: Bool? = false, hasOutput: Bool) -> Bool? {
        InputDevice.capturingElsewhere(otherProcessCapturing: process, runningSomewhere: somewhere,
                                       runningHere: here, hasOutput: hasOutput)
    }

    func testProcessObjectsAnswerForAnyDevice() {
        // macOS 14+: per-process input state, our own process already excluded.
        XCTAssertEqual(elsewhere(process: true, somewhere: true, hasOutput: true), true)
        XCTAssertEqual(elsewhere(process: false, somewhere: true, hasOutput: true), false,
                       "AirPods playing music run the device, but nobody captures from it")
        XCTAssertEqual(elsewhere(process: false, somewhere: false, hasOutput: false), false)
    }

    func testRunningInputOnlyDeviceMeansSomeoneCaptures() {
        // An input-only device runs only for capture, e.g. inside another app's aggregate,
        // which the process objects list under the aggregate's ID.
        XCTAssertEqual(elsewhere(process: false, somewhere: true, hasOutput: false), true)
        XCTAssertEqual(elsewhere(process: nil, somewhere: true, hasOutput: false), true)
        XCTAssertEqual(elsewhere(process: nil, somewhere: false, hasOutput: false), false)
    }

    func testOurOwnIODoesNotCount() {
        XCTAssertEqual(elsewhere(process: nil, somewhere: true, here: true, hasOutput: false), nil)
        XCTAssertEqual(elsewhere(process: false, somewhere: true, here: true, hasOutput: false), false)
    }

    func testDeviceWithOutputsIsAmbiguousWithoutProcessObjects() {
        // macOS 13: IsRunningSomewhere is device-wide, so playback alone sets it.
        XCTAssertNil(elsewhere(process: nil, somewhere: true, hasOutput: true))
        XCTAssertNil(elsewhere(process: nil, somewhere: nil, hasOutput: false))
    }

    func testIdleDeviceIsNotCaptured() {
        XCTAssertEqual(elsewhere(process: nil, somewhere: false, hasOutput: true), false)
    }
}
