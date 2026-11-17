import XCTest
import GRDB
@testable import HoldSpeakCore

final class HistoryStoreTests: XCTestCase {
    /// Every temp database handed out by `tempURL()`; removed with sidecars in tearDown.
    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs {
            for file in filesOnDisk(for: url) { try? FileManager.default.removeItem(at: file) }
        }
        tempURLs.removeAll()
        super.tearDown()
    }

    private func tempURL() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pt-test-\(UUID().uuidString).sqlite")
        tempURLs.append(url)
        return url
    }

    /// The database file plus every sidecar SQLite may leave next to it.
    private func filesOnDisk(for url: URL) -> [URL] {
        [url] + ["-journal", "-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
    }

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(url: tempURL())
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

    private func rec(_ t: Int64, words: Int = 1, ms: Int = 1000) -> TranscriptionRecord {
        .init(createdAt: t, rawText: "", cleanedText: "", durationMs: ms, wordCount: words, language: nil, inserted: true)
    }

    func test_metricsKeepGrowingPastHistoryCap() throws {
        let store = try makeStore()
        let n = HistoryStore.maxEntries + 50
        for i in 1...n { _ = try store.append(rec(Int64(i), words: 2, ms: 500)) }
        XCTAssertEqual(try store.recent(limit: 1000).count, HistoryStore.maxEntries)
        XCTAssertEqual(try store.totalWords(), n * 2)
        let s = try store.sumsSince(0)
        XCTAssertEqual(s.words, n * 2)
        XCTAssertEqual(s.durationMs, n * 500)
        // Window queries also see pruned rows.
        XCTAssertEqual(try store.sumsSince(10).words, (n - 10) * 2)
    }

    func test_clearKeepsMetrics() throws {
        let store = try makeStore()
        _ = try store.append(rec(1, words: 3))
        _ = try store.append(rec(2, words: 4))
        try store.clear()
        XCTAssertEqual(try store.recent(limit: 10).count, 0)
        XCTAssertEqual(try store.totalWords(), 7)
        _ = try store.append(rec(3, words: 5))
        XCTAssertEqual(try store.totalWords(), 12)
        XCTAssertEqual(try store.recent(limit: 10).count, 1)
    }

    // MARK: - Secure delete (HS-39)

    /// Long ASCII marker that cannot occur in the file by accident.
    private let marker = "HS39-SECRET-DICTATION-MARKER-\(UUID().uuidString)-END"


    /// Returns "<file>: <hits>" for each file (database or sidecar) whose raw
    /// bytes contain `marker`; empty when the marker is nowhere on disk.
    private func filesContainingMarker(_ url: URL) throws -> [String] {
        let needle = Data(marker.utf8)
        return try filesOnDisk(for: url)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .compactMap { file in
                let bytes = try Data(contentsOf: file)
                var hits = 0
                var from = bytes.startIndex
                while let r = bytes.range(of: needle, in: from..<bytes.endIndex) {
                    hits += 1; from = r.upperBound
                }
                return hits > 0 ? "\(file.lastPathComponent): \(hits) hits in \(bytes.count) bytes" : nil
            }
    }

    private func secretRec(_ t: Int64, _ i: Int) -> TranscriptionRecord {
        // Some rows exceed the 4 KiB page size so overflow pages are exercised too.
        let body = i % 10 == 0 ? String(repeating: "\(marker) #\(i) ", count: 80) : "\(marker) #\(i)"
        return .init(createdAt: t, rawText: "raw " + body, cleanedText: "clean " + body,
                     durationMs: 1000, wordCount: 3, language: "en", inserted: true)
    }

    func test_clear_leavesNoDeletedTextInFile() throws {
        let url = tempURL()
        do {
            let store = try HistoryStore(url: url)
            for i in 1...HistoryStore.maxEntries { _ = try store.append(secretRec(Int64(i), i)) }
            XCTAssertFalse(try filesContainingMarker(url).isEmpty, "precondition: text is on disk")
            try store.clear()
        } // store released -> connection closed, everything flushed
        XCTAssertEqual(try filesContainingMarker(url), [])
    }

    /// Text deleted by an older app version (no secure_delete) already sits in
    /// free pages; clear() must scrub it too.
    func test_clear_scrubsTextFreedByOlderVersions() throws {
        let url = tempURL()
        do { _ = try HistoryStore(url: url) } // create the current schema
        do {
            // Plain connection = pre-HS-39 behaviour: deletes leave text behind.
            let legacy = try DatabaseQueue(path: url.path)
            try legacy.write { db in
                for i in 1...50 { var r = self.secretRec(Int64(i), i); try r.insert(db) }
            }
            try legacy.write { db in try db.execute(sql: "DELETE FROM transcriptions") }
        }
        XCTAssertFalse(try filesContainingMarker(url).isEmpty, "precondition: stale text in free pages")
        do {
            let store = try HistoryStore(url: url)
            _ = try store.append(rec(100, words: 2))
            try store.clear()
        }
        XCTAssertEqual(try filesContainingMarker(url), [])
    }

    func test_capEviction_leavesNoEvictedTextInFile() throws {
        let url = tempURL()
        let evicted = 30
        do {
            let store = try HistoryStore(url: url)
            for i in 1...evicted { _ = try store.append(secretRec(Int64(i), i)) }
            for i in (evicted + 1)...(evicted + HistoryStore.maxEntries) {
                _ = try store.append(rec(Int64(i), words: 2))
            }
            XCTAssertEqual(try store.recent(limit: 1000).count, HistoryStore.maxEntries)
            XCTAssertEqual(try store.recent(limit: 1000).map(\.createdAt).min(), Int64(evicted + 1))
        }
        XCTAssertEqual(try filesContainingMarker(url), [])
    }

    func test_clear_onEmptyDatabase() throws {
        let url = tempURL()
        let store = try HistoryStore(url: url)
        XCTAssertNoThrow(try store.clear())
        XCTAssertNoThrow(try store.clear())
        XCTAssertEqual(try store.recent(limit: 10).count, 0)
        XCTAssertEqual(try store.totalWords(), 0)
        _ = try store.append(rec(1, words: 2))
        XCTAssertEqual(try store.recent(limit: 10).count, 1)
    }

    func test_clear_keepsMetricsRows() throws {
        let store = try makeStore()
        for i in 1...20 { _ = try store.append(secretRec(Int64(i * 10), i)) }
        let words = try store.totalWords()
        let sums = try store.sums(afterMs: 0, toMs: Int64.max)
        let count = try store.count(fromMs: 0, toMs: Int64.max)
        try store.clear()
        XCTAssertEqual(try store.recent(limit: 10).count, 0)
        XCTAssertEqual(try store.totalWords(), words)
        XCTAssertEqual(try store.sums(afterMs: 0, toMs: Int64.max).words, sums.words)
        XCTAssertEqual(try store.sums(afterMs: 0, toMs: Int64.max).durationMs, sums.durationMs)
        XCTAssertEqual(try store.count(fromMs: 0, toMs: Int64.max), count)
        XCTAssertEqual(count, 20)
    }

    func test_clear_postsHistoryDidChange() throws {
        let store = try makeStore()
        _ = try store.append(rec(1))
        let posted = expectation(forNotification: .historyDidChange, object: nil)
        try store.clear()
        wait(for: [posted], timeout: 1)
    }

    func test_migrationBackfillsStatsFromExistingHistory() throws {
        let url = tempURL()
        // Simulate a pre-v2 database: only the v1 schema with some rows.
        do {
            let q = try DatabaseQueue(path: url.path)
            var m = DatabaseMigrator()
            m.registerMigration("v1") { db in
                try db.create(table: "transcriptions") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("createdAt", .integer).notNull().indexed()
                    t.column("rawText", .text).notNull()
                    t.column("cleanedText", .text).notNull()
                    t.column("durationMs", .integer).notNull()
                    t.column("wordCount", .integer).notNull()
                    t.column("language", .text)
                    t.column("inserted", .boolean).notNull().defaults(to: false)
                }
            }
            try m.migrate(q)
            try q.write { db in
                var a = self.rec(1, words: 3, ms: 100); try a.insert(db)
                var b = self.rec(2, words: 4, ms: 200); try b.insert(db)
            }
        }
        let store = try HistoryStore(url: url)
        XCTAssertEqual(try store.totalWords(), 7)
        XCTAssertEqual(try store.sumsSince(0).durationMs, 300)
    }
}
