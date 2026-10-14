import Foundation

public enum GeminiModelID: String, CaseIterable, Identifiable, CloudModel {
    case transcribe = "gemini-3.5-transcribe"
    case flashLite = "gemini-3.5-flash-lite"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .transcribe: return "3.5 Transcribe — fast (~2 s, recommended)"
        case .flashLite:  return "3.5 Flash-Lite — better with terms, slower"
        }
    }
    public var shortLabel: String {
        switch self {
        case .transcribe: return "3.5 Transcribe"
        case .flashLite:  return "3.5 Flash-Lite"
        }
    }
    /// The dedicated transcription model rejects thinking settings; Flash-Lite needs
    /// minimal thinking or a reply takes 5–10 s.
    public var supportsThinkingConfig: Bool { self != .transcribe }
    /// Rough paid-tier price per hour of speech (Google's pricing page, October 2026):
    /// audio in at 25 tokens/s plus the transcript out.
    public var costPerHour: String {
        switch self {
        case .transcribe: return "$0.30"
        case .flashLite:  return "$0.06"
        }
    }
    public var fallback: GeminiModelID {
        switch self {
        case .transcribe: return .flashLite
        case .flashLite:  return .transcribe
        }
    }
}

/// Pure request/response helpers for the Gemini API — no networking, so `swift test` covers them.
public enum GeminiAPI {
    public static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!

    /// `language` is a two-letter code, nil for auto-detect. `terms` are canonical
    /// spellings from the terminology dictionary.
    public static func prompt(language: String?, terms: [String], removeFillers: Bool = false) -> String {
        var lines = [
            removeFillers
                ? "Transcribe this speech with natural punctuation. Drop filler words and hesitations "
                    + "(э, эм, ну, типа, короче, как бы, вот, um, uh, like, you know) where they carry no meaning, "
                    + "but keep them where they do (\"объект типа Promise\", \"I like it\"). Otherwise keep the wording as spoken."
                : "Transcribe this speech verbatim, with natural punctuation.",
            "Output only the transcript — no comments, no quotes.",
            "If the audio has no clear speech (silence, background noise, clicks), output nothing. Never guess or invent words.",
            "Keep technical terms, product names and English words in their original Latin spelling.",
        ]
        if let language, let name = Locale(identifier: "en").localizedString(forLanguageCode: language) {
            lines.append("The speech is mostly in \(name).")
        }
        if !terms.isEmpty {
            lines.append("Spelling reference — use only for words actually spoken, never output on its own: "
                + terms.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    public static func requestBody(model: GeminiModelID, prompt: String, wav: Data) throws -> Data {
        var generationConfig: [String: Any] = ["temperature": 0]
        if model.supportsThinkingConfig {
            generationConfig["thinkingConfig"] = ["thinkingLevel": "minimal"]
        }
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": ["mime_type": "audio/wav", "data": wav.base64EncodedString()]],
                ],
            ]],
            "generationConfig": generationConfig,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Regular models answer with `text` parts; gemini-*-transcribe with
    /// `audioTranscription`. Thought parts are skipped.
    public static func extractText(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return ""
        }
        return parts.compactMap { part -> String? in
            if part["thought"] as? Bool == true { return nil }
            if let text = part["text"] as? String { return text }
            return (part["audioTranscription"] as? [String: Any])?["text"] as? String
        }.joined()
    }

    /// Momentary overload ("model is experiencing high demand"). A 429 is not
    /// retried: when the daily quota is gone a retry only burns time.
    public static func isRetryable(status: Int) -> Bool { status >= 500 }

    public static func failure(status: Int, body: Data) -> TranscriptionFailure {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let details = error?["details"] as? [[String: Any]] ?? []
        switch status {
        case 401, 403:
            return .invalidAPIKey(.gemini)
        case 400:
            let reasons = details.compactMap { $0["reason"] as? String }
            let message = error?["message"] as? String ?? ""
            if reasons.contains("API_KEY_INVALID") || message.contains("API key not valid") {
                return .invalidAPIKey(.gemini)
            }
            return .serviceError(.gemini, status: status)
        case 429:
            let quotaIDs = details
                .flatMap { $0["violations"] as? [[String: Any]] ?? [] }
                .compactMap { $0["quotaId"] as? String }
            let daily = quotaIDs.contains { $0.contains("PerDay") }
            let retry = details
                .compactMap { $0["retryDelay"] as? String }
                .first
                .flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) }
                .map { Int($0.rounded(.up)) }
            return .quotaExceeded(.gemini, daily: daily, retryAfterSeconds: retry)
        default:
            return .serviceError(.gemini, status: status)
        }
    }
}

public struct GeminiClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Throws `TranscriptionFailure`.
    public func transcribe(wav: Data, model: GeminiModelID, prompt: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: GeminiAPI.baseURL.appendingPathComponent("models/\(model.rawValue):generateContent"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try GeminiAPI.requestBody(model: model, prompt: prompt, wav: wav)

        for attempt in 0..<2 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                pttLog("gemini request failed: \(error)")
                throw TranscriptionFailure.unreachable(.gemini)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return GeminiAPI.extractText(data) }
            pttLog("gemini HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
            guard attempt == 0, GeminiAPI.isRetryable(status: status) else {
                throw GeminiAPI.failure(status: status, body: data)
            }
        }
        throw TranscriptionFailure.unreachable(.gemini)
    }

    /// Cheapest authenticated call: list one model.
    public func check(apiKey: String) async -> APIKeyCheck {
        var components = URLComponents(url: GeminiAPI.baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "1")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (_, response) = try await session.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:           return .valid
            case 400, 401, 403: return .invalid
            default:            return .unreachable
            }
        } catch {
            return .unreachable
        }
    }
}
