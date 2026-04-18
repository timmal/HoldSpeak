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

    // Device-dependent modifier flag bits (IOKit NX_DEVICE* constants)
    private static let rightOptionMask: UInt64 = 0x40
    private static let rightCmdMask: UInt64 = 0x10
    // Any modifier bit except our watched one, within the modifier range
    private static let modifierRange: UInt64 = 0xFFFF0000

    private func watchedMask() -> UInt64 {
        prefs.hotkey == .rightOption ? Self.rightOptionMask : Self.rightCmdMask
    }

    private func handle(event: CGEvent, type: CGEventType) {
        guard type == .flagsChanged else { return }
        let flags = event.flags.rawValue
        let watched = watchedMask()
        let ourKeyDown = (flags & watched) != 0

        let otherMods = flags & Self.modifierRange & ~watched
        if ourKeyDown && otherMods != 0 { return }

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
