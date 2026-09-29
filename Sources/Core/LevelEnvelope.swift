import Foundation

/// Asymmetric one-pole follower for the HUD level meter: rises with the `attack`
/// time constant, falls with the slower `release` one, so speech reads as a
/// smooth swell instead of per-buffer jitter. Frame-rate independent.
public struct LevelEnvelope {
    public var attack: Double
    public var release: Double
    public private(set) var value: Double = 0

    /// - Parameters: time constants in seconds.
    public init(attack: Double, release: Double) {
        self.attack = attack
        self.release = release
    }

    @discardableResult
    public mutating func step(toward target: Double, dt: Double) -> Double {
        let tau = target > value ? attack : release
        value += (target - value) * (1 - exp(-dt / max(tau, 1e-4)))
        return value
    }

    public mutating func reset() { value = 0 }

    /// Maps a linear RMS amplitude onto 0...1 across a -55...-23 dBFS window.
    public static func normalize(rms: Float) -> Double {
        let db = 20 * log10(Double(max(rms, 1e-6)))
        return min(1, max(0, (db + 55) / 32))
    }
}
