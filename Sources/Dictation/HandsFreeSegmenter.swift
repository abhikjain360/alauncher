import Foundation

struct HandsFreeSegmenterSettings: Equatable, Sendable {
    var preRollSamples: Int
    var firstHeadCheckSamples: Int
    var secondHeadCheckSamples: Int
    var endPauseSamples: Int
    var wakeTimeoutSamples: Int
    var maxDurationSamples: Int

    init(
        preRollSamples: Int = 8_000,
        firstHeadCheckSamples: Int = 20_000,
        secondHeadCheckSamples: Int = 40_000,
        endPauseSamples: Int = 24_000,
        wakeTimeoutSamples: Int = 80_000,
        maxDurationSamples: Int = 4_800_000
    ) {
        self.preRollSamples = max(0, preRollSamples)
        self.firstHeadCheckSamples = max(1, firstHeadCheckSamples)
        self.secondHeadCheckSamples = max(self.firstHeadCheckSamples, secondHeadCheckSamples)
        self.endPauseSamples = max(1, endPauseSamples)
        self.wakeTimeoutSamples = max(1, wakeTimeoutSamples)
        self.maxDurationSamples = max(1, maxDurationSamples)
    }
}

struct HandsFreeSegmenter {
    enum HeadResult: Sendable {
        case wake
        case other
    }

    enum Event: Sendable {
        case segmentStart(sample: Int)
        case segmentEnd(sample: Int)
        case checkHead(samples: [Float], segmentEnded: Bool)
        case listening
        case level(Float)
        case dictation(samples: [Float])
        case nothingHeard
        case dropped
    }

    private enum State {
        case idle
        case segment
        case checking
        case listening
    }

    private var settings: HandsFreeSegmenterSettings
    private var state = State.idle
    private var idleSamples: [Float] = []
    private var segmentSamples: [Float] = []
    private var totalSamples = 0
    private var silenceSamples = 0
    private var segmentEnded = false
    private var segmentEndReported = false
    private var headChecks = 0
    private var samplesAfterHeadResult = 0
    private var speechAfterWake = false

    init(settings: HandsFreeSegmenterSettings = HandsFreeSegmenterSettings()) {
        self.settings = settings
    }

    mutating func update(settings: HandsFreeSegmenterSettings) {
        self.settings = settings
        reset()
    }

    mutating func reset() {
        state = .idle
        idleSamples.removeAll(keepingCapacity: true)
        segmentSamples.removeAll(keepingCapacity: true)
        totalSamples = 0
        silenceSamples = 0
        segmentEnded = false
        segmentEndReported = false
        headChecks = 0
        samplesAfterHeadResult = 0
        speechAfterWake = false
    }

    mutating func append(_ samples: [Float], speech: Bool, segmentEnded: Bool = false) -> [Event] {
        guard !samples.isEmpty else { return [] }
        let start = totalSamples
        totalSamples += samples.count
        switch state {
        case .idle:
            guard speech else {
                keepPreRoll(samples)
                return []
            }
            let segmentStart = max(0, start - idleSamples.count)
            segmentSamples = idleSamples + samples
            idleSamples.removeAll(keepingCapacity: true)
            state = .segment
            silenceSamples = 0
            self.segmentEnded = false
            segmentEndReported = false
            headChecks = 0
            var events = [Event.segmentStart(sample: segmentStart)]
            events += addToSegment(samples: [], speech: speech, segmentEnded: segmentEnded)
            return events
        case .segment, .checking:
            return addToSegment(samples: samples, speech: speech, segmentEnded: segmentEnded)
        case .listening:
            return addToListening(samples, speech: speech)
        }
    }

    mutating func headResult(_ result: HeadResult) -> [Event] {
        guard state == .checking else { return [] }
        switch result {
        case .wake:
            state = .listening
            silenceSamples = 0
            samplesAfterHeadResult = 0
            speechAfterWake = false
            return [.listening]
        case .other:
            guard segmentEnded else {
                if headChecks == 1, segmentSamples.count >= settings.secondHeadCheckSamples {
                    headChecks = 2
                    return [.checkHead(samples: segmentSamples, segmentEnded: false)]
                }
                state = .segment
                return []
            }
            let events = [Event.dropped]
            moveToIdle()
            return events
        }
    }

