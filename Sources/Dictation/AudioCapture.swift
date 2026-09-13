import AudioToolbox
import AVFoundation
import Core
import CoreAudio
import Foundation
import QuartzCore

public enum CaptureError: Error, Equatable, CustomStringConvertible {
    case microphoneDenied
    case microphonePermissionPending
    case noInputDevice
    case converterFailed
    case engineFailed(String)

    public var description: String {
        switch self {
        case .microphoneDenied: return "microphone access denied"
        case .microphonePermissionPending: return "allow microphone access, then try again"
        case .noInputDevice: return "no microphone"
        case .converterFailed: return "audio format not supported"
        case .engineFailed(let reason): return "audio: \(reason)"
        }
    }
}

public struct CaptureResult: Sendable {
    /// 16 kHz mono Float32.
    public var samples: [Float]
    /// Loudest 50 ms window, in dBFS.
    public var peakWindowDB: Float

    public var duration: TimeInterval { Double(samples.count) / AudioLevels.sampleRate }
}

/// Pure level math.
enum AudioLevels {
    static let sampleRate = 16_000.0
    /// A recording whose loudest 50 ms stays below this is treated as silence and dropped.
    static let silenceThresholdDB: Float = -50
    static let windowSamples = 800
    static let levelInterval: CFTimeInterval = 1.0 / 30

    static func decibels(rms: Float) -> Float {
        20 * log10(max(rms, 1e-9))
    }

    /// RMS mapped from −60…0 dBFS to 0…1.
    static func normalizedLevel(rms: Float) -> Float {
        min(1, max(0, (decibels(rms: rms) + 60) / 60))
    }

    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Converted samples plus the running 50 ms window, filled on the audio thread. The main thread
/// takes the lock only to finish.
final class SampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var windowSum: Float = 0
    private var windowCount = 0
    private var peakDB = -Float.infinity
    private let maxSamples: Int
    private var limitReported = false

    init(maxDuration: TimeInterval?) {
        maxSamples = maxDuration.map { Int($0 * AudioLevels.sampleRate) } ?? Int.max
        samples.reserveCapacity(Int(AudioLevels.sampleRate) * 30)
    }

    /// Appends up to the limit; true exactly once, when the limit is first reached.
    func append(_ chunk: UnsafeBufferPointer<Float>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let room = max(0, maxSamples - samples.count)
        let accepted = UnsafeBufferPointer(rebasing: chunk.prefix(room))
        samples.append(contentsOf: accepted)
        for sample in accepted {
            windowSum += sample * sample
            windowCount += 1
            if windowCount == AudioLevels.windowSamples {
                peakDB = max(peakDB, AudioLevels.decibels(rms: (windowSum / Float(windowCount)).squareRoot()))
                windowSum = 0
                windowCount = 0
            }
        }
        guard samples.count >= maxSamples, !limitReported else { return false }
        limitReported = true
        return true
    }

    func finish() -> CaptureResult {
        lock.lock()
        defer { lock.unlock() }
        var peak = peakDB
        if windowCount > 0 {
            peak = max(peak, AudioLevels.decibels(rms: (windowSum / Float(windowCount)).squareRoot()))
        }
        return CaptureResult(samples: samples, peakWindowDB: peak)
    }
}

/// Input devices through CoreAudio.
enum AudioDevices {
    struct Device: Equatable {
        var id: AudioDeviceID
        var name: String
        var uid: String
    }

