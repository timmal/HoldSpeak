import XCTest
@testable import PushToTalkCore

private final class MockStore: HistoryStoring {
    var total = 0
    var sums: (Int, Int) = (0, 0)
    func append(_ record: TranscriptionRecord) throws -> TranscriptionRecord { record }
    func recent(limit: Int) throws -> [TranscriptionRecord] { [] }
    func totalWords() throws -> Int { total }
    func sumsSince(_ unixMs: Int64) throws -> (words: Int, durationMs: Int) { sums }
    func clear() throws {}
}

final class MetricsEngineTests: XCTestCase {
    func test_computesTotalAndWpm() throws {
        let s = MockStore()
        s.total = 9313
        s.sums = (1280, 600_000) // 1280 words in 10 minutes → 128 wpm
        let engine = MetricsEngine(store: s)
        XCTAssertEqual(try engine.current(), Metrics(totalWords: 9313, wpm7d: 128))
    }

    func test_zeroDurationGivesZeroWpm() throws {
        let s = MockStore()
        s.total = 0
        s.sums = (0, 0)
        let engine = MetricsEngine(store: s)
        XCTAssertEqual(try engine.current().wpm7d, 0)
    }
}
