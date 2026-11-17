import XCTest
@testable import HoldSpeakCore

/// HS-45: failures outside the cloud clients that used to look like silence.
final class PipelineFailureTests: XCTestCase {
    private func assertNoFallback(_ failure: TranscriptionFailure, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(failure.isOffline, file: file, line: line)
        XCTAssertFalse(failure.warrantsModelFallback, file: file, line: line)
        XCTAssertEqual(failure.displaySeconds, 4, file: file, line: line)
    }

    // MARK: 1. Recorder start errors

    func test_recorderErrors_mapToHUDFailures() {
        XCTAssertEqual(TranscriptionFailure.recorder(AudioRecorderError.lidClosedNoMic), .lidClosedNoMic)
        XCTAssertEqual(TranscriptionFailure.recorder(AudioRecorderError.noInputDevice), .noInputDevice)
        XCTAssertEqual(TranscriptionFailure.recorder(AudioRecorderError.invalidInputFormat(sampleRate: 0, channels: 0)),
                       .micCouldNotStart)
        XCTAssertEqual(TranscriptionFailure.recorder(AudioRecorderError.coreAudio(operation: "start", status: -10875)),
                       .micCouldNotStart)
        XCTAssertEqual(TranscriptionFailure.recorder(AudioRecorderError.stalled(operation: "start")), .micStalled)
        XCTAssertEqual(TranscriptionFailure.recorder(CocoaError(.fileNoSuchFile)), .micCouldNotStart)
    }

    func test_recorderFailures_strings() {
        XCTAssertEqual(TranscriptionFailure.noInputDevice.title, "No microphone found")
        XCTAssertEqual(TranscriptionFailure.noInputDevice.body, "Connect one, or pick one in Preferences → Audio")
        XCTAssertEqual(TranscriptionFailure.micCouldNotStart.title, "Microphone couldn't start")
        XCTAssertEqual(TranscriptionFailure.micCouldNotStart.body, "Try again, or pick another in Preferences → Audio")
        XCTAssertEqual(TranscriptionFailure.micStalled.title, "Microphone not responding")
        XCTAssertEqual(TranscriptionFailure.micStalled.body, "Audio was reset — try again")
    }

    func test_recorderFailures_flags() {
        assertNoFallback(.noInputDevice)
        assertNoFallback(.micCouldNotStart)
        assertNoFallback(.micStalled)
    }

    func test_lidClosedNoMic_unchanged() {
        XCTAssertEqual(TranscriptionFailure.lidClosedNoMic.title, "Lid closed · built-in mic is off")
        XCTAssertEqual(TranscriptionFailure.lidClosedNoMic.body, "Connect a wired mic")
    }

    // MARK: 2. Local engine errors

    func test_engineFailed_strings() {
        XCTAssertEqual(TranscriptionFailure.engineFailed(.whisper).title, "Whisper couldn't transcribe")
        XCTAssertEqual(TranscriptionFailure.engineFailed(.parakeet).title, "Parakeet couldn't transcribe")
        XCTAssertEqual(TranscriptionFailure.engineFailed(.whisper).body, "Try again; details are in the log")
    }

    func test_engineFailed_flags() {
        assertNoFallback(.engineFailed(.whisper))
        assertNoFallback(.engineFailed(.parakeet))
    }

    // MARK: 3. No audio captured

    func test_noAudioCaptured_stringsAndFlags() {
        XCTAssertEqual(TranscriptionFailure.noAudioCaptured.title, "No audio captured")
        XCTAssertEqual(TranscriptionFailure.noAudioCaptured.body, "The mic didn't start in time — try again")
        assertNoFallback(.noAudioCaptured)
    }
}
