import Foundation
import SwiftUI


public enum AppTheme: String, CaseIterable, Identifiable {
    case auto, light, dark
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto:  return "Auto"
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }
    public var nsAppearance: NSAppearance? {
        switch self {
        case .auto:  return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark:  return NSAppearance(named: .darkAqua)
        }
    }
}

public enum HUDPosition: String, CaseIterable, Identifiable {
    case underMenuBarIcon, bottomCenter
    public var id: String { rawValue }
    public var label: String {
        switch self { case .underMenuBarIcon: return "Under menu bar icon"; case .bottomCenter: return "Bottom center" }
    }
}

public enum PrimaryLanguage: String, CaseIterable, Identifiable {
    case auto
    case ar, zh, nl, en, fr, de, hi, it, ja, ko, pl, pt, ru, es, tr, uk

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .ar:   return "Arabic"
        case .zh:   return "Chinese"
        case .nl:   return "Dutch"
        case .en:   return "English"
        case .fr:   return "French"
        case .de:   return "German"
        case .hi:   return "Hindi"
        case .it:   return "Italian"
        case .ja:   return "Japanese"
        case .ko:   return "Korean"
        case .pl:   return "Polish"
        case .pt:   return "Portuguese"
        case .ru:   return "Russian"
        case .es:   return "Spanish"
        case .tr:   return "Turkish"
        case .uk:   return "Ukrainian"
        }
    }
    public var whisperCode: String? {
        self == .auto ? nil : rawValue
    }
}

public enum WhisperModelID: String, CaseIterable, Identifiable {
    // Tiny ("openai_whisper-tiny") and Small ("openai_whisper-small") were removed in
    // HS-13; PreferencesStore.migrateLegacyDefaults moves their users to Turbo. Files
    // already downloaded stay in HoldSpeak's models folder, are counted in
    // "Downloaded models" and go with its Delete.
    case turbo = "openai_whisper-large-v3-v20240930"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .turbo: return "Turbo — large-v3 distilled (~1.5 GB, recommended)"
        }
    }
    /// For the closed dropdown, where the full label gets truncated.
    public var shortLabel: String {
        switch self {
        case .turbo: return "Turbo (~1.5 GB)"
        }
    }
}

public enum TranscriptionEngineKind: String {
    case whisper, gemini, openai, parakeet

    /// nil for the local engines (Whisper, Parakeet).
    public var cloudProvider: CloudProvider? {
        switch self {
        case .whisper, .parakeet: return nil
        case .gemini:  return .gemini
        case .openai:  return .openai
        }
    }

    /// Runs on this Mac.
    public var isLocal: Bool { cloudProvider == nil }
}

extension CloudProvider {
    public var engineKind: TranscriptionEngineKind {
        switch self {
        case .gemini: return .gemini
        case .openai: return .openai
        }
    }
}

/// One entry of the combined "Model" dropdown: a local model (Whisper, Parakeet) or a cloud model.
public enum ModelChoice: Hashable, Identifiable {
    case whisper(WhisperModelID)
    case parakeet(ParakeetModelID)
    case gemini(GeminiModelID)
    case openai(OpenAIModelID)

    public var id: String {
        switch self {
        case .whisper(let m):  return m.rawValue
        case .parakeet(let m): return m.rawValue
        case .gemini(let m):   return m.rawValue
        case .openai(let m):   return m.rawValue
        }
    }
    /// Shown in the closed dropdown; the open menu lists the full model labels.
    public var label: String {
        switch self {
        case .whisper(let m):  return "Whisper \(m.shortLabel)"
        case .parakeet(let m): return "Parakeet \(m.shortLabel)"
        case .gemini(let m):   return "Gemini \(m.shortLabel)"
        case .openai(let m):   return "OpenAI \(m.shortLabel)"
        }
    }

    /// nil for cloud models.
    public var local: LocalModel? {
        switch self {
        case .whisper(let m):  return .whisper(m)
        case .parakeet(let m): return .parakeet(m)
        case .gemini, .openai: return nil
        }
    }
}

