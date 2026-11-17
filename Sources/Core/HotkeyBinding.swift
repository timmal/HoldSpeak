import Foundation

import Carbon.HIToolbox

public enum HotkeyKind: String, Codable { case modifier, key }

public struct HotkeyBinding: Codable, Equatable {
    public var kind: HotkeyKind
    /// For `.modifier`: NX device-dependent bits (low 16 of CGEventFlags), all must be held.
    public var deviceBit: UInt64
    /// For `.key`: virtual keycode.
    public var keyCode: UInt16
    /// Required general-modifier mask (shift/ctrl/opt/cmd); for `.modifier` = the general bit of that mod.
    public var mods: UInt64
    public var label: String

    public static let allGeneralMods: UInt64 = 0x00020000 | 0x00040000 | 0x00080000 | 0x00100000

    public static let rightOption  = modifier(deviceBits: 0x40)!
    public static let rightCommand = modifier(deviceBits: 0x10)!

    private static let modifierTable: [(bit: UInt64, mods: UInt64, keyCode: UInt16, name: String)] = [
        (0x01, 0x00040000, UInt16(kVK_Control), "Left Control"),
        (0x2000, 0x00040000, UInt16(kVK_RightControl), "Right Control"),
        (0x20, 0x00080000, UInt16(kVK_Option), "Left Option"),
        (0x40, 0x00080000, UInt16(kVK_RightOption), "Right Option"),
        (0x02, 0x00020000, UInt16(kVK_Shift), "Left Shift"),
        (0x04, 0x00020000, UInt16(kVK_RightShift), "Right Shift"),
        (0x08, 0x00100000, UInt16(kVK_Command), "Left Command"),
        (0x10, 0x00100000, UInt16(kVK_RightCommand), "Right Command"),
    ]

    /// Virtual key codes that must all be physically down for the binding to count as held:
    /// the bound key for `.key`, one per device bit for `.modifier`. Computed, not stored.
    public var physicalKeyCodes: [UInt16] {
        switch kind {
        case .key: return [keyCode]
        case .modifier: return Self.modifierTable.filter { deviceBit & $0.bit != 0 }.map(\.keyCode)
        }
    }

    /// Create a `.modifier` binding from one or more device bits that must be held together.
    public static func modifier(deviceBits: UInt64) -> HotkeyBinding? {
        let parts = modifierTable.filter { deviceBits & $0.bit != 0 }
        guard !parts.isEmpty else { return nil }
        return .init(kind: .modifier,
                     deviceBit: parts.reduce(0) { $0 | $1.bit },
                     keyCode: 0,
                     mods: parts.reduce(0) { $0 | $1.mods },
                     label: parts.map(\.name).joined(separator: " + "))
    }

    public static func key(keyCode: UInt16, mods: UInt64) -> HotkeyBinding {
        let name = keyLabel(keyCode)
        let modStr = modsLabel(mods)
        return .init(kind: .key, deviceBit: 0, keyCode: keyCode, mods: mods, label: modStr + name)
    }

    private static let fKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Whether a `.key` binding leaves ordinary typing alone: it needs ⌃, ⌥ or ⌘
    /// (⇧ alone doesn't count), unless the key is F1–F20. A bound key is swallowed
    /// system-wide, so a plain letter, Space or Return would go dead in every app.
    public static func isAcceptableKey(keyCode: UInt16, mods: UInt64) -> Bool {
        let ctrlOptCmd: UInt64 = 0x00040000 | 0x00080000 | 0x00100000
        return mods & ctrlOptCmd != 0 || fKeys.contains(Int(keyCode))
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
