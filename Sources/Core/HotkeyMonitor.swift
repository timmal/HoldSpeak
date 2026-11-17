import Cocoa
import Combine

public final class HotkeyMonitor {
    /// `.startHold` fires immediately on key press so recording can begin without
    /// losing the first syllables. If the key is released before `holdThresholdMs`
    /// the press is treated as an accidental tap and `.cancelHold` follows instead
    /// of `.endHold`.
    public enum Event { case startHold; case endHold; case cancelHold }
    public let events = PassthroughSubject<Event, Never>()

    /// A hold longer than this is not a dictation (lost release, stuck key): it is
    /// discarded rather than transcribed.
    public static let maxHoldSeconds: TimeInterval = 600
    /// How often an active hold re-checks that the bound key is still physically down.
    static let pollInterval: TimeInterval = 0.5

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdStartedAt: Date?
    /// The binding the current hold was started with.
    private var holdBinding: HotkeyBinding?
    /// The poll only ends a hold once it has seen the binding physically down, so key
    /// state the HID layer can't see (Universal Control, software remappers) never
    /// cuts a dictation short; the `maxHoldSeconds` backstop still applies there.
    private var holdSeenDown = false
    private var pollTimer: Timer?
    /// The key-down a `.key` hold swallowed, given back if the press turns out to be a tap.
    private var swallowedKeyDown: CGEvent?
    /// Set when a `.modifier` hold was cancelled as a chord: the rest of that physical
    /// press is ignored until every bound modifier is up.
    private var suppressUntilRelease = false

    /// A key typed this soon after a modifier hotkey went down makes the press a chord
    /// (⌥←, AltGr characters), not a dictation.
    static let chordWindowMs: Double = 600
    private static let ownPID = Int64(getpid())

    /// Written to `.eventSourceUserData` of events we replay, so the tap lets them through.
    static let replayMarker: Int64 = 0x4853_5250_4C59 // "HSRPLY"

    /// Injectable for tests.
    var now: () -> Date = Date.init
    var isBindingPhysicallyDown: (HotkeyBinding) -> Bool = HotkeyMonitor.hidKeysDown
    /// Posts a replayed (already marked) key-down + key-up pair.
    var replayTap: (_ down: CGEvent, _ up: CGEvent) -> Void = HotkeyMonitor.post

    /// Set while Preferences is capturing a new binding: events pass through
    /// untouched so pressing the current hotkey doesn't start a dictation and
    /// still reaches the recorder. Main thread only (the tap runs on the main run loop).
    public static var isPaused = false

    /// While paused, keyDowns seen by the tap go here as (keyCode, flags); return true to swallow.
    public static var recorderKeyDown: ((UInt16, UInt64) -> Bool)?

    private let prefs: PreferencesStore
    public init(prefs: PreferencesStore = .shared) { self.prefs = prefs }
    deinit { pollTimer?.invalidate() }

