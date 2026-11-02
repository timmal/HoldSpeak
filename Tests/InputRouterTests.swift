import CoreAudio
import XCTest
@testable import HoldSpeakCore

final class InputRouterTests: XCTestCase {
    private func device(_ id: AudioDeviceID, _ uid: String, _ transport: UInt32) -> InputDevice.Info {
        InputDevice.Info(id: id, uid: uid, name: "Device \(id)", transport: transport)
    }

    private lazy var builtIn = device(1, "BuiltInMicrophoneDevice", kAudioDeviceTransportTypeBuiltIn)
    private lazy var usb = device(2, "usb-mic", kAudioDeviceTransportTypeUSB)
    private lazy var airPods = device(3, "AC-07-75:input", kAudioDeviceTransportTypeBluetooth)
    private lazy var bluetoothLE = device(4, "le-mic", kAudioDeviceTransportTypeBluetoothLE)
    private lazy var iPhoneWired = device(5, "iphone-wired", kAudioDeviceTransportTypeContinuityCaptureWired)
    private lazy var iPhoneWireless = device(6, "iphone-air", kAudioDeviceTransportTypeContinuityCaptureWireless)
    private lazy var blackHole = device(7, "BlackHole2ch_UID", kAudioDeviceTransportTypeVirtual)
    private lazy var teams = device(8, "MSLoopbackDriverDevice_UID", kAudioDeviceTransportTypeVirtual)
    private lazy var aggregate = device(9, "~:AMS2_Aggregate:0", kAudioDeviceTransportTypeAggregate)
    private lazy var autoAggregate = device(10, "auto-aggregate", kAudioDeviceTransportTypeAutoAggregate)
    private lazy var unknown = device(11, "no-transport", kAudioDeviceTransportTypeUnknown)
    /// A headset in the 3.5 mm jack reports the built-in transport, but its mic lives
    /// outside the lid and keeps working.
    private lazy var jack = device(12, "BuiltInHeadphoneInputDevice", kAudioDeviceTransportTypeBuiltIn)

    private func route(_ selection: InputSelection, _ devices: [InputDevice.Info], def: InputDevice.Info?,
                       lidClosed: Bool) -> InputRoute {
        InputRouter.route(selection: selection, devices: devices, defaultID: def?.id, lidClosed: lidClosed)
    }

    // MARK: - Lid open: same as before routing existed

    func testLidOpenSystemDefaultUsesDefault() {
        XCTAssertEqual(route(.systemDefault, [builtIn, usb], def: builtIn, lidClosed: false), .selected(builtIn.id))
        XCTAssertEqual(route(.systemDefault, [builtIn, airPods], def: airPods, lidClosed: false), .selected(airPods.id))
    }

    func testLidOpenAvoidBluetoothPicksBuiltInOverBluetoothDefault() {
        XCTAssertEqual(route(.avoidBluetooth, [airPods, builtIn], def: airPods, lidClosed: false), .selected(builtIn.id))
    }

    func testLidOpenAvoidBluetoothKeepsNonBluetoothDefault() {
        XCTAssertEqual(route(.avoidBluetooth, [builtIn, usb], def: usb, lidClosed: false), .selected(usb.id))
        XCTAssertEqual(route(.avoidBluetooth, [builtIn, usb], def: builtIn, lidClosed: false), .selected(builtIn.id))
    }

    func testLidOpenAvoidBluetoothWithoutBuiltInKeepsBluetoothDefault() {
        XCTAssertEqual(route(.avoidBluetooth, [airPods, usb], def: airPods, lidClosed: false), .selected(airPods.id))
    }

    func testLidOpenExplicitDeviceIsHonoured() {
        XCTAssertEqual(route(.device(uid: builtIn.uid), [builtIn, usb], def: usb, lidClosed: false), .selected(builtIn.id))
        XCTAssertEqual(route(.device(uid: blackHole.uid), [builtIn, blackHole], def: builtIn, lidClosed: false),
                       .selected(blackHole.id))
    }

    func testLidOpenDisconnectedDeviceUsesDefault() {
        XCTAssertEqual(route(.device(uid: "gone"), [builtIn, usb], def: usb, lidClosed: false), .selected(usb.id))
    }

    func testNoDefaultAndNothingSelectedIsNoDevice() {
        XCTAssertEqual(route(.systemDefault, [], def: nil, lidClosed: false), .noDevice)
        XCTAssertEqual(route(.systemDefault, [], def: nil, lidClosed: true), .noDevice)
        XCTAssertEqual(route(.device(uid: "gone"), [], def: nil, lidClosed: true), .noDevice)
    }

    // MARK: - Lid closed, selection resolves to the built-in mic

    func testLidClosedEverySelectionLeavesBuiltInForWiredMic() {
        let devices = [builtIn, airPods, usb]
        XCTAssertEqual(route(.systemDefault, devices, def: builtIn, lidClosed: true), .lidFallback(usb))
        XCTAssertEqual(route(.avoidBluetooth, devices, def: builtIn, lidClosed: true), .lidFallback(usb))
        XCTAssertEqual(route(.device(uid: builtIn.uid), devices, def: builtIn, lidClosed: true), .lidFallback(usb))
        // The default doesn't have to be the built-in mic for the explicit choice to leave it.
        XCTAssertEqual(route(.device(uid: builtIn.uid), devices, def: airPods, lidClosed: true), .lidFallback(usb))
    }

    func testLidClosedAvoidBluetoothNeverOpensBluetoothDefault() {
        XCTAssertEqual(route(.avoidBluetooth, [builtIn, airPods], def: airPods, lidClosed: true), .lidClosedNoMic)
    }