    mutating func finish() -> [Event] {
        switch state {
        case .idle:
            return []
        case .segment:
            segmentEnded = true
            var events: [Event] = []
            if !segmentEndReported {
                segmentEndReported = true
                events.append(.segmentEnd(sample: totalSamples))
            }
            if headChecks == 0 {
                state = .checking
                headChecks = 1
                events.append(.checkHead(samples: segmentSamples, segmentEnded: true))
            } else {
                events.append(.dropped)
                moveToIdle()
            }
            return events
        case .checking:
            return []
        case .listening:
            if speechAfterWake {
                let samples = segmentSamples
                moveToIdle()
                return [.dictation(samples: samples)]
            }
            moveToIdle()
            return [.nothingHeard]
        }
    }

    private mutating func addToSegment(samples: [Float], speech: Bool, segmentEnded explicitEnd: Bool) -> [Event] {
        if !samples.isEmpty { segmentSamples.append(contentsOf: samples) }
        if speech {
            silenceSamples = 0
        } else {
            silenceSamples += samples.count
        }
        if explicitEnd || silenceSamples >= settings.endPauseSamples { segmentEnded = true }
        if state == .checking {
            if segmentEnded && !segmentEndReported {
                segmentEndReported = true
                return [.segmentEnd(sample: totalSamples)]
            }
            return []
        }
        if segmentEnded {
            var events: [Event] = []
            if !segmentEndReported {
                segmentEndReported = true
                events.append(.segmentEnd(sample: totalSamples))
            }
            if headChecks == 0 || headChecks == 1 && segmentSamples.count < settings.secondHeadCheckSamples {
                state = .checking
                headChecks += 1
                events.append(.checkHead(samples: segmentSamples, segmentEnded: true))
            } else {
                events.append(.dropped)
                moveToIdle()
            }
            return events
        }
        if headChecks == 0, segmentSamples.count >= settings.firstHeadCheckSamples {
            state = .checking
            headChecks = 1
            return [.checkHead(samples: segmentSamples, segmentEnded: false)]
        }
        if headChecks == 1, segmentSamples.count >= settings.secondHeadCheckSamples {
            state = .checking
            headChecks = 2
            return [.checkHead(samples: segmentSamples, segmentEnded: false)]
        }
        return []
    }

    private mutating func addToListening(_ samples: [Float], speech: Bool) -> [Event] {
        segmentSamples.append(contentsOf: samples)
        samplesAfterHeadResult += samples.count
        if speech {
            speechAfterWake = true
            silenceSamples = 0
        } else if speechAfterWake {
            silenceSamples += samples.count
        }
        if !speechAfterWake, samplesAfterHeadResult >= settings.wakeTimeoutSamples {
            let events = [Event.nothingHeard]
            moveToIdle()
            return events
        }
        if segmentSamples.count >= settings.maxDurationSamples {
            let samples = segmentSamples
            moveToIdle()
            return [.dictation(samples: samples)]
        }
        if speechAfterWake, silenceSamples >= settings.endPauseSamples {
            let samples = segmentSamples
            moveToIdle()
            return [.dictation(samples: samples)]
        }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        return [.level(min(1, max(0, (20 * log10(max(rms, 1e-9)) + 60) / 60)))]
    }

    private mutating func moveToIdle() {
        state = .idle
        idleSamples.removeAll(keepingCapacity: true)
        segmentSamples.removeAll(keepingCapacity: true)
        silenceSamples = 0
        segmentEnded = false
        segmentEndReported = false
        headChecks = 0
        samplesAfterHeadResult = 0
        speechAfterWake = false
    }

    private mutating func keepPreRoll(_ samples: [Float]) {
        guard settings.preRollSamples > 0 else { return }
        idleSamples.append(contentsOf: samples)
        if idleSamples.count > settings.preRollSamples {
            idleSamples.removeFirst(idleSamples.count - settings.preRollSamples)
        }
    }
}
