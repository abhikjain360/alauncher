import Testing
@testable import Dictation

private let segmenterSettings = HandsFreeSegmenterSettings(
    preRollSamples: 4_096,
    firstHeadCheckSamples: 20_000,
    secondHeadCheckSamples: 40_000,
    endPauseSamples: 8_192,
    wakeTimeoutSamples: 8_192,
    maxDurationSamples: 80_000
)

private func chunk(_ value: Float, count: Int = 4_096) -> [Float] {
    [Float](repeating: value, count: count)
}

private func contains(_ events: [HandsFreeSegmenter.Event], matching predicate: (HandsFreeSegmenter.Event) -> Bool) -> Bool {
    events.contains(where: predicate)
}

@Test func continuousSpeechChecksHeadThenEndsAfterSilence() {
    var segmenter = HandsFreeSegmenter(settings: segmenterSettings)
    _ = segmenter.append(chunk(0.1), speech: false)
    var events: [HandsFreeSegmenter.Event] = []
    for _ in 0..<4 { events += segmenter.append(chunk(0.5), speech: true) }
    let check = events.compactMap { event -> [Float]? in
        if case .checkHead(let samples, _) = event { return samples }
        return nil
    }.first
    #expect(check?.first == 0.1)
    #expect(check?.count == 20_480)
    #expect(segmenter.headResult(.wake).contains { if case .listening = $0 { return true }; return false })
    _ = segmenter.append(chunk(0.5), speech: true)
    _ = segmenter.append(chunk(0), speech: false)
    let end = segmenter.append(chunk(0), speech: false)
    #expect(contains(end) { if case .dictation(let samples) = $0 { return samples.count == 32_768 }; return false })
}

@Test func wakeWithoutFollowingSpeechTimesOut() {
    var segmenter = HandsFreeSegmenter(settings: segmenterSettings)
    _ = segmenter.append(chunk(0.5), speech: true)
    for _ in 0..<4 { _ = segmenter.append(chunk(0.5), speech: true) }
    _ = segmenter.headResult(.wake)
    _ = segmenter.append(chunk(0), speech: false)
    let timeout = segmenter.append(chunk(0), speech: false)
    #expect(contains(timeout) { if case .nothingHeard = $0 { return true }; return false })
}

@Test func endedMissIsDroppedWithoutASecondHeadCheck() {
    var segmenter = HandsFreeSegmenter(settings: segmenterSettings)
    _ = segmenter.append(chunk(0.5), speech: true)
    var first: [HandsFreeSegmenter.Event] = []
    for _ in 0..<4 { first += segmenter.append(chunk(0.5), speech: true) }
    #expect(contains(first) { if case .checkHead = $0 { return true }; return false })
    _ = segmenter.append(chunk(0), speech: false)
    _ = segmenter.append(chunk(0), speech: false)
    let dropped = segmenter.headResult(.other)
    #expect(contains(dropped) { if case .dropped = $0 { return true }; return false })
    #expect(!contains(dropped) { if case .checkHead = $0 { return true }; return false })
}

@Test func continuingMissGetsTheSecondHeadCheck() {
    var segmenter = HandsFreeSegmenter(settings: segmenterSettings)
    _ = segmenter.append(chunk(0.5), speech: true)
    for _ in 0..<4 { _ = segmenter.append(chunk(0.5), speech: true) }
    _ = segmenter.headResult(.other)
    var events: [HandsFreeSegmenter.Event] = []
    for _ in 0..<5 { events += segmenter.append(chunk(0.5), speech: true) }
    #expect(contains(events) { if case .checkHead(let samples, _) = $0 { return samples.count >= 40_000 }; return false })
}

@Test func wakeThatEndedDuringTheCheckCanContinueLater() {
    var segmenter = HandsFreeSegmenter(settings: segmenterSettings)
    _ = segmenter.append(chunk(0.5), speech: true)
    for _ in 0..<4 { _ = segmenter.append(chunk(0.5), speech: true) }
    _ = segmenter.append(chunk(0), speech: false)
    _ = segmenter.append(chunk(0), speech: false)
    #expect(segmenter.headResult(.wake).contains { if case .listening = $0 { return true }; return false })
    _ = segmenter.append(chunk(0.5), speech: true)
    _ = segmenter.append(chunk(0), speech: false)
    let end = segmenter.append(chunk(0), speech: false)
    #expect(contains(end) { if case .dictation = $0 { return true }; return false })
}

@Test func finishingAfterWakeWithoutMoreSpeechReportsNothingHeard() {
    var segmenter = HandsFreeSegmenter(settings: segmenterSettings)
    _ = segmenter.append(chunk(0.5), speech: true)
    for _ in 0..<4 { _ = segmenter.append(chunk(0.5), speech: true) }
    _ = segmenter.headResult(.wake)
    #expect(contains(segmenter.finish()) { if case .nothingHeard = $0 { return true }; return false })
}
