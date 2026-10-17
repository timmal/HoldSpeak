import Foundation

/// Finds HoldSpeakParakeet.framework in the app bundle and loads it — only on macOS 14+
/// on Apple Silicon, see ParakeetEngineProtocol.swift for why it isn't linked.
@MainActor
enum ParakeetLoader {
    private static var bridge: (any ParakeetEngineProtocol)?
    private static var failed = false

    static func engine() -> (any ParakeetEngineProtocol)? {
        if let bridge { return bridge }
        guard ParakeetSupport.isAvailable, !failed else { return nil }
        failed = true
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("HoldSpeakParakeet.framework"),
              let bundle = Bundle(url: url) else {
            pttLog("Parakeet: framework missing from the app bundle")
            return nil
        }
        do {
            try bundle.loadAndReturnError()
        } catch {
            pttLog("Parakeet: framework failed to load: \(error)")
            return nil
        }
        guard let type = NSClassFromString("HSParakeetBridge") as? ParakeetEngineProtocol.Type else {
            pttLog("Parakeet: HSParakeetBridge not found or doesn't conform")
            return nil
        }
        failed = false
        let made = type.init()
        bridge = made
        return made
    }
}

enum ParakeetError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Parakeet needs macOS 14 on Apple Silicon" }
}

/// Local Parakeet recognition. Audio arrives already trimmed by the facade.
@MainActor
final class ParakeetTranscriber {
    private var bridge: (any ParakeetEngineProtocol)?
    private var currentModel: ParakeetModelID?
    /// Most recent model asked for; a queued load that has been superseded is skipped.
    private var requestedModel: ParakeetModelID?
    /// Tail of the load/unload queue, so loads and unloads reach the bridge in order.
    private var queue: Task<Void, Error>?

    func preload(model: ParakeetModelID) async throws {
        requestedModel = model
        let previous = queue
        let task = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, self.requestedModel == model else { return }
            if self.currentModel == model, self.bridge != nil { return }
            try await self.load(model: model)
        }
        queue = task
        try await task.value
    }

    private func load(model: ParakeetModelID) async throws {
        guard let engine = ParakeetLoader.engine() else { throw ParakeetError.unavailable }
        let url: URL
        if let local = ModelManager.shared.locateParakeet(model) {
            url = local
        } else {
            url = try await ModelManager.shared.download(.parakeet(model)) { _ in }
        }
        let started = Date()
        try await engine.load(model: model.rawValue, from: url.path)
        // Unloaded or switched to another model while this one was loading.
        guard requestedModel == model else {
            await engine.unload()
            return
        }
        bridge = engine
        currentModel = model
        pttLog("Parakeet \(model.rawValue) loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    /// Frees the model when the user switches to another engine.
    func unload() {
        requestedModel = nil
        guard let loaded = bridge else { return }
        bridge = nil
        currentModel = nil
        let previous = queue
        queue = Task { @MainActor in
            _ = await previous?.result
            await loaded.unload()
        }
    }

    func transcribe(_ trimmed: [Float], durationMs: Int) async -> TranscriptionResult {
        guard let bridge else { pttLog("finalize: parakeet not loaded"); return .failed(.parakeetModelNotReady) }
        let forced = PreferencesStore.shared.primaryLanguage.whisperCode
        let samples = trimmed.withUnsafeBufferPointer { Data(buffer: $0) }
        let started = Date()
        do {
            // Parakeet detects the language itself. FluidAudio's language hint only filters
            // tokens by alphabet, which would spell English terms in a Russian sentence in
            // Cyrillic ("pull request" → "пул реквест"), so it is never passed.
            let text = try await bridge.transcribe(samples: samples, language: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lang = forced ?? ScriptLanguage.guess(text)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            pttLog("finalize: parakeet text=\(logText(text)) lang=\(lang ?? "?") dur=\(durationMs)ms request=\(ms)ms")
            if text.isEmpty { return .empty }
            return .text(text, language: lang, durationMs: durationMs, engine: .parakeet)
        } catch {
            pttLog("finalize parakeet error: \(error)")
            return .empty
        }
    }
}
