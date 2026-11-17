import AVFoundation
import XCTest
@testable import HoldSpeakCore

/// The AUHAL client format must exist for any input width: the plain channel-count
/// initializer returns nil above two channels, which made every multichannel interface
/// or aggregate fail with `invalidInputFormat`.
final class CaptureFormatTests: XCTestCase {
    func testFormatForEveryChannelCount() throws {
        for channels: UInt32 in [1, 2, 3, 4, 8, 16, 18] {
            for rate in [16_000.0, 44_100, 48_000, 96_000] {
                let format = try XCTUnwrap(CaptureDSP.captureFormat(sampleRate: rate, channels: channels),
                                           "nil for \(channels) ch @ \(rate)")
                XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
                XCTAssertFalse(format.isInterleaved)
                XCTAssertEqual(format.channelCount, channels)
                XCTAssertEqual(format.sampleRate, rate)
                let asbd = format.streamDescription.pointee
                XCTAssertEqual(asbd.mChannelsPerFrame, channels)
                XCTAssertEqual(asbd.mBytesPerFrame, 4, "non-interleaved: one Float32 per buffer per frame")
                XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
                XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat, 0)
            }
        }
    }

    /// The tap's scratch and pending buffers are built from this format; each channel
    /// needs its own buffer for `AudioUnitRender` and the per-channel copy.
    func testBuffersHaveOneChannelBufferEach() throws {
        for channels: UInt32 in [1, 2, 3, 8, 18] {
            let format = try XCTUnwrap(CaptureDSP.captureFormat(sampleRate: 48_000, channels: channels))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            XCTAssertEqual(buffer.mutableAudioBufferList.pointee.mNumberBuffers, channels)
            XCTAssertNotNil(buffer.floatChannelData)
        }
    }

    func testRejectsEmptyFormats() {
        XCTAssertNil(CaptureDSP.captureFormat(sampleRate: 0, channels: 2))
        XCTAssertNil(CaptureDSP.captureFormat(sampleRate: 48_000, channels: 0))
        XCTAssertNil(CaptureDSP.captureFormat(sampleRate: -1, channels: 1))
    }
}
