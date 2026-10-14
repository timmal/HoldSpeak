import Foundation

/// Cloud recognition through OpenAI's transcription models with the user's own key.
@MainActor
final class OpenAITranscriber {
    private let client = OpenAIClient()
    private let runner = CloudModelRunner<OpenAIModelID>(provider: .openai)

    func transcribe(_ trimmed: [Float], durationMs: Int) async -> TranscriptionResult {
        let prefs = PreferencesStore.shared
        guard let apiKey = prefs.apiKey(.openai), !apiKey.isEmpty else {
            pttLog("finalize: no OpenAI API key")
            return .failed(.missingAPIKey(.openai))
        }
        // gpt-transcribe reports the detected language, which auto mode feeds back
        // into the terminology language; the other model leaves it as it was.
        let language = prefs.primaryLanguage.whisperCode
        let terms = TerminologyStore.shared
            .entries(for: language ?? TerminologyStore.shared.activeLanguage)
            .map(\.canonical)
        let wav = CloudAudio.wav(trimmed)
        return await runner.run(preferred: prefs.openAIModel, language: language, durationMs: durationMs) { model in
            try await client.transcribe(wav: wav, model: model, language: language, terms: terms, apiKey: apiKey)
        }
    }
}
