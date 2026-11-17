import XCTest
@testable import HoldSpeakCore

final class HistoryRecoveryTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-history-recovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func files(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func write(_ text: String, to url: URL) {
        try! Data(text.utf8).write(to: url)
    }

    private func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    func test_movesDatabaseAndSidecarsUnderOneBrokenName() throws {
        let dir = tempDir()
        let db = dir.appendingPathComponent("history.sqlite")
        write("main", to: db)
        write("wal", to: URL(fileURLWithPath: db.path + "-wal"))
        write("shm", to: URL(fileURLWithPath: db.path + "-shm"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let base = "history.sqlite.broken-\(stamp(date))"

        let moved = try HistoryRecovery.moveAside(db, date: date)

        XCTAssertEqual(Set(moved.map(\.lastPathComponent)), [base, "\(base)-wal", "\(base)-shm"])
        XCTAssertEqual(files(in: dir), [base, "\(base)-shm", "\(base)-wal"])
        // Bytes kept, and each sidecar still pairs with its database by SQLite's naming.
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(base)), "main")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("\(base)-wal")), "wal")
    }

    func test_journalAloneIsMovedToo() throws {
        let dir = tempDir()
        let db = dir.appendingPathComponent("history.sqlite")
        write("main", to: db)
        write("journal", to: URL(fileURLWithPath: db.path + "-journal"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let base = "history.sqlite.broken-\(stamp(date))"

        _ = try HistoryRecovery.moveAside(db, date: date)

        XCTAssertEqual(files(in: dir), [base, "\(base)-journal"])
    }

    func test_earlierBackupWithTheSameStampIsNotOverwritten() throws {
        let dir = tempDir()
        let db = dir.appendingPathComponent("history.sqlite")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let base = "history.sqlite.broken-\(stamp(date))"
        write("older", to: dir.appendingPathComponent(base))
        write("main", to: db)

        let moved = try HistoryRecovery.moveAside(db, date: date)

        XCTAssertEqual(moved.map(\.lastPathComponent), ["\(base)-2"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(base)), "older")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("\(base)-2")), "main")
    }

    func test_nothingToMoveIsNotAnError() throws {
        let dir = tempDir()
        XCTAssertEqual(try HistoryRecovery.moveAside(dir.appendingPathComponent("history.sqlite")), [])
        XCTAssertEqual(files(in: dir), [])
    }

    /// The launch path: a file that isn't a database fails to open; once moved aside, a
    /// fresh history opens in its place and the broken bytes are still there.
    func test_freshHistoryOpensAfterTheBrokenFileIsMovedAside() throws {
        let dir = tempDir()
        let db = dir.appendingPathComponent("history.sqlite")
        write(String(repeating: "not a database ", count: 100), to: db)
        XCTAssertThrowsError(try HistoryStore(url: db))

        let moved = try HistoryRecovery.moveAside(db)
        let store = try HistoryStore(url: db)

        XCTAssertTrue(try store.recent(limit: 10).isEmpty)
        // The database itself is moved last, after any sidecars.
        XCTAssertTrue(try String(contentsOf: moved.last!).hasPrefix("not a database"))
    }
}
