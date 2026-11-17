import XCTest
@testable import HoldSpeakCore

final class SingleInstanceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func inst(_ pid: Int32, _ seconds: TimeInterval?) -> SingleInstance.Instance {
        SingleInstance.Instance(pid: pid, launchDate: seconds.map { t0.addingTimeInterval($0) })
    }

    func test_aloneKeepsRunning() {
        XCTAssertNil(SingleInstance.instanceToYieldTo(me: inst(10, 5), others: []))
    }

    func test_ownEntryIsIgnored() {
        XCTAssertNil(SingleInstance.instanceToYieldTo(me: inst(10, 5), others: [inst(10, 5)]))
    }

    func test_laterCopyYieldsToTheRunningOne() {
        XCTAssertEqual(SingleInstance.instanceToYieldTo(me: inst(20, 5), others: [inst(10, 0)]), inst(10, 0))
    }

    /// The copy that started first must not quit because a newer one appeared.
    func test_olderCopyKeepsRunning() {
        XCTAssertNil(SingleInstance.instanceToYieldTo(me: inst(10, 0), others: [inst(20, 5)]))
    }

    /// Two copies started in the same instant: exactly one (the lower pid) stays.
    func test_simultaneousLaunchKeepsTheLowerPid() {
        XCTAssertEqual(SingleInstance.instanceToYieldTo(me: inst(20, 0), others: [inst(10, 0)]), inst(10, 0))
        XCTAssertNil(SingleInstance.instanceToYieldTo(me: inst(10, 0), others: [inst(20, 0)]))
    }

    /// A copy LaunchServices didn't start (run from Terminal or Xcode) has no launch
    /// date; it was already running, so a new launch gives way to it.
    func test_copyWithoutLaunchDateCountsAsEarlier() {
        XCTAssertEqual(SingleInstance.instanceToYieldTo(me: inst(5, 5), others: [inst(30, nil)]), inst(30, nil))
    }
}
