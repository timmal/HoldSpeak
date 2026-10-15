import Foundation
import GRDB

public struct TranscriptionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public var id: Int64?
    public var createdAt: Int64
    public var rawText: String
    public var cleanedText: String
    public var durationMs: Int
    public var wordCount: Int
    public var language: String?
    public var inserted: Bool

    public static let databaseTableName = "transcriptions"

    public init(id: Int64? = nil, createdAt: Int64, rawText: String, cleanedText: String,
                durationMs: Int, wordCount: Int, language: String?, inserted: Bool) {
        self.id = id; self.createdAt = createdAt; self.rawText = rawText; self.cleanedText = cleanedText
        self.durationMs = durationMs; self.wordCount = wordCount; self.language = language; self.inserted = inserted
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public protocol HistoryStoring {
    func append(_ record: TranscriptionRecord) throws -> TranscriptionRecord
    func recent(limit: Int) throws -> [TranscriptionRecord]
    /// Metrics query: covers every utterance ever appended, not just the
    /// pruned history window shown to the user.
    /// Words and audio duration over `afterMs < createdAt <= toMs`.
    func sums(afterMs: Int64, toMs: Int64) throws -> (words: Int, durationMs: Int)
    /// Dictations with `fromMs <= createdAt < toMs`, from the same unpruned table.
    func count(fromMs: Int64, toMs: Int64) throws -> Int
    /// Clears the visible history (transcript text) only. Metrics are kept;
    /// they have their own reset via `metricsResetAtMs`.
    func clear() throws
}

extension Notification.Name {
    public static let historyDidChange = Notification.Name("historyDidChange")
}

public final class HistoryStore: HistoryStoring {
    public static let maxEntries = 100

    private let dbQueue: DatabaseQueue

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: url.path)
        try migrate()
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HoldSpeak/history.sqlite")
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
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
        // History text is pruned to `maxEntries`, so metrics live in a separate
        // text-free table that is never pruned (rows are a few bytes each).
        migrator.registerMigration("v2_utterance_stats") { db in
            try db.create(table: "utterance_stats") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .integer).notNull().indexed()
                t.column("wordCount", .integer).notNull()
                t.column("durationMs", .integer).notNull()
            }
            try db.execute(sql: """
                INSERT INTO utterance_stats (createdAt, wordCount, durationMs)
                SELECT createdAt, wordCount, durationMs FROM transcriptions
                """)
        }
        try migrator.migrate(dbQueue)
    }

    public func append(_ record: TranscriptionRecord) throws -> TranscriptionRecord {
        let saved = try dbQueue.write { db -> TranscriptionRecord in
            var r = record
            try r.insert(db)
            try db.execute(
                sql: "INSERT INTO utterance_stats (createdAt, wordCount, durationMs) VALUES (?, ?, ?)",
                arguments: [r.createdAt, r.wordCount, r.durationMs]
            )
            try db.execute(
                sql: """
                DELETE FROM transcriptions
                WHERE id NOT IN (
                    SELECT id FROM transcriptions
                    ORDER BY createdAt DESC, id DESC
                    LIMIT ?
                )
                """,
                arguments: [Self.maxEntries]
            )
            return r
        }
        NotificationCenter.default.post(name: .historyDidChange, object: nil)
        return saved
    }

    public func recent(limit: Int) throws -> [TranscriptionRecord] {
        try dbQueue.read { db in
            try TranscriptionRecord
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func totalWords() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(wordCount), 0) FROM utterance_stats") ?? 0
        }
    }

    public func sumsSince(_ unixMs: Int64) throws -> (words: Int, durationMs: Int) {
        try sums(afterMs: unixMs, toMs: Int64.max)
    }

    public func sums(afterMs: Int64, toMs: Int64) throws -> (words: Int, durationMs: Int) {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT COALESCE(SUM(wordCount),0) AS w, COALESCE(SUM(durationMs),0) AS d FROM utterance_stats WHERE createdAt > ? AND createdAt <= ?",
                arguments: [afterMs, toMs]) else { return (0, 0) }
            let w: Int = row["w"] ?? 0
            let d: Int = row["d"] ?? 0
            return (w, d)
        }
    }

    public func count(fromMs: Int64, toMs: Int64) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM utterance_stats WHERE createdAt >= ? AND createdAt < ?",
                arguments: [fromMs, toMs]) ?? 0
        }
    }

    /// Deletes history rows only; `utterance_stats` is intentionally untouched so
    /// "Clear history" doesn't wipe metrics ("Reset metrics" moves the anchor instead).
    public func clear() throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM transcriptions") }
        NotificationCenter.default.post(name: .historyDidChange, object: nil)
    }
}
