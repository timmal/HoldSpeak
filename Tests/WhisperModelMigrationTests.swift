import XCTest
@testable import HoldSpeakCore

/// HS-13: Whisper Tiny and Small were removed; saved choices move to Turbo.
final class WhisperModelMigrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "HoldSpeakTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_onlyTurboIsOffered() {
        XCTAssertEqual(WhisperModelID.allCases, [.turbo])
        XCTAssertNil(WhisperModelID(rawValue: "openai_whisper-tiny"))
        XCTAssertNil(WhisperModelID(rawValue: "openai_whisper-small"))
    }

    func test_removedModelsMoveToTurbo() {
        for removed in ["openai_whisper-tiny", "openai_whisper-small"] {
            defaults.set(removed, forKey: "modelID")
            XCTAssertEqual(PreferencesStore.migrateLegacyDefaults(defaults), removed)
            XCTAssertEqual(defaults.string(forKey: "modelID"), WhisperModelID.turbo.rawValue)
            // Idempotent: a second launch changes nothing.
            XCTAssertNil(PreferencesStore.migrateLegacyDefaults(defaults))
        }
    }

    func test_unknownValueMovesToTurbo() {
        defaults.set("openai_whisper-base", forKey: "modelID")
        XCTAssertNotNil(PreferencesStore.migrateLegacyDefaults(defaults))
        XCTAssertEqual(defaults.string(forKey: "modelID"), WhisperModelID.turbo.rawValue)
    }

    func test_turboAndMissingValueAreLeftAlone() {
        XCTAssertNil(PreferencesStore.migrateLegacyDefaults(defaults))
        XCTAssertNil(defaults.object(forKey: "modelID"), "a fresh install gets no stored model")

        defaults.set(WhisperModelID.turbo.rawValue, forKey: "modelID")
        XCTAssertNil(PreferencesStore.migrateLegacyDefaults(defaults))
        XCTAssertEqual(defaults.string(forKey: "modelID"), WhisperModelID.turbo.rawValue)
    }

    func test_otherSettingsSurvive() {
        defaults.set("openai_whisper-small", forKey: "modelID")
        defaults.set("openai", forKey: "transcriptionEngine")
        defaults.set("whisper", forKey: "localEngine")
        defaults.set("en", forKey: "primaryLanguage")
        defaults.set(true, forKey: "engineFallback")
        defaults.set("parakeet-ultra", forKey: "parakeetModel")

        PreferencesStore.migrateLegacyDefaults(defaults)

        XCTAssertEqual(defaults.string(forKey: "transcriptionEngine"), "openai")
        XCTAssertEqual(defaults.string(forKey: "localEngine"), "whisper")
        XCTAssertEqual(defaults.string(forKey: "primaryLanguage"), "en")
        XCTAssertTrue(defaults.bool(forKey: "engineFallback"))
        XCTAssertEqual(defaults.string(forKey: "parakeetModel"), "parakeet-ultra")
    }

    /// A cloud user whose last local engine was Whisper Small now falls back to Turbo.
    func test_fallbackChainResolvesToTurbo() throws {
        defaults.set("openai_whisper-small", forKey: "modelID")
        defaults.set("whisper", forKey: "localEngine")
        PreferencesStore.migrateLegacyDefaults(defaults)

        let whisper = try XCTUnwrap(WhisperModelID(rawValue: defaults.string(forKey: "modelID") ?? ""))
        let lastLocal = TranscriptionEngineKind(rawValue: defaults.string(forKey: "localEngine") ?? "")
        for engine in [TranscriptionEngineKind.openai, .gemini, .whisper] {
            XCTAssertEqual(LocalModel.resolve(engine: engine, lastLocal: lastLocal, whisper: whisper,
                                              parakeet: .ultra, parakeetAvailable: true),
                           .whisper(.turbo))
        }
    }
}
