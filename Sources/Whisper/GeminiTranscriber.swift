import Foundation

/// Cloud recognition through the Gemini API with the user's own key.
@MainActor
final class GeminiTranscriber {
    private let client = GeminiClient()
    private let runner = CloudModelRunner<GeminiModelID>(provider: .gemini)

    func transcribe(_ trimmed: [Float], durationMs: Int) async -> TranscriptionResult {
        let prefs = PreferencesStore.shared
        guard let apiKey = prefs.apiKey(.gemini), !apiKey.isEmpty else {
            pttLog("finalize: no Gemini API key")
            return .failed(.missingAPIKey(.gemini))
        }
        // Gemini doesn't report the language, so in auto mode the terminology
        // language simply stays whatever it was.
        let language = prefs.primaryLanguage.whisperCode
        let terms = TerminologyStore.shared
            .entries(for: language ?? TerminologyStore.shared.activeLanguage)
            .map(\.canonical)
        let wav = CloudAudio.wav(trimmed)
        let prompt = GeminiAPI.prompt(language: language, terms: terms, removeFillers: prefs.removeFillers)
        return await runner.run(preferred: prefs.geminiModel, language: language, durationMs: durationMs) { model in
            let text = try await client.transcribe(wav: wav, model: model, prompt: prompt, apiKey: apiKey)
            return (text, nil)
        }
    }
}
