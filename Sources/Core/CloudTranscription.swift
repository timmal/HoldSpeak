import Foundation

/// A cloud recognition service the user brings their own API key for.
public enum CloudProvider: String, CaseIterable {
    case gemini, openai

    /// The engine's name in the UI.
    public var name: String {
        switch self {
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        }
    }

    /// Who receives the audio and checks the key.
    public var company: String {
        switch self {
        case .gemini: return "Google"
        case .openai: return "OpenAI"
        }
    }
}

/// A model of one provider that has a sibling to retry on.
public protocol CloudModel: Hashable {
    var shortLabel: String { get }
    /// Tried with the same audio when this model fails on the provider's side.
    var fallback: Self { get }
}

/// Which model to ask first. A model that just failed on the provider's side is
/// skipped for `cooldown` seconds, so every dictation doesn't pay for the failed round trip.
public struct ModelFallbackPolicy<Model: CloudModel> {
    public let cooldown: TimeInterval
    private var failedAt: [Model: Date] = [:]

    public init(cooldown: TimeInterval = 30 * 60) {
        self.cooldown = cooldown
    }

    public func order(preferred: Model, now: Date = Date()) -> [Model] {
        if let failed = failedAt[preferred], now.timeIntervalSince(failed) < cooldown {
            return [preferred.fallback, preferred]
        }
        return [preferred, preferred.fallback]
    }

    public mutating func markFailed(_ model: Model, now: Date = Date()) {
        failedAt[model] = now
    }

    public mutating func markSucceeded(_ model: Model) {
        failedAt[model] = nil
    }
}

/// Cloud engines to try after `selected` fails, before the local model: the other
/// providers whose key is saved.
public enum EngineFallback {
    public static func cloudBackups(after selected: CloudProvider,
                                    hasKey: (CloudProvider) -> Bool) -> [CloudProvider] {
        CloudProvider.allCases.filter { $0 != selected && hasKey($0) }
    }
}

/// Shown in the HUD pill when the dictation went through another model or engine.
public struct ModelFallbackNotice: Equatable {
    public let title: String
    public let body: String

    public init<Model: CloudModel>(failed: Model, used: Model) {
        title = "\(failed.shortLabel) unavailable"
        body = "Used \(used.shortLabel) instead"
    }

    /// The selected engine failed and `usedEngine` (another engine's name) answered.
    public init(failure: TranscriptionFailure, usedEngine: String) {
        title = failure.title
        body = "Used \(usedEngine) instead"
    }
}

/// Why a dictation produced no text, worded for the HUD pill.
public enum TranscriptionFailure: Error, Equatable {
    case whisperModelNotReady
    case parakeetModelNotReady
    case missingAPIKey(CloudProvider)
    case invalidAPIKey(CloudProvider)
    case quotaExceeded(CloudProvider, daily: Bool, retryAfterSeconds: Int?)
    /// OpenAI: the prepaid balance or the monthly budget is used up.
    case outOfCredits(CloudProvider)
    case unreachable(CloudProvider)
    /// The request got no answer in time (`URLError.timedOut`). The connection may be
    /// fine, so other engines are still tried; the same model is not asked again.
    case timedOut(CloudProvider)
    /// The take is over the provider's upload limit: caught before uploading, or HTTP 413.
    /// The sibling model has the same limit, so no model fallback; another engine may take it.
    case audioTooLong(CloudProvider)
    /// The provider answered but withheld the transcript (Gemini: a safety, recitation or
    /// prohibited-content block). Not silence, so it is shown; another engine may take it.
    case blocked(CloudProvider)
    case serviceError(CloudProvider, status: Int)
    /// The cloud engine failed with the wrapped error and the backup local model
    /// (`backup` is its name, `LocalModel.shortLabel`) is still downloading.
    indirect case backupDownloading(TranscriptionFailure, backup: String = WhisperModelID.turbo.shortLabel)
    /// The whole take was exact zeros; no engine was asked.
    case noMicSignal
    /// Nothing was recorded: see `InputRoute.lidClosedNoMic`.
    case lidClosedNoMic
    /// The recorder found no input device at all (`AudioRecorderError.noInputDevice`).
    case noInputDevice
    /// The input device couldn't be opened or gave an unusable format
    /// (`AudioRecorderError.coreAudio`, `.invalidInputFormat`).
    case micCouldNotStart
    /// A CoreAudio call hung and the capture was rebuilt (`AudioRecorderError.stalled`).
    case micStalled
    /// A local engine (Whisper, Parakeet) threw while transcribing; the error is in the log.
    case engineFailed(TranscriptionEngineKind)
    /// A hold past the tap threshold delivered no samples at all: the mic never started
    /// (e.g. a Continuity or Bluetooth mic still waking up).
    case noAudioCaptured

