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
    /// The open Model dropdown: name, what it's good at, download size.
    public var label: String {
        switch self {
        case .turbo: return "\(shortLabel) — 99 languages, slower · \(downloadSize)"
        }
    }
    /// The model's name: closed dropdown, HUD, fallback hints, onboarding.
    public var shortLabel: String {
        switch self {
        case .turbo: return "OpenAI Whisper Turbo"
        }
    }
    public var downloadSize: String {
        switch self {
        case .turbo: return "1.5 GB"
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
    /// Shown in the closed dropdown: the model's name. The open menu lists the full labels.
    public var label: String {
        switch self {
        case .whisper(let m):  return m.shortLabel
        case .parakeet(let m): return m.shortLabel
        case .gemini(let m):   return m.shortLabel
        case .openai(let m):   return m.shortLabel
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
    /// Installs from before HS-37 had `.ru` as the default; `migratePrimaryLanguageDefault`
    /// stores it for them, so only new installs start on auto-detect.
    @AppStorage("primaryLanguage") public var primaryLanguage: PrimaryLanguage = PreferencesStore.defaultPrimaryLanguage
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

    /// Cloud API keys, one Keychain item for all providers (see APIKeyStore).
    private let apiKeys = APIKeyStore(keychain: SystemKeychain())

    /// nil when there is no key, or when Keychain access was denied (`apiKeysUnavailable`).
    public func apiKey(_ provider: CloudProvider) -> String? {
        apiKeys.key(provider)
    }

    /// nil or empty removes the key. False when nothing was saved.
    @discardableResult
    public func setAPIKey(_ key: String?, for provider: CloudProvider) -> Bool {
        objectWillChange.send()
        return apiKeys.setKey(key, for: provider)
    }

    public func hasAPIKey(_ provider: CloudProvider) -> Bool { apiKey(provider)?.isEmpty == false }

    public var apiKeyAvailability: APIKeyStore.Availability { apiKeys.availability }

    /// The Keychain read failed (password prompt denied or cancelled): no key is
    /// served or saved until `reloadAPIKeys()` succeeds.
    public var apiKeysUnavailable: Bool { apiKeyAvailability == .unavailable }

    /// Reads the API keys off the main thread, so the password prompt macOS shows after
    /// an update doesn't stall the main run loop (and the hotkey event tap on it) inside
    /// the first `apiKey` call. Observers are notified on main when it's done. Does
    /// nothing once the keys are loaded, and doesn't prompt again after a denied read.
    public func warmAPIKeys() {
        apiKeys.loadInBackground(retry: false) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Asks the Keychain again after a denied prompt, off the main thread.
    public func reloadAPIKeys() {
        apiKeys.loadInBackground(retry: true) { [weak self] _ in
            self?.objectWillChange.send()
        }
        objectWillChange.send()
    }

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

    public static let defaultPrimaryLanguage: PrimaryLanguage = .auto
    /// Set once the primary-language migration has looked at this install.
    static let primaryLanguageCheckedKey = "primaryLanguageDefaultChecked"
    /// Keys only a previous launch could have stored: every setting the app has saved
    /// through @AppStorage, plus the pre-HotkeyBinding "hotkey". @AppStorage writes a
    /// key only when it's changed, so these catch installs whose user touched anything.
    static let installMarkerKeys = [
        "transcriptionEngine", "localEngine", "hotkeyBindingJSON", "hotkey", "holdThresholdMs",
        "hudPosition", "modelID", "parakeetModel", "geminiModel", "openAIModel", "launchAtLogin",
        "appTheme", "autoPunctuation", "autoCapitalize", "removeFillers", "engineFallback",
        "fillerWords", "metricsResetAtMs", "inputDevice",
    ]

    /// The language `primaryLanguage` reads from these defaults.
    static func effectivePrimaryLanguage(_ defaults: UserDefaults) -> PrimaryLanguage {
        defaults.string(forKey: "primaryLanguage").flatMap(PrimaryLanguage.init(rawValue:))
            ?? defaultPrimaryLanguage
    }

    /// The default primary language was Russian until HS-37 and is auto-detect now.
    /// An install that ran before and never picked a language stored nothing, so it
    /// gets "ru" written once to keep recognising exactly as it did. Runs once per
    /// install (`primaryLanguageCheckedKey`): a new install creates history and picks an
    /// engine on its first launch, and must not look "existing" on the second.
    ///
    /// An install counts as existing when it has any of `installMarkerKeys`, or
    /// `hasExistingHistory`: the history database, created on every launch since the
    /// first version, so it also covers installs from before the engine-choice
    /// onboarding whose settings were never touched (no defaults key at all). The
    /// caller checks it before anything creates the database on this launch.
    /// Returns true when "ru" was written.
    @discardableResult
    public static func migratePrimaryLanguageDefault(_ defaults: UserDefaults, hasExistingHistory: Bool) -> Bool {
        guard !defaults.bool(forKey: primaryLanguageCheckedKey) else { return false }
        defaults.set(true, forKey: primaryLanguageCheckedKey)
        guard defaults.object(forKey: "primaryLanguage") == nil else { return false }
        let existing = hasExistingHistory || installMarkerKeys.contains { defaults.object(forKey: $0) != nil }
        guard existing else { return false }
        defaults.set(PrimaryLanguage.ru.rawValue, forKey: "primaryLanguage")
        return true
    }

    /// history.sqlite in Application Support, or in its folder from before the rename
    /// (AppDelegate moves "push-to-talk" to "HoldSpeak" after this runs).
    private static func historyDatabaseExists() -> Bool {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("push-to-talk/history.sqlite")
        return fm.fileExists(atPath: HistoryStore.defaultURL().path) || fm.fileExists(atPath: legacy.path)
    }

    public static let shared = PreferencesStore()
    private init() {
        if let removed = Self.migrateLegacyDefaults(.standard) {
            pttLog("Prefs: Whisper model \(removed) is no longer offered, switched to \(WhisperModelID.turbo.rawValue)")
        }
        if Self.migratePrimaryLanguageDefault(.standard, hasExistingHistory: Self.historyDatabaseExists()) {
            pttLog("Prefs: existing install without a language choice, keeping Russian")
        }
    }
}
