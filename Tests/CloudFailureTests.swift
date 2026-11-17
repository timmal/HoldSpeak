import XCTest
@testable import HoldSpeakCore

/// HS-40: how cloud requests fail, end to end through the clients with a stubbed session.
final class CloudFailureTests: XCTestCase {
    private let wav = CloudAudio.wav([Float](repeating: 0.1, count: 1600))

    private func geminiFailure(durationMs: Int = 1000, wav: Data? = nil) async -> TranscriptionFailure? {
        do {
            _ = try await GeminiClient(session: URLStub.session())
                .transcribe(wav: wav ?? self.wav, model: .transcribe, prompt: "p", apiKey: "AIzaTEST",
                            durationMs: durationMs)
            return nil
        } catch {
            return error as? TranscriptionFailure
        }
    }

    private func openAIFailure(durationMs: Int = 1000, wav: Data? = nil) async -> TranscriptionFailure? {
        do {
            _ = try await OpenAIClient(session: URLStub.session())
                .transcribe(wav: wav ?? self.wav, model: .transcribe, language: nil, terms: [], apiKey: "sk-TEST",
                            durationMs: durationMs)
            return nil
        } catch {
            return error as? TranscriptionFailure
        }
    }

    // MARK: 1. Timeout

    func test_timedOut_strings() {
        XCTAssertEqual(TranscriptionFailure.timedOut(.gemini).title, "Gemini took too long")
        XCTAssertEqual(TranscriptionFailure.timedOut(.openai).title, "OpenAI took too long")
        XCTAssertEqual(TranscriptionFailure.timedOut(.openai).body, "Try again, or dictate in shorter takes")
    }

    func test_timedOut_isNotOfflineAndNoModelFallback() {
        let failure = TranscriptionFailure.timedOut(.gemini)
        XCTAssertFalse(failure.isOffline)
        XCTAssertFalse(failure.warrantsModelFallback)
    }

    func test_transportError_onlyTimeoutIsTimedOut() {
        XCTAssertEqual(TranscriptionFailure.transport(URLError(.timedOut), provider: .gemini), .timedOut(.gemini))
        XCTAssertEqual(TranscriptionFailure.transport(URLError(.notConnectedToInternet), provider: .openai), .unreachable(.openai))
        XCTAssertEqual(TranscriptionFailure.transport(URLError(.networkConnectionLost), provider: .openai), .unreachable(.openai))
        XCTAssertEqual(TranscriptionFailure.transport(CocoaError(.fileNoSuchFile), provider: .gemini), .unreachable(.gemini))
    }

    func test_clients_mapTimeoutAndDoNotRetryIt() async {
        URLStub.reset { _ in .error(URLError(.timedOut)) }
        let gemini = await geminiFailure()
        XCTAssertEqual(gemini, .timedOut(.gemini))
        XCTAssertEqual(URLStub.requests.count, 1)

        URLStub.reset { _ in .error(URLError(.timedOut)) }
        let openai = await openAIFailure()
        XCTAssertEqual(openai, .timedOut(.openai))
        XCTAssertEqual(URLStub.requests.count, 1)
    }

    func test_clients_otherTransportErrorsStayUnreachable() async {
        URLStub.reset { _ in .error(URLError(.notConnectedToInternet)) }
        let gemini = await geminiFailure()
        XCTAssertEqual(gemini, .unreachable(.gemini))
        let openai = await openAIFailure()
        XCTAssertEqual(openai, .unreachable(.openai))
    }

    // MARK: 2. Timeout grows with the take

    func test_requestTimeout_flatThenGrowsThenCapped() {
        XCTAssertEqual(CloudLimits.requestTimeout(durationMs: 0), 20)
        XCTAssertEqual(CloudLimits.requestTimeout(durationMs: 5_000), 20)
        XCTAssertEqual(CloudLimits.requestTimeout(durationMs: 20_000), 20)
        XCTAssertEqual(CloudLimits.requestTimeout(durationMs: 21_000), 20.5)
        XCTAssertEqual(CloudLimits.requestTimeout(durationMs: 60_000), 40)
        XCTAssertEqual(CloudLimits.requestTimeout(durationMs: 160_000), 90)
        XCTAssertEqual(CloudLimits.requestTimeout(durationMs: 600_000), 90)
    }

    func test_clients_useTheTakesTimeout() async {
        URLStub.reset { _ in .error(URLError(.notConnectedToInternet)) }
        _ = await geminiFailure(durationMs: 60_000)
        _ = await openAIFailure(durationMs: 300_000)
        XCTAssertEqual(URLStub.requests.map(\.timeoutInterval), [40, 90])
    }

