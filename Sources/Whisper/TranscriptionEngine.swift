import AVFoundation

public enum TranscriptionResult {
    /// `engine` is the one that actually answered; `fallback` is set when that wasn't
    /// the selected model or engine.
    case text(String, language: String?, durationMs: Int, engine: TranscriptionEngineKind,
              fallback: ModelFallbackNotice? = nil)
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
    private let openai = OpenAITranscriber()
    private var accumulated: [Float] = []
    private let vad = SilenceTrimmer()
    /// The backup Whisper model isn't on disk: start downloading it (with progress in
    /// Preferences). Called on main.
    public var onBackupDownloadNeeded: ((WhisperModelID) -> Void)?

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
        let prefs = PreferencesStore.shared
        guard let selected = prefs.engine.cloudProvider else {
            return await whisper.transcribe(trimmed, durationMs: durationMs)
        }
        let result = await transcribe(trimmed, durationMs: durationMs, with: selected)
        guard case .failed(let failure) = result, prefs.engineFallback else { return result }
        return await fallBack(trimmed, durationMs: durationMs, after: selected, failure: failure)
    }

    private func transcribe(_ trimmed: [Float], durationMs: Int, with provider: CloudProvider) async -> TranscriptionResult {
        switch provider {
        case .gemini: return await gemini.transcribe(trimmed, durationMs: durationMs)
        case .openai: return await openai.transcribe(trimmed, durationMs: durationMs)
        }
    }

    /// The selected cloud engine failed with `failure`: the other cloud engines with a
    /// saved key, then local Whisper. The HUD shows `failure`, the reason for the switch.
    private func fallBack(_ trimmed: [Float], durationMs: Int, after selected: CloudProvider,
                          failure: TranscriptionFailure) async -> TranscriptionResult {
        let prefs = PreferencesStore.shared
        var offline = failure.isOffline
        for provider in EngineFallback.cloudBackups(after: selected, hasKey: prefs.hasAPIKey) where !offline {
            pttLog("fallback: \(selected.rawValue) failed (\(failure)), trying \(provider.rawValue)")
            switch await transcribe(trimmed, durationMs: durationMs, with: provider) {
            case .text(let text, let language, let ms, let engine, _):
                return .text(text, language: language, durationMs: ms, engine: engine,
                             fallback: ModelFallbackNotice(failure: failure, usedEngine: provider.name))
            case .empty:
                return .empty
            case .failed(let next):
                offline = next.isOffline
            }
        }

        let model = prefs.modelID
        guard ModelManager.shared.locateModel(model) != nil else {
            // Without a connection there is nothing to download it with.
            if offline {
                pttLog("fallback: offline and Whisper \(model.rawValue) not downloaded")
                return .failed(failure)
            }
            pttLog("fallback: Whisper \(model.rawValue) not downloaded, starting download")
            onBackupDownloadNeeded?(model)
            return .failed(.backupDownloading(failure))
        }
        pttLog("fallback: \(selected.rawValue) failed (\(failure)), trying Whisper \(model.rawValue)")
        do {
            // Loads the model on the first fallback; it then stays loaded until the
            // user switches engines.
            try await whisper.preload(model: model)
        } catch {
            pttLog("fallback: Whisper load failed: \(error)")
            return .failed(failure)
        }
        switch await whisper.transcribe(trimmed, durationMs: durationMs) {
        case .text(let text, let language, let ms, let engine, _):
            return .text(text, language: language, durationMs: ms, engine: engine,
                         fallback: ModelFallbackNotice(failure: failure, usedEngine: "Whisper"))
        case .empty:
            return .empty
        case .failed:
            return .failed(failure)
        }
    }
}
