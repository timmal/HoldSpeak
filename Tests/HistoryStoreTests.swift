import XCTest
@testable import PushToTalkCore

final class HistoryStoreTests: XCTestCase {
    private func makeStore() throws -> HistoryStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pt-test-\(UUID().uuidString).sqlite")
        return try HistoryStore(url: url)
    }

    func test_appendAndFetchRecent() throws {
        let store = try makeStore()
        _ = try store.append(.init(createdAt: 1, rawText: "a", cleanedText: "A.", durationMs: 1000, wordCount: 1, language: "ru", inserted: true))
        _ = try store.append(.init(createdAt: 2, rawText: "b", cleanedText: "B.", durationMs: 2000, wordCount: 2, language: "ru", inserted: true))
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.cleanedText), ["B.", "A."])
    }

    func test_totalWords() throws {
        let store = try makeStore()
        for (i, wc) in [1, 2, 3].enumerated() {
            _ = try store.append(.init(createdAt: Int64(i), rawText: "", cleanedText: "", durationMs: 1000, wordCount: wc, language: nil, inserted: true))
        }
        XCTAssertEqual(try store.totalWords(), 6)
    }

    func test_sumsSince_excludesOlder() throws {
        let store = try makeStore()
        _ = try store.append(.init(createdAt: 100, rawText: "", cleanedText: "", durationMs: 1000, wordCount: 5, language: nil, inserted: true))
        _ = try store.append(.init(createdAt: 200, rawText: "", cleanedText: "", durationMs: 2000, wordCount: 10, language: nil, inserted: true))
        let s = try store.sumsSince(150)
        XCTAssertEqual(s.words, 10)
        XCTAssertEqual(s.durationMs, 2000)
    }

    func test_clear() throws {
        let store = try makeStore()
        _ = try store.append(.init(createdAt: 1, rawText: "", cleanedText: "", durationMs: 1, wordCount: 1, language: nil, inserted: true))
        try store.clear()
        XCTAssertEqual(try store.recent(limit: 10).count, 0)
    }
}