    // MARK: 3. Oversized takes

    func test_audioTooLong_strings() {
        XCTAssertEqual(TranscriptionFailure.audioTooLong(.gemini).title, "Take too long for Gemini")
        XCTAssertEqual(TranscriptionFailure.audioTooLong(.openai).title, "Take too long for OpenAI")
        XCTAssertEqual(TranscriptionFailure.audioTooLong(.openai).body, "Dictate in shorter takes")
    }

    func test_audioTooLong_isNotOfflineAndNoModelFallback() {
        let failure = TranscriptionFailure.audioTooLong(.openai)
        XCTAssertFalse(failure.isOffline)
        XCTAssertFalse(failure.warrantsModelFallback)
    }

    func test_uploadLimits() {
        XCTAssertEqual(CloudLimits.maxUploadBytes(.openai), 25_000_000)
        XCTAssertEqual(CloudLimits.maxUploadBytes(.gemini), 20_000_000)
        // 16 kHz 16-bit mono is 32 kB/s: about 13 min for OpenAI's file, and Gemini's
        // base64 request (4/3 of the WAV) runs out after about 7.8 min.
        let openAISeconds = CloudLimits.maxUploadBytes(.openai) / 32_000
        let geminiSeconds = CloudLimits.maxUploadBytes(.gemini) * 3 / 4 / 32_000
        XCTAssertEqual(openAISeconds, 781)
        XCTAssertEqual(geminiSeconds, 468)
    }

    func test_http413_isAudioTooLong() {
        XCTAssertEqual(GeminiAPI.failure(status: 413, body: Data()), .audioTooLong(.gemini))
        XCTAssertEqual(OpenAIAPI.failure(status: 413, body: Data()), .audioTooLong(.openai))
    }

    func test_gemini400PayloadTooLarge_isAudioTooLong() throws {
        let body = try JSONSerialization.data(withJSONObject: ["error": [
            "code": 400, "status": "INVALID_ARGUMENT",
            "message": "Request payload size exceeds the limit: 20971520 bytes."]])
        XCTAssertEqual(GeminiAPI.failure(status: 400, body: body), .audioTooLong(.gemini))
    }

    func test_clients_rejectOversizedAudioWithoutUploading() async {
        URLStub.reset { _ in .http(status: 200, body: Data()) }
        // Base64 makes 15.1 MB of WAV a 20.1 MB request.
        let gemini = await geminiFailure(wav: Data(count: 15_100_000))
        XCTAssertEqual(gemini, .audioTooLong(.gemini))
        let openai = await openAIFailure(wav: Data(count: 25_000_001))
        XCTAssertEqual(openai, .audioTooLong(.openai))
        XCTAssertTrue(URLStub.requests.isEmpty)
    }

    func test_clients_uploadAudioUnderTheLimit() async {
        URLStub.reset { _ in .http(status: 200, body: Data()) }
        _ = await geminiFailure(wav: Data(count: 14_000_000))
        _ = await openAIFailure(wav: Data(count: 24_000_000))
        XCTAssertEqual(URLStub.requests.count, 2)
    }

    func test_clients_413IsNotRetried() async {
        URLStub.reset { _ in .http(status: 413, body: Data("Request Entity Too Large".utf8)) }
        let gemini = await geminiFailure()
        XCTAssertEqual(gemini, .audioTooLong(.gemini))
        let openai = await openAIFailure()
        XCTAssertEqual(openai, .audioTooLong(.openai))
        XCTAssertEqual(URLStub.requests.count, 2)
    }

    // MARK: 4. Blocked responses

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func test_blocked_strings() {
        XCTAssertEqual(TranscriptionFailure.blocked(.gemini).title, "Gemini blocked this take")
        XCTAssertEqual(TranscriptionFailure.blocked(.gemini).body, "Flagged by its content filter")
        XCTAssertFalse(TranscriptionFailure.blocked(.gemini).isOffline)
        XCTAssertFalse(TranscriptionFailure.blocked(.gemini).warrantsModelFallback)
    }

    func test_gemini_promptBlocked() {
        let data = json(["promptFeedback": ["blockReason": "PROHIBITED_CONTENT"],
                         "usageMetadata": ["promptTokenCount": 120]])
        XCTAssertThrowsError(try GeminiAPI.transcript(data)) { error in
            XCTAssertEqual(error as? TranscriptionFailure, .blocked(.gemini))
        }
    }

