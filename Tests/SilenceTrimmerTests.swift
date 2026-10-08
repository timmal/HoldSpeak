import XCTest
@testable import HoldSpeakCore

final class SilenceTrimmerTests: XCTestCase {
    private let vad = SilenceTrimmer()

    /// 16 kHz samples: `ms` milliseconds of a 440 Hz tone at the given amplitude.
    private func tone(ms: Int, amplitude: Float = 0.3) -> [Float] {
        let count = ms * 16
        return (0..<count).map { amplitude * sin(2 * .pi * 440 * Float($0) / 16_000) }
    }

    private func silence(ms: Int) -> [Float] {
        [Float](repeating: 0, count: ms * 16)
    }

    /// Deterministic white noise, uniform in ±amplitude (rms ≈ amplitude / √3).
    private func noise(ms: Int, amplitude: Float, seed: UInt64 = 1) -> [Float] {
        var state = seed
        return (0..<ms * 16).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(state >> 40) / Float(1 << 24)     // 0..<1
            return amplitude * (unit * 2 - 1)
        }
    }

    private func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map { $0 + $1 }
    }

    /// Built-in mic at a typical input volume: rms ≈ 0.004–0.009 with nobody talking.
    func test_roomNoiseOnlyReturnsNil() {
        XCTAssertNil(vad.trimSilence(noise(ms: 1000, amplitude: 0.012)))
    }

    func test_risingRoomNoiseReturnsNil() {
        let input = noise(ms: 300, amplitude: 0.007, seed: 1)
            + noise(ms: 300, amplitude: 0.010, seed: 2)
            + noise(ms: 400, amplitude: 0.016, seed: 3)
        XCTAssertNil(vad.trimSilence(input))
    }

    /// Hotkey press and release clicks picked up by the mic, no speech.
    func test_keyClicksInRoomNoiseReturnNil() {
        let clicks = silence(ms: 50) + noise(ms: 30, amplitude: 0.15, seed: 7)
            + silence(ms: 800) + noise(ms: 30, amplitude: 0.15, seed: 8) + silence(ms: 90)
        XCTAssertNil(vad.trimSilence(mix(noise(ms: 1000, amplitude: 0.01), clicks)))
    }

    func test_shortWordOverRoomNoiseIsKept() {
        let word = silence(ms: 300) + tone(ms: 180, amplitude: 0.06) + silence(ms: 320)
        XCTAssertNotNil(vad.trimSilence(mix(noise(ms: 800, amplitude: 0.01), word)))
    }

    func test_pureSilenceReturnsNil() {
        XCTAssertNil(vad.trimSilence(silence(ms: 2000)))
    }

    func test_bufferShorterThanOneWindowReturnsNil() {
        XCTAssertNil(vad.trimSilence(tone(ms: 20)))
    }

    func test_blipShorterThanMinDurationReturnsNil() {
        var d = SilenceTrimmer()
        d.paddingMs = 0
        XCTAssertNil(d.trimSilence(silence(ms: 500) + tone(ms: 60) + silence(ms: 500)))
    }

    func test_trimsSurroundingSilenceKeepingPadding() {
        let input = silence(ms: 1000) + tone(ms: 600) + silence(ms: 1000)
        let out = vad.trimSilence(input)
        XCTAssertNotNil(out)
        let outMs = out!.count / 16
        // Expect roughly speech + 2×250ms padding, never the full 2.6s input.
        XCTAssertGreaterThanOrEqual(outMs, 600)
        XCTAssertLessThanOrEqual(outMs, 600 + 2 * 250 + 60)
    }

    func test_speechWithNoSurroundingSilencePassesThrough() {
        let input = tone(ms: 800)
        let out = vad.trimSilence(input)
        XCTAssertNotNil(out)
        XCTAssertEqual(out!.count / 16, 800, accuracy: 40)
    }

    func test_quietSpeechAboveFloorIsKept() {
        let input = silence(ms: 300) + tone(ms: 500, amplitude: 0.005) + silence(ms: 300)
        XCTAssertNotNil(vad.trimSilence(input))
    }

    private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) != \(b) ± \(accuracy)",
                                 file: file, line: line)
    }
}
