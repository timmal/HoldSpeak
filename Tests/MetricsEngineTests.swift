import XCTest
@testable import HoldSpeakCore

/// Stands in for the metrics side of `HistoryStore` (the unpruned `utterance_stats`
/// table), so sums here are independent of the 100-entry history cap.
private final class MockStore: HistoryStoring {
    var recentSums: (Int, Int) = (0, 0)
    func append(_ record: TranscriptionRecord) throws -> TranscriptionRecord { record }
    func recent(limit: Int) throws -> [TranscriptionRecord] { [] }
    func sums(afterMs: Int64, toMs: Int64) throws -> (words: Int, durationMs: Int) { recentSums }
    func count(fromMs: Int64, toMs: Int64) throws -> Int { 0 }
    func clear() throws {}
}

final class MetricsEngineTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func makeStore() throws -> HistoryStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pt-test-\(UUID().uuidString).sqlite")
        return try HistoryStore(url: url)
    }

    private func add(_ store: HistoryStore, at date: Date, words: Int = 10, durationMs: Int = 6000) throws {
        _ = try store.append(.init(createdAt: Int64(date.timeIntervalSince1970 * 1000), rawText: "", cleanedText: "",
                                   durationMs: durationMs, wordCount: words, language: nil, inserted: true))
    }

    func test_computesWpm() throws {
        let s = MockStore()
        s.recentSums = (1280, 600_000) // 1280 words in 10 minutes → 128 wpm
        XCTAssertEqual(try MetricsEngine(store: s).current().wpm7d, 128)
    }

    func test_zeroDurationGivesZeroWpm() throws {
        XCTAssertEqual(try MetricsEngine(store: MockStore()).current().wpm7d, 0)
    }

    func test_countsTodayAndYesterdayByCalendarDay() throws {
        let store = try makeStore()
        let now = ISO8601DateFormatter().date(from: "2026-10-03T10:00:00Z")!
        try add(store, at: now.addingTimeInterval(-60))                 // today
        try add(store, at: now.addingTimeInterval(-9 * 3600))           // 01:00 today
        try add(store, at: now.addingTimeInterval(-10 * 3600 - 1))      // 23:59:59 yesterday
        try add(store, at: now.addingTimeInterval(-33 * 3600))          // 01:00 yesterday
        try add(store, at: now.addingTimeInterval(-35 * 3600))          // two days ago
        let m = try MetricsEngine(store: store, calendar: utc).current(now: now)
        XCTAssertEqual(m.dictationsToday, 2)
        XCTAssertEqual(m.dictationsYesterday, 2)
    }

    func test_resetAnchorHidesEarlierDictations() throws {
        let store = try makeStore()
        let now = ISO8601DateFormatter().date(from: "2026-10-03T10:00:00Z")!
        try add(store, at: now.addingTimeInterval(-3600))
        try add(store, at: now.addingTimeInterval(-60))
        let anchor = Int64(now.addingTimeInterval(-1800).timeIntervalSince1970 * 1000)
        let m = try MetricsEngine(store: store, resetAnchor: { anchor }, calendar: utc).current(now: now)
        XCTAssertEqual(m.dictationsToday, 1)
        XCTAssertEqual(m.dictationsYesterday, 0)
    }

    func test_realStore_countsNotCappedByHistoryPruning() throws {
        let store = try makeStore()
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let n = HistoryStore.maxEntries * 2
        for i in 0..<n {
            _ = try store.append(.init(createdAt: nowMs - Int64(n - i), rawText: "", cleanedText: "",
                                       durationMs: 60_000, wordCount: 100, language: nil, inserted: true))
        }
        try store.clear() // clearing history must not reset metrics
        let m = try MetricsEngine(store: store).current(now: now)
        XCTAssertEqual(m.wpm7d, 100)
        // All were appended within the last second; unless that straddles midnight they count as today.
        XCTAssertEqual(m.dictationsToday + m.dictationsYesterday, n)
    }

    func test_wpmChangeComparesWithSameWindowAWeekAgo() throws {
        let store = try makeStore()
        let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
        let day: TimeInterval = 86400
        try add(store, at: now.addingTimeInterval(-1 * day), words: 110, durationMs: 60_000)  // 110 wpm now
        try add(store, at: now.addingTimeInterval(-8 * day), words: 100, durationMs: 60_000)  // 100 wpm a week ago
        try add(store, at: now.addingTimeInterval(-15 * day), words: 999, durationMs: 60_000) // outside both windows
        let m = try MetricsEngine(store: store, calendar: utc).current(now: now)
        XCTAssertEqual(m.wpm7d, 110)
        XCTAssertEqual(m.wpm7dChangePercent, 10)
    }

    func test_wpmChangeIsNilWithoutLastWeekData() throws {
        let store = try makeStore()
        let now = Date()
        try add(store, at: now.addingTimeInterval(-60))
        XCTAssertNil(try MetricsEngine(store: store).current(now: now).wpm7dChangePercent)
    }

    func test_wpmChangeIsNilWhenResetHidesLastWeek() throws {
        let store = try makeStore()
        let now = Date()
        try add(store, at: now.addingTimeInterval(-60))
        try add(store, at: now.addingTimeInterval(-8 * 86400))
        let anchor = Int64(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        XCTAssertNil(try MetricsEngine(store: store, resetAnchor: { anchor }).current(now: now).wpm7dChangePercent)
    }

    func test_todayChangeComparesWithSameTimeAWeekAgo() throws {
        let store = try makeStore()
        let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        for h in 1...3 { try add(store, at: now.addingTimeInterval(-Double(h) * 3600)) }     // 3 today
        for h in 1...2 { try add(store, at: weekAgo.addingTimeInterval(-Double(h) * 3600)) } // 2 by noon a week ago
        try add(store, at: weekAgo.addingTimeInterval(3600))                                // after noon: not counted
        let m = try MetricsEngine(store: store, calendar: utc).current(now: now)
        XCTAssertEqual(m.dictationsToday, 3)
        XCTAssertEqual(m.dictationsTodayChangePercent, 50)
    }

    func test_todayChangeIsNilWhenResetFallsInsideLastWeeksDay() throws {
        let store = try makeStore()
        let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        try add(store, at: now.addingTimeInterval(-3600))
        try add(store, at: weekAgo.addingTimeInterval(-3600))
        let anchor = Int64(weekAgo.addingTimeInterval(-7200).timeIntervalSince1970 * 1000)
        let m = try MetricsEngine(store: store, resetAnchor: { anchor }, calendar: utc).current(now: now)
        XCTAssertNil(m.dictationsTodayChangePercent)
    }
}
