import Core
import FluidAudio
import Foundation

enum HandsFreeHeadKind: String, Sendable {
    case wake
    case off
    case send
    case none
}

enum HandsFreeListenerEvent: Sendable {
    case segmentStart(samplePosition: Int)
    case segmentEnd(samplePosition: Int)
    case headCheck(samplePosition: Int, duration: TimeInterval, kind: HandsFreeHeadKind, transcript: String, segmentEnded: Bool)
    case listeningStart(samplePosition: Int)
    case level(Float)
    case dictationEnd(samples: [Float], samplePosition: Int)
    case nothingHeard(samplePosition: Int)
    case dropped
    case failed
    case sendPhrase(samplePosition: Int)
    case offPhrase(samplePosition: Int)
}

actor HandsFreeListener {
    typealias EventSink = @Sendable (Int, HandsFreeListenerEvent) -> Void

    private let vad: VadManager
    private let transcriber: Transcriber
    private let onEvent: EventSink
    private let continuation: AsyncStream<[Float]>.Continuation
    private let stream: AsyncStream<[Float]>
    private var consumeTask: Task<Void, Never>?
    private var pendingSamples: [Float] = []
    private var streamState: VadStreamState
    private var segmenter: HandsFreeSegmenter
    private var dictationSettings: DictationSettings
    private var samplePosition = 0
    private var followUpUntil: Int?
    private var isFailed = false
    private var isClosed = false
    private var isResetting = false
    private var epoch = 0

    static func load(
        settings: DictationSettings, transcriber: Transcriber, onEvent: @escaping EventSink
    ) async throws -> HandsFreeListener {
        let vad = try await VadManager()
        let listener = HandsFreeListener(vad: vad, settings: settings, transcriber: transcriber, onEvent: onEvent)
        await listener.start()
        return listener
    }

    init(vad: VadManager, settings: DictationSettings, transcriber: Transcriber, onEvent: @escaping EventSink) {
        self.vad = vad
        self.dictationSettings = settings
        self.transcriber = transcriber
        self.onEvent = onEvent
        let pair = AsyncStream<[Float]>.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(64))
        stream = pair.stream
        continuation = pair.continuation
        streamState = VadStreamState()
        segmenter = HandsFreeSegmenter(settings: Self.segmenterSettings(settings))
    }

    deinit {
        continuation.finish()
        consumeTask?.cancel()
    }

    func close(epoch: Int) {
        self.epoch = max(self.epoch, epoch)
        guard !isClosed else { return }
        isClosed = true
        continuation.finish()
        consumeTask?.cancel()
        consumeTask = nil
    }

    nonisolated func receive(_ samples: [Float]) {
        continuation.yield(samples)
    }

    func feed(_ samples: [Float]) async {
        await processSamples(samples)
    }

    func finish() async {
        guard !isClosed, !isFailed else { return }
        let finishEpoch = epoch
        if !pendingSamples.isEmpty {
            let actual = pendingSamples
            pendingSamples.removeAll(keepingCapacity: true)
            samplePosition += actual.count
            let rms = (actual.reduce(0) { $0 + $1 * $1 } / Float(actual.count)).squareRoot()
            let events = segmenter.append(actual, speech: rms >= 0.005)
            for event in events { await handle(event, epoch: finishEpoch) }
        }
        await report(segments: segmenter.finish(), epoch: finishEpoch)
    }

    func reset(epoch: Int) async {
        guard !isClosed, epoch >= self.epoch else { return }
        self.epoch = epoch
        isResetting = true
        pendingSamples.removeAll(keepingCapacity: true)
        segmenter.reset()
        let state = await vad.makeStreamState()
        guard !isClosed, epoch == self.epoch else { return }
        streamState = state
        isFailed = false
        isResetting = false
    }

    func update(settings: DictationSettings, epoch: Int) async {
        guard !isClosed, epoch >= self.epoch else { return }
        self.epoch = epoch
        isResetting = true
        dictationSettings = settings
        segmenter.update(settings: Self.segmenterSettings(settings))
        pendingSamples.removeAll(keepingCapacity: true)
        let state = await vad.makeStreamState()
        guard !isClosed, epoch == self.epoch else { return }
        streamState = state
        isFailed = false
        isResetting = false
    }

    func openFollowUp() {
        let length = Self.sampleCount(dictationSettings.handsFree.followUp)
        followUpUntil = samplePosition + length
    }

    private func start() {
        guard consumeTask == nil else { return }
        let stream = self.stream
        consumeTask = Task { [weak self, stream] in
            for await samples in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.processSamples(samples)
            }
        }
    }

    private func processSamples(_ samples: [Float]) async {
        guard !isClosed, !isFailed, !isResetting, !Task.isCancelled, !samples.isEmpty else { return }
        pendingSamples.append(contentsOf: samples)
        while pendingSamples.count >= VadManager.chunkSize {
            guard !isClosed, !isFailed, !isResetting, !Task.isCancelled else { return }
            let chunk = Array(pendingSamples.prefix(VadManager.chunkSize))
            pendingSamples.removeFirst(VadManager.chunkSize)
            await processChunk(chunk, audioSamples: chunk)
        }
    }

    private func processChunk(_ chunk: [Float], audioSamples: [Float]) async {
        guard !isClosed, !isFailed, !isResetting, !Task.isCancelled else { return }
        let chunkEpoch = epoch
        do {
            let result = try await vad.processStreamingChunk(
                chunk, state: streamState,
                config: VadSegmentationConfig(minSilenceDuration: 0.6, speechPadding: 0.1)
            )
            guard !isClosed, !isFailed, !Task.isCancelled, chunkEpoch == epoch else { return }
            streamState = result.state
            samplePosition += audioSamples.count
            let events = segmenter.append(audioSamples, speech: result.probability >= 0.85, segmentEnded: result.event?.isEnd == true)
            for event in events { await handle(event, epoch: chunkEpoch) }
        } catch {
            guard !isClosed, !isFailed, !Task.isCancelled, chunkEpoch == epoch else { return }
            isFailed = true
            emit(.failed, epoch: chunkEpoch)
        }
    }

    private func handle(_ event: HandsFreeSegmenter.Event, epoch: Int) async {
        guard !isClosed, !isFailed, epoch == self.epoch else { return }
        switch event {
        case .segmentStart:
            emit(.segmentStart(samplePosition: samplePosition), epoch: epoch)
            transcriber.prepare()
        case .segmentEnd:
            emit(.segmentEnd(samplePosition: samplePosition), epoch: epoch)
        case .checkHead(let samples, let segmentEnded):
            await checkHead(samples: samples, segmentEnded: segmentEnded, epoch: epoch)
        case .listening:
            emit(.listeningStart(samplePosition: samplePosition), epoch: epoch)
        case .level(let level):
            emit(.level(level), epoch: epoch)
        case .dictation(let samples):
            emit(.dictationEnd(samples: samples, samplePosition: samplePosition), epoch: epoch)
        case .nothingHeard:
            emit(.nothingHeard(samplePosition: samplePosition), epoch: epoch)
        case .dropped:
            emit(.dropped, epoch: epoch)
        }
    }

    private func checkHead(samples: [Float], segmentEnded: Bool, epoch: Int) async {
        let checkEpoch = epoch
        guard !isClosed, checkEpoch == self.epoch else { return }
        let start = Date()
        let output: Transcriber.Output
        do {
            output = try await transcriber.transcribe(samples)
        } catch {
            guard !isClosed, !Task.isCancelled, checkEpoch == self.epoch else { return }
            Log.main("hands-free: head check failed")
            emit(.headCheck(
                samplePosition: samplePosition, duration: Date().timeIntervalSince(start),
                kind: .none, transcript: "", segmentEnded: segmentEnded
            ), epoch: checkEpoch)
            await report(segments: segmenter.headResult(.other), epoch: checkEpoch)
            return
        }
        guard !isClosed, !Task.isCancelled, checkEpoch == self.epoch else { return }

        let kind: HandsFreeHeadKind
        if HandsFreePhrases.afterWakePhrase(in: output.text, wakePhrases: dictationSettings.handsFree.wakePhrases) != nil {
            kind = .wake
        } else if segmentEnded && HandsFreePhrases.isOnly(output.text, phrases: dictationSettings.handsFree.offPhrases) {
            kind = .off
        } else if segmentEnded,
                  HandsFreePhrases.isOnly(output.text, phrases: dictationSettings.handsFree.sendPhrases),
                  followUpUntil.map({ samplePosition <= $0 }) == true {
            kind = .send
        } else {
            kind = .none
        }
        emit(.headCheck(
            samplePosition: samplePosition, duration: Date().timeIntervalSince(start),
            kind: kind, transcript: output.text, segmentEnded: segmentEnded
        ), epoch: checkEpoch)
        if kind == .off {
            emit(.offPhrase(samplePosition: samplePosition), epoch: checkEpoch)
        } else if kind == .send {
            emit(.sendPhrase(samplePosition: samplePosition), epoch: checkEpoch)
        }
        await report(segments: segmenter.headResult(kind == .wake ? .wake : .other), epoch: checkEpoch)
    }

    private func emit(_ event: HandsFreeListenerEvent, epoch: Int? = nil) {
        onEvent(epoch ?? self.epoch, event)
    }

    private func report(segments: [HandsFreeSegmenter.Event], epoch: Int) async {
        for event in segments { await handle(event, epoch: epoch) }
    }

    private static func segmenterSettings(_ settings: DictationSettings) -> HandsFreeSegmenterSettings {
        HandsFreeSegmenterSettings(
            preRollSamples: 8_000,
            firstHeadCheckSamples: 20_000,
            secondHeadCheckSamples: 40_000,
            endPauseSamples: sampleCount(settings.handsFree.endPause),
            wakeTimeoutSamples: sampleCount(settings.handsFree.wakeTimeout),
            maxDurationSamples: sampleCount(settings.maxDuration)
        )
    }

    private static func sampleCount(_ setting: DurationSetting) -> Int {
        guard let seconds = setting.timeInterval else { return Int.max / 4 }
        return max(1, Int(min(Double(Int.max / 4) / 16_000, seconds) * 16_000))
    }
}
