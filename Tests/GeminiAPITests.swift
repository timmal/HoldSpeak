import XCTest
@testable import HoldSpeakCore

final class GeminiAPITests: XCTestCase {
    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: WAV

    func test_wav_hasPCMHeaderAndSize() {
        let data = GeminiAPI.wav([0, 0.5, -0.5, 1])
        XCTAssertEqual(data.count, 44 + 4 * 2)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        let rate = data[24..<28].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        XCTAssertEqual(rate, 16_000)
    }

    func test_wav_clampsSamples() {
        let data = GeminiAPI.wav([2, -2])
        let first = Int16(bitPattern: UInt16(data[44]) | UInt16(data[45]) << 8)
        let second = Int16(bitPattern: UInt16(data[46]) | UInt16(data[47]) << 8)
        XCTAssertEqual(first, Int16.max)
        XCTAssertEqual(second, -Int16.max)
    }

    // MARK: Request

    func test_prompt_includesLanguageAndTerms() {
        let prompt = GeminiAPI.prompt(language: "ru", terms: ["pull request", "merge"])
        XCTAssertTrue(prompt.contains("mostly in Russian"))
        XCTAssertTrue(prompt.contains("pull request, merge"))
    }

    func test_prompt_autoLanguageAndNoTerms() {
        let prompt = GeminiAPI.prompt(language: nil, terms: [])
        XCTAssertFalse(prompt.contains("mostly in"))
        XCTAssertFalse(prompt.contains("Vocabulary"))
    }

    func test_prompt_fillerRemoval() {
        let verbatim = GeminiAPI.prompt(language: "ru", terms: [])
        XCTAssertTrue(verbatim.contains("verbatim"))
        XCTAssertFalse(verbatim.contains("filler"))
        let clean = GeminiAPI.prompt(language: "ru", terms: [], removeFillers: true)
        XCTAssertFalse(clean.contains("verbatim"))
        XCTAssertTrue(clean.contains("filler words"))
    }

    func test_requestBody_thinkingConfigOnlyForFlashLite() throws {
        func config(_ model: GeminiModelID) throws -> [String: Any] {
            let body = try GeminiAPI.requestBody(model: model, prompt: "p", wav: Data([1, 2]))
            let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            return obj["generationConfig"] as! [String: Any]
        }
        XCTAssertNil(try config(.transcribe)["thinkingConfig"])
        XCTAssertNotNil(try config(.flashLite)["thinkingConfig"])
    }

    // MARK: Response

    func test_extractText_regularTextParts_skipsThoughts() {
        let data = json(["candidates": [["content": ["parts": [
            ["text": "thinking…", "thought": true],
            ["text": "Привет, "],
            ["text": "мир."],
        ]]]]])
        XCTAssertEqual(GeminiAPI.extractText(data), "Привет, мир.")
    }

    func test_extractText_audioTranscriptionParts() {
        let data = json(["candidates": [["content": ["parts": [
            ["audioTranscription": ["text": "Запушим в main."]],
            ["thoughtSignature": "abc"],
        ]]]]])
        XCTAssertEqual(GeminiAPI.extractText(data), "Запушим в main.")
    }

    func test_extractText_malformedIsEmpty() {
        XCTAssertEqual(GeminiAPI.extractText(Data("nope".utf8)), "")
        XCTAssertEqual(GeminiAPI.extractText(json(["candidates": []])), "")
    }

    // MARK: Errors

    func test_failure_invalidKey() {
        let body = json(["error": ["code": 400, "message": "API key not valid. Please pass a valid API key.",
                                   "details": [["reason": "API_KEY_INVALID"]]]])
        XCTAssertEqual(GeminiAPI.failure(status: 400, body: body), .invalidAPIKey)
        XCTAssertEqual(GeminiAPI.failure(status: 403, body: Data()), .invalidAPIKey)
    }

    func test_failure_plain400IsServiceError() {
        let body = json(["error": ["code": 400, "message": "Invalid JSON payload"]])
        XCTAssertEqual(GeminiAPI.failure(status: 400, body: body), .serviceError(status: 400))
    }

