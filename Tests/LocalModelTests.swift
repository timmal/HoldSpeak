import XCTest
@testable import HoldSpeakCore

final class LocalModelTests: XCTestCase {
    func test_parakeetIsALocalEngine() {
        XCTAssertNil(TranscriptionEngineKind.parakeet.cloudProvider)
        XCTAssertTrue(TranscriptionEngineKind.parakeet.isLocal)
        XCTAssertTrue(TranscriptionEngineKind.whisper.isLocal)
        XCTAssertFalse(TranscriptionEngineKind.openai.isLocal)
        XCTAssertFalse(TranscriptionEngineKind.gemini.isLocal)
    }

    func test_modelChoice_mapsToLocalModel() {
        XCTAssertEqual(ModelChoice.parakeet(.ultra).local, .parakeet(.ultra))
        XCTAssertEqual(ModelChoice.whisper(.turbo).local, .whisper(.turbo))
        XCTAssertNil(ModelChoice.openai(.transcribe).local)
        XCTAssertNil(ModelChoice.gemini(.transcribe).local)
        // Dropdown tags must stay unique across engines.
        XCTAssertNotEqual(ModelChoice.parakeet(.ultra).id, ModelChoice.whisper(.turbo).id)
    }

    func test_modelChoice_closedDropdownLabels() {
        XCTAssertEqual(ModelChoice.parakeet(.ultra).label, "NVIDIA Parakeet Ultra")
        XCTAssertEqual(ModelChoice.whisper(.turbo).label, "OpenAI Whisper Turbo")
        XCTAssertEqual(ModelChoice.openai(.transcribe).label, "OpenAI GPT Transcribe")
        XCTAssertEqual(ModelChoice.openai(.miniTranscribe).label, "OpenAI GPT-4o mini")
        XCTAssertEqual(ModelChoice.gemini(.transcribe).label, "Gemini 3.5 Transcribe")
        XCTAssertEqual(ModelChoice.gemini(.flashLite).label, "Gemini 3.5 Flash-Lite")
    }

    func test_modelLabels_openDropdown() {
        XCTAssertEqual(ParakeetModelID.ultra.label, "NVIDIA Parakeet Ultra — fastest · 25 European languages · 610 MB")
        XCTAssertEqual(WhisperModelID.turbo.label, "OpenAI Whisper Turbo — 99 languages, slower · 1.5 GB")
        XCTAssertEqual(OpenAIModelID.transcribe.label, "OpenAI GPT Transcribe — most accurate · $0.27/h")
        XCTAssertEqual(OpenAIModelID.miniTranscribe.label, "OpenAI GPT-4o mini — cheaper · $0.18/h")
        XCTAssertEqual(GeminiModelID.transcribe.label, "Gemini 3.5 Transcribe — fast · $0.30/h")
        XCTAssertEqual(GeminiModelID.flashLite.label, "Gemini 3.5 Flash-Lite — best with terms, slower · $0.06/h")
    }

    func test_modelLabels_neverSayRecommended() {
        let labels = WhisperModelID.allCases.map(\.label) + ParakeetModelID.allCases.map(\.label)
            + OpenAIModelID.allCases.map(\.label) + GeminiModelID.allCases.map(\.label)
        for label in labels {
            XCTAssertFalse(label.lowercased().contains("recommended"), label)
        }
    }

    func test_cloudLabels_takePriceFromCostPerHour() {
        for m in OpenAIModelID.allCases { XCTAssertTrue(m.label.hasSuffix("· \(m.costPerHour)/h"), m.label) }
        for m in GeminiModelID.allCases { XCTAssertTrue(m.label.hasSuffix("· \(m.costPerHour)/h"), m.label) }
    }

    func test_localModel_namesAndKinds() {
        XCTAssertEqual(LocalModel.parakeet(.ultra).engineKind, .parakeet)
        XCTAssertEqual(LocalModel.parakeet(.ultra).engineName, "Parakeet")
        XCTAssertEqual(LocalModel.parakeet(.ultra).shortLabel, "NVIDIA Parakeet Ultra")
        XCTAssertEqual(LocalModel.parakeet(.ultra).downloadSize, "610 MB")
        XCTAssertEqual(LocalModel.whisper(.turbo).engineKind, .whisper)
        XCTAssertEqual(LocalModel.whisper(.turbo).shortLabel, "OpenAI Whisper Turbo")
        XCTAssertEqual(LocalModel.whisper(.turbo).downloadSize, "1.5 GB")
    }

