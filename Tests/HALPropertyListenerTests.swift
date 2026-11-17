import CoreAudio
import XCTest
@testable import HoldSpeakCore

/// Device listeners must really go away on remove. Registered through the block API from
/// Swift they never did: the block is re-bridged per call, so Remove matched nothing and
/// every tap teardown left its listeners behind.
///
/// Uses `kAudioHardwarePropertySleepingIsAllowed` on the system object as the trigger: a
/// per-process power hint, so toggling it touches only this test process and no device
/// is opened. The original value is restored.
///
/// Machines without usable HAL notifications (hosted CI runners without audio hardware,
/// a HAL that refuses the write) skip instead of failing. Once the first notification
/// has arrived, every check is a hard assertion.
final class HALPropertyListenerTests: XCTestCase {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    /// Value to restore in `tearDown`; nil when it could not be read.
    private var original: UInt32?

    private static var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertySleepingIsAllowed,
                                                            mScope: kAudioObjectPropertyScopeGlobal,
                                                            mElement: kAudioObjectPropertyElementMain)

    private func readSleepingAllowed() -> (status: OSStatus, value: UInt32) {
        var addr = Self.address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &value)
        return (status, value)
    }

    private func writeSleepingAllowed(_ value: UInt32) -> OSStatus {
        var addr = Self.address
        var v = value
        return AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    /// Flips the property; skips the test when the HAL won't read or write it.
    private func toggle() throws {
        let read = readSleepingAllowed()
        guard read.status == noErr else {
            throw XCTSkip("Cannot read kAudioHardwarePropertySleepingIsAllowed (OSStatus \(read.status)) — no HAL to test against")
        }
        let status = writeSleepingAllowed(read.value == 0 ? 1 : 0)
        guard status == noErr else {
            throw XCTSkip("HAL refused to write kAudioHardwarePropertySleepingIsAllowed (OSStatus \(status))")
        }
    }

    override func setUp() {
        super.setUp()
        let read = readSleepingAllowed()
        original = read.status == noErr ? read.value : nil
    }

    override func tearDown() {
        if let original { _ = writeSleepingAllowed(original) }
        super.tearDown()
    }

    func testFiresOnItsQueueAndStopsAfterRemove() throws {
        guard original != nil else {
            throw XCTSkip("Cannot read kAudioHardwarePropertySleepingIsAllowed — no HAL to test against")
        }
        let queue = DispatchQueue(label: "HALPropertyListenerTests")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let lock = NSLock()
        var fired = 0
        var onQueue = true
        let listener = HALPropertyListener(object: system, selectors: [kAudioHardwarePropertySleepingIsAllowed],
                                           queue: queue) {
            lock.lock(); fired += 1; onQueue = onQueue && DispatchQueue.getSpecific(key: key) == true; lock.unlock()
        }
        defer { listener.remove() }

        try toggle()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            queue.sync {}
            lock.lock(); let n = fired; lock.unlock()
            if n > 0 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        lock.lock(); let firstFired = fired; lock.unlock()
        guard firstFired > 0 else {
            throw XCTSkip("HAL delivered no property notification within 2 s — cannot test listener removal here")
        }
        lock.lock(); XCTAssertTrue(onQueue, "listener ran off its queue"); lock.unlock()

        // From here on the HAL demonstrably delivers notifications: hard assertions only.
        listener.remove()
        lock.lock(); let before = fired; lock.unlock()
        for _ in 0..<2 {
            let read = readSleepingAllowed()
            XCTAssertEqual(read.status, noErr)
            XCTAssertEqual(writeSleepingAllowed(read.value == 0 ? 1 : 0), noErr)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        queue.sync {}
        lock.lock(); XCTAssertEqual(fired, before, "listener still fires after remove"); lock.unlock()

        listener.remove() // idempotent
    }
}