    func testLidClosedDisconnectedSelectionFallingToBuiltInDefaultIsRouted() {
        XCTAssertEqual(route(.device(uid: "gone"), [builtIn, usb], def: builtIn, lidClosed: true), .lidFallback(usb))
    }

    func testLidClosedFallsBackToWiredOnly() {
        let everything = [iPhoneWired, iPhoneWireless, bluetoothLE, airPods, usb, builtIn]
        XCTAssertEqual(route(.systemDefault, everything, def: builtIn, lidClosed: true), .lidFallback(usb))

        // Bluetooth makes headphone audio jump; an iPhone takes seconds to wake.
        let noWired = [iPhoneWired, iPhoneWireless, bluetoothLE, airPods, builtIn]
        XCTAssertEqual(route(.systemDefault, noWired, def: builtIn, lidClosed: true), .lidClosedNoMic)
    }

    func testLidClosedWiredBeatsBluetoothDefaultUnderAvoidBluetooth() {
        XCTAssertEqual(route(.avoidBluetooth, [builtIn, airPods, usb], def: airPods, lidClosed: true), .lidFallback(usb))
    }

    func testLidClosedDefaultWinsAmongWiredMics() {
        XCTAssertEqual(route(.avoidBluetooth, [builtIn, jack, usb], def: usb, lidClosed: true), .selected(usb.id))
        XCTAssertEqual(route(.device(uid: builtIn.uid), [builtIn, jack, usb], def: usb, lidClosed: true), .lidFallback(usb))
    }

    func testEveryWiredTransportCounts() {
        for transport in [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
                          kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
                          kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
                          kAudioDeviceTransportTypeAVB] {
            let wired = device(20, "wired", transport)
            XCTAssertEqual(route(.systemDefault, [builtIn, airPods, wired], def: builtIn, lidClosed: true),
                           .lidFallback(wired))
        }
    }

    func testLidClosedNeverPicksWirelessVirtualAggregateOrUnknown() {
        let unusable = [airPods, bluetoothLE, iPhoneWired, iPhoneWireless, blackHole, teams, aggregate,
                        autoAggregate, unknown, device(21, "airplay", kAudioDeviceTransportTypeAirPlay)]
        for selection in [InputSelection.systemDefault, .avoidBluetooth, .device(uid: builtIn.uid)] {
            XCTAssertEqual(route(selection, unusable + [builtIn], def: builtIn, lidClosed: true), .lidClosedNoMic)
        }
    }

    func testLidClosedNoOtherMicAtAll() {
        XCTAssertEqual(route(.systemDefault, [builtIn], def: builtIn, lidClosed: true), .lidClosedNoMic)
        XCTAssertEqual(route(.avoidBluetooth, [builtIn], def: builtIn, lidClosed: true), .lidClosedNoMic)
        XCTAssertEqual(route(.device(uid: builtIn.uid), [builtIn], def: builtIn, lidClosed: true), .lidClosedNoMic)
    }

    // MARK: - Lid closed, selection is another device: nothing changes

    func testLidClosedExplicitOtherDeviceIsHonoured() {
        let devices = [builtIn, usb, airPods, iPhoneWired, blackHole, aggregate]
        for choice in [airPods, iPhoneWired, blackHole, aggregate] {
            XCTAssertEqual(route(.device(uid: choice.uid), devices, def: builtIn, lidClosed: true), .selected(choice.id))
        }
    }

    func testLidClosedNonBuiltInDefaultIsHonoured() {
        let devices = [builtIn, usb, airPods, iPhoneWired, blackHole, aggregate]
        for def in [airPods, iPhoneWired, blackHole, aggregate] {
            XCTAssertEqual(route(.systemDefault, devices, def: def, lidClosed: true), .selected(def.id))
        }
        for def in [iPhoneWired, blackHole, aggregate] {
            XCTAssertEqual(route(.avoidBluetooth, devices, def: def, lidClosed: true), .selected(def.id))
        }
    }

    func testDefaultMissingFromDeviceListIsHonoured() {
        XCTAssertEqual(InputRouter.route(selection: .systemDefault, devices: [builtIn, usb], defaultID: 99, lidClosed: true),
                       .selected(99))
    }

    // MARK: - Headset in the jack: built-in transport, not the mic behind the lid

    func testJackMicIsNotTheLidMic() {
        XCTAssertTrue(builtIn.isInternalMic)
        XCTAssertFalse(jack.isInternalMic)
        XCTAssertEqual(route(.systemDefault, [builtIn, jack], def: jack, lidClosed: true), .selected(jack.id))
    }

    func testJackMicCountsAsWiredAlternative() {
        XCTAssertEqual(route(.systemDefault, [builtIn, airPods, jack], def: builtIn, lidClosed: true), .lidFallback(jack))
    }

    // MARK: - HUD wording

    func testFailureWording() {
        XCTAssertEqual(TranscriptionFailure.noMicSignal.title, "Microphone gave no signal")
        XCTAssertEqual(TranscriptionFailure.noMicSignal.body, "Check the input in Preferences → Audio")
        XCTAssertEqual(TranscriptionFailure.lidClosedNoMic.title, "Lid closed · built-in mic is off")
        XCTAssertEqual(TranscriptionFailure.lidClosedNoMic.body, "Connect a wired mic")
        XCTAssertFalse(TranscriptionFailure.noMicSignal.warrantsModelFallback)
        XCTAssertFalse(TranscriptionFailure.noMicSignal.isOffline)
    }
}
