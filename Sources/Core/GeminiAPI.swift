import Foundation

public enum GeminiModelID: String, CaseIterable, Identifiable {
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
    /// Tried with the same audio when this model fails on Google's side.
    public var fallback: GeminiModelID {
        switch self {
        case .transcribe: return .flashLite
        case .flashLite:  return .transcribe
        }
    }
}

/// Which model to ask first. A model that just failed on Google's side is skipped
/// for `cooldown` seconds, so every dictation doesn't pay for the failed round trip.
public struct GeminiFallbackPolicy {
    public let cooldown: TimeInterval
    private var failedAt: [GeminiModelID: Date] = [:]

    public init(cooldown: TimeInterval = 30 * 60) {
        self.cooldown = cooldown
    }

    public func order(preferred: GeminiModelID, now: Date = Date()) -> [GeminiModelID] {
        if let failed = failedAt[preferred], now.timeIntervalSince(failed) < cooldown {
            return [preferred.fallback, preferred]
        }
        return [preferred, preferred.fallback]
    }

    public mutating func markFailed(_ model: GeminiModelID, now: Date = Date()) {
        failedAt[model] = now
    }

    public mutating func markSucceeded(_ model: GeminiModelID) {
        failedAt[model] = nil
    }
}

/// Shown in the HUD pill when the dictation went through the other model.
public struct ModelFallbackNotice: Equatable {
    public let failed: GeminiModelID
    public let used: GeminiModelID

    public init(failed: GeminiModelID, used: GeminiModelID) {
        self.failed = failed
        self.used = used
    }

    public var title: String { "\(failed.shortLabel) unavailable" }
    public var body: String { "Used \(used.shortLabel) instead" }
}

/// Why a dictation produced no text, worded for a user notification.
public enum TranscriptionFailure: Error, Equatable {
    case whisperModelNotReady
    case missingAPIKey
    case invalidAPIKey
    case quotaExceeded(daily: Bool, retryAfterSeconds: Int?)
    case unreachable
    case serviceError(status: Int)

    /// Both lines are shown in the HUD pill, so keep them short.
    public var title: String {
        switch self {
        case .whisperModelNotReady:  return "Whisper model not ready"
        case .missingAPIKey:         return "No Gemini API key"
        case .invalidAPIKey:         return "Gemini rejected the API key"
        case .quotaExceeded(let daily, _):
            return daily ? "Gemini daily limit reached" : "Gemini rate limit reached"
        case .unreachable:           return "Gemini unreachable"
        case .serviceError(let status): return "Gemini error (HTTP \(status))"
        }
    }

    public var body: String {
        switch self {
        case .whisperModelNotReady: return "Still loading, or download it in Preferences"
        case .missingAPIKey:        return "Add it in Preferences → Audio"
        case .invalidAPIKey:        return "Check it in Preferences → Audio"
        // A key without billing runs on the free tier: a couple dozen requests a day.
        case .quotaExceeded(let daily, let retry):
            if daily { return "Set up billing for the key in Google AI Studio" }
            if let retry { return "Retry in \(retry) s, or set up billing in AI Studio" }
            return "Set up billing for the key in Google AI Studio"
        case .unreachable:          return "Check your internet connection"
        case .serviceError:         return "Try again in a moment"
        }
    }

    /// The model itself is broken or down (bad request, not found, 5xx after a retry),
    /// so the other model may still work. Key, quota and network errors would hit it too.
    public var warrantsModelFallback: Bool {
        if case .serviceError = self { return true }
        return false
    }

    /// How long the HUD keeps the message up.
    public var displaySeconds: Double {
        if case .quotaExceeded = self { return 6 }
        return 4
    }
}

/// Pure request/response helpers for the Gemini API — no networking, so `swift test` covers them.
public enum GeminiAPI {
    public static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!
    public static let sampleRate = 16_000

    /// 16 kHz mono 16-bit PCM WAV.
    public static func wav(_ samples: [Float]) -> Data {
        let dataSize = samples.count * 2
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * Float(Int16.max))
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

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
            return .invalidAPIKey
        case 400:
            let reasons = details.compactMap { $0["reason"] as? String }
            let message = error?["message"] as? String ?? ""
            if reasons.contains("API_KEY_INVALID") || message.contains("API key not valid") {
                return .invalidAPIKey
            }
            return .serviceError(status: status)
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
            return .quotaExceeded(daily: daily, retryAfterSeconds: retry)
        default:
            return .serviceError(status: status)
        }
    }
}

public enum GeminiKeyCheck: Equatable {
    case valid, invalid, unreachable
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
                throw TranscriptionFailure.unreachable
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return GeminiAPI.extractText(data) }
            pttLog("gemini HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
            guard attempt == 0, GeminiAPI.isRetryable(status: status) else {
                throw GeminiAPI.failure(status: status, body: data)
            }
        }
        throw TranscriptionFailure.unreachable
    }

    /// Cheapest authenticated call: list one model.
    public func check(apiKey: String) async -> GeminiKeyCheck {
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
