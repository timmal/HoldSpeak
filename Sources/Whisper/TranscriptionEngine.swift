import AVFoundation

public enum TranscriptionResult {
    /// `fallback` is set when Gemini answered through the other model.
    case text(String, language: String?, durationMs: Int, fallback: ModelFallbackNotice? = nil)
    /// Silence or nothing recognisable — nothing to tell the user.
    case empty
    case failed(TranscriptionFailure)
}

/// Collects the recording's samples and hands them to the engine picked in
/// Preferences (read on every finalize, so switching takes effect immediately).
@MainActor
public final class TranscriptionEngine {
    private let whisper = WhisperTranscriber()
    private let gemini = GeminiTranscriber()
    private var accumulated: [Float] = []
    private let vad = SilenceTrimmer()

    public init() {}

    public func preload(model: WhisperModelID) async throws {
        try await whisper.preload(model: model)
    }

    public func unloadWhisper() {
        whisper.unload()
    }

    /// Hands over everything fed since the last call and starts a fresh buffer.
    /// Call synchronously from the recorder's stop completion: every chunk of the
    /// finished recording has been fed by then, and none of the next one yet.
    public func takeSamples() -> [Float] {
        defer { accumulated = [] }
        return accumulated
    }

    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        accumulated.append(contentsOf: UnsafeBufferPointer(start: ch, count: count))
    }

    public func finalize(samples: [Float]) async -> TranscriptionResult {
        guard !samples.isEmpty else { pttLog("finalize: samples empty (no audio captured)"); return .empty }
        let rawMs = Int(Double(samples.count) / 16.0)
        guard let trimmed = vad.trimSilence(samples) else {
            pttLog("finalize: VAD dropped buffer (raw=\(rawMs)ms \(vad.stats(samples)))")
            return .empty
        }
        let durationMs = Int(Double(trimmed.count) / 16.0)
        pttLog("finalize: VAD raw=\(rawMs)ms → trimmed=\(durationMs)ms \(vad.stats(samples))")
        switch PreferencesStore.shared.engine {
        case .whisper: return await whisper.transcribe(trimmed, durationMs: durationMs)
        case .gemini:  return await gemini.transcribe(trimmed, durationMs: durationMs)
        }
    }
}
