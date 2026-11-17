import AppKit
import AudioToolbox
import AVFoundation
import Combine
import CoreAudio

public enum AudioRecorderError: Error {
    case invalidInputFormat(sampleRate: Double, channels: UInt32)
    /// No input device is connected.
    case noInputDevice
    /// The lid disconnected the built-in mic and no wired mic is connected.
    case lidClosedNoMic
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
    private var terminationObserver: NSObjectProtocol?

    public init() {
        capture = Capture(amplitude: amplitude, chunks: chunks, failures: failures)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.restoreMuteBeforeExit() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    /// Quitting mid-hold must not leave a mute we lifted lifted. The HAL call runs on the
    /// capture queue like every other; a wedged HAL gets a bounded wait, not the exit.
    private func restoreMuteBeforeExit() {
        let c = capture
        let done = DispatchSemaphore(value: 0)
        c.queue.async {
            c.restoreMute()
            done.signal()
        }
        if done.wait(timeout: .now() + 1) == .timedOut {
            pttLog("AudioRecorder: audio queue busy at quit — device mute not restored")
        }
    }

    public func start(input: InputSelection) {
        perform("start") { try $0.start(input: input) }
    }

    /// `completion` runs on main once capture has stopped (or the stop stalled, or an
    /// earlier call on the same capture stalled and it was abandoned), after every chunk
    /// captured so far has been delivered, and before a later `start` can deliver any.
    public func stop(completion: (() -> Void)? = nil) {
        perform("stop", completion: completion) { $0.stop() }
    }

    private let pending = PendingCalls()

    private func perform(_ label: String,
                         completion: (() -> Void)? = nil,
                         _ work: @escaping (Capture) throws -> Void) {
        let c = capture
        let call = pending.begin(owner: c, completion: completion)
        c.queue.async { [weak self] in
            var failure: Error?
            do { try work(c) } catch { failure = error }
            DispatchQueue.main.async {
                guard let self, !call.finished else { return }
                if let failure, self.capture === c { self.failures.send(failure) }
                self.pending.finish(call)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogTimeout) { [weak self] in
            guard let self, !call.finished else { return }
            guard self.capture === c else {
                self.pending.finish(call)
                return
            }
            pttLog("AudioRecorder: \(label) stalled >\(self.watchdogTimeout)s — abandoning audio capture")
            c.abandon()
            self.capture = Capture(amplitude: self.amplitude, chunks: self.chunks, failures: self.failures)
            self.failures.send(AudioRecorderError.stalled(operation: label))
            // Calls queued behind the stalled one on `c` are finished now, in order, too:
            // left to their own watchdogs, a stop's completion would run `takeSamples()`
            // in the middle of the next recording, which only starts after this returns.
            self.pending.finishAll(owner: c)
        }
    }
}

/// Main-thread bookkeeping of start/stop calls whose completion hasn't run yet.
final class PendingCalls {
    final class Call {
        fileprivate let owner: AnyObject
        fileprivate let completion: (() -> Void)?
        fileprivate(set) var finished = false

        fileprivate init(owner: AnyObject, completion: (() -> Void)?) {
            self.owner = owner
            self.completion = completion
        }
    }

    private var calls: [Call] = []

    func begin(owner: AnyObject, completion: (() -> Void)?) -> Call {
        let call = Call(owner: owner, completion: completion)
        calls.append(call)
        return call
    }

    /// Runs the call's completion unless it already ran.
    func finish(_ call: Call) {
        guard !call.finished else { return }
        call.finished = true
        calls.removeAll { $0 === call }
        call.completion?()
    }

    /// Finishes every unfinished call made on `owner`, oldest first.
    func finishAll(owner: AnyObject) {
        for call in calls where call.owner === owner { finish(call) }
    }
}

/// Pure pieces of the capture path, free of HAL state so they can be unit-tested.
enum CaptureDSP {
    /// The AUHAL client format: the device's own rate and channel count, Float32
    /// non-interleaved. The channel-count initializer returns nil above two channels,
    /// so wider inputs (multichannel interfaces, aggregates) get a discrete layout.
    static func captureFormat(sampleRate: Double, channels: UInt32) -> AVAudioFormat? {
        guard sampleRate > 0, channels > 0, channels <= 0xFFFF else { return nil }
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                 channels: channels, interleaved: false)
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else {
            return nil
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                             interleaved: false, channelLayout: layout)
    }

    /// Mixes `channelCount` planar channels of `frames` samples into `dst`. Averages only
    /// the inputs whose RMS in this chunk is at least 10% (−20 dB) of the loudest one's:
    /// an unused input on a multi-input interface would otherwise cut the mic by 6 dB
    /// (more with more inputs) before the VAD. All channels silent → zeros.
    /// No heap allocation: the per-channel energies live in temporary (stack) storage.
    static func downmix(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames: Int,
                        into dst: UnsafeMutablePointer<Float>) {
        guard frames > 0, channelCount > 0 else { return }
        if channelCount == 1 {
            memcpy(dst, channels[0], frames * MemoryLayout<Float>.size)
            return
        }
        withUnsafeTemporaryAllocation(of: Float.self, capacity: channelCount) { energy in
            var loudest: Float = 0
            for c in 0..<channelCount {
                let ch = channels[c]
                var sum: Float = 0
                for i in 0..<frames { sum += ch[i] * ch[i] }
                energy[c] = sum
                loudest = max(loudest, sum)
            }
            memset(dst, 0, frames * MemoryLayout<Float>.size)
            guard loudest > 0 else { return }
            // RMS ≥ 10% of the loudest RMS ⇔ energy ≥ 1% of its energy (same frame count).
            let floor = loudest * 0.01
            var live = 0
            for c in 0..<channelCount where energy[c] >= floor {
                live += 1
                let ch = channels[c]
                for i in 0..<frames { dst[i] += ch[i] }
            }
            let inv = 1 / Float(live)
            for i in 0..<frames { dst[i] *= inv }
        }
    }

    /// A capture that ended with render errors and not a single rendered frame has a
    /// broken input unit; drop it so the next start builds a fresh one.
    static func shouldDropTap(renderErrors: Int, renderedFrames: Int) -> Bool {
        renderErrors > 0 && renderedFrames == 0
    }
}

/// A HAL property listener that `remove()` really removes. The block API can't do that
/// from Swift: `AudioObjectPropertyListenerBlock` imports as a Swift closure type and is
/// bridged to a new block on every call, so Remove never matches what Add registered and
/// listeners pile up (checked: a block still fires after Remove, at -O and -Onone, even
/// when the same stored `@convention(block)` value is passed to both). The C-proc API
/// matches on (proc, client data), which are stable here.
final class HALPropertyListener {
    private final class Handler {
        let queue: DispatchQueue
        let onChange: () -> Void
        init(queue: DispatchQueue, onChange: @escaping () -> Void) {
            self.queue = queue
            self.onChange = onChange
        }
    }

