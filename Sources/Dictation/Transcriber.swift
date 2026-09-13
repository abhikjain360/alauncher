import Core
import FluidAudio
import Foundation

public enum TranscriberStatus: Equatable, Sendable {
    /// First run: fetching the model (fraction when known).
    case downloading(Double?)
    case loading
    case ready
    case unloaded
    case failed(String)
}

/// The Parakeet TDT versions `dictation.model` can name.
enum ParakeetModel: Equatable, Sendable {
    case v2
    case v3

    /// `parakeet-tdt-0.6b-v2` → `.v2`, `…-v3` → `.v3`; nil for anything else.
    init?(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.hasPrefix("parakeet") else { return nil }
        if name.hasSuffix("-v2") || name.contains("-v2-") {
            self = .v2
        } else if name.hasSuffix("-v3") || name.contains("-v3-") {
            self = .v3
        } else {
            return nil
        }
    }

    var asrVersion: AsrModelVersion {
        switch self {
        case .v2: return .v2
        case .v3: return .v3
        }
    }
}

/// Parakeet TDT through FluidAudio, used exactly as in spike/asr-bench.
///
/// `prepare()` starts a load (downloading first if the files are missing) and returns at once;
/// `transcribe` waits for a load in progress. The model unloads `unloadAfter` after its last use,
/// which is cheap: reloading takes ~0.14 s, hidden inside the mic's ~150 ms start.
public actor Transcriber {
    public struct Output: Sendable {
        public var text: String
        /// Time spent waiting for the model to load (0 when it was loaded).
        public var loadWait: TimeInterval
        public var transcription: TimeInterval
    }

    /// FluidAudio rejects audio shorter than 0.3 s; short clips are padded with silence to this.
    static let minimumSamples = 16_000
    static let sampleRate = 16_000.0

    private let log = Log.main
    private let onStatus: @Sendable (TranscriberStatus) -> Void
    private var model: ParakeetModel
    private var unloadAfter: TimeInterval?
    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    private var unloadTask: Task<Void, Never>?
    private var activeUses = 0

    public init(model: String, unloadAfter: DurationSetting, onStatus: @escaping @Sendable (TranscriberStatus) -> Void = { _ in }) {
        self.model = ParakeetModel(name: model) ?? .v2
        self.unloadAfter = unloadAfter.timeInterval
        self.onStatus = onStatus
        if ParakeetModel(name: model) == nil {
            Log.main("transcriber: unknown dictation.model \(model), using parakeet-tdt-0.6b-v2")
        }
    }

    public static func modelFilesPresent(model: String) -> Bool {
        let version = (ParakeetModel(name: model) ?? .v2).asrVersion
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// A WAV (or any AVAudioFile format) as 16 kHz mono Float32.
    public static func samples(fromFile url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }

    public var isLoaded: Bool { manager != nil }

    /// Starts loading if unloaded and returns at once. Resets the idle timer.
    public nonisolated func prepare() {
        Task { await self.beginPrepare() }
    }

    private func beginPrepare() {
        if manager == nil { startLoad() }
        scheduleUnload()
    }

    /// Follows config changes. A different model drops the loaded one.
    public func update(model name: String, unloadAfter: DurationSetting) async {
        self.unloadAfter = unloadAfter.timeInterval
        if let newModel = ParakeetModel(name: name), newModel != model {
            model = newModel
            loadTask = nil
            // A transcription still using the old manager keeps it alive until it finishes.
            if let manager {
                self.manager = nil
                if activeUses == 0 { await manager.cleanup() }
            }
        }
        scheduleUnload()
    }

    /// Transcribes 16 kHz mono Float32 samples, waiting for any load in progress.
    public func transcribe(_ samples: [Float]) async throws -> Output {
        activeUses += 1
        defer {
            activeUses -= 1
            scheduleUnload()
        }
        let waitStart = Date()
        let manager = try await loadedManager()
        let loadWait = Date().timeIntervalSince(waitStart)

        var audio = samples
        if audio.count < Self.minimumSamples {
            audio += [Float](repeating: 0, count: Self.minimumSamples - audio.count)
        }
        var decoderState = TdtDecoderState.make()
        let start = Date()
        let result = try await manager.transcribe(audio, decoderState: &decoderState)
        return Output(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            loadWait: loadWait,
            transcription: Date().timeIntervalSince(start)
        )
    }

    /// Unloads now, unless a transcription is running.
    public func unload() async {
        guard activeUses == 0, let manager else { return }
        self.manager = nil
        await manager.cleanup()
        onStatus(.unloaded)
        log("transcriber: unloaded")
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        let task = startLoad()
        return try await task.value
    }

    @discardableResult
    private func startLoad() -> Task<AsrManager, Error> {
        if let loadTask { return loadTask }
        let version = model.asrVersion
        let onStatus = self.onStatus
        let log = self.log
        let task = Task<AsrManager, Error>.detached(priority: .userInitiated) {
            let started = Date()
            let directory = AsrModels.defaultCacheDirectory(for: version)
            if !AsrModels.modelsExist(at: directory, version: version) {
                log("transcriber: model files missing; downloading to \(directory.path)")
                onStatus(.downloading(nil))
                _ = try await AsrModels.download(to: directory, version: version) { progress in
                    onStatus(.downloading(progress.fractionCompleted))
                }
                log(String(format: "transcriber: downloaded in %.1f s", Date().timeIntervalSince(started)))
            }
            onStatus(.loading)
            let loadStart = Date()
            let models = try await AsrModels.load(from: directory, version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            log(String(format: "transcriber: loaded in %.2f s", Date().timeIntervalSince(loadStart)))
            return manager
        }
        loadTask = task
        Task { await self.finishLoad(task) }
        return task
    }

    private func finishLoad(_ task: Task<AsrManager, Error>) async {
        do {
            let loaded = try await task.value
            // Superseded by a model change. A transcription that awaited this load may still be
            // using it; dropping the reference frees it once that finishes.
            guard loadTask == task else { return }
            loadTask = nil
            manager = loaded
            onStatus(.ready)
            scheduleUnload()
        } catch {
            guard loadTask == task else { return }
            loadTask = nil
            log("transcriber: load failed: \(error.localizedDescription)")
            onStatus(.failed(error.localizedDescription))
        }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = nil
        guard let delay = unloadAfter else { return }
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }
}
