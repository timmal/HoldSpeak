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

/// Cloud engines to try after `selected` fails, before local Whisper: the other
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
    case missingAPIKey(CloudProvider)
    case invalidAPIKey(CloudProvider)
    case quotaExceeded(CloudProvider, daily: Bool, retryAfterSeconds: Int?)
    /// OpenAI: the prepaid balance or the monthly budget is used up.
    case outOfCredits(CloudProvider)
    case unreachable(CloudProvider)
    case serviceError(CloudProvider, status: Int)
    /// The cloud engine failed with the wrapped error and the backup Whisper model
    /// is still downloading.
    indirect case backupDownloading(TranscriptionFailure)

    /// Both lines are shown in the HUD pill, so keep them short.
    public var title: String {
        switch self {
        case .whisperModelNotReady:  return "Whisper model not ready"
        case .missingAPIKey(let p):  return "No \(p.name) API key"
        case .invalidAPIKey(let p):  return "\(p.company) rejected the API key"
        case .quotaExceeded(let p, let daily, _):
            return daily ? "\(p.name) daily limit reached" : "\(p.name) rate limit reached"
        case .outOfCredits(let p):   return "\(p.name) credits used up"
        case .unreachable(let p):    return "\(p.name) unreachable"
        case .serviceError(let p, let status): return "\(p.name) error (HTTP \(status))"
        case .backupDownloading(let failure):  return failure.title
        }
    }

    public var body: String {
        switch self {
        case .whisperModelNotReady: return "Still loading, or download it in Preferences"
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
        case .serviceError:         return "Try again in a moment"
        case .backupDownloading:    return "Downloading Whisper as a backup…"
        }
    }

    /// The model itself is broken or down (bad request, not found, 5xx after a retry),
    /// so the other model may still work. Key, quota and network errors would hit it too.
    public var warrantsModelFallback: Bool {
        if case .serviceError = self { return true }
        return false
    }

    /// No connection: other cloud engines would fail the same way, only Whisper can help.
    public var isOffline: Bool {
        if case .unreachable = self { return true }
        return false
    }

    /// How long the HUD keeps the message up.
    public var displaySeconds: Double {
        switch self {
        case .quotaExceeded, .outOfCredits, .backupDownloading: return 6
        default: return 4
        }
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
