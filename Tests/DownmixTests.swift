import XCTest
@testable import HoldSpeakCore

/// Downmix must not average silent inputs in: a 2-input interface with the mic on
/// input 1 and nothing on input 2 used to lose 6 dB before the VAD.
final class DownmixTests: XCTestCase {
    private func mix(_ channels: [[Float]]) -> [Float] {
        let frames = channels[0].count
        let planes = channels.map { ch -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            p.initialize(from: ch, count: frames)
            return p
        }
        defer { planes.forEach { $0.deallocate() } }
        var out = [Float](repeating: .nan, count: frames)
        planes.withUnsafeBufferPointer { table in
            out.withUnsafeMutableBufferPointer { dst in
                CaptureDSP.downmix(table.baseAddress!, channelCount: channels.count, frames: frames,
                                   into: dst.baseAddress!)
            }
        }
        return out
    }

    private func sine(_ amplitude: Float, frames: Int = 1600, period: Float = 37) -> [Float] {
        (0..<frames).map { amplitude * sin(2 * .pi * Float($0) / period) }
    }

    private func rms(_ x: [Float]) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    /// Deterministic noise in [-amplitude, amplitude].
    private func noise(_ amplitude: Float, frames: Int = 1600) -> [Float] {
        var state: UInt32 = 0x1234_5678
        return (0..<frames).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(state >> 8) / Float(1 << 24) * 2 - 1)
        }
    }

    func testMonoPassesThrough() {
        let s = sine(0.3)
        XCTAssertEqual(mix([s]), s)
    }

    func testTwoEqualChannelsKeepTheirLevel() {
        let s = sine(0.3)
        XCTAssertEqual(mix([s, s]), s)
    }

    func testSignalPlusDigitalSilenceKeepsSignalLevel() {
        let s = sine(0.3)
        let out = mix([s, [Float](repeating: 0, count: s.count)])
        XCTAssertEqual(out, s, "silent input must not halve the signal")
        XCTAssertEqual(rms(out), rms(s), accuracy: 1e-6)
    }

    func testSilenceFirstThenSignal() {
        let s = sine(0.3)
        XCTAssertEqual(mix([[Float](repeating: 0, count: s.count), s]), s)
    }

    func testNoiseFortyDecibelsDownIsDropped() {
        let s = sine(0.3)
        let n = noise(1)
        let scale = rms(s) / 100 / rms(n)  // −40 dB relative to the signal
        let quiet = n.map { $0 * scale }
        XCTAssertEqual(mix([s, quiet]), s)
        XCTAssertEqual(mix([quiet, s]), s)
    }

    func testFourChannelsWithOneLive() {
        let s = sine(0.2)
        let zero = [Float](repeating: 0, count: s.count)
        XCTAssertEqual(mix([zero, zero, s, zero]), s)
    }

    func testChannelsAboveThresholdAreAveraged() {
        // −6 dB is well above the −20 dB cut: both inputs count.
        let a = sine(0.4)
        let b = sine(0.2, period: 53)
        let out = mix([a, b])
        for i in out.indices { XCTAssertEqual(out[i], (a[i] + b[i]) / 2, accuracy: 1e-7) }
    }

    func testThresholdIsTwentyDecibelsBelowTheLoudest() {
        let a = [Float](repeating: 1, count: 100)
        let justAbove = [Float](repeating: 0.112, count: 100)  // −19 dB: averaged in
        for v in mix([a, justAbove]) { XCTAssertEqual(v, 0.556, accuracy: 1e-6) }
        let justBelow = [Float](repeating: 0.089, count: 100)  // −21 dB: left out
        XCTAssertEqual(mix([a, justBelow]), a)
    }

    func testAllSilentGivesZeros() {
        let zero = [Float](repeating: 0, count: 480)
        XCTAssertEqual(mix([zero, zero, zero]), zero)
    }
}
