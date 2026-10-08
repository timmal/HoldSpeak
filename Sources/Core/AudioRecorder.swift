import AudioToolbox
import AVFoundation
import Combine
import CoreAudio

public enum AudioRecorderError: Error {
    case invalidInputFormat(sampleRate: Double, channels: UInt32)
    /// No input device is connected.
    case noInputDevice
    /// A CoreAudio call returned an error.
    case coreAudio(operation: String, status: OSStatus)
    /// A CoreAudio call did not return within the watchdog timeout.
    case stalled(operation: String)
}

/// Captures microphone audio as 16 kHz mono chunks.
///
/// Uses an input-only AUHAL rather than AVAudioEngine: the engine's shared IO unit binds
/// the system default input before a device can be chosen, so with Bluetooth headphones
/// as the default it switched them to the headset (HFP) profile — beep, 16 kHz music —
/// even when the built-in mic was selected.
///
/// All CoreAudio work runs on a private serial queue: after sleep/wake or an audio route
/// change HAL calls can block for hours, and doing them on the main thread froze the
/// whole app (and got the hotkey event tap disabled). A watchdog abandons a wedged
/// capture and continues with a fresh one on a fresh queue.
///
/// Public methods must be called on the main thread; `failures` is delivered on main.
public final class AudioRecorder {
    public let amplitude = PassthroughSubject<Float, Never>()
    public let chunks = PassthroughSubject<AVAudioPCMBuffer, Never>()
    public let failures = PassthroughSubject<Error, Never>()

    /// Real HAL hangs last minutes to hours; Continuity (iPhone) mics can take ~5s to wake.
    public var watchdogTimeout: TimeInterval = 10

    private var capture: Capture

    public init() {
        capture = Capture(amplitude: amplitude, chunks: chunks, failures: failures)
    }

    public func start(input: InputSelection) {
        perform("start") { try $0.start(input: input) }
    }

    /// `completion` runs on main once capture has stopped (or the stop stalled), after
    /// every chunk captured so far has been delivered.
    public func stop(completion: (() -> Void)? = nil) {
        perform("stop", completion: completion) { $0.stop() }
    }

    private final class Op { var finished = false }

    private func perform(_ label: String,
                         completion: (() -> Void)? = nil,
                         _ work: @escaping (Capture) throws -> Void) {
        let c = capture
        let op = Op()
        c.queue.async { [weak self] in
            var failure: Error?
            do { try work(c) } catch { failure = error }
            DispatchQueue.main.async {
                guard let self, !op.finished else { return }
                op.finished = true
                if let failure, self.capture === c { self.failures.send(failure) }
                completion?()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogTimeout) { [weak self] in
            guard let self, !op.finished else { return }
            op.finished = true
            if self.capture === c {
                pttLog("AudioRecorder: \(label) stalled >\(self.watchdogTimeout)s — abandoning audio capture")
                c.abandon()
                self.capture = Capture(amplitude: self.amplitude, chunks: self.chunks, failures: self.failures)
                self.failures.send(AudioRecorderError.stalled(operation: label))
            }
            completion?()
        }
    }
}

/// Render state owned by the HAL IO thread while the unit runs. Accumulates the
/// device's ~10 ms IO cycles into ~100 ms chunks so downstream work stays coarse.
private final class InputTap {
    let unit: AudioUnit
    let device: AudioDeviceID
    /// Client format: the device's own rate and channel count, Float32 non-interleaved.
    /// AUHAL cannot resample on the input side, so the converter downstream does it.
    let format: AVAudioFormat
    /// Render failures since the last `takeRenderErrors()`; touched only by the IO thread
    /// and by the owner while the unit is stopped.
    private var renderErrors = 0
    private let scratch: AVAudioPCMBuffer
    private var pending: AVAudioPCMBuffer
    private let chunkFrames: AVAudioFrameCount
    private let deliver: (AVAudioPCMBuffer) -> Void

