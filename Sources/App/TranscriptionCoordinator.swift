import Foundation

/// Runs the post-recording pipeline: finalize → clean → insert → persist.
/// UI reactions (notifications, popover refresh) stay in AppDelegate.
@MainActor
final class TranscriptionCoordinator {
    enum Outcome {
        /// Nothing usable was transcribed; nothing inserted or persisted.
        case empty
        case inserted
        case skippedSecureField
        case noFocus
        /// The engine couldn't transcribe (no model, bad key, quota, network).
        case failed(TranscriptionFailure)
    }

    private let engine: TranscriptionEngine
    /// Another model or engine answered; called before the text is inserted.
    var onModelFallback: ((ModelFallbackNotice) -> Void)?
    private let store: HistoryStore
    /// Tail of the FIFO: each finish waits for the previous one so two transcriptions
    /// never share the WhisperKit instance and text is inserted in dictation order.
    private var lastFinish: Task<Outcome, Never>?

    init(engine: TranscriptionEngine, store: HistoryStore) {
        self.engine = engine
        self.store = store
    }

    func finishRecording(samples: [Float]) async -> Outcome {
        let previous = lastFinish
        let task = Task { [weak self] () -> Outcome in
            _ = await previous?.value
            guard let self else { return .empty }
            return await self.process(samples)
        }
        lastFinish = task
        return await task.value
    }

    private func process(_ samples: [Float]) async -> Outcome {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let result: (text: String, language: String?, durationMs: Int, engine: TranscriptionEngineKind)
        switch await engine.finalize(samples: samples) {
        case .text(let text, let language, let durationMs, let engine, let fallback):
            result = (text, language, durationMs, engine)
            if let fallback { onModelFallback?(fallback) }
        case .empty:
            return .empty
        case .failed(let failure):
            return .failed(failure)
        }
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
        pttLog("result raw: \(logText(result.text)) lang=\(result.language ?? "?") durMs=\(result.durationMs) elapsedMs=\(elapsedMs)")
        if TextCleaner.isImplausiblyLong(result.text, durationMs: result.durationMs) {
            pttLog("result dropped: too long for \(result.durationMs)ms of audio")
            return .empty
        }

        let prefs = PreferencesStore.shared
        let lang = result.language ?? prefs.primaryLanguage.whisperCode ?? TerminologyStore.shared.activeLanguage
        if prefs.primaryLanguage == .auto, let detected = result.language, !detected.isEmpty {
            TerminologyStore.shared.setActiveLanguage(detected)
        }
        let cleaned = TextCleaner.clean(
            result.text,
            terminology: TerminologyStore.shared.entries(for: lang),
            autoPunctuation: prefs.autoPunctuation,
            autoCapitalize: prefs.autoCapitalize,
            // By the engine that answered, which may be a fallback rather than the selected one.
            // The list is Whisper's own subtitle boilerplate; Parakeet doesn't produce it.
            dropHallucinations: result.engine == .whisper,
            // Gemini is asked to drop fillers by context; the others get the list.
            fillers: prefs.removeFillers && result.engine != .gemini
                ? TextCleaner.parseFillers(prefs.fillerWords) : []
        )
        pttLog("cleaned: \(logText(cleaned))")
        guard !cleaned.isEmpty else { return .empty }

        let insertion = await TextInserter.insert(cleaned + " ")
        pttLog("insertion: \(insertion)")
        let record = TranscriptionRecord(
            id: nil,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000),
            rawText: result.text,
            cleanedText: cleaned,
            durationMs: result.durationMs,
            wordCount: cleaned.split(whereSeparator: { $0.isWhitespace }).count,
            language: result.language,
            // Blind typing isn't confirmed by AX, so history doesn't claim it landed.
            inserted: insertion == .inserted
        )
        _ = try? store.append(record)

        switch insertion {
        case .inserted:          return .inserted
        // Shown like an insertion: the text most likely landed, and a "No focused input"
        // notification would be wrong more often than not.
        case .typedBlind:        return .inserted
        case .skippedSecureField: return .skippedSecureField
        case .noFocus:           return .noFocus
        }
    }
}
