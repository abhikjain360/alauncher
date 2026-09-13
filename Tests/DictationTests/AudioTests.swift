import Testing
@testable import Dictation

private func near(_ value: Float, _ expected: Float, tolerance: Float = 0.01) -> Bool {
    abs(value - expected) <= tolerance
}

private func append(_ value: Float, count: Int, to accumulator: SampleAccumulator) -> Bool {
    [Float](repeating: value, count: count).withUnsafeBufferPointer { accumulator.append($0) }
}

@Test func levelMapsMinus60To0DBFSOntoZeroToOne() {
    #expect(AudioLevels.normalizedLevel(rms: 1) == 1)
    #expect(AudioLevels.normalizedLevel(rms: 2) == 1)
    #expect(AudioLevels.normalizedLevel(rms: 0) == 0)
    #expect(near(AudioLevels.normalizedLevel(rms: 0.001), 0))
    #expect(near(AudioLevels.normalizedLevel(rms: 0.0316228), 0.5))
    #expect(near(AudioLevels.decibels(rms: 0.1), -20))
}

@Test func rmsOfABuffer() {
    #expect([Float](arrayLiteral: 0.5, -0.5, 0.5, -0.5).withUnsafeBufferPointer(AudioLevels.rms) == 0.5)
    #expect([Float]().withUnsafeBufferPointer(AudioLevels.rms) == 0)
}

@Test func accumulatorKeepsTheLoudest50msWindow() {
    let accumulator = SampleAccumulator(maxDuration: nil)
    _ = append(0.001, count: 800, to: accumulator)
    _ = append(0.5, count: 800, to: accumulator)
    _ = append(0.001, count: 1_600, to: accumulator)
    let result = accumulator.finish()
    #expect(result.samples.count == 3_200)
    #expect(near(result.peakWindowDB, -6.02))
    #expect(near(Float(result.duration), 0.2))
}

@Test func aTrailingPartialWindowCounts() {
    let accumulator = SampleAccumulator(maxDuration: nil)
    _ = append(0.5, count: 400, to: accumulator)
    #expect(near(accumulator.finish().peakWindowDB, -6.02))
}

@Test func quietRoomNoiseIsSilence() {
    let accumulator = SampleAccumulator(maxDuration: nil)
    _ = append(0.001, count: 16_000, to: accumulator)
    let peak = accumulator.finish().peakWindowDB
    #expect(near(peak, -60))
    #expect(peak < AudioLevels.silenceThresholdDB)

    let speech = SampleAccumulator(maxDuration: nil)
    _ = append(0.01, count: 16_000, to: speech)
    #expect(speech.finish().peakWindowDB > AudioLevels.silenceThresholdDB)
}

@Test func accumulatorStopsAtMaxDurationAndReportsOnce() {
    let accumulator = SampleAccumulator(maxDuration: 0.1)
    #expect(!append(0.1, count: 1_000, to: accumulator))
    #expect(append(0.1, count: 1_000, to: accumulator))
    #expect(!append(0.1, count: 1_000, to: accumulator))
    #expect(accumulator.finish().samples.count == 1_600)
}

@Test func inputDeviceMatchesUIDThenName() {
    let devices = [
        AudioDevices.Device(id: 1, name: "MacBook Air Microphone", uid: "BuiltInMicrophoneDevice"),
        AudioDevices.Device(id: 2, name: "AirPods Pro", uid: "00-11-22-33-44-55:input"),
    ]
    #expect(AudioDevices.match("BuiltInMicrophoneDevice", in: devices)?.id == 1)
    #expect(AudioDevices.match("airpods pro", in: devices)?.id == 2)
    #expect(AudioDevices.match(" MacBook Air Microphone ", in: devices)?.id == 1)
    #expect(AudioDevices.match("", in: devices) == nil)
    #expect(AudioDevices.match("USB Mic", in: devices) == nil)
}
