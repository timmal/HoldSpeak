import Foundation
import SwiftUI
import Carbon.HIToolbox

public enum HotkeyKind: String, Codable { case modifier, key }

public struct HotkeyBinding: Codable, Equatable {
    public var kind: HotkeyKind
    /// For `.modifier`: NX device-dependent bit (low 16 of CGEventFlags).
    public var deviceBit: UInt64
    /// For `.key`: virtual keycode.
    public var keyCode: UInt16
    /// Required general-modifier mask (shift/ctrl/opt/cmd); for `.modifier` = the general bit of that mod.
    public var mods: UInt64
    public var label: String

    public static let allGeneralMods: UInt64 = 0x00020000 | 0x00040000 | 0x00080000 | 0x00100000

    public static let rightOption  = HotkeyBinding(kind: .modifier, deviceBit: 0x40, keyCode: 0, mods: 0x00080000, label: "Right Option")
    public static let rightCommand = HotkeyBinding(kind: .modifier, deviceBit: 0x10, keyCode: 0, mods: 0x00100000, label: "Right Command")

    /// Create a `.modifier` binding from a single newly-set device bit.
    public static func modifier(deviceBit: UInt64) -> HotkeyBinding? {
        switch deviceBit {
        case 0x01: return .init(kind: .modifier, deviceBit: 0x01, keyCode: 0, mods: 0x00040000, label: "Left Control")
        case 0x02: return .init(kind: .modifier, deviceBit: 0x02, keyCode: 0, mods: 0x00020000, label: "Left Shift")
        case 0x04: return .init(kind: .modifier, deviceBit: 0x04, keyCode: 0, mods: 0x00020000, label: "Right Shift")
        case 0x08: return .init(kind: .modifier, deviceBit: 0x08, keyCode: 0, mods: 0x00100000, label: "Left Command")
        case 0x10: return .rightCommand
        case 0x20: return .init(kind: .modifier, deviceBit: 0x20, keyCode: 0, mods: 0x00080000, label: "Left Option")
        case 0x40: return .rightOption
        case 0x2000: return .init(kind: .modifier, deviceBit: 0x2000, keyCode: 0, mods: 0x00040000, label: "Right Control")
        default: return nil
        }
    }

    public static func key(keyCode: UInt16, mods: UInt64) -> HotkeyBinding {
        let name = keyLabel(keyCode)
        let modStr = modsLabel(mods)
        return .init(kind: .key, deviceBit: 0, keyCode: keyCode, mods: mods, label: modStr + name)
    }

    private static func modsLabel(_ mods: UInt64) -> String {
        var s = ""
        if mods & 0x00040000 != 0 { s += "⌃" }
        if mods & 0x00080000 != 0 { s += "⌥" }
        if mods & 0x00020000 != 0 { s += "⇧" }
        if mods & 0x00100000 != 0 { s += "⌘" }
        return s
    }

    private static func keyLabel(_ kc: UInt16) -> String {
        switch Int(kc) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_F13: return "F13"; case kVK_F14: return "F14"; case kVK_F15: return "F15"
        case kVK_F16: return "F16"; case kVK_F17: return "F17"; case kVK_F18: return "F18"
        case kVK_F19: return "F19"; case kVK_F20: return "F20"
        default:
            if let s = charForKeyCode(kc) { return s.uppercased() }
            return "Key \(kc)"
        }
    }

    private static func charForKeyCode(_ kc: UInt16) -> String? {
        let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buf -> OSStatus in
            let layout = buf.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout, kc, UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

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
    case ru, en
    case uk, es, fr, de, it, pt, pl, nl, tr, ar, zh, ja, ko, hi

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .ru:   return "Russian (mixed en terms ok)"
        case .en:   return "English"
        case .uk:   return "Ukrainian"
        case .es:   return "Spanish"
        case .fr:   return "French"
        case .de:   return "German"
        case .it:   return "Italian"
        case .pt:   return "Portuguese"
        case .pl:   return "Polish"
        case .nl:   return "Dutch"
        case .tr:   return "Turkish"
        case .ar:   return "Arabic"
        case .zh:   return "Chinese"
        case .ja:   return "Japanese"
        case .ko:   return "Korean"
        case .hi:   return "Hindi"
        }
    }
    public var whisperCode: String? {
        self == .auto ? nil : rawValue
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
    @AppStorage("hotkeyBindingJSON") private var hotkeyBindingJSON: String = ""
    @AppStorage("holdThresholdMs") public var holdThresholdMs: Int = 150
    @AppStorage("hudPosition")     public var hudPosition: HUDPosition = .underMenuBarIcon
    @AppStorage("modelID")         public var modelID: WhisperModelID = .turbo
    @AppStorage("primaryLanguage") public var primaryLanguage: PrimaryLanguage = .ru
    @AppStorage("launchAtLogin")   public var launchAtLogin: Bool = false
    @AppStorage("fastInsert")      public var fastInsert: Bool = false
    @AppStorage("appTheme")        public var appTheme: AppTheme = .auto

    public func applyAppearance() {
        NSApp.appearance = appTheme.nsAppearance
    }

    public var hotkey: HotkeyBinding {
        get {
            if let data = hotkeyBindingJSON.data(using: .utf8),
               let b = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
                return b
            }
            let legacy = UserDefaults.standard.string(forKey: "hotkey")
            return legacy == "rightCmd" ? .rightCommand : .rightOption
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue),
               let s = String(data: data, encoding: .utf8) {
                hotkeyBindingJSON = s
            }
        }
    }

    public static let shared = PreferencesStore()
    private init() {}
}
