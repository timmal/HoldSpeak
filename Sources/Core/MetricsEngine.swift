import Foundation

public struct Metrics: Equatable {
    public let totalWords: Int
    public let wpm7d: Int           // rounded to nearest int
    public init(totalWords: Int, wpm7d: Int) { self.totalWords = totalWords; self.wpm7d = wpm7d }
}

public protocol MetricsComputing {
    func current(now: Date) throws -> Metrics
}

public final class MetricsEngine: MetricsComputing {
    private let store: HistoryStoring
    public init(store: HistoryStoring) { self.store = store }

    public func current(now: Date = Date()) throws -> Metrics {
        let total = try store.totalWords()
        let sevenDaysAgo = Int64((now.timeIntervalSince1970 - 7 * 86400) * 1000)
        let sums = try store.sumsSince(sevenDaysAgo)
        let wpm: Int
        if sums.durationMs > 0 {
            wpm = Int((Double(sums.words) * 60_000.0 / Double(sums.durationMs)).rounded())
        } else {
            wpm = 0
        }
        return Metrics(totalWords: total, wpm7d: wpm)
    }
}