    public func start() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let this = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // macOS disables the tap if the main thread stalls; without this
                    // the hotkey stays dead until relaunch.
                    pttLog("HotkeyMonitor: event tap disabled (\(type.rawValue)) — re-enabling")
                    if let tap = this.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    // The release may have happened while the tap was off.
                    this.pollTick()
                    return Unmanaged.passUnretained(event)
                }
                if this.handle(event: event, type: type) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        )
        guard let tap else {
            NSLog("HotkeyMonitor: failed to create event tap (missing Accessibility permission?)")
            return
        }
        self.eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        }
        eventTap = nil
        runLoopSource = nil
        clearHold()
        suppressUntilRelease = false
    }

    /// Returns true if the event should be consumed (dropped).
    private func handle(event: CGEvent, type: CGEventType) -> Bool {
        // Our own replay of a short tap: it is for the focused app.
        if Self.isReplayed(event) { return false }
        if Self.isPaused {
            // A hold in progress when capture began would never see its release.
            suppressUntilRelease = false
            if holdStartedAt != nil {
                clearHold()
                events.send(.cancelHold)
            }
            if type == .keyDown, NSApplication.shared.isActive, let hook = Self.recorderKeyDown {
                return hook(UInt16(event.getIntegerValueField(.keyboardEventKeycode)), event.flags.rawValue)
            }
            return false
        }
        let binding = prefs.hotkey
        switch binding.kind {
        case .modifier:
            if type == .flagsChanged { handleModifier(event: event, binding: binding) }
            else if type == .keyDown { handleModifierKeyDown(event: event) }
            return false
        case .key:
            return handleKey(event: event, type: type, binding: binding)
        }
    }

    func handleModifier(event: CGEvent, binding: HotkeyBinding) {
        let flags = event.flags.rawValue
        if suppressUntilRelease {
            if flags & binding.deviceBit == 0 { suppressUntilRelease = false }
            return
        }
        let ourKeyDown = (flags & binding.deviceBit) == binding.deviceBit
        let otherGeneralMods = flags & HotkeyBinding.allGeneralMods & ~binding.mods
        if ourKeyDown && otherGeneralMods != 0 { return }

        if ourKeyDown && holdStartedAt == nil {
            beginHold(binding)
        } else if !ourKeyDown {
            endOrCancel()
        }
    }

    /// A key-down while a `.modifier` hold is active. Never swallowed.
    func handleModifierKeyDown(event: CGEvent) {
        guard let startedAt = holdStartedAt, holdBinding?.kind == .modifier else { return }
        // Our own typing of the previous dictation, or a replayed tap, is not a chord.
        guard !Self.isReplayed(event),
              event.getIntegerValueField(.eventSourceUnixProcessID) != Self.ownPID else { return }
        guard now().timeIntervalSince(startedAt) * 1000.0 < Self.chordWindowMs else { return }
        pttLog("HotkeyMonitor: hotkey used in a key chord — discarding hold")
        clearHold()
        suppressUntilRelease = true
        events.send(.cancelHold)
    }

    func handleKey(event: CGEvent, type: CGEventType, binding: HotkeyBinding) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }
        let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard kc == binding.keyCode else { return false }
        let flags = event.flags.rawValue
        let currentMods = flags & HotkeyBinding.allGeneralMods
        if type == .keyDown {
            // Auto-repeat during a hold stays swallowed, even if a modifier was let go.
            if holdStartedAt != nil { return true }
            guard currentMods == binding.mods else { return false }
            beginHold(binding)
            swallowedKeyDown = event.copy()
            return true
        } else {
            // Only swallow the keyUp that ends our hold — e.g. with ⌥Space bound, a
            // plain Space keyUp must still reach the focused app.
            guard holdStartedAt != nil else { return false }
            let tapDown = swallowedKeyDown
            if endOrCancel() == .cancelHold, let down = tapDown, let up = event.copy() {
                // A tap, not a dictation: give the key to the focused app after all.
                down.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
                up.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
                replayTap(down, up)
            }
            return true
        }
    }

    static func isReplayed(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == replayMarker
    }

    private static func post(_ down: CGEvent, _ up: CGEvent) {
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func beginHold(_ binding: HotkeyBinding) {
        holdStartedAt = now()
        holdBinding = binding
        holdSeenDown = isBindingPhysicallyDown(binding)
        startPollTimer()
        events.send(.startHold)
    }

    @discardableResult
    private func endOrCancel() -> Event? {
        guard let startedAt = holdStartedAt else { return nil }
        clearHold()
        let heldMs = now().timeIntervalSince(startedAt) * 1000.0
        let event: Event = heldMs >= Double(prefs.holdThresholdMs) ? .endHold : .cancelHold
        events.send(event)
        return event
    }

    private func clearHold() {
        holdStartedAt = nil
        holdBinding = nil
        holdSeenDown = false
        swallowedKeyDown = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Lost release

    /// The release event can be lost (tap disabled by timeout, secure input, lock
    /// screen or an auth dialog taking the keyboard mid-hold); without this the mic
    /// would keep recording until the next press.
    private func startPollTimer() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// One poll step; run by the timer and right after the tap is re-enabled.
    func pollTick() {
        guard let startedAt = holdStartedAt, let binding = holdBinding else {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        if now().timeIntervalSince(startedAt) >= Self.maxHoldSeconds {
            pttLog("HotkeyMonitor: hold exceeded \(Int(Self.maxHoldSeconds)) s — discarding")
            clearHold()
            events.send(.cancelHold)
            return
        }
        if isBindingPhysicallyDown(binding) {
            holdSeenDown = true
        } else if holdSeenDown {
            pttLog("HotkeyMonitor: hotkey is up but its release was missed — ending hold")
            endOrCancel()
        }
    }

    static func hidKeysDown(_ binding: HotkeyBinding) -> Bool {
        binding.physicalKeyCodes.allSatisfy { CGEventSource.keyState(.hidSystemState, key: $0) }
    }
}
