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
final class HALPropertyListenerTests: XCTestCase {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var original: UInt32 = 0

    private func sleepingAllowed() -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertySleepingIsAllowed,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &value), noErr)
        return value
    }

    private func setSleepingAllowed(_ value: UInt32) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertySleepingIsAllowed,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v = value
        XCTAssertEqual(AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v), noErr)
    }

    private func toggle() { setSleepingAllowed(sleepingAllowed() == 0 ? 1 : 0) }

    override func setUp() {
        super.setUp()
        original = sleepingAllowed()
    }

    override func tearDown() {
        setSleepingAllowed(original)
        super.tearDown()
    }

    func testFiresOnItsQueueAndStopsAfterRemove() {
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

        toggle()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            queue.sync {}
            lock.lock(); let n = fired; lock.unlock()
            if n > 0 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        lock.lock(); XCTAssertGreaterThan(fired, 0, "listener never fired"); XCTAssertTrue(onQueue); lock.unlock()

        listener.remove()
        lock.lock(); let before = fired; lock.unlock()
        toggle()
        toggle()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        queue.sync {}
        lock.lock(); XCTAssertEqual(fired, before, "listener still fires after remove"); lock.unlock()

        listener.remove() // idempotent
    }
}
