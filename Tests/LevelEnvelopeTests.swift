import XCTest
@testable import HoldSpeakCore

final class LevelEnvelopeTests: XCTestCase {
    private func run(_ env: inout LevelEnvelope, to target: Double, seconds: Double) {
        let dt = 1.0 / 60
        for _ in 0..<Int(seconds / dt) { env.step(toward: target, dt: dt) }
    }

    func testAttackIsFasterThanRelease() {
        var env = LevelEnvelope(attack: 0.06, release: 0.22)
        run(&env, to: 1, seconds: 0.1)
        let risen = env.value
        run(&env, to: 1, seconds: 1)
        run(&env, to: 0, seconds: 0.1)
        let fallen = 1 - env.value
        XCTAssertGreaterThan(risen, 0.75)
        XCTAssertLessThan(fallen, 0.45)
    }

    func testFrameRateIndependent() {
        var a = LevelEnvelope(attack: 0.06, release: 0.22)
        var b = a
        for _ in 0..<30 { a.step(toward: 1, dt: 1.0 / 30) }
        for _ in 0..<120 { b.step(toward: 1, dt: 1.0 / 120) }
        XCTAssertEqual(a.value, b.value, accuracy: 1e-9)
    }

    func testNormalizeClampsToUnitRange() {
        XCTAssertEqual(LevelEnvelope.normalize(rms: 0), 0)
        XCTAssertEqual(LevelEnvelope.normalize(rms: 1), 1)
        XCTAssertEqual(LevelEnvelope.normalize(rms: 0.01), (-40.0 + 55) / 32, accuracy: 1e-6)
    }
}