    init(unit: AudioUnit, device: AudioDeviceID, format: AVAudioFormat, maxFrames: AVAudioFrameCount,
         deliver: @escaping (AVAudioPCMBuffer) -> Void) {
        self.unit = unit
        self.device = device
        self.format = format
        self.deliver = deliver
        chunkFrames = AVAudioFrameCount(max(format.sampleRate / 10, 256))
        scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames)!
        pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)!
    }

    func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                _ timeStamp: UnsafePointer<AudioTimeStamp>,
                _ frames: UInt32) -> OSStatus {
        guard frames <= scratch.frameCapacity else { renderErrors += 1; return noErr }
        scratch.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, 1, frames, scratch.mutableAudioBufferList)
        guard status == noErr else { renderErrors += 1; return status }
        append(scratch)
        return noErr
    }

    private func append(_ src: AVAudioPCMBuffer) {
        guard let from = src.floatChannelData else { return }
        let channels = Int(format.channelCount)
        var offset: AVAudioFrameCount = 0
        while offset < src.frameLength {
            let n = min(src.frameLength - offset, chunkFrames - pending.frameLength)
            let to = pending.floatChannelData!
            for c in 0..<channels {
                memcpy(to[c] + Int(pending.frameLength), from[c] + Int(offset), Int(n) * MemoryLayout<Float>.size)
            }
            pending.frameLength += n
            offset += n
            if pending.frameLength == chunkFrames { flush() }
        }
    }

    /// Hands over the partial chunk. Call only from the IO thread or while the unit is stopped.
    func flush() {
        guard pending.frameLength > 0 else { return }
        deliver(pending)
        pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)!
    }

    func takeRenderErrors() -> Int {
        defer { renderErrors = 0 }
        return renderErrors
    }
}

private let inputCallback: AURenderCallback = { refCon, flags, timeStamp, _, frames, _ in
    Unmanaged<InputTap>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, frames)
}

/// One input unit plus the serial queue that owns it. Every method except `abandon()`
/// runs on `queue`.
private final class Capture {
    let queue = DispatchQueue(label: "HoldSpeak.audio", qos: .userInitiated)
    /// Converts and publishes chunks off the IO thread.
    private let delivery = DispatchQueue(label: "HoldSpeak.audio.delivery", qos: .userInitiated)

