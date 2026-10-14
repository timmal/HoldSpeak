import Foundation

/// Sends one dictation to a cloud provider, falling back to the provider's other
/// model when the preferred one fails on their side.
@MainActor
final class CloudModelRunner<Model: CloudModel & RawRepresentable> where Model.RawValue == String {
    private let provider: CloudProvider
    private var fallbackPolicy = ModelFallbackPolicy<Model>()

    init(provider: CloudProvider) {
        self.provider = provider
    }

    /// `request` returns the transcript and the language the service detected, if it
    /// reports one; otherwise `language` (the forced one, or nil) is kept.
    func run(preferred: Model, language: String?, durationMs: Int,
             request: (Model) async throws -> (text: String, language: String?)) async -> TranscriptionResult {
        let tag = provider.rawValue
        let models = fallbackPolicy.order(preferred: preferred)
        if models.first != preferred {
            pttLog("finalize: \(preferred.rawValue) failed recently, starting with \(models[0].rawValue)")
        }

        // The model that failed in this dictation, for the HUD notice.
        var failedModel: Model?
        var lastFailure = TranscriptionFailure.unreachable(provider)
        for model in models {
            let started = Date()
            do {
                let reply = try await request(model)
                let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                pttLog("finalize: \(tag) model=\(model.rawValue) text=\(logText(text)) lang=\(reply.language ?? "-") dur=\(durationMs)ms request=\(ms)ms")
                fallbackPolicy.markSucceeded(model)
                if text.isEmpty { return .empty }
                let notice = failedModel.map { ModelFallbackNotice(failed: $0, used: model) }
                return .text(text, language: reply.language ?? language, durationMs: durationMs,
                             engine: provider.engineKind, fallback: notice)
            } catch let failure as TranscriptionFailure {
                pttLog("finalize \(tag) failed: model=\(model.rawValue) \(failure)")
                lastFailure = failure
                guard failure.warrantsModelFallback else { return .failed(failure) }
                fallbackPolicy.markFailed(model)
                failedModel = model
            } catch {
                pttLog("finalize \(tag) error: \(error)")
                return .failed(.unreachable(provider))
            }
        }
        return .failed(lastFailure)
    }
}
