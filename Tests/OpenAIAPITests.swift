import XCTest
@testable import HoldSpeakCore

final class OpenAIAPITests: XCTestCase {
    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func values(_ fields: [(name: String, value: String)], _ name: String) -> [String] {
        fields.filter { $0.name == name }.map(\.value)
    }

    // MARK: Request

    func test_fields_gptTranscribe_keywordsAndLanguages() {
        let fields = OpenAIAPI.fields(model: .transcribe, language: "ru", terms: ["pull request", "merge"])
        XCTAssertEqual(values(fields, "model"), ["gpt-transcribe"])
        XCTAssertEqual(values(fields, "keywords[]"), ["pull request", "merge"])
        XCTAssertEqual(values(fields, "languages[]"), ["ru"])
        // `languages` replaces `language`; sending both is rejected.
        XCTAssertTrue(values(fields, "language").isEmpty)
        let prompt = values(fields, "prompt").first ?? ""
        XCTAssertTrue(prompt.contains("mostly in Russian"))
        XCTAssertFalse(prompt.contains("pull request"))
    }

    func test_fields_miniTranscribe_termsInPromptAndSingleLanguage() {
        let fields = OpenAIAPI.fields(model: .miniTranscribe, language: "en", terms: ["Kubernetes"])
        XCTAssertEqual(values(fields, "model"), ["gpt-4o-mini-transcribe"])
        XCTAssertEqual(values(fields, "language"), ["en"])
        XCTAssertTrue(values(fields, "keywords[]").isEmpty)
        XCTAssertTrue(values(fields, "languages[]").isEmpty)
        XCTAssertTrue(values(fields, "prompt").first?.contains("Terms: Kubernetes.") == true)
    }

    func test_fields_autoLanguageAndNoTerms() {
        let fields = OpenAIAPI.fields(model: .transcribe, language: nil, terms: [])
        XCTAssertTrue(values(fields, "languages[]").isEmpty)
        XCTAssertTrue(values(fields, "keywords[]").isEmpty)
        XCTAssertFalse(values(fields, "prompt").first?.contains("mostly in") == true)
    }

    func test_keywords_dropForbiddenCharactersAndDuplicates() {
        XCTAssertEqual(OpenAIAPI.keywords([" Git ", "a<b", "line\nbreak", "", "Git", "PR"]), ["Git", "PR"])
    }

    func test_multipartBody_fieldsThenFile() {
        let body = OpenAIAPI.multipartBody(fields: [("model", "gpt-transcribe")], wav: Data("RIFF".utf8), boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF\r\n"))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
    }

    // MARK: Response

    func test_extractTranscript_textAndLanguage() {
        let reply = OpenAIAPI.extractTranscript(json(["text": "Запушим в main.", "languages": [["code": "ru"]]]))
        XCTAssertEqual(reply.text, "Запушим в main.")
        XCTAssertEqual(reply.language, "ru")
    }

    func test_extractTranscript_normalizesLanguageCodes() {
        XCTAssertEqual(OpenAIAPI.extractTranscript(json(["text": "x", "languages": [["code": "eng"]]])).language, "en")
        XCTAssertEqual(OpenAIAPI.extractTranscript(json(["text": "x", "languages": [["code": "zh-cn"]]])).language, "zh")
        XCTAssertNil(OpenAIAPI.extractTranscript(json(["text": "x", "languages": []])).language)
        XCTAssertNil(OpenAIAPI.extractTranscript(json(["text": "x"])).language)
    }

    func test_extractTranscript_malformedIsEmpty() {
        XCTAssertEqual(OpenAIAPI.extractTranscript(Data("nope".utf8)).text, "")
    }

    // MARK: Errors

    func test_failure_invalidKey() {
        let body = json(["error": ["message": "Incorrect API key provided", "type": "invalid_request_error", "code": "invalid_api_key"]])
        XCTAssertEqual(OpenAIAPI.failure(status: 401, body: body), .invalidAPIKey(.openai))
        XCTAssertEqual(OpenAIAPI.failure(status: 403, body: Data()), .invalidAPIKey(.openai))
    }

    func test_failure_outOfCredits() {
        let body = json(["error": ["message": "You exceeded your current quota", "type": "insufficient_quota", "code": "insufficient_quota"]])
        let failure = OpenAIAPI.failure(status: 429, body: body)
        XCTAssertEqual(failure, .outOfCredits(.openai))
        XCTAssertFalse(failure.warrantsModelFallback)
        XCTAssertEqual(failure.title, "OpenAI credits used up")
    }

    func test_failure_rateLimit() {
        let body = json(["error": ["message": "Rate limit reached", "code": "rate_limit_exceeded"]])
        let failure = OpenAIAPI.failure(status: 429, body: body, retryAfter: "7")
        XCTAssertEqual(failure, .quotaExceeded(.openai, daily: false, retryAfterSeconds: 7))
        XCTAssertEqual(failure.body, "Retry in 7 s")
        XCTAssertFalse(failure.body.contains("AI Studio"))
    }

    func test_failure_otherIsServiceError() {
        XCTAssertEqual(OpenAIAPI.failure(status: 400, body: Data()), .serviceError(.openai, status: 400))
        XCTAssertEqual(OpenAIAPI.failure(status: 500, body: Data()), .serviceError(.openai, status: 500))
        XCTAssertEqual(TranscriptionFailure.serviceError(.openai, status: 500).title, "OpenAI error (HTTP 500)")
    }

    func test_failureMessagesNameTheProvider() {
        XCTAssertEqual(TranscriptionFailure.missingAPIKey(.openai).title, "No OpenAI API key")
        XCTAssertEqual(TranscriptionFailure.invalidAPIKey(.openai).title, "OpenAI rejected the API key")
        XCTAssertEqual(TranscriptionFailure.invalidAPIKey(.gemini).title, "Google rejected the API key")
        XCTAssertEqual(TranscriptionFailure.unreachable(.openai).title, "OpenAI unreachable")
    }

    // MARK: Models

    func test_fallbackAndPrices() {
        XCTAssertEqual(OpenAIModelID.transcribe.fallback, .miniTranscribe)
        XCTAssertEqual(OpenAIModelID.miniTranscribe.fallback, .transcribe)
        XCTAssertEqual(OpenAIModelID.transcribe.costPerHour, "$0.27")
        XCTAssertEqual(OpenAIModelID.miniTranscribe.costPerHour, "$0.18")
        let notice = ModelFallbackNotice(failed: OpenAIModelID.transcribe, used: .miniTranscribe)
        XCTAssertEqual(notice.title, "GPT Transcribe unavailable")
        XCTAssertEqual(notice.body, "Used 4o mini Transcribe instead")
    }
}