    func test_resolve_localModelForEngineAndFallback() {
        func resolve(_ engine: TranscriptionEngineKind, last: TranscriptionEngineKind?, available: Bool = true) -> LocalModel {
            LocalModel.resolve(engine: engine, lastLocal: last, whisper: .turbo, parakeet: .ultra, parakeetAvailable: available)
        }
        // A local engine is its own local model.
        XCTAssertEqual(resolve(.parakeet, last: .whisper), .parakeet(.ultra))
        XCTAssertEqual(resolve(.whisper, last: .parakeet), .whisper(.turbo))
        // Cloud engines fall back to the local engine picked last; Whisper by default.
        XCTAssertEqual(resolve(.openai, last: .parakeet), .parakeet(.ultra))
        XCTAssertEqual(resolve(.gemini, last: .whisper), .whisper(.turbo))
        XCTAssertEqual(resolve(.openai, last: nil), .whisper(.turbo))
        XCTAssertEqual(resolve(.openai, last: .gemini), .whisper(.turbo))
        // macOS 13 / Intel: Parakeet reads as Whisper.
        XCTAssertEqual(resolve(.parakeet, last: .parakeet, available: false), .whisper(.turbo))
        XCTAssertEqual(resolve(.openai, last: .parakeet, available: false), .whisper(.turbo))
        XCTAssertEqual(LocalModel.supported(.parakeet, parakeetAvailable: false), .whisper)
        XCTAssertEqual(LocalModel.supported(.openai, parakeetAvailable: false), .openai)
    }

    /// FluidAudio keeps Ultra in `<models>/parakeet-ultra` (Repo.folderName strips "-coreml").
    func test_ultraFolderMatchesFluidAudio() {
        XCTAssertEqual(ParakeetModelID.ultra.folderName, "parakeet-ultra")
    }

    func test_modelExists_needsEveryFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(ParakeetSupport.modelExists(.ultra, in: dir))
        let files = ParakeetModelID.ultra.requiredFiles
        for name in files.dropLast() {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        XCTAssertFalse(ParakeetSupport.modelExists(.ultra, in: dir), "vocabulary still missing")
        FileManager.default.createFile(atPath: dir.appendingPathComponent(files.last!).path, contents: Data("{}".utf8))
        XCTAssertTrue(ParakeetSupport.modelExists(.ultra, in: dir))
    }

    func test_backupDownloading_namesTheLocalEngine() {
        let failure = TranscriptionFailure.backupDownloading(.unreachable(.openai),
                                                             backup: LocalModel.parakeet(.ultra).shortLabel)
        XCTAssertEqual(failure.title, "OpenAI unreachable")
        XCTAssertEqual(failure.body, "Downloading NVIDIA Parakeet Ultra as a backup…")
        let notice = ModelFallbackNotice(failure: .outOfCredits(.openai),
                                         usedEngine: LocalModel.whisper(.turbo).shortLabel)
        XCTAssertEqual(notice.body, "Used OpenAI Whisper Turbo instead")
        XCTAssertEqual(TranscriptionFailure.parakeetModelNotReady.title, "Parakeet model not ready")
    }

    func test_scriptLanguage() {
        XCTAssertEqual(ScriptLanguage.guess("Привет! Сегодня я закончил задачу."), "ru")
        XCTAssertEqual(ScriptLanguage.guess("Сделай pull request и после ревью запустим деплой в Kubernetes."), "ru")
        XCTAssertEqual(ScriptLanguage.guess("Привіт, як справи? Їжак."), "uk")
        XCTAssertEqual(ScriptLanguage.guess("Please schedule the review meeting."), "en")
        // Accented Latin could be any of Parakeet's European languages.
        XCTAssertNil(ScriptLanguage.guess("Wir müssen das Release vorbereiten."))
        XCTAssertNil(ScriptLanguage.guess("123, 456."))
        XCTAssertNil(ScriptLanguage.guess(""))
    }
}
