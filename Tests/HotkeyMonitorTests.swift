import XCTest
import Combine
import Carbon.HIToolbox
@testable import HoldSpeakCore

/// A monitor that can never post a real event or read real key state.
func makeTestMonitor() -> HotkeyMonitor {
    let monitor = HotkeyMonitor()
    monitor.replayTap = { _, _ in }
    monitor.isBindingPhysicallyDown = { _ in true }
    return monitor
}

final class HotkeyMonitorTests: XCTestCase {
    private let optSpace = HotkeyBinding.key(keyCode: UInt16(kVK_Space), mods: 0x00080000)

    /// Builds (never posts) a keyboard event for feeding `handleKey` directly.
    private func key(_ code: Int, down: Bool, flags: CGEventFlags = []) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        e.flags = flags
        return e
    }

    func test_plainKeyUp_passesThroughWhenNoHoldActive() {
        let monitor = makeTestMonitor()
        XCTAssertFalse(monitor.handleKey(event: key(kVK_Space, down: true), type: .keyDown, binding: optSpace))
        XCTAssertFalse(monitor.handleKey(event: key(kVK_Space, down: false), type: .keyUp, binding: optSpace))
    }

    func test_boundKeyUp_isConsumedAndEndsHold() {
        let monitor = makeTestMonitor()
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
        let monitor = makeTestMonitor()
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
        let monitor = makeTestMonitor()
        XCTAssertFalse(monitor.handleKey(event: key(kVK_ANSI_A, down: true, flags: .maskAlternate),
                                         type: .keyDown, binding: optSpace))
    }

    // MARK: - Lost release (poll)

    /// A monitor with a controllable clock and physical key state.
    private final class Rig {
        let monitor = makeTestMonitor()
        var events: [HotkeyMonitor.Event] = []
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var physicallyDown = true
        var queriedBindings: [HotkeyBinding] = []
        var replayed: [(down: CGEvent, up: CGEvent)] = []
        private var sub: AnyCancellable?

        init() {
            sub = monitor.events.sink { [unowned self] in events.append($0) }
            monitor.now = { [unowned self] in now }
            monitor.replayTap = { [unowned self] down, up in replayed.append((down, up)) }
            monitor.isBindingPhysicallyDown = { [unowned self] b in
                queriedBindings.append(b)
                return physicallyDown
            }
        }
        func advance(ms: Double) { now = now.addingTimeInterval(ms / 1000) }
    }

    private func flagsEvent(_ raw: UInt64) -> CGEvent {
        key(kVK_RightOption, down: true, flags: CGEventFlags(rawValue: raw))
    }

    private let rightOptDown: UInt64 = 0x00080000 | 0x40
    private let noMods: UInt64 = 0x100

    func test_pollTick_endsHoldWhenBindingNoLongerPhysicallyDown() {
        let rig = Rig()
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold])

        rig.advance(ms: 1000)
        rig.monitor.pollTick()
        XCTAssertEqual(rig.events, [.startHold], "key still down: hold continues")

        rig.physicallyDown = false
        rig.monitor.pollTick()
        XCTAssertEqual(rig.events, [.startHold, .endHold])
        XCTAssertEqual(rig.queriedBindings.last, .rightOption)

        // The late release (if it ever arrives) is a no-op.
        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold, .endHold])
    }

    func test_pollTick_keyBinding_endsHold() {
        let rig = Rig()
        XCTAssertTrue(rig.monitor.handleKey(event: key(kVK_Space, down: true, flags: .maskAlternate),
                                            type: .keyDown, binding: optSpace))
        rig.advance(ms: 2000)
        rig.physicallyDown = false
        rig.monitor.pollTick()
        XCTAssertEqual(rig.events, [.startHold, .endHold])
        XCTAssertEqual(rig.queriedBindings.last, optSpace)
        // Without a hold the late keyUp reaches the app.
        XCTAssertFalse(rig.monitor.handleKey(event: key(kVK_Space, down: false, flags: .maskAlternate),
                                             type: .keyUp, binding: optSpace))
    }

    func test_pollTick_neverSeenDown_doesNotEndHold() {
        // Key state the HID layer can't see (Universal Control, software remappers):
        // the poll must stay inert rather than cut every dictation short.
        let rig = Rig()
        rig.physicallyDown = false
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        rig.advance(ms: 1000)
        rig.monitor.pollTick()
        rig.monitor.pollTick()
        XCTAssertEqual(rig.events, [.startHold])
        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold, .endHold])
    }

    func test_pollTick_cancelsHoldPastMaxDuration() {
        let rig = Rig()
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        rig.advance(ms: (HotkeyMonitor.maxHoldSeconds - 1) * 1000)
        rig.monitor.pollTick()
        XCTAssertEqual(rig.events, [.startHold])
        rig.advance(ms: 2000)
        rig.monitor.pollTick()
        XCTAssertEqual(rig.events, [.startHold, .cancelHold])
        // A new press starts a fresh hold.
        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: .rightOption)
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold, .cancelHold, .startHold])
    }

    func test_pollTick_withoutHold_doesNothing() {
        let rig = Rig()
        rig.physicallyDown = false
        rig.monitor.pollTick()
        XCTAssertTrue(rig.events.isEmpty)
    }

    // MARK: - Short taps of a key binding pass through

    private func keyCode(_ e: CGEvent) -> Int { Int(e.getIntegerValueField(.keyboardEventKeycode)) }

    func test_shortTap_replaysSwallowedKeyDownAndKeyUp() {
        let rig = Rig()
        XCTAssertTrue(rig.monitor.handleKey(event: key(kVK_Space, down: true, flags: .maskAlternate),
                                            type: .keyDown, binding: optSpace))
        XCTAssertTrue(rig.replayed.isEmpty, "nothing is given back until the press turns out to be a tap")
        rig.advance(ms: 20)
        XCTAssertTrue(rig.monitor.handleKey(event: key(kVK_Space, down: false, flags: .maskAlternate),
                                            type: .keyUp, binding: optSpace))
        XCTAssertEqual(rig.events, [.startHold, .cancelHold])

        XCTAssertEqual(rig.replayed.count, 1)
        guard let (down, up) = rig.replayed.first else { return }
        XCTAssertEqual(down.type, .keyDown)
        XCTAssertEqual(up.type, .keyUp)
        XCTAssertEqual(keyCode(down), kVK_Space)
        XCTAssertEqual(keyCode(up), kVK_Space)
        XCTAssertTrue(down.flags.contains(.maskAlternate))
        XCTAssertTrue(up.flags.contains(.maskAlternate))
        XCTAssertTrue(SyntheticEvent.isOurs(down))
        XCTAssertTrue(SyntheticEvent.isOurs(up))
    }

    func test_realHold_doesNotReplay() {
        let rig = Rig()
        _ = rig.monitor.handleKey(event: key(kVK_Space, down: true, flags: .maskAlternate),
                                  type: .keyDown, binding: optSpace)
        rig.advance(ms: 5000)
        XCTAssertTrue(rig.monitor.handleKey(event: key(kVK_Space, down: false, flags: .maskAlternate),
                                            type: .keyUp, binding: optSpace))
        XCTAssertEqual(rig.events, [.startHold, .endHold])
        XCTAssertTrue(rig.replayed.isEmpty)
    }

    func test_autoRepeatDuringHold_staysSwallowed_andIsNotReplayed() {
        let rig = Rig()
        _ = rig.monitor.handleKey(event: key(kVK_Space, down: true, flags: .maskAlternate),
                                  type: .keyDown, binding: optSpace)
        XCTAssertTrue(rig.monitor.handleKey(event: key(kVK_Space, down: true, flags: .maskAlternate),
                                            type: .keyDown, binding: optSpace))
        // ⌥ let go first: the repeating Space must not leak into the app mid-hold.
        XCTAssertTrue(rig.monitor.handleKey(event: key(kVK_Space, down: true),
                                            type: .keyDown, binding: optSpace))
        rig.advance(ms: 20)
        _ = rig.monitor.handleKey(event: key(kVK_Space, down: false, flags: .maskAlternate),
                                  type: .keyUp, binding: optSpace)
        XCTAssertEqual(rig.events, [.startHold, .cancelHold])
        XCTAssertEqual(rig.replayed.count, 1, "one tap replays exactly one key-down/key-up pair")
    }

    func test_tapEndedByPoll_isNotReplayed() {
        let rig = Rig()
        _ = rig.monitor.handleKey(event: key(kVK_Space, down: true, flags: .maskAlternate),
                                  type: .keyDown, binding: optSpace)
        rig.physicallyDown = false
        rig.monitor.pollTick()
        XCTAssertEqual(rig.events, [.startHold, .cancelHold])
        XCTAssertTrue(rig.replayed.isEmpty)
    }

    // MARK: - Modifier hotkey used in a chord

    /// A key-down as if typed on the keyboard: events built in-process carry our own pid.
    private func foreignKeyDown(_ code: Int, flags: CGEventFlags = []) -> CGEvent {
        let e = key(code, down: true, flags: flags)
        e.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return e
    }

    func test_chordInsideWindow_cancelsAndSuppressesUntilRelease() {
        let rig = Rig()
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        rig.advance(ms: 100)
        rig.monitor.handleModifierKeyDown(event: foreignKeyDown(kVK_LeftArrow, flags: .maskAlternate))
        XCTAssertEqual(rig.events, [.startHold, .cancelHold])

        // Still the same physical press: no restart, release is silent.
        rig.advance(ms: 2000)
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold, .cancelHold])
        rig.monitor.pollTick()
        XCTAssertEqual(rig.events, [.startHold, .cancelHold])

        // The next press works normally.
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        rig.advance(ms: 1000)
        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold, .cancelHold, .startHold, .endHold])
    }

    func test_chord_comboBinding_suppressedUntilAllBoundModifiersReleased() {
        let rig = Rig()
        let combo = HotkeyBinding.modifier(deviceBits: 0x21)! // Left Control + Left Option
        let both: UInt64 = 0x00040000 | 0x00080000 | 0x21
        let ctrlOnly: UInt64 = 0x00040000 | 0x01
        rig.monitor.handleModifier(event: flagsEvent(both), binding: combo)
        rig.monitor.handleModifierKeyDown(event: foreignKeyDown(kVK_ANSI_A))
        XCTAssertEqual(rig.events, [.startHold, .cancelHold])

        rig.monitor.handleModifier(event: flagsEvent(ctrlOnly), binding: combo)
        rig.monitor.handleModifier(event: flagsEvent(both), binding: combo)
        XCTAssertEqual(rig.events, [.startHold, .cancelHold], "one bound modifier still held")

        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: combo)
        rig.monitor.handleModifier(event: flagsEvent(both), binding: combo)
        XCTAssertEqual(rig.events, [.startHold, .cancelHold, .startHold])
    }

    func test_keyDownAfterChordWindow_doesNothing() {
        let rig = Rig()
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        rig.advance(ms: HotkeyMonitor.chordWindowMs + 50)
        rig.monitor.handleModifierKeyDown(event: foreignKeyDown(kVK_LeftArrow))
        XCTAssertEqual(rig.events, [.startHold])
        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold, .endHold])
    }

    func test_keyDownFromOwnProcess_doesNothing() {
        // The previous dictation is being typed while the next hold has started.
        let rig = Rig()
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        let own = key(kVK_ANSI_A, down: true)
        own.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        rig.monitor.handleModifierKeyDown(event: own)
        XCTAssertEqual(rig.events, [.startHold])
    }

    func test_markedKeyDown_insideChordWindow_doesNotCancel_evenWithForeignPid() {
        // The marker alone must hold even if the pid field doesn't survive post(tap:).
        let rig = Rig()
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        rig.advance(ms: 100)
        let typed = foreignKeyDown(kVK_ANSI_A)
        SyntheticEvent.mark(typed)
        rig.monitor.handleModifierKeyDown(event: typed)
        XCTAssertFalse(rig.monitor.handle(event: typed, type: .keyDown, binding: .rightOption))
        XCTAssertEqual(rig.events, [.startHold])
        rig.advance(ms: 1000)
        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold, .endHold])
    }

    // MARK: - Our own typing vs. a key binding

    /// Shaped like `TextInserter.type`: virtual key 0, no flags, marked.
    private func typedText(down: Bool) -> CGEvent {
        let e = key(kVK_ANSI_A, down: down)
        e.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        SyntheticEvent.mark(e)
        return e
    }

    func test_markedKeyEvent_matchingKeyBinding_isNotSwallowed_andStartsNoHold() {
        let rig = Rig()
        let marked = foreignKeyDown(kVK_Space, flags: .maskAlternate)
        SyntheticEvent.mark(marked)
        XCTAssertFalse(rig.monitor.handle(event: marked, type: .keyDown, binding: optSpace))
        let markedUp = key(kVK_Space, down: false, flags: .maskAlternate)
        SyntheticEvent.mark(markedUp)
        XCTAssertFalse(rig.monitor.handle(event: markedUp, type: .keyUp, binding: optSpace))
        XCTAssertTrue(rig.events.isEmpty)
        XCTAssertTrue(rig.replayed.isEmpty)
    }

    func test_typedText_duringKeyHold_isNotSwallowed_andDoesNotEndIt() {
        // ⌃A bound (key code 0, same as the inserter's events): take 2 is being held
        // while take 1 is typed.
        let rig = Rig()
        let ctrlA = HotkeyBinding.key(keyCode: UInt16(kVK_ANSI_A), mods: 0x00040000)
        let real = foreignKeyDown(kVK_ANSI_A, flags: .maskControl)
        XCTAssertTrue(rig.monitor.handle(event: real, type: .keyDown, binding: ctrlA))
        rig.advance(ms: 300)
        XCTAssertFalse(rig.monitor.handle(event: typedText(down: true), type: .keyDown, binding: ctrlA))
        XCTAssertFalse(rig.monitor.handle(event: typedText(down: false), type: .keyUp, binding: ctrlA))
        XCTAssertEqual(rig.events, [.startHold], "typing must not end the hold")
        rig.advance(ms: 1000)
        XCTAssertTrue(rig.monitor.handle(event: key(kVK_ANSI_A, down: false, flags: .maskControl),
                                         type: .keyUp, binding: ctrlA))
        XCTAssertEqual(rig.events, [.startHold, .endHold])
    }

    func test_syntheticEventMarker() {
        let e = key(kVK_Space, down: true)
        XCTAssertFalse(SyntheticEvent.isOurs(e))
        SyntheticEvent.mark(e)
        XCTAssertTrue(SyntheticEvent.isOurs(e))
        XCTAssertEqual(e.getIntegerValueField(.eventSourceUserData), SyntheticEvent.marker)
    }

    func test_keyDownWithoutHold_doesNothing() {
        let rig = Rig()
        rig.monitor.handleModifierKeyDown(event: foreignKeyDown(kVK_ANSI_A))
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold], "an earlier key-down doesn't suppress the next press")
    }

    func test_plainModifierHold_startsAndEnds() {
        let rig = Rig()
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        rig.advance(ms: 1500)
        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold, .endHold])
    }

    // MARK: - Single-modifier path

    func test_singleModifier_startsOnPress_endsOnRelease() {
        let rig = Rig()
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold], "recording starts on press, no delay")
        // Repeated flagsChanged while held (another device bit of the same mod) don't restart.
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown | 0x20), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold])
        rig.advance(ms: 800)
        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold, .endHold])
    }

    func test_singleModifier_quickTap_cancels() {
        let rig = Rig()
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        rig.advance(ms: 10)
        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold, .cancelHold])
        XCTAssertTrue(rig.replayed.isEmpty, "modifier taps are never swallowed, so nothing is replayed")
    }

    func test_singleModifier_noStartWhileAnotherGeneralModifierHeld() {
        let rig = Rig()
        let cmdHeld: UInt64 = 0x00100000 | 0x08
        rig.monitor.handleModifier(event: flagsEvent(cmdHeld), binding: .rightOption)
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown | cmdHeld), binding: .rightOption)
        XCTAssertTrue(rig.events.isEmpty)
        rig.monitor.handleModifier(event: flagsEvent(0x00020000 | 0x02 | rightOptDown), binding: .rightOption)
        XCTAssertTrue(rig.events.isEmpty, "shift is a general modifier too")
    }

    func test_singleModifier_otherModifierAddedMidHold_doesNotEndIt() {
        let rig = Rig()
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown), binding: .rightOption)
        rig.monitor.handleModifier(event: flagsEvent(rightOptDown | 0x00100000 | 0x08), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold])
        rig.advance(ms: 800)
        rig.monitor.handleModifier(event: flagsEvent(noMods), binding: .rightOption)
        XCTAssertEqual(rig.events, [.startHold, .endHold])
    }

    func test_physicalKeyCodes() {
        XCTAssertEqual(HotkeyBinding.rightOption.physicalKeyCodes, [UInt16(kVK_RightOption)])
        XCTAssertEqual(HotkeyBinding.modifier(deviceBits: 0x2001)!.physicalKeyCodes,
                       [UInt16(kVK_Control), UInt16(kVK_RightControl)])
        XCTAssertEqual(optSpace.physicalKeyCodes, [UInt16(kVK_Space)])
    }
}
