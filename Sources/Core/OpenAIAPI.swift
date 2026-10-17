import Foundation

public enum OpenAIModelID: String, CaseIterable, Identifiable, CloudModel {
    case transcribe = "gpt-transcribe"
    case miniTranscribe = "gpt-4o-mini-transcribe"
    public var id: String { rawValue }
    /// The open Model dropdown: name, what it's good at, price.
    public var label: String {
        switch self {
        case .transcribe:     return "\(shortLabel) — most accurate · \(costPerHour)/h"
        case .miniTranscribe: return "\(shortLabel) — cheaper · \(costPerHour)/h"
        }
    }
    /// The model's name: closed dropdown, HUD fallback notice, key-editor price hint.
    public var shortLabel: String {
        switch self {
        case .transcribe:     return "OpenAI GPT Transcribe"
        case .miniTranscribe: return "OpenAI GPT-4o mini"
        }
    }
    /// gpt-transcribe takes the terms as `keywords` and a `languages` list; older
    /// models get the terms inside `prompt` and a single `language`.
    public var supportsKeywords: Bool { self == .transcribe }
    /// Per hour of speech, OpenAI's pricing page (October 2026): $0.0045 / $0.003 a minute.
    public var costPerHour: String {
        switch self {
        case .transcribe:     return "$0.27"
        case .miniTranscribe: return "$0.18"
        }
    }
    public var fallback: OpenAIModelID {
        switch self {
        case .transcribe:     return .miniTranscribe
        case .miniTranscribe: return .transcribe
        }
    }
}

/// Pure request/response helpers for OpenAI's transcription endpoint — no networking,
/// so `swift test` covers them.
public enum OpenAIAPI {
    public static let baseURL = URL(string: "https://api.openai.com/v1/")!

    /// Form fields besides the file, in order. `language` is a two-letter code, nil
    /// for auto-detect; `terms` are canonical spellings from the terminology dictionary.
    /// The model transcribes rather than follows instructions, so the prompt only
    /// describes the recording; filler words are removed afterwards from the list.
    public static func fields(model: OpenAIModelID, language: String?, terms: [String]) -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = [("model", model.rawValue), ("response_format", "json")]
        var context = "Dictation typed into a text field"
        if let language, let name = Locale(identifier: "en").localizedString(forLanguageCode: language) {
            context += ", mostly in \(name)"
        }
        context += ". Technical terms, product names and English words keep their original Latin spelling."
        let terms = keywords(terms)
        if model.supportsKeywords {
            fields.append(("prompt", context))
            fields += terms.map { ("keywords[]", $0) }
            if let language { fields.append(("languages[]", language)) }
        } else {
            if !terms.isEmpty { context += " Terms: " + terms.joined(separator: ", ") + "." }
            fields.append(("prompt", context))
            if let language { fields.append(("language", language)) }
        }
        return fields
    }

    /// The API rejects the whole request if a keyword contains `<`, `>` or a line break.
    public static func keywords(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "<>\r\n")) == nil }
            .filter { seen.insert($0).inserted }
    }

    public static func multipartBody(fields: [(name: String, value: String)], wav: Data, boundary: String) -> Data {
        var d = Data()
        func line(_ s: String) { d.append(contentsOf: Array((s + "\r\n").utf8)) }
        for field in fields {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(field.name)\"")
            line("")
            line(field.value)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"")
        line("Content-Type: audio/wav")
        line("")
        d.append(wav)
        line("")
        line("--\(boundary)--")
        return d
    }

    /// `{"text": …, "languages": [{"code": "ru"}]}`; only gpt-transcribe reports languages.
    /// The language comes back as a two-letter code, or nil when none was detected.
    public static func extractTranscript(_ data: Data) -> (text: String, language: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("", nil)
        }
        let text = json["text"] as? String ?? ""
        let code = (json["languages"] as? [[String: Any]])?.first?["code"] as? String
        return (text, code.flatMap(alpha2))
    }

    /// The API also uses ISO 639-3 codes ("yue") and regional ones ("zh-cn").
    static func alpha2(_ code: String) -> String? {
        let base = String(code.lowercased().prefix { $0 != "-" && $0 != "_" })
        if base.count == 2 { return base }
        return Locale.LanguageCode(base).identifier(.alpha2)
    }

    /// Momentary overload. A 429 is not retried: out of credits a retry only burns time.
    public static func isRetryable(status: Int) -> Bool { status >= 500 }

    public static func failure(status: Int, body: Data, retryAfter: String? = nil) -> TranscriptionFailure {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? error?["type"] as? String
        switch status {
        // 403 also covers a restricted key without the audio permission.
        case 401, 403:
            return .invalidAPIKey(.openai)
        case 429:
            if code == "insufficient_quota" { return .outOfCredits(.openai) }
            let retry = retryAfter.flatMap(Double.init).map { Int($0.rounded(.up)) }
            return .quotaExceeded(.openai, daily: false, retryAfterSeconds: retry)
        default:
            return .serviceError(.openai, status: status)
        }
    }
}

public struct OpenAIClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Throws `TranscriptionFailure`.
    public func transcribe(wav: Data, model: OpenAIModelID, language: String?, terms: [String],
                           apiKey: String) async throws -> (text: String, language: String?) {
        let boundary = "HoldSpeak-\(UUID().uuidString)"
        var request = URLRequest(url: OpenAIAPI.baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = OpenAIAPI.multipartBody(
            fields: OpenAIAPI.fields(model: model, language: language, terms: terms),
            wav: wav, boundary: boundary)

        for attempt in 0..<2 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                pttLog("openai request failed: \(error)")
                throw TranscriptionFailure.unreachable(.openai)
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 200 { return OpenAIAPI.extractTranscript(data) }
            pttLog("openai HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
            guard attempt == 0, OpenAIAPI.isRetryable(status: status) else {
                throw OpenAIAPI.failure(status: status, body: data,
                                        retryAfter: http?.value(forHTTPHeaderField: "retry-after"))
            }
        }
        throw TranscriptionFailure.unreachable(.openai)
    }

    /// Cheapest authenticated call: look up one model.
    public func check(apiKey: String) async -> APIKeyCheck {
        var request = URLRequest(url: OpenAIAPI.baseURL.appendingPathComponent("models/\(OpenAIModelID.transcribe.rawValue)"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            // A restricted key may be allowed to transcribe but not to read models:
            // 403 still means OpenAI knows the key.
            case 200, 403, 404: return .valid
            case 401:           return .invalid
            default:            return .unreachable
            }
        } catch {
            return .unreachable
        }
    }
}