    /// Both lines are shown in the HUD pill, so keep them short.
    public var title: String {
        switch self {
        case .whisperModelNotReady:  return "Whisper model not ready"
        case .parakeetModelNotReady: return "Parakeet model not ready"
        case .missingAPIKey(let p):  return "No \(p.name) API key"
        case .invalidAPIKey(let p):  return "\(p.company) rejected the API key"
        case .quotaExceeded(let p, let daily, _):
            return daily ? "\(p.name) daily limit reached" : "\(p.name) rate limit reached"
        case .outOfCredits(let p):   return "\(p.name) credits used up"
        case .unreachable(let p):    return "\(p.name) unreachable"
        case .timedOut(let p):       return "\(p.name) took too long"
        case .audioTooLong(let p):   return "Take too long for \(p.name)"
        case .blocked(let p):        return "\(p.name) blocked this take"
        case .serviceError(let p, let status): return "\(p.name) error (HTTP \(status))"
        case .backupDownloading(let failure, _): return failure.title
        case .noMicSignal:           return "Microphone gave no signal"
        case .lidClosedNoMic:        return "Lid closed · built-in mic is off"
        case .noInputDevice:         return "No microphone found"
        case .micCouldNotStart:      return "Microphone couldn't start"
        case .micStalled:            return "Microphone not responding"
        case .engineFailed(let kind): return "\(Self.engineName(kind)) couldn't transcribe"
        case .noAudioCaptured:       return "No audio captured"
        }
    }

    public var body: String {
        switch self {
        case .whisperModelNotReady, .parakeetModelNotReady:
            return "Still loading, or download it in Preferences"
        case .missingAPIKey:        return "Add it in Preferences → Audio"
        case .invalidAPIKey:        return "Check it in Preferences → Audio"
        // A Gemini key without billing runs on the free tier: a couple dozen requests a day.
        case .quotaExceeded(.gemini, let daily, let retry):
            if daily { return "Set up billing for the key in Google AI Studio" }
            if let retry { return "Retry in \(retry) s, or set up billing in AI Studio" }
            return "Set up billing for the key in Google AI Studio"
        case .quotaExceeded(_, _, let retry):
            if let retry { return "Retry in \(retry) s" }
            return "Try again in a moment"
        case .outOfCredits:         return "Add credits or raise the limit in OpenAI Billing"
        case .unreachable:          return "Check your internet connection"
        case .timedOut:             return "Try again, or dictate in shorter takes"
        case .audioTooLong:         return "Dictate in shorter takes"
        case .blocked:              return "Flagged by its content filter"
        case .serviceError:         return "Try again in a moment"
        case .backupDownloading(_, let backup): return "Downloading \(backup) as a backup…"
        case .noMicSignal:          return "Check the input in Preferences → Audio"
        case .lidClosedNoMic:       return "Connect a wired mic"
        case .noInputDevice:        return "Connect one, or pick one in Preferences → Audio"
        case .micCouldNotStart:     return "Try again, or pick another in Preferences → Audio"
        case .micStalled:           return "Audio was reset — try again"
        case .engineFailed:         return "Try again; details are in the log"
        case .noAudioCaptured:      return "The mic didn't start in time — try again"
        }
    }

