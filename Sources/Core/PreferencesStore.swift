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

public enum WhisperModelID: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case small = "openai_whisper-small"
    case turbo = "openai_whisper-large-v3-v20240930"
    case largeV3 = "openai_whisper-large-v3"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .tiny: return "Tiny (~40 MB)"
        case .small: return "Small (~250 MB)"
        case .turbo: return "Turbo (recommended, ~800 MB)"
        case .largeV3: return "Large v3 (~1.5 GB)"
        }
    }
}

public final class PreferencesStore: ObservableObject {
    @AppStorage("hotkey")          public var hotkey: HotkeyChoice = .rightOption
    @AppStorage("holdThresholdMs") public var holdThresholdMs: Int = 150
    @AppStorage("hudContentMode")  public var hudContentMode: HUDContentMode = .waveformPill
    @AppStorage("hudPosition")     public var hudPosition: HUDPosition = .underMenuBarIcon
    @AppStorage("modelID")         public var modelID: WhisperModelID = .turbo
    @AppStorage("launchAtLogin")   public var launchAtLogin: Bool = false

    public static let shared = PreferencesStore()
    private init() {}
}
