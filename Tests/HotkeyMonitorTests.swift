import XCTest
import Combine
import Carbon.HIToolbox
@testable import HoldSpeakCore

final class HotkeyMonitorTests: XCTestCase {
    private let optSpace = HotkeyBinding.key(keyCode: UInt16(kVK_Space), mods: 0x00080000)

    /// Builds (never posts) a keyboard event for feeding `handleKey` directly.
    private func key(_ code: Int, down: Bool, flags: CGEventFlags = []) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        e.flags = flags
        return e
    }

    func test_plainKeyUp_passesThroughWhenNoHoldActive() {
        let monitor = HotkeyMonitor()
        XCTAssertFalse(monitor.handleKey(event: key(kVK_Space, down: true), type: .keyDown, binding: optSpace))
        XCTAssertFalse(monitor.handleKey(event: key(kVK_Space, down: false), type: .keyUp, binding: optSpace))
    }

    func test_boundKeyUp_isConsumedAndEndsHold() {
        let monitor = HotkeyMonitor()
        var events: [HotkeyMonitor.Event] = []
        let sub = monitor.events.sink { events.append($0) }
        defer { sub.cancel() }

        XCTAssertTrue(monitor.handleKey(event: key(kVK_Space, down: true, flags: .maskAlternate),
                                        type: .keyDown, binding: optSpace))
        XCTAssertTrue(monitor.handleKey(event: key(kVK_Space, down: false, flags: .maskAlternate),
                                        type: .keyUp, binding: optSpace))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .startHold)

        // A second keyUp with the hold already over must pass through.
        XCTAssertFalse(monitor.handleKey(event: key(kVK_Space, down: false), type: .keyUp, binding: optSpace))
    }

    func test_modifierCombo_binding() {
        let b = HotkeyBinding.modifier(deviceBits: 0x21)!
        XCTAssertEqual(b.deviceBit, 0x21)
        XCTAssertEqual(b.mods, 0x000C0000)
        XCTAssertEqual(b.label, "Left Control + Left Option")
    }

    func test_modifierCombo_startsOnlyWhenAllHeld() {
        let monitor = HotkeyMonitor()
        var events: [HotkeyMonitor.Event] = []
        let sub = monitor.events.sink { events.append($0) }
        defer { sub.cancel() }
        let combo = HotkeyBinding.modifier(deviceBits: 0x21)!
        func flags(_ raw: UInt64) -> CGEvent { key(kVK_Control, down: true, flags: CGEventFlags(rawValue: raw)) }

        monitor.handleModifier(event: flags(0x00040000 | 0x01), binding: combo)
        XCTAssertTrue(events.isEmpty)
        monitor.handleModifier(event: flags(0x00040000 | 0x00080000 | 0x21), binding: combo)
        XCTAssertEqual(events, [.startHold])
    }

    func test_otherKeys_areIgnored() {
        let monitor = HotkeyMonitor()
        XCTAssertFalse(monitor.handleKey(event: key(kVK_ANSI_A, down: true, flags: .maskAlternate),
                                         type: .keyDown, binding: optSpace))
    }
}
