import XCTest
@testable import HoldSpeakCore

/// `SingleFlight` keeps one download per model: a second request joins the first.
@MainActor
final class SingleFlightTests: XCTestCase {
    /// An operation the test finishes by hand, counting how often it was started.
    private final class Gate {
        var started = 0
        var report: (@Sendable (Double) -> Void)?
        private var continuation: CheckedContinuation<Int, Error>?

        func operation(_ report: @escaping @Sendable (Double) -> Void) async throws -> Int {
            started += 1
            self.report = report
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }

        var isWaiting: Bool { continuation != nil }

        func finish(_ result: Result<Int, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private struct Boom: Error {}

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "timed out")
    }

    func test_twoConcurrentRequests_runOneOperation_andBothGetTheResult() async throws {
        let flights = SingleFlight<String, Int>()
        let gate = Gate()
        let first = Task { try await flights.run("turbo", operation: gate.operation) }
        await waitUntil { gate.isWaiting }
        var joined = false
        let second = Task { try await flights.run("turbo", progress: { _ in joined = true }, operation: gate.operation) }
        await waitUntil { joined }

        XCTAssertTrue(flights.isRunning("turbo"))
        gate.finish(.success(42))
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a, 42)
        XCTAssertEqual(b, 42)
        XCTAssertEqual(gate.started, 1)
        XCTAssertFalse(flights.isRunning("turbo"))
    }

    func test_failure_reachesBothCallers_andTheNextRequestStartsFresh() async throws {
        let flights = SingleFlight<String, Int>()
        let gate = Gate()
        let first = Task { try await flights.run("turbo", operation: gate.operation) }
        await waitUntil { gate.isWaiting }
        var joined = false
        let second = Task { try await flights.run("turbo", progress: { _ in joined = true }, operation: gate.operation) }
        await waitUntil { joined }

        gate.finish(.failure(Boom()))
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("expected the failure")
            } catch {
                XCTAssertTrue(error is Boom)
            }
        }
        XCTAssertFalse(flights.isRunning("turbo"))
        XCTAssertEqual(flights.running, [])

        let retry = Task { try await flights.run("turbo", operation: gate.operation) }
        await waitUntil { gate.isWaiting }
        XCTAssertEqual(gate.started, 2, "a failed flight is not reused")
        gate.finish(.success(7))
        let value = try await retry.value
        XCTAssertEqual(value, 7)
    }

    func test_progress_reachesEveryCaller_andIsReadable() async throws {
        let flights = SingleFlight<String, Int>()
        let gate = Gate()
        var changes = 0
        flights.onChange = { changes += 1 }
        var seenByFirst: Double?
        var seenBySecond: Double?
        let first = Task { try await flights.run("turbo", progress: { seenByFirst = $0 }, operation: gate.operation) }
        await waitUntil { gate.isWaiting }
        XCTAssertEqual(flights.running, ["turbo"])
        XCTAssertEqual(changes, 1, "start is reported")

        gate.report?(0.25)
        await waitUntil { seenByFirst == 0.25 }
        // A caller that joins late gets the current fraction straight away.
        let second = Task { try await flights.run("turbo", progress: { seenBySecond = $0 }, operation: gate.operation) }
        await waitUntil { seenBySecond == 0.25 }

        gate.report?(0.5)
        await waitUntil { seenByFirst == 0.5 && seenBySecond == 0.5 }
        XCTAssertEqual(flights.progress(of: "turbo"), 0.5)

        gate.finish(.success(1))
        _ = try await first.value
        _ = try await second.value
        XCTAssertNil(flights.progress(of: "turbo"))
        XCTAssertEqual(flights.running, [])
        XCTAssertGreaterThanOrEqual(changes, 4, "start, two progress reports, finish")
    }

    func test_differentKeys_runSeparately() async throws {
        let flights = SingleFlight<String, Int>()
        let whisper = Gate()
        let parakeet = Gate()
        let a = Task { try await flights.run("whisper", operation: whisper.operation) }
        let b = Task { try await flights.run("parakeet", operation: parakeet.operation) }
        await waitUntil { whisper.isWaiting && parakeet.isWaiting }
        XCTAssertEqual(Set(flights.running), ["whisper", "parakeet"])
        whisper.finish(.success(1))
        parakeet.finish(.success(2))
        let resultA = try await a.value
        let resultB = try await b.value
        XCTAssertEqual(resultA, 1)
        XCTAssertEqual(resultB, 2)
        XCTAssertEqual(whisper.started, 1)
        XCTAssertEqual(parakeet.started, 1)
    }

    /// A progress report that arrives after the flight finished must not resurrect it.
    func test_lateProgress_afterFinish_isIgnored() async throws {
        let flights = SingleFlight<String, Int>()
        let gate = Gate()
        let task = Task { try await flights.run("turbo", operation: gate.operation) }
        await waitUntil { gate.isWaiting }
        let report = gate.report
        gate.finish(.success(1))
        _ = try await task.value
        report?(0.9)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(flights.progress(of: "turbo"))
        XCTAssertEqual(flights.running, [])
    }
}
