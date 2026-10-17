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
        XCTAssertEqual(ModelChoice.parakeet(.ultra).label, "Parakeet Ultra (~630 MB)")
        // Dropdown tags must stay unique across engines.
        XCTAssertNotEqual(ModelChoice.parakeet(.ultra).id, ModelChoice.whisper(.turbo).id)
    }

    func test_localModel_namesAndKinds() {
        XCTAssertEqual(LocalModel.parakeet(.ultra).engineKind, .parakeet)
        XCTAssertEqual(LocalModel.parakeet(.ultra).engineName, "Parakeet")
        XCTAssertEqual(LocalModel.whisper(.turbo).engineKind, .whisper)
        XCTAssertEqual(LocalModel.whisper(.turbo).shortLabel, "Whisper Turbo (~800 MB)")
    }

    func test_resolve_localModelForEngineAndFallback() {
        func resolve(_ engine: TranscriptionEngineKind, last: TranscriptionEngineKind?, available: Bool = true) -> LocalModel {
            LocalModel.resolve(engine: engine, lastLocal: last, whisper: .small, parakeet: .ultra, parakeetAvailable: available)
        }
        // A local engine is its own local model.
        XCTAssertEqual(resolve(.parakeet, last: .whisper), .parakeet(.ultra))
        XCTAssertEqual(resolve(.whisper, last: .parakeet), .whisper(.small))
        // Cloud engines fall back to the local engine picked last; Whisper by default.
        XCTAssertEqual(resolve(.openai, last: .parakeet), .parakeet(.ultra))
        XCTAssertEqual(resolve(.gemini, last: .whisper), .whisper(.small))
        XCTAssertEqual(resolve(.openai, last: nil), .whisper(.small))
        XCTAssertEqual(resolve(.openai, last: .gemini), .whisper(.small))
        // macOS 13 / Intel: Parakeet reads as Whisper.
        XCTAssertEqual(resolve(.parakeet, last: .parakeet, available: false), .whisper(.small))
        XCTAssertEqual(resolve(.openai, last: .parakeet, available: false), .whisper(.small))
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
        let failure = TranscriptionFailure.backupDownloading(.unreachable(.openai), backup: "Parakeet")
        XCTAssertEqual(failure.title, "OpenAI unreachable")
        XCTAssertEqual(failure.body, "Downloading Parakeet as a backup…")
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
