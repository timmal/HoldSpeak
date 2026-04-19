import Foundation
import SwiftUI

public enum HotkeyChoice: String, CaseIterable, Identifiable {
    case rightOption, rightCmd
    public var id: String { rawValue }
    public var label: String {
        switch self { case .rightOption: return "Right Option"; case .rightCmd: return "Right Command" }
    }
}

public enum HUDContentMode: String, CaseIterable, Identifiable {
    case waveformPill, liveTranscript
    public var id: String { rawValue }
    public var label: String {
        switch self { case .waveformPill: return "Waveform"; case .liveTranscript: return "Live Transcript" }
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
    case auto, ru, en
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .ru:   return "Russian (mixed en terms ok)"
        case .en:   return "English"
        }
    }
    /// Whisper language code; `nil` means auto-detect.
    public var whisperCode: String? {
        switch self { case .auto: return nil; case .ru: return "ru"; case .en: return "en" }
    }
}

public enum WhisperModelID: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case small = "openai_whisper-small"
    case turbo = "openai_whisper-large-v3-v20240930"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .tiny:  return "Tiny (~40 MB)"
        case .small: return "Small (~250 MB)"
        case .turbo: return "Turbo — large-v3 distilled (~800 MB, recommended)"
        }
    }
}

public final class PreferencesStore: ObservableObject {
    @AppStorage("hotkey")          public var hotkey: HotkeyChoice = .rightOption
    @AppStorage("holdThresholdMs") public var holdThresholdMs: Int = 150
    @AppStorage("hudContentMode")  public var hudContentMode: HUDContentMode = .waveformPill
    @AppStorage("hudPosition")     public var hudPosition: HUDPosition = .underMenuBarIcon
    @AppStorage("modelID")         public var modelID: WhisperModelID = .turbo
    @AppStorage("primaryLanguage") public var primaryLanguage: PrimaryLanguage = .ru
    @AppStorage("launchAtLogin")   public var launchAtLogin: Bool = false

    public static let shared = PreferencesStore()
    private init() {}
}
