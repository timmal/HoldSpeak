import Cocoa
import Combine

public final class HotkeyMonitor {
    public enum Event { case startHold; case endHold }
    public let events = PassthroughSubject<Event, Never>()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingStartWork: DispatchWorkItem?
    private var isHolding = false

    private let prefs: PreferencesStore
    public init(prefs: PreferencesStore = .shared) { self.prefs = prefs }

    public func start() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let this = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                this.handle(event: event, type: type)
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
        pendingStartWork?.cancel()
        pendingStartWork = nil
        isHolding = false
    }

    // Device-dependent modifier flag bits (IOKit NX_DEVICE* constants, lower 16 bits)
    private static let rightOptionDeviceBit: UInt64 = 0x40
    private static let rightCmdDeviceBit: UInt64 = 0x10
    // CGEventFlags general modifier bits that indicate a user-facing modifier is held
    private static let generalShift:   UInt64 = 0x00020000
    private static let generalControl: UInt64 = 0x00040000
    private static let generalOption:  UInt64 = 0x00080000
    private static let generalCommand: UInt64 = 0x00100000
    private static let allGeneralModifiers: UInt64 =
        generalShift | generalControl | generalOption | generalCommand

    private func watchedDeviceBit() -> UInt64 {
        prefs.hotkey == .rightOption ? Self.rightOptionDeviceBit : Self.rightCmdDeviceBit
    }

    private func watchedGeneralBit() -> UInt64 {
        prefs.hotkey == .rightOption ? Self.generalOption : Self.generalCommand
    }

    private func handle(event: CGEvent, type: CGEventType) {
        guard type == .flagsChanged else { return }
        let flags = event.flags.rawValue
        let deviceBit = watchedDeviceBit()
        let generalBit = watchedGeneralBit()
        let ourKeyDown = (flags & deviceBit) != 0

        // Reject only if a *different* general modifier is also held (chord collision avoidance).
        let otherGeneralMods = flags & Self.allGeneralModifiers & ~generalBit
        if ourKeyDown && otherGeneralMods != 0 { return }

        if ourKeyDown && !isHolding {
            pendingStartWork?.cancel()
            let threshold = Double(prefs.holdThresholdMs) / 1000.0
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.isHolding = true
                self.events.send(.startHold)
            }
            pendingStartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: work)
        } else if !ourKeyDown {
            if isHolding {
                isHolding = false
                events.send(.endHold)
            } else {
                pendingStartWork?.cancel()
                pendingStartWork = nil
            }
        }
    }
}