    /// The model itself is broken or down (bad request, not found, 5xx after a retry),
    /// so the other model may still work. Key, quota and network errors would hit it too.
    public var warrantsModelFallback: Bool {
        if case .serviceError = self { return true }
        return false
    }

    /// No connection: other cloud engines would fail the same way, only the local model can help.
    public var isOffline: Bool {
        if case .unreachable = self { return true }
        return false
    }

    /// A request that threw before any HTTP response: only a timeout is told apart,
    /// everything else (no route, DNS, TLS, dropped connection) counts as offline.
    public static func transport(_ error: Error, provider: CloudProvider) -> TranscriptionFailure {
        if let urlError = error as? URLError, urlError.code == .timedOut { return .timedOut(provider) }
        return .unreachable(provider)
    }

    private static func engineName(_ kind: TranscriptionEngineKind) -> String {
        switch kind {
        case .whisper:  return "Whisper"
        case .parakeet: return "Parakeet"
        case .gemini:   return CloudProvider.gemini.name
        case .openai:   return CloudProvider.openai.name
        }
    }

    /// What the HUD says when the recorder reports `error` on its `failures` stream.
    public static func recorder(_ error: Error) -> TranscriptionFailure {
        guard let error = error as? AudioRecorderError else { return .micCouldNotStart }
        switch error {
        case .lidClosedNoMic:                   return .lidClosedNoMic
        case .noInputDevice:                    return .noInputDevice
        case .invalidInputFormat, .coreAudio:   return .micCouldNotStart
        case .stalled:                          return .micStalled
        }
    }

    /// How long the HUD keeps the message up.
    public var displaySeconds: Double {
        switch self {
        case .quotaExceeded, .outOfCredits, .backupDownloading: return 6
        default: return 4
        }
    }
}

/// Request limits shared by the cloud clients.
public enum CloudLimits {
    /// How long a transcription request may wait for the provider's answer: 20 s for a
    /// take of up to 20 s, then half a second more per further second of audio, at most 90 s.
    /// URLSession applies it as an idle timeout, so a long upload in progress doesn't trip it;
    /// it bounds the wait for the transcript once the audio is sent.
    public static func requestTimeout(durationMs: Int) -> TimeInterval {
        let seconds = Double(max(0, durationMs)) / 1000
        return min(90, 20 + max(0, seconds - 20) * 0.5)
    }

    /// The largest upload a provider accepts, checked before sending. Gemini: the whole
    /// JSON request with the base64 audio inline (4/3 of the WAV), "Maximum request size is
    /// 20 MB total (including prompts and all files)". OpenAI: the audio file, "Files can be
    /// up to 25 MB". Both from the providers' docs as of November 2026; taken as decimal MB,
    /// which is below the 20 MiB / 25 MiB the servers seem to enforce, so we err towards
    /// stopping a take that might have passed rather than uploading one that will bounce.
    public static func maxUploadBytes(_ provider: CloudProvider) -> Int {
        switch provider {
        case .gemini: return 20_000_000
        case .openai: return 25_000_000
        }
    }
}

/// Scrubs API keys out of text bound for the log file. OpenAI's 401 body echoes the
/// key it rejected (masked, but with its first and last characters).
public enum LogRedaction {
    /// `sk-…` (OpenAI) and `AIza…` (Google), full or masked with `*`, `…` or `...`,
    /// not preceded by a letter or digit (so "task-force" stays).
    private static let keyPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?:sk-|AIza)(?:[A-Za-z0-9_*\-]|…|\\u2026|\.\.\.)+"#)

    public static func apiKeys(_ text: String) -> String {
        keyPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                            withTemplate: "<redacted>")
    }
}

public enum APIKeyCheck: Equatable {
    case valid, invalid, unreachable
}

public enum CloudAudio {
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
}
