import Foundation

/// Energy-based VAD over 16 kHz mono float samples: trims leading/trailing
/// silence and rejects buffers that are too short, almost entirely silent, or
/// only room noise and key clicks.
public struct SilenceTrimmer {
    public var windowSamples: Int = 480          // 30 ms at 16 kHz
    public var floor: Float = 0.0008
    public var relative: Float = 0.10            // threshold = max(floor, relative * peak)
    public var paddingMs: Int = 250
    public var minDurationMs: Int = 150
    public var maxSilenceFraction: Float = 0.98
    /// Speech must rise this many times above the noise floor (quietest 10% of
    /// windows). Room noise on the built-in mic is ~0.004–0.009 rms and drifts,
    /// so the absolute `floor` alone lets it through.
    public var noiseSNR: Float = 4
    /// This loud always counts as speech, so a clip with no pause to measure the
    /// noise floor from isn't rejected.
    public var speechLevel: Float = 0.02
    /// Longest voiced run must be at least this long: a syllable is ~100 ms or
    /// more, a key click 30–60 ms.
    public var minVoicedRunMs: Int = 90
    /// A voiced run starts at a window above the speech threshold and lasts while
    /// windows stay above this fraction of it. Quiet speech crosses the threshold
    /// only at each syllable's peak, for 30–60 ms, but holds above 0.6× of it for
    /// 100+ ms; a key click drops straight back to the noise floor. Not 0.5: room
    /// noise drifts to ~2.3× its floor within a clip.
    public var holdRatio: Float = 0.6

    public struct Stats: CustomStringConvertible {
        public let noiseFloor: Float
        public let peak: Float
        public let voicedRunMs: Int
        /// Every window above the speech threshold, in a run or not.
        public let voicedMs: Int

        public var description: String {
            String(format: "noise=%.4f peak=%.4f voicedRun=%dms voiced=%dms",
                   noiseFloor, peak, voicedRunMs, voicedMs)
        }
    }

    public init() {}

    private func windowRMS(_ samples: [Float]) -> [Float] {
        let windowSize = windowSamples
        return (0..<samples.count / windowSize).map { w in
            var sum: Float = 0
            for v in samples[w * windowSize ..< (w + 1) * windowSize] { sum += v * v }
            return (sum / Float(windowSize)).squareRoot()
        }
    }

    private func stats(windows rms: [Float]) -> Stats {
        let sorted = rms.sorted()
        let noise = sorted.isEmpty ? 0 : max(floor, sorted[sorted.count / 10])
        let threshold = min(noise * noiseSNR, speechLevel)
        let hold = threshold * holdRatio
        var run = 0, longest = 0, voiced = 0
        var crossed = false     // current run has a window above `threshold`
        for r in rms {
            if r > threshold { voiced += 1 }
            if r > hold {
                run += 1
                crossed = crossed || r > threshold
            } else {
                run = 0
                crossed = false
            }
            if crossed { longest = max(longest, run) }
        }
        let windowMs = windowSamples / 16
        return Stats(noiseFloor: noise, peak: sorted.last ?? 0,
                     voicedRunMs: longest * windowMs, voicedMs: voiced * windowMs)
    }

    /// For logging why a buffer was kept or dropped.
    public func stats(_ samples: [Float]) -> Stats {
        stats(windows: windowRMS(samples))
    }

    /// Trim leading/trailing silence from the buffer and return `nil` if the result
    /// is too short or the input holds no speech.
    public func trimSilence(_ samples: [Float]) -> [Float]? {
        let windowSize = windowSamples
        guard samples.count >= windowSize else { return nil }

        let rms = windowRMS(samples)
        let windowCount = rms.count
        let speech = stats(windows: rms)
        if speech.voicedRunMs < minVoicedRunMs { return nil }
        let peak = speech.peak

        let threshold = max(floor, relative * peak)
        var firstVoice = -1
        var lastVoice = -1
        var silentCount = 0
        for (i, r) in rms.enumerated() {
            if r > threshold {
                if firstVoice < 0 { firstVoice = i }
                lastVoice = i
            } else {
                silentCount += 1
            }
        }
        guard firstVoice >= 0 else { return nil }

        let silentFraction = Float(silentCount) / Float(windowCount)
        if silentFraction > maxSilenceFraction { return nil }

        let paddingWindows = (paddingMs * 16) / windowSize    // 16 samples per ms
        let startWindow = max(0, firstVoice - paddingWindows)
        let endWindow = min(windowCount - 1, lastVoice + paddingWindows)

        let startSample = startWindow * windowSize
        let endSample = min(samples.count, (endWindow + 1) * windowSize)
        let durationMs = (endSample - startSample) / 16
        if durationMs < minDurationMs { return nil }

        return Array(samples[startSample..<endSample])
    }
}