    func test_gemini_candidateStoppedBySafetyOrRecitation() {
        for reason in ["SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII"] {
            let data = json(["candidates": [["finishReason": reason, "index": 0,
                                             "safetyRatings": [["category": "HARM_CATEGORY_HARASSMENT",
                                                                "probability": "HIGH", "blocked": true]]]]])
            XCTAssertThrowsError(try GeminiAPI.transcript(data), reason) { error in
                XCTAssertEqual(error as? TranscriptionFailure, .blocked(.gemini))
            }
        }
    }

    func test_gemini_plainEmptyTranscriptStaysEmpty() throws {
        // Silence: the model stops normally with no parts, or an empty text part.
        XCTAssertEqual(try GeminiAPI.transcript(json(["candidates": [["finishReason": "STOP",
                                                                         "content": ["role": "model"]]]])), "")
        XCTAssertEqual(try GeminiAPI.transcript(json(["candidates": [["finishReason": "STOP",
                                                                         "content": ["parts": [["text": ""]]]]]])), "")
        XCTAssertEqual(try GeminiAPI.transcript(json(["candidates": []])), "")
        XCTAssertEqual(try GeminiAPI.transcript(json(["promptFeedback": ["blockReason": "BLOCK_REASON_UNSPECIFIED"]])), "")
    }

    func test_gemini_textWinsOverAStopReason() throws {
        // Recitation can cut a transcript short; what came back is still typed.
        let data = json(["candidates": [["finishReason": "RECITATION",
                                         "content": ["parts": [["text": "Hello world"]]]]]])
        XCTAssertEqual(try GeminiAPI.transcript(data), "Hello world")
    }

    func test_geminiClient_blockedResponse() async {
        URLStub.reset { [self] _ in .http(status: 200, body: json(["promptFeedback": ["blockReason": "SAFETY"]])) }
        let failure = await geminiFailure()
        XCTAssertEqual(failure, .blocked(.gemini))
        XCTAssertEqual(URLStub.requests.count, 1)
    }

    // MARK: 5. Keys never reach the log

    func test_redact_openAI401EchoesAMaskedKey() {
        let body = """
        {
            "error": {
                "message": "Incorrect API key provided: sk-proj-********************************************************************************************************************************************************Ab3d. You can find your API key at https://platform.openai.com/account/api-keys.",
                "type": "invalid_request_error",
                "param": null,
                "code": "invalid_api_key"
            }
        }
        """
        let redacted = LogRedaction.apiKeys(body)
        XCTAssertFalse(redacted.contains("sk-"))
        XCTAssertFalse(redacted.contains("Ab3d"))
        XCTAssertTrue(redacted.contains("Incorrect API key provided: <redacted>. You can find your API key at https://platform.openai.com/account/api-keys."))
        XCTAssertTrue(redacted.contains("\"code\": \"invalid_api_key\""))
    }

    func test_redact_ellipsisMasksAndFullKeys() {
        XCTAssertEqual(LogRedaction.apiKeys("Incorrect API key provided: sk-abc12…wxyz."),
                       "Incorrect API key provided: <redacted>.")
        XCTAssertEqual(LogRedaction.apiKeys("key sk-abc12...wxyz here"), "key <redacted> here")
        XCTAssertEqual(LogRedaction.apiKeys(#"{"message":"key sk-abc…wxyz"}"#), #"{"message":"key <redacted>"}"#)
        // Built at runtime: no key-shaped literal in the repo for secret scanners to flag.
        let fullKey = "sk-proj-" + String(repeating: "Ab_Cd-12", count: 5)
        XCTAssertEqual(LogRedaction.apiKeys(fullKey), "<redacted>")
    }

    func test_redact_googleKeys() {
        // Same length and alphabet as a real key, assembled here rather than written out.
        let fakeKey = "AIza" + String(repeating: "x9-Q_", count: 7)
        let body = """
        {"error": {"code": 403, "message": "Permission denied: Consumer 'api_key:\(fakeKey)' has been suspended.", "status": "PERMISSION_DENIED"}}
        """
        let redacted = LogRedaction.apiKeys(body)
        XCTAssertFalse(redacted.contains("AIza"))
        XCTAssertTrue(redacted.contains("Consumer 'api_key:<redacted>' has been suspended."))
        XCTAssertEqual(LogRedaction.apiKeys("AIzaSy…3bC6"), "<redacted>")
    }

    func test_redact_leavesOrdinaryTextAlone() {
        let text = #"{"error": {"message": "Invalid JSON payload: task-force, desk-top, risk-free", "code": 400}}"#
        XCTAssertEqual(LogRedaction.apiKeys(text), text)
    }
}
