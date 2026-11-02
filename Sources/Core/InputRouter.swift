import CoreAudio

/// Which microphone a recording uses.
public enum InputRoute: Equatable {
    /// What the selection resolves to, as chosen.
    case selected(AudioDeviceID)
    /// The lid is closed and the selection resolves to the built-in mic: this wired mic instead.
    case lidFallback(InputDevice.Info)
    /// The lid is closed, the selection resolves to the built-in mic, and no wired mic is connected.
    case lidClosedNoMic
    case noDevice
}

/// With the lid closed a MacBook disconnects its built-in mic in hardware. The device stays
/// listed, and can stay the macOS default, but delivers exact zeros, so recording from it
/// loses the take without an error. The saved selection never changes: reopening the lid
/// returns to it.
public enum InputRouter {
    public static func route(selection: InputSelection, devices: [InputDevice.Info],
                             defaultID: AudioDeviceID?, lidClosed: Bool) -> InputRoute {
        guard let chosen = resolve(selection, devices: devices, defaultID: defaultID) else { return .noDevice }
        guard lidClosed, devices.first(where: { $0.id == chosen })?.isInternalMic == true else {
            return .selected(chosen)
        }
        // The system default wins, then the order CoreAudio lists them in.
        let wired = devices.filter(\.isWiredMic)
        guard let best = wired.first(where: { $0.id == defaultID }) ?? wired.first else { return .lidClosedNoMic }
        return .lidFallback(best)
    }

    /// What `selection` means with the lid open.
    private static func resolve(_ selection: InputSelection, devices: [InputDevice.Info],
                                defaultID: AudioDeviceID?) -> AudioDeviceID? {
        switch selection {
        case .systemDefault:
            return defaultID
        case .avoidBluetooth:
            guard devices.first(where: { $0.id == defaultID })?.isBluetooth == true else { return defaultID }
            return devices.first(where: \.isBuiltIn)?.id ?? defaultID
        case .device(let uid):
            return devices.first(where: { $0.uid == uid })?.id ?? defaultID
        }
    }
}
