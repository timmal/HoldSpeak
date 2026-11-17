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

    // MARK: - No signal at all

    func testExactZeroTakeOfRealLengthHasNoSignal() {
        XCTAssertTrue(SilenceTrimmer.hasNoSignal(silence(ms: 1461)))
        XCTAssertTrue(SilenceTrimmer.hasNoSignal(silence(ms: SilenceTrimmer.noSignalMinMs)))
        XCTAssertTrue(SilenceTrimmer.hasNoSignal([Float](repeating: -0.0, count: 16_000)))
    }

    func testShortZeroTakeIsNotNoSignal() {
        // A mic can hand over zeros for its first moments, so a short hold proves nothing.
        XCTAssertFalse(SilenceTrimmer.hasNoSignal(silence(ms: SilenceTrimmer.noSignalMinMs - 1)))
        XCTAssertFalse(SilenceTrimmer.hasNoSignal([]))
    }

    func testAnyNonZeroSampleIsASignal() {
        var almost = silence(ms: 1500)
        almost[almost.count - 1] = 1e-7
        XCTAssertFalse(SilenceTrimmer.hasNoSignal(almost))
    }

    func testOrdinaryQuietClipsAreNotNoSignal() {
        // Room noise far below anything the VAD keeps: still a live mic.
        let quiet = noise(ms: 1500, amplitude: 0.0001)
        XCTAssertNil(vad.trimSilence(quiet))
        XCTAssertFalse(SilenceTrimmer.hasNoSignal(quiet))
        XCTAssertFalse(SilenceTrimmer.hasNoSignal(noise(ms: 1500, amplitude: 0.007)))
    }


    /// Quiet speech on the built-in mic at a low input volume: syllables at 4.5 Hz
    /// (sin² envelope) on a 140 Hz voiced carrier, loudness jittered ±35% every
    /// 20 ms. Each syllable's 30-ms RMS crosses the speech threshold for only
    /// 30–60 ms, but stays well above the noise floor for 100+ ms.
    private func quietSyllables(ms: Int, level: Float, seed: UInt64) -> [Float] {
        var state = seed
        func unit() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
        let count = ms * 16, knot = 320
        let gains = (0...count / knot + 1).map { _ in 0.65 + 0.7 * unit() }
        let norm: Float = ((1 + 0.36 + 0.16) / 2).squareRoot()     // carrier rms → 1
        return (0..<count).map { i in
            let t = Float(i) / 16_000
            let f = Float(i % knot) / Float(knot)
            let gain = gains[i / knot] * (1 - f) + gains[i / knot + 1] * f
            let envelope = pow(sin(.pi * 4.5 * t), 2)
            let carrier = sin(2 * .pi * 140 * t) + 0.6 * sin(2 * .pi * 280 * t) + 0.4 * sin(2 * .pi * 420 * t)
            return level * envelope * gain * carrier / norm
        }
    }

    /// Logged HS-22 drops: noise≈0.004–0.007, peak≈0.02–0.03, voicedRun 30–60 ms over seconds of speech.
    private func quietSpeechClip(roomNoise: Float, level: Float, seed: UInt64) -> [Float] {
        let speech = silence(ms: 300) + quietSyllables(ms: 2400, level: level, seed: seed) + silence(ms: 300)
        return mix(noise(ms: 3000, amplitude: roomNoise, seed: seed + 100), speech)
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

    func test_quietSyllablesOverRoomNoiseAreKept() {
        for seed: UInt64 in 1...6 {
            let input = quietSpeechClip(roomNoise: 0.008, level: 0.019, seed: seed)   // noise rms ≈ 0.0046
            XCTAssertNotNil(vad.trimSilence(input), "seed \(seed): \(vad.stats(input))")
        }
    }

    func test_quietSyllablesInNoisierRoomAreKept() {
        for seed: UInt64 in 1...6 {
            let input = quietSpeechClip(roomNoise: 0.0113, level: 0.02, seed: seed)   // noise rms ≈ 0.0065
            XCTAssertNotNil(vad.trimSilence(input), "seed \(seed): \(vad.stats(input))")
        }
    }

    /// Typing while the hotkey is held: separate 30 ms clicks never add up to a syllable.
    func test_keyClicksEvery150msReturnNil() {
        var clicks = silence(ms: 500)
        for i: UInt64 in 0..<6 { clicks += noise(ms: 30, amplitude: 0.15, seed: 20 + i) + silence(ms: 120) }
        clicks += silence(ms: 2000 - clicks.count / 16)
        XCTAssertNil(vad.trimSilence(mix(noise(ms: 2000, amplitude: 0.008), clicks)))
    }

    /// Room noise drifting to ~2.3× its floor must not stretch a key click into a voiced run.
    func test_keyClickWhileRoomNoiseDriftsReturnsNil() {
        var input = noise(ms: 1000, amplitude: 0.0075, seed: 31) + noise(ms: 1000, amplitude: 0.017, seed: 32)
        for (i, v) in noise(ms: 30, amplitude: 0.15, seed: 33).enumerated() { input[1500 * 16 + i] += v }
        XCTAssertNil(vad.trimSilence(input))
    }

    /// Logged silent presses: a rustle up to ~3.5× the noise floor, nothing crosses 4×.
    func test_softRustleBelowSpeechThresholdReturnsNil() {
        let rustle = silence(ms: 800) + noise(ms: 400, amplitude: 0.026, seed: 41) + silence(ms: 800)
        XCTAssertNil(vad.trimSilence(mix(noise(ms: 2000, amplitude: 0.0075), rustle)))
    }

    func test_statsReportTotalVoicedTime() {
        let input = silence(ms: 300) + tone(ms: 180, amplitude: 0.06) + silence(ms: 300)
            + tone(ms: 90, amplitude: 0.06) + silence(ms: 300)
        let stats = vad.stats(mix(noise(ms: 1170, amplitude: 0.01), input))
        XCTAssertEqual(stats.voicedMs, 270, accuracy: 60)
        XCTAssertTrue(stats.description.contains("voiced=\(stats.voicedMs)ms"), stats.description)
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

    // MARK: - One loud transient (HS-36)

    /// Built-in mic room noise, rms ≈ 0.005.
    private func roomNoise(ms: Int, seed: UInt64 = 51) -> [Float] {
        noise(ms: ms, amplitude: 0.005 * Float(3).squareRoot(), seed: seed)
    }

    /// Quiet speech, rms ≈ 0.03: well above the gate's speech threshold
    /// (min(4 × 0.005, 0.02) = 0.02), about ten times below a click.
    private func quietSpeech(ms: Int) -> [Float] {
        tone(ms: ms, amplitude: 0.03 * Float(2).squareRoot())
    }

    /// A 40 ms click at rms ≈ 0.35 (the hotkey next to the built-in mic, a cough),
    /// added at `atMs`; window-aligned so it spans 2 windows, short of a voiced run.
    /// Its peak puts `relative * peak` (0.035) above every speech window.
    private func addClick(_ input: inout [Float], atMs: Int, seed: UInt64 = 52) {
        for (i, v) in noise(ms: 40, amplitude: 0.35 * Float(3).squareRoot(), seed: seed).enumerated() {
            input[atMs * 16 + i] += v
        }
    }

    /// 800 ms room noise, 2500 ms quiet speech, 800 ms room noise.
    private let speechStartMs = 800, speechEndMs = 3300, clipMs = 4100

    private func quietSpeechWithClick(atMs: Int?) -> [Float] {
        var input = mix(roomNoise(ms: clipMs),
                        silence(ms: speechStartMs) + quietSpeech(ms: speechEndMs - speechStartMs)
                            + silence(ms: clipMs - speechEndMs))
        if let atMs { addClick(&input, atMs: atMs) }
        return input
    }

    /// Where `out` starts in `input`, in ms (trimSilence returns a window-aligned slice).
    private func offsetMs(of out: [Float], in input: [Float]) -> Int? {
        stride(from: 0, through: input.count - out.count, by: vad.windowSamples)
            .first { input[$0 ..< $0 + out.count].elementsEqual(out) }
            .map { $0 / 16 }
    }

    /// The take must survive and hold the whole speech span; `expected`, if given,
    /// is the span ± 250 ms padding, widened to reach the click.
    private func assertKeepsSpeech(_ input: [Float], expectedMs: ClosedRange<Int>? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard let out = vad.trimSilence(input) else {
            return XCTFail("dropped: \(vad.stats(input))", file: file, line: line)
        }
        guard let start = offsetMs(of: out, in: input) else {
            return XCTFail("output is not a slice of the input", file: file, line: line)
        }
        let end = start + out.count / 16
        XCTAssertLessThanOrEqual(start, speechStartMs, "starts at \(start) ms", file: file, line: line)
        XCTAssertGreaterThanOrEqual(end, speechEndMs, "ends at \(end) ms", file: file, line: line)
        guard let expectedMs else { return }
        XCTAssertEqual(start, expectedMs.lowerBound, accuracy: 30, file: file, line: line)
        XCTAssertEqual(end, expectedMs.upperBound, accuracy: 30, file: file, line: line)
    }

    /// Baseline: `relative * peak` (0.003) is below the room noise, so the whole clip is kept.
    func test_quietSpeechWithoutClickIsKept() {
        assertKeepsSpeech(quietSpeechWithClick(atMs: nil))
    }

    func test_clickAtStartDoesNotDropQuietSpeech() {
        assertKeepsSpeech(quietSpeechWithClick(atMs: 30), expectedMs: 0 ... speechEndMs + 250)
    }

    func test_clickInMiddleDoesNotDropQuietSpeech() {
        assertKeepsSpeech(quietSpeechWithClick(atMs: 2040),
                          expectedMs: speechStartMs - 250 ... speechEndMs + 250)
    }

    func test_clickAtEndDoesNotDropQuietSpeech() {
        assertKeepsSpeech(quietSpeechWithClick(atMs: clipMs - 80),
                          expectedMs: speechStartMs - 250 ... clipMs)
    }

    func test_loudClickAloneInRoomNoiseReturnsNil() {
        for atMs in [30, 2040, clipMs - 80] {
            var input = roomNoise(ms: clipMs)
            addClick(&input, atMs: atMs)
            XCTAssertNil(vad.trimSilence(input), "click at \(atMs) ms: \(vad.stats(input))")
        }
    }

    /// Loud speech with ordinary pauses: leading/trailing room noise is still cut to the padding.
    func test_loudSpeechWithPausesTrimsToPadding() {
        let speech = tone(ms: 600) + silence(ms: 300) + tone(ms: 500) + silence(ms: 200) + tone(ms: 400)
        let input = mix(roomNoise(ms: 4000), silence(ms: 1000) + speech + silence(ms: 1000))
        guard let out = vad.trimSilence(input) else { return XCTFail("dropped: \(vad.stats(input))") }
        XCTAssertEqual(offsetMs(of: out, in: input) ?? -1, 1000 - 250, accuracy: 30)
        XCTAssertEqual(out.count / 16, 2000 + 2 * 250, accuracy: 60)
    }

    private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) != \(b) ± \(accuracy)",
                                 file: file, line: line)
    }
}