    private static let proc: AudioObjectPropertyListenerProc = { _, _, _, data in
        guard let data else { return noErr }
        let handler = Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue()
        handler.queue.async(execute: handler.onChange)
        return noErr
    }

    private let object: AudioObjectID
    private let context: UnsafeMutableRawPointer
    private var registered: [AudioObjectPropertySelector] = []

    /// `onChange` runs on `queue`.
    init(object: AudioObjectID, selectors: [AudioObjectPropertySelector], queue: DispatchQueue,
         onChange: @escaping () -> Void) {
        self.object = object
        // Never released: a notification already in flight on a HAL thread may still read
        // it after Remove returns. A few dozen bytes per device rebuild.
        context = Unmanaged.passRetained(Handler(queue: queue, onChange: onChange)).toOpaque()
        for selector in selectors {
            var addr = Self.address(selector)
            if AudioObjectAddPropertyListener(object, &addr, Self.proc, context) == noErr {
                registered.append(selector)
            }
        }
    }

    func remove() {
        for selector in registered {
            var addr = Self.address(selector)
            AudioObjectRemovePropertyListener(object, &addr, Self.proc, context)
        }
        registered = []
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
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
    /// Render failures and rendered frames since the last `takeRenderStats()`; touched only
    /// by the IO thread and by the owner while the unit is stopped.
    private var renderErrors = 0
    private var renderedFrames = 0
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
        renderedFrames += Int(frames)
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

    func takeRenderStats() -> (errors: Int, frames: Int) {
        defer { renderErrors = 0; renderedFrames = 0 }
        return (renderErrors, renderedFrames)
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
    private var deviceListener: HALPropertyListener?
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
        let device = try routedDevice()
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

    /// Picks the device for the current selection and lid state, and logs the decision.
    private func routedDevice() throws -> AudioDeviceID {
        let lidClosed = InputDevice.isLidClosed()
        let defaultID = InputDevice.defaultID()
        let devices = InputDevice.inputDevices()
        let route = InputRouter.route(selection: input, devices: devices, defaultID: defaultID, lidClosed: lidClosed)
        let chosen: String
        switch route {
        case .selected(let id):   chosen = "\"\(devices.first { $0.id == id }?.name ?? "\(id)")\""
        case .lidFallback(let d): chosen = "\"\(d.name)\" (replaces built-in mic)"
        case .lidClosedNoMic:     chosen = "none (built-in mic is off, no wired mic)"
        case .noDevice:           chosen = "none (no input device)"
        }
        pttLog("AudioRecorder route: lid=\(lidClosed ? "closed" : "open") selection=\(input.rawValue) → \(chosen)")
        switch route {
        case .selected(let id):   return id
        case .lidFallback(let d): return d.id
        case .lidClosedNoMic:     throw AudioRecorderError.lidClosedNoMic
        case .noDevice:           throw AudioRecorderError.noInputDevice
        }
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
            guard let format = CaptureDSP.captureFormat(sampleRate: deviceFormat.mSampleRate,
                                                        channels: deviceFormat.mChannelsPerFrame) else {
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
        unwatch()
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
        let stats = tap.takeRenderStats()
        if stats.errors > 0 {
            pttLog("AudioRecorder: \(stats.errors) render errors during capture (\(stats.frames) frames rendered)")
        }
        delivery.sync {}
        isRecording = false
        if CaptureDSP.shouldDropTap(renderErrors: stats.errors, renderedFrames: stats.frames) {
            pttLog("AudioRecorder: no frame rendered — dropping the input unit so the next start rebuilds it")
            dropTap()
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status != noErr else { return }
        pttLog("AudioRecorder: \(operation) failed (\(status))")
        throw AudioRecorderError.coreAudio(operation: operation, status: status)
    }

    // MARK: - Device changes

    private static let watchedProperties = [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive]

    private func watch(_ device: AudioDeviceID) {
        deviceListener?.remove()
        deviceListener = HALPropertyListener(object: device, selectors: Self.watchedProperties, queue: queue) {
            [weak self] in self?.handleDeviceChange()
        }
    }

    private func unwatch() {
        deviceListener?.remove()
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
            try startTap(device: routedDevice())
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

    /// Runs before our unit starts on `id`, so our own IO can't make the device look busy.
    private func unmuteIfNeeded(_ id: AudioDeviceID?) {
        guard let id else { return }
        pttLog("AudioRecorder input device: \(InputDevice.describe(id))")
        let muted = InputDevice.isMuted(id)
        guard muted == true else { return }
        let elsewhere = InputDevice.isCapturingElsewhere(id)
        guard InputDevice.shouldLiftMute(muted: muted, capturingElsewhere: elsewhere) else {
            pttLog("AudioRecorder: input is muted at device level while another app is capturing from it — leaving it muted")
            return
        }
        if InputDevice.setMuted(id, false) {
            mutedDevice = id
            pttLog("AudioRecorder: input was muted at device level (in use elsewhere: \(elsewhere.map { "\($0)" } ?? "unknown")) — unmuted for recording")
        } else {
            pttLog("AudioRecorder: input is muted at device level and cannot be unmuted")
        }
    }

    func restoreMute() {
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
        CaptureDSP.downmix(channelData, channelCount: channels, frames: Int(frames), into: dst)
        return out
    }
}
