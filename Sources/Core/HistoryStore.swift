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
    func totalWords() throws -> Int
    func sumsSince(_ unixMs: Int64) throws -> (words: Int, durationMs: Int)
    func clear() throws
}

public final class HistoryStore: HistoryStoring {
    private let dbQueue: DatabaseQueue

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: url.path)
        try migrate()
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("push-to-talk/history.sqlite")
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
        try migrator.migrate(dbQueue)
    }

    public func append(_ record: TranscriptionRecord) throws -> TranscriptionRecord {
        try dbQueue.write { db in
            var r = record
            try r.insert(db)
            return r
        }
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
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(wordCount), 0) FROM transcriptions") ?? 0
        }
    }

    public func sumsSince(_ unixMs: Int64) throws -> (words: Int, durationMs: Int) {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT COALESCE(SUM(wordCount),0) AS w, COALESCE(SUM(durationMs),0) AS d FROM transcriptions WHERE createdAt > ?",
                arguments: [unixMs]) else { return (0, 0) }
            let w: Int = row["w"] ?? 0
            let d: Int = row["d"] ?? 0
            return (w, d)
        }
    }

    public func clear() throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM transcriptions") }
    }
}
