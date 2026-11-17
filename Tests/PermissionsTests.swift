import AVFoundation
import XCTest
@testable import HoldSpeakCore

final class PermissionsTests: XCTestCase {
    /// macOS shows the microphone prompt only while the choice is undecided; afterwards
    /// `requestAccess` answers false without a prompt, so the row opens System Settings.
    func test_microphoneRowPromptsOnlyWhileUndecided() {
        XCTAssertEqual(PermissionsManager.microphoneAction(for: .notDetermined), .prompt)
        XCTAssertEqual(PermissionsManager.microphoneAction(for: .denied), .openSettings)
        XCTAssertEqual(PermissionsManager.microphoneAction(for: .restricted), .openSettings)
    }

    /// Without Accessibility every insertion ends in "no focus"; the HUD names the cause.
    func test_noFocusWithoutAccessibilityNamesThePermission() {
        let off = NotTypedReason.noFocus(accessibilityTrusted: false)
        XCTAssertEqual(off, .accessibilityOff)
        XCTAssertEqual(off.title, "Accessibility is off")
        XCTAssertEqual(off.detail, "Turn HoldSpeak on in Privacy & Security → Accessibility")
    }

    func test_noFocusWithAccessibilityStaysNoFocusedInput() {
        let reason = NotTypedReason.noFocus(accessibilityTrusted: true)
        XCTAssertEqual(reason, .noFocusedInput)
        XCTAssertEqual(reason.title, "No focused input")
        XCTAssertEqual(reason.detail, "Transcript saved to history")
        XCTAssertEqual(NotTypedReason.secureField.title, "Skipped password field")
        XCTAssertEqual(NotTypedReason.secureField.detail, "Transcript saved to history")
    }
}
