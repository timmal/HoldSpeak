import XCTest
@testable import HoldSpeakCore

/// A capture whose every render cycle failed must not keep its input unit: the next
/// hold rebuilds it instead of failing the same way forever.
final class RenderFailureTests: XCTestCase {
    func testDropsATapThatNeverRendered() {
        XCTAssertTrue(CaptureDSP.shouldDropTap(renderErrors: 1, renderedFrames: 0))
        XCTAssertTrue(CaptureDSP.shouldDropTap(renderErrors: 500, renderedFrames: 0))
    }

    func testKeepsATapThatDeliveredAudio() {
        // A glitch or two in a working capture is not a broken unit.
        XCTAssertFalse(CaptureDSP.shouldDropTap(renderErrors: 3, renderedFrames: 48_000))
        XCTAssertFalse(CaptureDSP.shouldDropTap(renderErrors: 0, renderedFrames: 48_000))
    }

    func testKeepsATapThatWasNeverCalled() {
        // A very short tap can end before the first IO cycle: no errors, nothing to fix.
        XCTAssertFalse(CaptureDSP.shouldDropTap(renderErrors: 0, renderedFrames: 0))
    }
}
