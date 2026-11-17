import XCTest
@testable import HoldSpeakCore

/// Which term list the store starts on, and that the choice survives a relaunch.
final class TerminologyLanguageTests: XCTestCase {
    private let bundled = ["en", "ru", "uk"]

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-term-lang-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func throwawayDefaults() -> UserDefaults {
        let name = "hs-term-lang-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// A flat directory as a Bundle, holding a seed list per language.
    private func seedBundle(_ languages: [String], prefix: String = "test-seed") -> Bundle {
        let dir = tempDir()
        let data = try! JSONEncoder().encode([TerminologyEntry(canonical: "Kubernetes", variants: [])])
        for lang in languages {
            try! data.write(to: dir.appendingPathComponent("\(prefix)-\(lang).json"))
        }
        try! Data("[]".utf8).write(to: dir.appendingPathComponent("unrelated.json"))
        return Bundle(url: dir)!
    }

    // MARK: - launchLanguage

    func test_explicitPrimaryLanguageWins() {
        XCTAssertEqual(TerminologyStore.launchLanguage(primary: "de", persisted: "ru",
                                                       preferredLanguages: ["uk-UA"], available: bundled), "de")
    }

    func test_autoStartsWhereTheLastRunLeftOff() {
        XCTAssertEqual(TerminologyStore.launchLanguage(primary: nil, persisted: "uk",
                                                       preferredLanguages: ["en-US"], available: bundled), "uk")
        // A detected language without a bundled list is still the user's own list.
        XCTAssertEqual(TerminologyStore.launchLanguage(primary: nil, persisted: "de",
                                                       preferredLanguages: ["en-US"], available: bundled), "de")
    }

    func test_autoWithoutHistoryTakesTheFirstMacLanguageWithABundledList() {
        XCTAssertEqual(TerminologyStore.launchLanguage(primary: nil, persisted: nil,
                                                       preferredLanguages: ["de-DE", "uk-UA", "ru-RU"],
                                                       available: bundled), "uk")
        XCTAssertEqual(TerminologyStore.launchLanguage(primary: nil, persisted: "",
                                                       preferredLanguages: ["ru"], available: bundled), "ru")
    }

    func test_regionAndScriptAreIgnored() {
        XCTAssertEqual(TerminologyStore.launchLanguage(primary: nil, persisted: nil,
                                                       preferredLanguages: ["zh-Hans-CN", "EN_gb"],
                                                       available: bundled), "en")
    }

    func test_englishWhenNoMacLanguageHasAList() {
        XCTAssertEqual(TerminologyStore.launchLanguage(primary: nil, persisted: nil,
                                                       preferredLanguages: ["de-DE", "fr-FR"],
                                                       available: bundled), "en")
        XCTAssertEqual(TerminologyStore.launchLanguage(primary: nil, persisted: nil,
                                                       preferredLanguages: [], available: []), "en")
    }

    // MARK: - Bundled lists

    func test_bundledLanguagesAreReadFromTheSeedFiles() {
        let bundle = seedBundle(["uk", "en"])
        XCTAssertEqual(TerminologyStore.bundledLanguages(in: bundle, prefix: "test-seed"), ["en", "uk"])
    }

    // MARK: - The store

    @MainActor
    func test_activeLanguageIsPersistedAtStartAndOnEveryChange() {
        let defaults = throwawayDefaults()
        let store = TerminologyStore(directory: tempDir(), bundle: seedBundle(["en"]),
                                     defaultsBundlePrefix: "test-seed", legacyFlatFile: nil,
                                     initialLanguage: "en", languageDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: TerminologyStore.activeLanguageKey), "en")
        store.setActiveLanguage("uk")
        XCTAssertEqual(defaults.string(forKey: TerminologyStore.activeLanguageKey), "uk")
    }

    /// Only the language the store starts on gets its seed written; Russian isn't
    /// seeded for someone who never dictated in it.
    @MainActor
    func test_onlyTheStartingLanguageIsSeeded() {
        let dir = tempDir()
        _ = TerminologyStore(directory: dir, bundle: seedBundle(["en", "ru", "uk"]),
                             defaultsBundlePrefix: "test-seed", legacyFlatFile: nil,
                             initialLanguage: "en")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["en.json"])
    }
}
