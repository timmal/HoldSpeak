import XCTest
@testable import HoldSpeakCore

final class LoggingTests: XCTestCase {
    /// Debug builds (and `swift test`) used to quote the dictated text in the log.
    func test_transcriptsAreRedactedByDefault() {
        XCTAssertEqual(logText("секретный текст"), "<15 chars>")
    }

    func test_transcriptsAreQuotedOnlyWhenAskedFor() {
        XCTAssertEqual(logText("hello", verbatim: true), "\"hello\"")
        XCTAssertEqual(logText("hello", verbatim: false), "<5 chars>")
    }

    // MARK: - Log files

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-logs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func test_logFromBeforeTheRenameIsRemoved() throws {
        let dir = tempDir()
        for name in ["PushToTalk.log", "PushToTalk.log.1", "HoldSpeak.log", "Other.log"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        XCTAssertEqual(removeLegacyLogs(in: dir), ["PushToTalk.log", "PushToTalk.log.1"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["HoldSpeak.log", "Other.log"])
    }

    func test_noLegacyLogIsNotAnError() {
        XCTAssertEqual(removeLegacyLogs(in: tempDir()), [])
    }

    /// The tests log too; that must not land in the user's ~/Library/Logs/HoldSpeak.log.
    func test_testsLogToTheTempDirectory() {
        XCTAssertTrue(logPath.hasPrefix(NSTemporaryDirectory()), logPath)
        XCTAssertFalse(logPath.contains("Library/Logs"), logPath)
    }
}