    func test_failure_dailyQuota() {
        let body = json(["error": ["code": 429, "status": "RESOURCE_EXHAUSTED", "details": [
            ["@type": "type.googleapis.com/google.rpc.QuotaFailure",
             "violations": [["quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier"]]],
            ["@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "41.5s"],
        ]]])
        let failure = GeminiAPI.failure(status: 429, body: body)
        XCTAssertEqual(failure, .quotaExceeded(daily: true, retryAfterSeconds: 42))
        XCTAssertTrue(failure.body.contains("billing"))
    }

    func test_failure_perMinuteQuota() {
        let body = json(["error": ["code": 429, "details": [
            ["violations": [["quotaId": "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"]]],
            ["retryDelay": "12s"],
        ]]])
        XCTAssertEqual(GeminiAPI.failure(status: 429, body: body), .quotaExceeded(daily: false, retryAfterSeconds: 12))
    }

    func test_retryOnlyServerErrors() {
        XCTAssertTrue(GeminiAPI.isRetryable(status: 503))
        XCTAssertTrue(GeminiAPI.isRetryable(status: 500))
        XCTAssertFalse(GeminiAPI.isRetryable(status: 429))
        XCTAssertFalse(GeminiAPI.isRetryable(status: 400))
    }

    // MARK: Model fallback

    func test_fallbackModel_isTheOtherOne() {
        XCTAssertEqual(GeminiModelID.transcribe.fallback, .flashLite)
        XCTAssertEqual(GeminiModelID.flashLite.fallback, .transcribe)
    }

    func test_fallbackOnlyForModelSideErrors() {
        XCTAssertTrue(TranscriptionFailure.serviceError(status: 400).warrantsModelFallback)
        XCTAssertTrue(TranscriptionFailure.serviceError(status: 404).warrantsModelFallback)
        XCTAssertTrue(TranscriptionFailure.serviceError(status: 503).warrantsModelFallback)
        XCTAssertFalse(TranscriptionFailure.invalidAPIKey.warrantsModelFallback)
        XCTAssertFalse(TranscriptionFailure.missingAPIKey.warrantsModelFallback)
        XCTAssertFalse(TranscriptionFailure.quotaExceeded(daily: true, retryAfterSeconds: nil).warrantsModelFallback)
        XCTAssertFalse(TranscriptionFailure.unreachable.warrantsModelFallback)
    }

    func test_fallbackPolicy_preferredFirstUntilItFails() {
        var policy = GeminiFallbackPolicy(cooldown: 1800)
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(policy.order(preferred: .transcribe, now: now), [.transcribe, .flashLite])

        policy.markFailed(.transcribe, now: now)
        XCTAssertEqual(policy.order(preferred: .transcribe, now: now.addingTimeInterval(60)), [.flashLite, .transcribe])
        // Only the failed model is skipped: picking the other one in Preferences is unaffected.
        XCTAssertEqual(policy.order(preferred: .flashLite, now: now.addingTimeInterval(60)), [.flashLite, .transcribe])
        // After the cooldown the preferred model gets another try.
        XCTAssertEqual(policy.order(preferred: .transcribe, now: now.addingTimeInterval(1801)), [.transcribe, .flashLite])
    }

    func test_fallbackPolicy_successClearsFailure() {
        var policy = GeminiFallbackPolicy(cooldown: 1800)
        let now = Date(timeIntervalSince1970: 1_000_000)
        policy.markFailed(.transcribe, now: now)
        policy.markSucceeded(.transcribe)
        XCTAssertEqual(policy.order(preferred: .transcribe, now: now), [.transcribe, .flashLite])
    }

    func test_costPerHour_perModel() {
        XCTAssertEqual(GeminiModelID.transcribe.costPerHour, "$0.30")
        XCTAssertEqual(GeminiModelID.flashLite.costPerHour, "$0.06")
    }

    func test_fallbackNotice_namesBothModels() {
        let notice = ModelFallbackNotice(failed: .transcribe, used: .flashLite)
        XCTAssertEqual(notice.title, "3.5 Transcribe unavailable")
        XCTAssertEqual(notice.body, "Used 3.5 Flash-Lite instead")
    }
}
