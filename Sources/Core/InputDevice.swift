import CoreAudio
import Foundation

/// Which microphone HoldSpeak records from. Persisted as `rawValue`.
public enum InputSelection: Equatable, Hashable {
    /// Whatever macOS has selected as the input device.
    case systemDefault
    /// System default, except the built-in mic when the default is Bluetooth: opening a
    /// Bluetooth mic makes headphone playback glitch and drop to headset quality.
    case avoidBluetooth
    case device(uid: String)

    public init(rawValue: String) {
        switch rawValue {
        case "system": self = .systemDefault
        case "avoidBluetooth", "": self = .avoidBluetooth
        default:
            self = rawValue.hasPrefix("uid:") ? .device(uid: String(rawValue.dropFirst(4))) : .avoidBluetooth
        }
    }

    public var rawValue: String {
        switch self {
        case .systemDefault: return "system"
        case .avoidBluetooth: return "avoidBluetooth"
        case .device(let uid): return "uid:\(uid)"
        }
    }
}

/// Thin CoreAudio helpers for the system default input device.
///
/// Bluetooth headsets (AirPods in particular) can carry a device-level input mute
/// set by a call app or a stem press. Capture then delivers pure zeros, so
/// the recorder lifts the mute for the duration of a recording and restores it.
public enum InputDevice {
    public static func defaultID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        guard get(AudioObjectID(kAudioObjectSystemObject),
                  kAudioHardwarePropertyDefaultInputDevice,
                  kAudioObjectPropertyScopeGlobal, &id),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    public struct Info: Identifiable, Hashable {
        public let id: AudioDeviceID
        public let uid: String
        public let name: String
        public let transport: UInt32
        public var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
        public var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
        /// iPhone mic via Continuity: takes seconds to wake, so push-to-talk loses the start.
        public var isContinuity: Bool {
            transport == kAudioDeviceTransportTypeContinuityCaptureWired
                || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
        }
    }

    /// Devices that have at least one input stream.
    public static func inputDevices() -> [Info] {
        var addr = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(info)
    }

    public static func info(_ id: AudioDeviceID) -> Info? {
        var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0 else { return nil }
        var uid: Unmanaged<CFString>?
        guard get(id, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &uid),
              let uidString = uid?.takeRetainedValue() as String? else { return nil }
        var name: Unmanaged<CFString>?
        _ = get(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name)
        var transport: UInt32 = 0
        _ = get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
        return Info(id: id, uid: uidString,
                    name: name?.takeRetainedValue() as String? ?? uidString,
                    transport: transport)
    }

    /// The device to record from, or `nil` to let the engine use the system default.
    public static func resolve(_ selection: InputSelection) -> AudioDeviceID? {
        switch selection {
        case .systemDefault:
            return nil
        case .avoidBluetooth:
            guard let def = defaultID(), info(def)?.isBluetooth == true else { return nil }
            return inputDevices().first(where: \.isBuiltIn)?.id
        case .device(let uid):
            if let match = inputDevices().first(where: { $0.uid == uid }) { return match.id }
            pttLog("InputDevice: selected device \(uid) not connected — using system default")
            return nil
        }
    }

    public static func describe(_ id: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        let n = get(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name)
            ? (name?.takeRetainedValue() as String? ?? "?") : "?"
        var transport: UInt32 = 0
        _ = get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
        let t = withUnsafeBytes(of: transport.bigEndian) { String(decoding: $0, as: UTF8.self) }
        var volume: Float32 = -1
        _ = get(id, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, &volume)
        let muted = isMuted(id).map { "\($0)" } ?? "n/a"
        return "\"\(n)\" transport=\(t) inputVolume=\(volume >= 0 ? String(format: "%.2f", volume) : "n/a") muted=\(muted)"
    }

    public static func isAlive(_ id: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0
        return get(id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, &alive) && alive != 0
    }

    public static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var rate: Float64 = 0
        return get(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate) ? rate : nil
    }

    /// `nil` when the device has no input mute control.
    public static func isMuted(_ id: AudioDeviceID) -> Bool? {
        var v: UInt32 = 0
        guard get(id, kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput, &v) else { return nil }
        return v != 0
    }

    @discardableResult
    public static func setMuted(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectIsPropertySettable(id, &addr, &settable) == noErr,
              settable.boolValue else { return false }
        var v: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T>(_ id: AudioObjectID,
                               _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope,
                               _ value: inout T) -> Bool {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) == noErr
        }
    }
}
