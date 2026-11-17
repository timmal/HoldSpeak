import XCTest
import Carbon.HIToolbox
@testable import HoldSpeakCore

final class HotkeyBindingTests: XCTestCase {
    private let shift: UInt64 = 0x00020000
    private let ctrl: UInt64 = 0x00040000
    private let opt: UInt64 = 0x00080000
    private let cmd: UInt64 = 0x00100000

    // MARK: - Which key bindings are acceptable

    func test_plainKeys_areRejected() {
        for kc in [kVK_ANSI_A, kVK_Space, kVK_Return, kVK_Tab, kVK_Delete, kVK_LeftArrow, kVK_ANSI_1] {
            XCTAssertFalse(HotkeyBinding.isAcceptableKey(keyCode: UInt16(kc), mods: 0), "key \(kc)")
        }
    }

    func test_shiftAlone_doesNotCount() {
        XCTAssertFalse(HotkeyBinding.isAcceptableKey(keyCode: UInt16(kVK_ANSI_A), mods: shift))
        XCTAssertFalse(HotkeyBinding.isAcceptableKey(keyCode: UInt16(kVK_Space), mods: shift))
    }

    func test_ctrlOptOrCmd_makesAnyKeyAcceptable() {
        for mods in [ctrl, opt, cmd, ctrl | shift, opt | cmd, ctrl | opt | shift | cmd] {
            XCTAssertTrue(HotkeyBinding.isAcceptableKey(keyCode: UInt16(kVK_Space), mods: mods), "mods \(mods)")
            XCTAssertTrue(HotkeyBinding.isAcceptableKey(keyCode: UInt16(kVK_ANSI_Grave), mods: mods), "mods \(mods)")
        }
    }

    func test_fKeys_areAcceptableWithAnyOrNoModifiers() {
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for kc in fKeys {
            for mods in [0, shift, ctrl | opt] {
                XCTAssertTrue(HotkeyBinding.isAcceptableKey(keyCode: UInt16(kc), mods: mods), "F-key \(kc)")
            }
        }
    }

    // MARK: - Modifier bindings

    func test_eachSingleModifier_hasDocumentedBitModsAndLabel() {
        let expected: [(bit: UInt64, mods: UInt64, keyCode: Int, label: String)] = [
            (0x01, ctrl, kVK_Control, "Left Control"),
            (0x2000, ctrl, kVK_RightControl, "Right Control"),
            (0x20, opt, kVK_Option, "Left Option"),
            (0x40, opt, kVK_RightOption, "Right Option"),
            (0x02, shift, kVK_Shift, "Left Shift"),
            (0x04, shift, kVK_RightShift, "Right Shift"),
            (0x08, cmd, kVK_Command, "Left Command"),
            (0x10, cmd, kVK_RightCommand, "Right Command"),
        ]
        for e in expected {
            guard let b = HotkeyBinding.modifier(deviceBits: e.bit) else {
                XCTFail("no binding for bit \(e.bit)"); continue
            }
            XCTAssertEqual(b.kind, .modifier)
            XCTAssertEqual(b.deviceBit, e.bit, e.label)
            XCTAssertEqual(b.mods, e.mods, e.label)
            XCTAssertEqual(b.label, e.label)
            XCTAssertEqual(b.keyCode, 0, e.label)
            XCTAssertEqual(b.physicalKeyCodes, [UInt16(e.keyCode)], e.label)
        }
        XCTAssertEqual(HotkeyBinding.rightOption, HotkeyBinding.modifier(deviceBits: 0x40))
        XCTAssertEqual(HotkeyBinding.rightCommand, HotkeyBinding.modifier(deviceBits: 0x10))
    }

    func test_modifierCombo_joinsLabelsAndMergesMasks() {
        let b = HotkeyBinding.modifier(deviceBits: 0x2000 | 0x10)!
        XCTAssertEqual(b.label, "Right Control + Right Command")
        XCTAssertEqual(b.deviceBit, 0x2010)
        XCTAssertEqual(b.mods, ctrl | cmd)

        let three = HotkeyBinding.modifier(deviceBits: 0x01 | 0x20 | 0x08)!
        XCTAssertEqual(three.label, "Left Control + Left Option + Left Command")
        XCTAssertEqual(three.mods, ctrl | opt | cmd)
    }

    func test_modifier_withoutKnownBits_isNil() {
        XCTAssertNil(HotkeyBinding.modifier(deviceBits: 0))
        XCTAssertNil(HotkeyBinding.modifier(deviceBits: 0x100)) // non-coalesced flag, not a key
    }

    // MARK: - Key bindings

    func test_keyBinding_labels() {
        XCTAssertEqual(HotkeyBinding.key(keyCode: UInt16(kVK_Space), mods: opt).label, "⌥Space")
        XCTAssertEqual(HotkeyBinding.key(keyCode: UInt16(kVK_F13), mods: 0).label, "F13")
        XCTAssertEqual(HotkeyBinding.key(keyCode: UInt16(kVK_Return), mods: ctrl | opt | shift | cmd).label,
                       "⌃⌥⇧⌘Return")
        XCTAssertEqual(HotkeyBinding.key(keyCode: UInt16(kVK_LeftArrow), mods: cmd).label, "⌘←")
        XCTAssertEqual(HotkeyBinding.key(keyCode: UInt16(kVK_Escape), mods: ctrl).label, "⌃Esc")

        let b = HotkeyBinding.key(keyCode: UInt16(kVK_Space), mods: opt)
        XCTAssertEqual(b.kind, .key)
        XCTAssertEqual(b.keyCode, UInt16(kVK_Space))
        XCTAssertEqual(b.mods, opt)
        XCTAssertEqual(b.deviceBit, 0)
    }

    func test_keyBinding_letterLabel_comesFromLayout() {
        // The letter depends on the ASCII-capable layout; only its shape is fixed.
        let label = HotkeyBinding.key(keyCode: UInt16(kVK_ANSI_A), mods: ctrl).label
        XCTAssertTrue(label.hasPrefix("⌃"))
        XCTAssertEqual(label.count, 2)
        XCTAssertEqual(label, label.uppercased())
    }

    func test_storedJSONFormat_isUnchanged() throws {
        let json = #"{"kind":"modifier","deviceBit":64,"keyCode":0,"mods":524288,"label":"Right Option"}"#
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .rightOption)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HotkeyBinding.rightOption))
        XCTAssertEqual(Set((encoded as? [String: Any])?.keys ?? [:].keys),
                       ["kind", "deviceBit", "keyCode", "mods", "label"])
    }

    func test_nonGeneralFlagBits_doNotCount() {
        // Fn (secondaryFn) and caps lock are not ⌃⌥⌘.
        XCTAssertFalse(HotkeyBinding.isAcceptableKey(keyCode: UInt16(kVK_ANSI_A), mods: 0x00800000))
        XCTAssertFalse(HotkeyBinding.isAcceptableKey(keyCode: UInt16(kVK_ANSI_A), mods: 0x00010000))
    }
}
