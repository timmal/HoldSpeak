import XCTest
@testable import HoldSpeakCore

/// When a stall abandons a capture, every start/stop still queued on it must finish right
/// then, in order. A stop completion that fired later (its own watchdog, or the wedged HAL
/// call finally returning) ran `takeSamples()` in the middle of the NEXT recording and
/// split that take in two.
final class PendingCallsTests: XCTestCase {
    private final class Owner {}

    func testFinishRunsTheCompletionOnce() {
        let calls = PendingCalls()
        var runs = 0
        let call = calls.begin(owner: Owner(), completion: { runs += 1 })
        XCTAssertFalse(call.finished)
        calls.finish(call)
        calls.finish(call)
        XCTAssertTrue(call.finished)
        XCTAssertEqual(runs, 1)
    }

    func testFinishAllRunsEveryCallOfTheOwnerInOrder() {
        let calls = PendingCalls()
        let stalled = Owner(), fresh = Owner()
        var log: [String] = []
        let start = calls.begin(owner: stalled, completion: nil)
        let stop1 = calls.begin(owner: stalled, completion: { log.append("stop1") })
        let start2 = calls.begin(owner: stalled, completion: nil)
        let stop2 = calls.begin(owner: stalled, completion: { log.append("stop2") })
        let other = calls.begin(owner: fresh, completion: { log.append("other") })

        calls.finishAll(owner: stalled)
        XCTAssertEqual(log, ["stop1", "stop2"])
        XCTAssertTrue([start, stop1, start2, stop2].allSatisfy(\.finished))
        XCTAssertFalse(other.finished)

        // The stalled calls' own watchdogs or late HAL returns change nothing.
        calls.finish(stop1)
        calls.finish(stop2)
        XCTAssertEqual(log, ["stop1", "stop2"])

        calls.finish(other)
        XCTAssertEqual(log, ["stop1", "stop2", "other"])
    }

    /// The reported race: hold 1's start stalls, its stop queues behind it; the start's
    /// watchdog replaces the capture; hold 2 starts on the fresh capture; then hold 1's
    /// stop watchdog fires. Its completion must already have run — before hold 2 began.
    func testStopQueuedBehindAStallFinishesBeforeTheNextHold() {
        let calls = PendingCalls()
        var engine: [String] = []      // what `engine.feed` has accumulated
        var takes: [[String]] = []     // what each stop completion took
        let take = { takes.append(engine); engine = [] }

        let wedged = Owner()
        _ = calls.begin(owner: wedged, completion: nil)               // hold 1 start, stalls
        let stop1 = calls.begin(owner: wedged, completion: take)      // hold 1 stop, queued behind it
        calls.finishAll(owner: wedged)                                // start's watchdog: capture replaced

        let fresh = Owner()
        let start2 = calls.begin(owner: fresh, completion: nil)       // hold 2
        calls.finish(start2)
        engine += ["h2-a", "h2-b"]                                    // hold 2's chunks arrive
        calls.finish(stop1)                                           // hold 1 stop's watchdog fires late
        XCTAssertEqual(engine, ["h2-a", "h2-b"], "a late stop completion must not take hold 2's audio")

        let stop2 = calls.begin(owner: fresh, completion: take)
        calls.finish(stop2)
        XCTAssertEqual(takes, [[], ["h2-a", "h2-b"]])
    }
}
