import XCTest
@testable import HoldSpeakCore

final class EngineFallbackTests: XCTestCase {
    func test_cloudBackups_otherProvidersWithKey() {
        XCTAssertEqual(EngineFallback.cloudBackups(after: .openai, hasKey: { _ in true }), [.gemini])
        XCTAssertEqual(EngineFallback.cloudBackups(after: .gemini, hasKey: { _ in true }), [.openai])
        // No key, no hop: straight to Whisper.
        XCTAssertEqual(EngineFallback.cloudBackups(after: .openai, hasKey: { $0 == .openai }), [])
    }

    func test_onlyUnreachableCountsAsOffline() {
        XCTAssertTrue(TranscriptionFailure.unreachable(.openai).isOffline)
        XCTAssertFalse(TranscriptionFailure.outOfCredits(.openai).isOffline)
        XCTAssertFalse(TranscriptionFailure.serviceError(.gemini, status: 503).isOffline)
    }

    func test_engineNotice_showsWhySelectedEngineFailed() {
        let notice = ModelFallbackNotice(failure: .outOfCredits(.openai), usedEngine: "Gemini")
        XCTAssertEqual(notice.title, "OpenAI credits used up")
        XCTAssertEqual(notice.body, "Used Gemini instead")
    }

    func test_backupDownloading_keepsOriginalReason() {
        let failure = TranscriptionFailure.backupDownloading(.invalidAPIKey(.openai))
        XCTAssertEqual(failure.title, "OpenAI rejected the API key")
        XCTAssertEqual(failure.body, "Downloading Whisper as a backup…")
        XCTAssertEqual(failure.displaySeconds, 6)
        XCTAssertFalse(failure.warrantsModelFallback)
    }
}