public final class PreferencesStore: ObservableObject {
    @AppStorage("hotkeyBindingJSON") private var hotkeyBindingJSON: String = ""
    @AppStorage("holdThresholdMs") public var holdThresholdMs: Int = 150
    @AppStorage("hudPosition")     public var hudPosition: HUDPosition = .bottomCenter
    @AppStorage("modelID")         public var modelID: WhisperModelID = .turbo
    @AppStorage("parakeetModel")   public var parakeetModel: ParakeetModelID = .ultra
    /// The local engine picked last (whisper or parakeet): cloud engines fall back to it.
    @AppStorage("localEngine")     private var localEngineRaw: String = TranscriptionEngineKind.whisper.rawValue
    @AppStorage("geminiModel")     public var geminiModel: GeminiModelID = .transcribe
    @AppStorage("openAIModel")     public var openAIModel: OpenAIModelID = .transcribe
    /// Empty until the user picks an engine in onboarding.
    @AppStorage("transcriptionEngine") private var engineRaw: String = ""
    @AppStorage("primaryLanguage") public var primaryLanguage: PrimaryLanguage = .ru
    @AppStorage("launchAtLogin")   public var launchAtLogin: Bool = false
    @AppStorage("appTheme")        public var appTheme: AppTheme = .auto
    @AppStorage("autoPunctuation") public var autoPunctuation: Bool = true
    @AppStorage("autoCapitalize")  public var autoCapitalize: Bool = true
    @AppStorage("removeFillers")   public var removeFillers: Bool = false
    /// When the selected cloud engine fails: try the other cloud engines with a key, then the local model.
    @AppStorage("engineFallback")  public var engineFallback: Bool = false
    /// Whisper, Parakeet and OpenAI; Gemini drops fillers by context instead of a list.
    @AppStorage("fillerWords")     public var fillerWords: String = TextCleaner.defaultFillers
    @AppStorage("metricsResetAtMs") public var metricsResetAtMs: Int = 0
    @AppStorage("inputDevice")     private var inputDeviceRaw: String = InputSelection.avoidBluetooth.rawValue

    public var inputSelection: InputSelection {
        get { InputSelection(rawValue: inputDeviceRaw) }
        set { objectWillChange.send(); inputDeviceRaw = newValue.rawValue }
    }

    public var engine: TranscriptionEngineKind {
        get { LocalModel.supported(TranscriptionEngineKind(rawValue: engineRaw) ?? .whisper) }
        set {
            objectWillChange.send()
            engineRaw = newValue.rawValue
            if newValue.isLocal { localEngineRaw = newValue.rawValue }
        }
    }

    public var engineChosen: Bool { !engineRaw.isEmpty }

    /// The selected local model, or with a cloud engine the local model it falls back to.
    public var localModel: LocalModel {
        LocalModel.resolve(engine: engine, lastLocal: TranscriptionEngineKind(rawValue: localEngineRaw),
                           whisper: modelID, parakeet: parakeetModel)
    }

    public var modelChoice: ModelChoice {
        get {
            switch engine {
            case .whisper:  return .whisper(modelID)
            case .parakeet: return .parakeet(parakeetModel)
            case .gemini:   return .gemini(geminiModel)
            case .openai:   return .openai(openAIModel)
            }
        }
        set {
            switch newValue {
            case .whisper(let m):  modelID = m; engine = .whisper
            case .parakeet(let m): parakeetModel = m; engine = .parakeet
            case .gemini(let m):   geminiModel = m; engine = .gemini
            case .openai(let m):   openAIModel = m; engine = .openai
            }
        }
    }

    /// All cloud keys live in one Keychain item: the app is self-signed, so macOS asks
    /// for the password once per item after every update, and one item means one prompt.
    private static let keysAccount = "api-keys"
    /// One item per provider, before the keys were merged.
    private static func legacyKeyAccount(_ provider: CloudProvider) -> String {
        "\(provider.rawValue)-api-key"
    }
    /// Read once from the Keychain, then served from memory: finalize asks on every dictation.
    private var cachedKeys: [String: String]?

