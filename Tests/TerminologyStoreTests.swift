import XCTest
@testable import PushToTalkCore

final class TerminologyStoreTests: XCTestCase {
    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptt-term-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("terminology.json")
    }

    @MainActor
    func test_emptyWhenNoFileAndNoSeed() {
        let store = TerminologyStore(fileURL: tempURL(), bundle: .main, defaultsBundleResource: "nonexistent-seed")
        XCTAssertEqual(store.entries, [])
    }

    @MainActor
    func test_roundTripJSON() {
        let url = tempURL()
        let s1 = TerminologyStore(fileURL: url, bundle: .main, defaultsBundleResource: "nonexistent")
        let e1 = TerminologyEntry(canonical: "pull request",
                                  variants: ["пулл реквест", "пул-реквест"],
                                  caseSensitive: false)
        s1.add(e1)
        XCTAssertEqual(s1.entries.count, 1)

        let s2 = TerminologyStore(fileURL: url, bundle: .main, defaultsBundleResource: "nonexistent")
        XCTAssertEqual(s2.entries.count, 1)
        XCTAssertEqual(s2.entries.first?.canonical, "pull request")
        XCTAssertEqual(s2.entries.first?.variants, ["пулл реквест", "пул-реквест"])
    }

    @MainActor
    func test_addRemoveUpdate() {
        let store = TerminologyStore(fileURL: tempURL(), bundle: .main, defaultsBundleResource: "nonexistent")
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
        let store = TerminologyStore(fileURL: tempURL(), bundle: .main, defaultsBundleResource: "nonexistent")
        store.add(TerminologyEntry(canonical: "a", variants: []))
        store.add(TerminologyEntry(canonical: "b", variants: []))
        store.replaceAll([TerminologyEntry(canonical: "c", variants: [])])
        XCTAssertEqual(store.entries.map(\.canonical), ["c"])
    }

    @MainActor
    func test_promptHintTruncatesByChars() {
        let store = TerminologyStore(fileURL: tempURL(), bundle: .main, defaultsBundleResource: "nonexistent")
        for i in 0..<200 {
            store.add(TerminologyEntry(canonical: "term\(i)", variants: []))
        }
        let hint = store.promptHint(maxChars: 60)
        XCTAssertLessThanOrEqual(hint.count, 60)
        XCTAssertTrue(hint.hasPrefix("term0"))
    }

    @MainActor
    func test_promptHintEmpty() {
        let store = TerminologyStore(fileURL: tempURL(), bundle: .main, defaultsBundleResource: "nonexistent")
        XCTAssertEqual(store.promptHint(), "")
    }
}
