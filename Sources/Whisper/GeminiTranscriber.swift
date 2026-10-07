import Foundation

/// Cloud recognition through the Gemini API with the user's own key.
@MainActor
final class GeminiTranscriber {
    private let client = GeminiClient()
    private var fallbackPolicy = GeminiFallbackPolicy()

    func transcribe(_ trimmed: [Float], durationMs: Int) async -> TranscriptionResult {
        let prefs = PreferencesStore.shared
        guard let apiKey = prefs.geminiAPIKey, !apiKey.isEmpty else {
            pttLog("finalize: no Gemini API key")
            return .failed(.missingAPIKey)
        }
        // Gemini doesn't report the language, so in auto mode the terminology
        // language simply stays whatever it was.
        let language = prefs.primaryLanguage.whisperCode
        let terms = TerminologyStore.shared
            .entries(for: language ?? TerminologyStore.shared.activeLanguage)
            .map(\.canonical)
        let wav = GeminiAPI.wav(trimmed)
        let prompt = GeminiAPI.prompt(language: language, terms: terms)
        let preferred = prefs.geminiModel
        let models = fallbackPolicy.order(preferred: preferred)
        if models.first != preferred {
            pttLog("finalize: \(preferred.rawValue) failed recently, starting with \(models[0].rawValue)")
        }

        // The model that failed in this dictation, for the HUD notice.
        var failedModel: GeminiModelID?
        var lastFailure = TranscriptionFailure.unreachable
        for model in models {
            let started = Date()
            do {
                let text = try await client.transcribe(wav: wav, model: model, prompt: prompt, apiKey: apiKey)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                pttLog("finalize: gemini model=\(model.rawValue) text=\(logText(text)) dur=\(durationMs)ms request=\(ms)ms")
                fallbackPolicy.markSucceeded(model)
                if text.isEmpty { return .empty }
                let notice = failedModel.map { ModelFallbackNotice(failed: $0, used: model) }
                return .text(text, language: language, durationMs: durationMs, fallback: notice)
            } catch let failure as TranscriptionFailure {
                pttLog("finalize gemini failed: model=\(model.rawValue) \(failure)")
                lastFailure = failure
                guard failure.warrantsModelFallback else { return .failed(failure) }
                fallbackPolicy.markFailed(model)
                failedModel = model
            } catch {
                pttLog("finalize gemini error: \(error)")
                return .failed(.unreachable)
            }
        }
        return .failed(lastFailure)
    }
}
