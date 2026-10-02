import Foundation
import Testing
@testable import Dictation

private func recordingDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("alauncher-recordings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func savedRecordingReadsBackWithTheSameSampleCount() async throws {
    let directory = try recordingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecordingStore(directory: directory, limit: 10)
    let samples = (0..<16_000).map { Float($0 % 100) / 100 }
    await store.save(samples, name: "20260923-141502-17.wav").value
    let url = directory.appendingPathComponent("20260923-141502-17.wav")
    let saved = try Transcriber.samples(fromFile: url)
    #expect(saved.count == samples.count)
    #expect(zip(samples, saved).allSatisfy { abs(Double($0 - $1)) <= 2.0 / 32_767 })
}

@Test func savedRecordingsKeepOnlyTheNewestNames() async throws {
    let directory = try recordingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecordingStore(directory: directory, limit: 2)
    for index in 1...3 {
        await store.save([0.1, 0.2], name: "20260923-141502-\(index).wav").value
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .map(\.lastPathComponent)
        .sorted()
    #expect(files == ["20260923-141502-2.wav", "20260923-141502-3.wav"])
}