    private func storedKeys() -> [String: String] {
        if let cachedKeys { return cachedKeys }
        var keys: [String: String] = [:]
        if let json = Keychain.string(for: Self.keysAccount),
           let decoded = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) {
            keys = decoded
        } else {
            for provider in CloudProvider.allCases {
                if let key = Keychain.string(for: Self.legacyKeyAccount(provider)), !key.isEmpty {
                    keys[provider.rawValue] = key
                }
            }
            if !keys.isEmpty, saveKeys(keys) {
                CloudProvider.allCases.forEach { Keychain.delete(Self.legacyKeyAccount($0)) }
                pttLog("Keychain: merged \(keys.count) API key(s) into one item")
            }
        }
        cachedKeys = keys
        return keys
    }

    @discardableResult
    private func saveKeys(_ keys: [String: String]) -> Bool {
        if keys.isEmpty {
            Keychain.delete(Self.keysAccount)
            return true
        }
        guard let data = try? JSONEncoder().encode(keys) else { return false }
        return Keychain.set(String(decoding: data, as: UTF8.self), for: Self.keysAccount)
    }

    public func apiKey(_ provider: CloudProvider) -> String? {
        storedKeys()[provider.rawValue]
    }

    /// nil or empty removes the key.
    public func setAPIKey(_ key: String?, for provider: CloudProvider) {
        objectWillChange.send()
        var keys = storedKeys()
        if let key, !key.isEmpty {
            keys[provider.rawValue] = key
        } else {
            keys[provider.rawValue] = nil
        }
        saveKeys(keys)
        cachedKeys = keys
    }

    public func hasAPIKey(_ provider: CloudProvider) -> Bool { apiKey(provider)?.isEmpty == false }

    public func applyAppearance() {
        NSApp.appearance = appTheme.nsAppearance
    }

    /// Decoded `hotkey`, keyed by the JSON it came from. The event tap reads the
    /// binding on every system-wide key event, so avoid re-decoding each time.
    private var cachedHotkey: (json: String, binding: HotkeyBinding)?

    public var hotkey: HotkeyBinding {
        get {
            let json = hotkeyBindingJSON
            if let cached = cachedHotkey, cached.json == json { return cached.binding }
            let binding: HotkeyBinding
            if let data = json.data(using: .utf8),
               let b = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
                binding = b
            } else {
                let legacy = UserDefaults.standard.string(forKey: "hotkey")
                binding = legacy == "rightCmd" ? .rightCommand : .rightOption
            }
            cachedHotkey = (json, binding)
            return binding
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue),
               let s = String(data: data, encoding: .utf8) {
                hotkeyBindingJSON = s
                cachedHotkey = (s, newValue)
            }
        }
    }

    /// Rewrites a saved Whisper model that is no longer offered (Tiny, Small) to Turbo.
    /// `@AppStorage` already reads an unknown raw value as its default, but the stale
    /// string would stay in the defaults; only that one key is touched. The fallback
    /// chain's "localEngine" holds the engine kind ("whisper"), not the model, so it
    /// keeps pointing at Whisper and now resolves to Turbo.
    /// Returns the raw value that was replaced, nil when nothing changed.
    @discardableResult
    public static func migrateLegacyDefaults(_ defaults: UserDefaults) -> String? {
        guard let raw = defaults.string(forKey: "modelID"), WhisperModelID(rawValue: raw) == nil else {
            return nil
        }
        defaults.set(WhisperModelID.turbo.rawValue, forKey: "modelID")
        return raw
    }

    public static let shared = PreferencesStore()
    private init() {
        if let removed = Self.migrateLegacyDefaults(.standard) {
            pttLog("Prefs: Whisper model \(removed) is no longer offered, switched to \(WhisperModelID.turbo.rawValue)")
        }
    }
}