    /// Exact UID first, then a case-insensitive name. Pure.
    static func match(_ spec: String, in devices: [Device]) -> Device? {
        let wanted = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return devices.first { $0.uid == wanted }
            ?? devices.first { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    static func inputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Device(id: id, name: name, uid: uid)
        }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Records the mic through an AVAudioEngine input tap, converted to 16 kHz mono Float32.
@MainActor
final class AudioCapture {
    struct Callbacks {
        /// The first converted buffer arrived (~150 ms after start on this Mac).
        var onFirstBuffer: @MainActor @Sendable () -> Void
        /// 0…1, at most 30 Hz.
        var onLevel: @MainActor @Sendable (Float) -> Void
        /// `maxDuration` reached; the controller should stop.
        var onLimit: @MainActor @Sendable () -> Void
    }

    private let log = Log.main
    private var engine = AVAudioEngine()
    private var engineDeviceSpec: String?
    private var accumulator: SampleAccumulator?
    private var callbacks: Callbacks?
    private var configurationObserver: NSObjectProtocol?

    var isRecording: Bool { accumulator != nil }

    /// Selects the device and prepares the engine ahead of the first recording.
    func prepare(deviceSpec: String) {
        guard !isRecording else { return }
        configureEngine(deviceSpec: deviceSpec)
        prepareEngine()
    }

    func start(deviceSpec: String, maxDuration: TimeInterval?, callbacks: Callbacks) throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw CaptureError.microphonePermissionPending
        default: throw CaptureError.microphoneDenied
        }
        if isRecording { _ = stop() }
        configureEngine(deviceSpec: deviceSpec)
        let accumulator = SampleAccumulator(maxDuration: maxDuration)
        self.accumulator = accumulator
        self.callbacks = callbacks
        do {
            try installTapAndStart(accumulator: accumulator, callbacks: callbacks)
        } catch {
            self.accumulator = nil
            self.callbacks = nil
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    /// Stops and returns the recording, then re-prepares, since `stop()` releases the engine's
    /// prepared resources.
    func stop() -> CaptureResult {
        let result = accumulator?.finish() ?? CaptureResult(samples: [], peakWindowDB: -.infinity)
        halt()
        return result
    }

    func cancel() {
        halt()
    }

    private func halt() {
        guard accumulator != nil else { return }
        accumulator = nil
        callbacks = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        prepareEngine()
    }

    /// `prepare()` raises an Objective-C exception, which Swift can't catch, on an engine whose
    /// input node was never created or whose input has no channels. Touching `inputNode` creates
    /// it; a missing input is skipped and reported when recording starts.
    private func prepareEngine() {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            log("audio: no usable input device; not preparing the engine")
            return
        }
        engine.prepare()
    }

    private func configureEngine(deviceSpec: String) {
        guard engineDeviceSpec != deviceSpec else { return }
        // A fresh engine starts on the system default, which also covers switching back to "".
        if engineDeviceSpec != nil {
            engine.stop()
            engine = AVAudioEngine()
        }
        engineDeviceSpec = deviceSpec
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }

        guard !deviceSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let device = AudioDevices.match(deviceSpec, in: AudioDevices.inputDevices()) else {
            log("audio: input device \"\(deviceSpec)\" not found; using the system default")
            return
        }
        guard let unit = engine.inputNode.audioUnit else { return }
        var id = device.id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            log("audio: could not select \"\(device.name)\" (status \(status)); using the system default")
        }
    }

    private func installTapAndStart(accumulator: SampleAccumulator, callbacks: Callbacks) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureError.noInputDevice }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioLevels.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw CaptureError.converterFailed }
        converter.downmix = true
        input.installTap(
            onBus: 0, bufferSize: 1024, format: format,
            block: Self.tapBlock(converter: converter, target: target, accumulator: accumulator, callbacks: callbacks)
        )
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineFailed(error.localizedDescription)
        }
    }

    /// Device or format change: the engine has stopped. Rebuild the converter and tap and carry on
    /// with the same recording.
    private func configurationChanged() {
        guard let accumulator, let callbacks else {
            prepareEngine()
            return
        }
        log("audio: configuration changed during a recording; restarting input")
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTapAndStart(accumulator: accumulator, callbacks: callbacks)
        } catch {
            log("audio: restart failed: \(error)")
        }
    }

    /// Built outside the main actor: the block runs on the audio thread.
    private nonisolated static func tapBlock(
        converter: AVAudioConverter, target: AVAudioFormat, accumulator: SampleAccumulator, callbacks: Callbacks
    ) -> AVAudioNodeTapBlock {
        let state = TapState()
        return { buffer, _ in
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard buffer.frameLength > 0,
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            let input = OneShotBuffer(buffer)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard let next = input.take() else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return next
            }
            guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            let limitReached = accumulator.append(chunk)

            if !state.sawFirstBuffer {
                state.sawFirstBuffer = true
                DispatchQueue.main.async { MainActor.assumeIsolated { callbacks.onFirstBuffer() } }
            }
            let now = CACurrentMediaTime()
            if now - state.lastLevelTime >= AudioLevels.levelInterval {
                state.lastLevelTime = now
                let level = AudioLevels.normalizedLevel(rms: AudioLevels.rms(chunk))
                DispatchQueue.main.async { MainActor.assumeIsolated { callbacks.onLevel(level) } }
            }
            if limitReached {
                DispatchQueue.main.async { MainActor.assumeIsolated { callbacks.onLimit() } }
            }
        }
    }
}

/// Hands one tap buffer to the converter's input block, which runs synchronously inside
/// `convert` on the audio thread.
private final class OneShotBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Audio-thread-only state of one tap.
private final class TapState: @unchecked Sendable {
    var sawFirstBuffer = false
    var lastLevelTime: CFTimeInterval = 0
}
