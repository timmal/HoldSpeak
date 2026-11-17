import XCTest
@testable import HoldSpeakCore

final class TerminologyStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptt-term-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private static let seedPrefix = "test-seed"
    private static let seed = [TerminologyEntry(canonical: "Kubernetes", variants: ["кубернетес"])]

    /// A flat directory works as a Bundle, so tests can ship their own seed file.
    private func seedBundle(language: String = "ru") -> Bundle {
        let dir = tempDir()
        let data = try! JSONEncoder().encode(Self.seed)
        try! data.write(to: dir.appendingPathComponent("\(Self.seedPrefix)-\(language).json"))
        return Bundle(url: dir)!
    }

    @MainActor
    private func seededStore(directory: URL, language: String = "ru", seedLanguage: String = "ru") -> TerminologyStore {
        TerminologyStore(directory: directory,
                         bundle: seedBundle(language: seedLanguage),
                         defaultsBundlePrefix: Self.seedPrefix,
                         legacyFlatFile: nil,
                         initialLanguage: language)
    }

    private func files(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func backups(in dir: URL, matching pattern: String) -> [String] {
        files(in: dir).filter { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    @MainActor
    private func newStore(directory: URL? = nil, language: String = "ru") -> TerminologyStore {
        TerminologyStore(directory: directory ?? tempDir(),
                         bundle: .main,
                         defaultsBundlePrefix: "nonexistent-seed",
                         legacyFlatFile: nil,
                         initialLanguage: language)
    }

    @MainActor
    func test_emptyWhenNoFileAndNoSeed() {
        XCTAssertEqual(newStore().entries, [])
    }

    @MainActor
    func test_roundTripJSON() {
        let dir = tempDir()
        let s1 = newStore(directory: dir)
        s1.add(TerminologyEntry(canonical: "pull request",
                                variants: ["пулл реквест", "пул-реквест"],
                                caseSensitive: false))
        XCTAssertEqual(s1.entries.count, 1)

        let s2 = newStore(directory: dir)
        XCTAssertEqual(s2.entries.count, 1)
        XCTAssertEqual(s2.entries.first?.canonical, "pull request")
        XCTAssertEqual(s2.entries.first?.variants, ["пулл реквест", "пул-реквест"])
    }

    @MainActor
    func test_addRemoveUpdate() {
        let store = newStore()
        let e = TerminologyEntry(canonical: "merge", variants: ["мёрдж"])
        store.add(e)
        XCTAssertEqual(store.entries.count, 1)

        var updated = store.entries[0]
        updated.variants.append("мердж")
        store.update(updated)
        XCTAssertEqual(store.entries[0].variants, ["мёрдж", "мердж"])

        store.remove(id: updated.id)
        XCTAssertEqual(store.entries.count, 0)
    }

    @MainActor
    func test_replaceAll() {
        let store = newStore()
        store.add(TerminologyEntry(canonical: "a", variants: []))
        store.add(TerminologyEntry(canonical: "b", variants: []))
        store.replaceAll([TerminologyEntry(canonical: "c", variants: [])])
        XCTAssertEqual(store.entries.map(\.canonical), ["c"])
    }

    @MainActor
    func test_perLanguageSetsAreIndependent() {
        let dir = tempDir()
        let ruStore = newStore(directory: dir, language: "ru")
        ruStore.add(TerminologyEntry(canonical: "pull request", variants: ["пулл реквест"]))

        ruStore.setActiveLanguage("uk")
        XCTAssertEqual(ruStore.entries, [], "switching to uk should show empty (no seed, no disk file)")
        ruStore.add(TerminologyEntry(canonical: "merge", variants: ["мердж"]))
        XCTAssertEqual(ruStore.entries.map(\.canonical), ["merge"])

        ruStore.setActiveLanguage("ru")
        XCTAssertEqual(ruStore.entries.map(\.canonical), ["pull request"], "ru set must persist")
    }

    @MainActor
    func test_entriesForLanguage_readsOtherSetsWithoutSwitching() {
        let dir = tempDir()
        let store = newStore(directory: dir, language: "ru")
        store.add(TerminologyEntry(canonical: "pull request", variants: []))
        store.setActiveLanguage("uk")
        store.add(TerminologyEntry(canonical: "merge", variants: []))

        let store2 = newStore(directory: dir, language: "en")
        XCTAssertEqual(store2.entries(for: "ru").map(\.canonical), ["pull request"])
        XCTAssertEqual(store2.entries(for: "uk").map(\.canonical), ["merge"])
        XCTAssertEqual(store2.activeLanguage, "en")
    }

    @MainActor
    func test_legacyFlatFileMigratesToRu() {
        let dir = tempDir()
        // Simulate legacy flat file living alongside the directory
        let legacyDir = dir.deletingLastPathComponent()
        let legacy = legacyDir.appendingPathComponent("legacy-terminology-\(UUID()).json")
        let seedEntry = TerminologyEntry(canonical: "legacy", variants: ["старый"])
        let data = try! JSONEncoder().encode([seedEntry])
        try! data.write(to: legacy)

        let store = TerminologyStore(directory: dir,
                                     bundle: .main,
                                     defaultsBundlePrefix: "nonexistent-seed",
                                     legacyFlatFile: legacy,
                                     initialLanguage: "ru")
        XCTAssertEqual(store.entries.map(\.canonical), ["legacy"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "legacy file should be moved away")
    }

    // MARK: - Damaged files (HS-38)

    @MainActor
    func test_unreadableFile_isMovedAsideNotOverwritten() throws {
        let dir = tempDir()
        let garbage = Data("[{ \"canonical\": \"my term\", oops }".utf8)
        try garbage.write(to: dir.appendingPathComponent("ru.json"))

        let store = seededStore(directory: dir)

        XCTAssertEqual(store.entries, Self.seed, "the seed is in use")
        let backupNames = backups(in: dir, matching: #"^ru\.json\.unreadable-\d{8}-\d{6}$"#)
        XCTAssertEqual(backupNames.count, 1, "files: \(files(in: dir))")
        let backup = try XCTUnwrap(backupNames.first)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(backup)), garbage,
                       "the user's bytes are kept verbatim")
        let written = try Data(contentsOf: dir.appendingPathComponent("ru.json"))
        XCTAssertEqual(try JSONDecoder().decode([TerminologyEntry].self, from: written), Self.seed)

        let notice = try XCTUnwrap(store.fileNotices["ru"])
        XCTAssertEqual(notice.language, "ru")
        XCTAssertEqual(notice.kind, .unreadable)
        XCTAssertEqual(notice.backupFileName, backup)
        XCTAssertFalse(notice.reason.isEmpty)
    }

    @MainActor
    func test_unreadableFile_withoutSeed_isStillMovedAside() throws {
        let dir = tempDir()
        let garbage = Data("not json at all".utf8)
        try garbage.write(to: dir.appendingPathComponent("ru.json"))

        let store = newStore(directory: dir)

        XCTAssertEqual(store.entries, [])
        let backup = try XCTUnwrap(backups(in: dir, matching: #"^ru\.json\.unreadable-"#).first)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(backup)), garbage)
        XCTAssertEqual(store.fileNotices["ru"]?.kind, .unreadable)
    }

    @MainActor
    func test_missingFile_seedsAndWrites_noNotice() throws {
        let dir = tempDir()
        let store = seededStore(directory: dir)

        XCTAssertEqual(store.entries, Self.seed)
        XCTAssertEqual(files(in: dir), ["ru.json"])
        let written = try Data(contentsOf: dir.appendingPathComponent("ru.json"))
        XCTAssertEqual(try JSONDecoder().decode([TerminologyEntry].self, from: written), Self.seed)
        XCTAssertTrue(store.fileNotices.isEmpty)
    }

    @MainActor
    func test_validFile_isLoadedUntouched() throws {
        let dir = tempDir()
        let mine = [TerminologyEntry(canonical: "pull request", variants: ["пулл реквест"], caseSensitive: true)]
        let bytes = try JSONEncoder().encode(mine)
        try bytes.write(to: dir.appendingPathComponent("ru.json"))

        let store = seededStore(directory: dir)

        XCTAssertEqual(store.entries, mine)
        XCTAssertEqual(files(in: dir), ["ru.json"])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("ru.json")), bytes)
        XCTAssertTrue(store.fileNotices.isEmpty)
    }

    @MainActor
    func test_entriesForLanguage_unreadableFile_isRecordedNotSilentlySeeded() throws {
        let dir = tempDir()
        let garbage = Data("{{{".utf8)
        try garbage.write(to: dir.appendingPathComponent("ru.json"))

        let store = seededStore(directory: dir, language: "en")
        XCTAssertTrue(store.fileNotices.isEmpty, "ru is not read until asked for")

        XCTAssertEqual(store.entries(for: "ru"), Self.seed)
        let backup = try XCTUnwrap(backups(in: dir, matching: #"^ru\.json\.unreadable-\d{8}-\d{6}$"#).first)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(backup)), garbage)
        XCTAssertEqual(store.fileNotices["ru"]?.kind, .unreadable)
        XCTAssertEqual(store.fileNotices["ru"]?.backupFileName, backup)
    }

    @MainActor
    func test_dismissFileNotice() throws {
        let dir = tempDir()
        try Data("nope".utf8).write(to: dir.appendingPathComponent("ru.json"))
        let store = seededStore(directory: dir)
        XCTAssertNotNil(store.fileNotices["ru"])
        store.dismissFileNotice(for: "ru")
        XCTAssertNil(store.fileNotices["ru"])
    }

    // MARK: - Lenient decoding (HS-38)

    private func decode(_ json: String) throws -> TerminologyDecodeResult {
        try TerminologyStore.decodeLenient(Data(json.utf8))
    }

    func test_lenient_missingId_getsFreshId() throws {
        let r = try decode(#"[{"canonical":"merge","variants":["мердж"],"caseSensitive":true}]"#)
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries[0].canonical, "merge")
        XCTAssertEqual(r.entries[0].variants, ["мердж"])
        XCTAssertTrue(r.entries[0].caseSensitive)
        XCTAssertEqual(r.filledIn, 1)
        XCTAssertEqual(r.skipped, 0)
    }

    func test_lenient_missingCaseSensitive_usesNewEntryDefault() throws {
        let id = UUID()
        let r = try decode(#"[{"id":"\#(id.uuidString)","canonical":"merge","variants":[]}]"#)
        let newEntryDefault = TerminologyEntry(canonical: "", variants: []).caseSensitive
        XCTAssertEqual(r.entries.first?.caseSensitive, newEntryDefault)
        XCTAssertEqual(r.entries.first?.id, id)
        XCTAssertEqual(r.filledIn, 1)
    }

    func test_lenient_missingVariants_becomeEmpty() throws {
        let r = try decode(#"[{"canonical":"Kubernetes"}]"#)
        XCTAssertEqual(r.entries.first?.variants, [])
        XCTAssertEqual(r.filledIn, 1, "one entry, counted once however many fields were filled")
    }

    func test_lenient_unknownKeysAreIgnored() throws {
        let id = UUID()
        let r = try decode(#"[{"id":"\#(id.uuidString)","canonical":"merge","variants":[],"caseSensitive":false,"note":"mine"}]"#)
        XCTAssertEqual(r.entries, [TerminologyEntry(id: id, canonical: "merge", variants: [])])
        XCTAssertEqual(r.filledIn, 0)
        XCTAssertEqual(r.skipped, 0)
    }

    func test_lenient_entriesWithoutUsableCanonical_areSkippedAndCounted() throws {
        let r = try decode(#"""
        [
          {"canonical":"merge"},
          {"variants":["нет"]},
          {"canonical":"   "},
          {"canonical":42},
          "just a string",
          {"canonical":"rebase","variants":"not a list"},
          {"canonical":"Swift","caseSensitive":"yes"},
          {"canonical":"Docker","variants":["докер"]}
        ]
        """#)
        XCTAssertEqual(r.entries.map(\.canonical), ["merge", "Docker"])
        XCTAssertEqual(r.skipped, 6)
    }

    func test_lenient_notAList_throws() {
        XCTAssertThrowsError(try decode(#"{"canonical":"merge"}"#))
        XCTAssertThrowsError(try decode("[{ broken"))
    }

    @MainActor
    func test_fileWithFilledInFields_isRewrittenCanonically() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("ru.json")
        try Data(#"[{"canonical":"merge","variants":["мердж"]}]"#.utf8).write(to: url)

        let store = seededStore(directory: dir)

        XCTAssertEqual(store.entries.map(\.canonical), ["merge"])
        XCTAssertEqual(files(in: dir), ["ru.json"], "nothing was lost, so no backup")
        XCTAssertTrue(store.fileNotices.isEmpty)
        let rewritten = try Data(contentsOf: url)
        XCTAssertEqual(try JSONDecoder().decode([TerminologyEntry].self, from: rewritten), store.entries,
                       "the file now decodes strictly, with the generated id kept")
        // JSONEncoder's key order is not stable between calls, so compare structure, not bytes.
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.entries)) as? NSArray
        XCTAssertEqual(try JSONSerialization.jsonObject(with: rewritten) as? NSArray, expected,
                       "written the way the app writes")
    }

    @MainActor
    func test_fileWithUnknownKeysOnly_isLeftUntouched() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("ru.json")
        let bytes = Data(#"[{"id":"\#(UUID().uuidString)","canonical":"merge","variants":[],"caseSensitive":false,"note":"x"}]"#.utf8)
        try bytes.write(to: url)

        let store = seededStore(directory: dir)

        XCTAssertEqual(store.entries.map(\.canonical), ["merge"])
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(store.fileNotices.isEmpty)
    }

    @MainActor
    func test_fileWithSkippedEntries_keepsOriginalAsPartialBackup() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("ru.json")
        let original = Data(#"[{"canonical":"merge"},{"variants":["x"]},{"canonical":""}]"#.utf8)
        try original.write(to: url)

        let store = seededStore(directory: dir)

        XCTAssertEqual(store.entries.map(\.canonical), ["merge"], "readable entries survive; no seed")
        let backup = try XCTUnwrap(backups(in: dir, matching: #"^ru\.json\.partial-\d{8}-\d{6}$"#).first,
                                   "files: \(files(in: dir))")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(backup)), original)
        XCTAssertEqual(try JSONDecoder().decode([TerminologyEntry].self, from: Data(contentsOf: url)),
                       store.entries)
        let notice = try XCTUnwrap(store.fileNotices["ru"])
        XCTAssertEqual(notice.kind, .partial(skipped: 2))
        XCTAssertEqual(notice.backupFileName, backup)
    }

    @MainActor
    func test_entriesForLanguage_partialFile_isRecorded() throws {
        let dir = tempDir()
        try Data(#"[{"canonical":"merge"},{"nope":1}]"#.utf8).write(to: dir.appendingPathComponent("ru.json"))
        let store = seededStore(directory: dir, language: "en")

        XCTAssertEqual(store.entries(for: "ru").map(\.canonical), ["merge"])
        XCTAssertEqual(store.fileNotices["ru"]?.kind, .partial(skipped: 1))
        XCTAssertEqual(backups(in: dir, matching: #"^ru\.json\.partial-"#).count, 1)
    }
}