    private let amplitude: PassthroughSubject<Float, Never>
    private let chunks: PassthroughSubject<AVAudioPCMBuffer, Never>
    private let failures: PassthroughSubject<Error, Never>
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: 16_000, channels: 1, interleaved: false)!

    private var tap: InputTap?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var input: InputSelection = .systemDefault
    private var isRecording = false
    /// Device whose input mute we lifted in `start`; re-muted in `stop`.
    private var mutedDevice: AudioDeviceID?

    // Delivery-queue state.
    private var monoFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var chunkCount = 0

    private let abandonLock = NSLock()
    private var _abandoned = false
    private var abandoned: Bool { abandonLock.lock(); defer { abandonLock.unlock() }; return _abandoned }

    init(amplitude: PassthroughSubject<Float, Never>,
         chunks: PassthroughSubject<AVAudioPCMBuffer, Never>,
         failures: PassthroughSubject<Error, Never>) {
        self.amplitude = amplitude
        self.chunks = chunks
        self.failures = failures
    }

    /// Called on main when this capture is wedged. Whatever op is stuck finishes
    /// eventually; after that the capture tears itself down and stays silent.
    func abandon() {
        abandonLock.lock(); _abandoned = true; abandonLock.unlock()
        queue.async { [self] in
            teardown()
            restoreMute()
            dropTap()
        }
    }

    func start(input: InputSelection) throws {
        guard !abandoned, !isRecording else { return }
        self.input = input
        guard let device = InputDevice.resolve(input) ?? InputDevice.defaultID() else {
            throw AudioRecorderError.noInputDevice
        }
        if device != tap?.device { dropTap() }
        unmuteIfNeeded(device)
        do {
            try startTap(device: device)
        } catch {
            restoreMute()
            throw error
        }
    }

    func stop() {
        teardown()
        restoreMute()
    }

    // MARK: - Input unit

    private func makeTap(device: AudioDeviceID) throws -> InputTap {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioRecorderError.coreAudio(operation: "find AUHAL", status: kAudioUnitErr_InvalidElement)
        }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "create AUHAL")
        guard let unit = newUnit else {
            throw AudioRecorderError.coreAudio(operation: "create AUHAL", status: kAudioUnitErr_FailedInitialization)
        }
        do {
            // Input only, device chosen before initialize: nothing but `device` is ever opened.
            var off: UInt32 = 0, on: UInt32 = 1
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                           &off, UInt32(MemoryLayout<UInt32>.size)), "disable output")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                           &on, UInt32(MemoryLayout<UInt32>.size)), "enable input")
            var id = device
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "select device")

            var deviceFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                           &deviceFormat, &size), "read device format")
            pttLog("AudioRecorder device format: sampleRate=\(deviceFormat.mSampleRate) channels=\(deviceFormat.mChannelsPerFrame)")
            guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: deviceFormat.mSampleRate,
                                             channels: deviceFormat.mChannelsPerFrame, interleaved: false) else {
                throw AudioRecorderError.invalidInputFormat(sampleRate: deviceFormat.mSampleRate,
                                                            channels: deviceFormat.mChannelsPerFrame)
            }
            var client = format.streamDescription.pointee
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           &client, size), "set client format")

            var maxFrames: UInt32 = 4096
            var maxSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                     &maxFrames, &maxSize)
            let tap = InputTap(unit: unit, device: device, format: format,
                               maxFrames: max(maxFrames, 4096)) { [weak self] chunk in
                self?.delivery.async { self?.publish(chunk) }
            }
            var callback = AURenderCallbackStruct(inputProc: inputCallback,
                                                  inputProcRefCon: Unmanaged.passUnretained(tap).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                           &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                      "set input callback")
            try check(AudioUnitInitialize(unit), "initialize")
            return tap
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func dropTap() {
        guard let tap else { return }
        unwatch(tap.device)
        AudioUnitUninitialize(tap.unit)
        AudioComponentInstanceDispose(tap.unit)
        self.tap = nil
    }

    private func startTap(device: AudioDeviceID) throws {
        // A Bluetooth device can switch sample rate between reading the format and
        // starting; a fresh unit picks up the new format, so retry once.
        do {
            try startTapOnce(device: device)
        } catch {
            pttLog("AudioRecorder: start failed (\(error)) — retrying with a fresh input unit")
            dropTap()
            try startTapOnce(device: device)
        }
    }

    private func startTapOnce(device: AudioDeviceID) throws {
        let tap = try self.tap ?? makeTap(device: device)
        if self.tap == nil {
            self.tap = tap
            watch(device)
        }
        let format = tap.format
        let ready = delivery.sync {
            monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                       channels: 1, interleaved: false)
            converter = monoFormat.flatMap { AVAudioConverter(from: $0, to: Self.targetFormat) }
            chunkCount = 0
            return converter != nil
        }
        guard ready else {
            dropTap()
            throw AudioRecorderError.invalidInputFormat(sampleRate: format.sampleRate, channels: format.channelCount)
        }
        do {
            try check(AudioOutputUnitStart(tap.unit), "start")
        } catch {
            dropTap()
            throw error
        }
        isRecording = true
    }

    /// Stops the unit and waits until every captured chunk has been published, so a
    /// completion dispatched to main afterwards runs after the last chunk.
    private func teardown() {
        guard isRecording, let tap else { isRecording = false; return }
        AudioOutputUnitStop(tap.unit)
        tap.flush()
        let errors = tap.takeRenderErrors()
        if errors > 0 { pttLog("AudioRecorder: \(errors) render errors during capture") }
        delivery.sync {}
        isRecording = false
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status != noErr else { return }
        pttLog("AudioRecorder: \(operation) failed (\(status))")
        throw AudioRecorderError.coreAudio(operation: operation, status: status)
    }

    // MARK: - Device changes

    private static let watchedProperties = [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive]

    private func watch(_ device: AudioDeviceID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleDeviceChange() }
        for selector in Self.watchedProperties {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(device, &addr, queue, listener)
        }
        deviceListener = listener
    }

    private func unwatch(_ device: AudioDeviceID) {
        guard let listener = deviceListener else { return }
        for selector in Self.watchedProperties {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(device, &addr, queue, listener)
        }
        deviceListener = nil
    }

    /// Bluetooth headsets switch sample rate when their mic opens (A2DP → HFP), and
    /// devices vanish on disconnect or sleep. The unit's client format no longer matches
    /// either way, so rebuild; mid-recording, resume so the take isn't silently dropped.
    private func handleDeviceChange() {
        guard !abandoned, let tap else { return }
        if InputDevice.isAlive(tap.device), InputDevice.nominalSampleRate(tap.device) == tap.format.sampleRate {
            return
        }
        pttLog("AudioRecorder: input device changed (recording=\(isRecording)) — rebuilding input unit")
        let wasRecording = isRecording
        teardown()
        dropTap()
        guard wasRecording else { return }
        do {
            guard let device = InputDevice.resolve(input) ?? InputDevice.defaultID() else {
                throw AudioRecorderError.noInputDevice
            }
            try startTap(device: device)
            pttLog("AudioRecorder: capture resumed after device change")
        } catch {
            pttLog("AudioRecorder: resume after device change failed: \(error)")
            restoreMute()
            let failures = self.failures
            DispatchQueue.main.async { failures.send(error) }
        }
    }

    // MARK: - Delivery

    private func publish(_ chunk: AVAudioPCMBuffer) {
        guard !abandoned, let monoFormat, let converter,
              chunk.format.sampleRate == monoFormat.sampleRate else { return }
        chunkCount += 1
        if chunkCount <= 3 || chunkCount % 50 == 0 {
            pttLog("chunk #\(chunkCount) frames=\(chunk.frameLength) rms=\(Self.rms(chunk))")
        }
        guard let out = Self.convert(chunk, monoFormat: monoFormat, converter: converter) else { return }
        amplitude.send(Self.rms(out))
        chunks.send(out)
    }

    // MARK: - Device mute

    private func unmuteIfNeeded(_ id: AudioDeviceID?) {
        guard let id else { return }
        pttLog("AudioRecorder input device: \(InputDevice.describe(id))")
        guard InputDevice.isMuted(id) == true else { return }
        if InputDevice.setMuted(id, false) {
            mutedDevice = id
            pttLog("AudioRecorder: input was muted at device level — unmuted for recording")
        } else {
            pttLog("AudioRecorder: input is muted at device level and cannot be unmuted")
        }
    }

    private func restoreMute() {
        guard let id = mutedDevice else { return }
        mutedDevice = nil
        InputDevice.setMuted(id, true)
    }

    // MARK: - DSP

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return (sum / Float(n)).squareRoot()
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                monoFormat: AVAudioFormat,
                                converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard let mono = downmixToMono(buffer, monoFormat: monoFormat) else { return nil }
        let ratio = targetFormat.sampleRate / monoFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * ratio + 128)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var err: NSError?
        var didProvide = false
        converter.convert(to: out, error: &err) { _, status in
            if didProvide { status.pointee = .noDataNow; return nil }
            didProvide = true
            status.pointee = .haveData
            return mono
        }
        guard err == nil, out.frameLength > 0 else { return nil }
        return out
    }

    private static func downmixToMono(_ src: AVAudioPCMBuffer, monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = src.frameLength
        guard frames > 0, let channelData = src.floatChannelData else { return nil }
        let channels = Int(src.format.channelCount)
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = frames
        let n = Int(frames)
        if channels == 1 {
            memcpy(dst, channelData[0], n * MemoryLayout<Float>.size)
        } else {
            let inv = 1.0 / Float(channels)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += channelData[c][i] }
                dst[i] = sum * inv
            }
        }
        return out
    }
}
