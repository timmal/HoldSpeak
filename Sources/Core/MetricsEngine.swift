import Foundation

public struct Metrics: Equatable {
    /// Dictations since local midnight, and over the whole previous day.
    public let dictationsToday: Int
    public let dictationsYesterday: Int
    /// `dictationsToday` vs yesterday from its midnight up to this time of day, in percent.
    /// nil when yesterday had no dictations by then. (`dictationsYesterday` stays the
    /// full-day count.)
    public let dictationsTodayChangePercent: Int?
    public let wpm7d: Int           // rounded to nearest int
    /// `wpm7d` vs the same 7-day window as it stood exactly one week ago, in percent.
    /// nil when either window has no dictations.
    public let wpm7dChangePercent: Int?
    public init(dictationsToday: Int, dictationsYesterday: Int, dictationsTodayChangePercent: Int? = nil,
                wpm7d: Int, wpm7dChangePercent: Int? = nil) {
        self.dictationsToday = dictationsToday
        self.dictationsYesterday = dictationsYesterday
        self.dictationsTodayChangePercent = dictationsTodayChangePercent
        self.wpm7d = wpm7d
        self.wpm7dChangePercent = wpm7dChangePercent
    }
    public static let zero = Metrics(dictationsToday: 0, dictationsYesterday: 0, wpm7d: 0)
}

public protocol MetricsComputing {
    func current(now: Date) throws -> Metrics
}

public final class MetricsEngine: MetricsComputing {
    private let store: HistoryStoring
    private let resetAnchor: () -> Int64
    private let calendar: Calendar
    public init(store: HistoryStoring, resetAnchor: @escaping () -> Int64 = { 0 }, calendar: Calendar = .current) {
        self.store = store
        self.resetAnchor = resetAnchor
        self.calendar = calendar
    }

    public func current(now: Date = Date()) throws -> Metrics {
        let anchor = resetAnchor()
        let week: Int64 = 7 * 86_400_000
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        func wpm(afterMs: Int64, toMs: Int64) throws -> Double? {
            let from = max(anchor, afterMs)
            guard from < toMs else { return nil }
            let sums = try store.sums(afterMs: from, toMs: toMs)
            guard sums.durationMs > 0 else { return nil }
            return Double(sums.words) * 60_000.0 / Double(sums.durationMs)
        }
        let wpmNow = try wpm(afterMs: nowMs - week, toMs: Int64.max)
        let wpmWeekAgo = try wpm(afterMs: nowMs - 2 * week, toMs: nowMs - week)
        func percent(_ a: Double, vs b: Double) -> Int { Int(((a - b) / b * 100).rounded()) }
        var wpmChange: Int?
        if let a = wpmNow, let b = wpmWeekAgo, b > 0 { wpmChange = percent(a, vs: b) }

        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
        // "Reset metrics" counts only what came after the anchor (exclusive, as in sums(afterMs:)).
        let floor = anchor + 1
        let today = try store.count(fromMs: max(floor, ms(todayStart)), toMs: Int64.max)
        let yesterday = try store.count(fromMs: max(floor, ms(yesterdayStart)), toMs: ms(todayStart))

        // Yesterday, midnight up to this time of day (calendar day back, so DST-safe).
        // Skipped if a reset falls inside it: a partial day would skew the comparison.
        var todayChange: Int?
        if let yesterdayNow = calendar.date(byAdding: .day, value: -1, to: now) {
            let yesterdayNowStart = calendar.startOfDay(for: yesterdayNow)
            if anchor < ms(yesterdayNowStart) {
                let soFar = try store.count(fromMs: ms(yesterdayNowStart), toMs: ms(yesterdayNow))
                if soFar > 0 { todayChange = percent(Double(today), vs: Double(soFar)) }
            }
        }
        return Metrics(dictationsToday: today, dictationsYesterday: yesterday, dictationsTodayChangePercent: todayChange,
                       wpm7d: Int((wpmNow ?? 0).rounded()), wpm7dChangePercent: wpmChange)
    }
}
