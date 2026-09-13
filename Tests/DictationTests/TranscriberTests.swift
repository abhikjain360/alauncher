import Foundation
import Testing
@testable import Dictation

@Test func modelNamesMapToParakeetVersions() {
    #expect(ParakeetModel(name: "parakeet-tdt-0.6b-v2") == .v2)
    #expect(ParakeetModel(name: "parakeet-tdt-0.6b-v3") == .v3)
    #expect(ParakeetModel(name: " PARAKEET-TDT-0.6B-V3 ") == .v3)
    #expect(ParakeetModel(name: "parakeet-tdt-0.6b-v2-coreml") == .v2)
    #expect(ParakeetModel(name: "parakeet-tdt-0.6b") == nil)
    #expect(ParakeetModel(name: "whisper-large-v3") == nil)
}

/// A folder of `.wav` recordings from `ALAUNCHER_TEST_AUDIO_DIR`. The transcription test is
/// skipped without it, or when the speech model isn't downloaded.
private let recordingsDirectory: URL? = ProcessInfo.processInfo.environment["ALAUNCHER_TEST_AUDIO_DIR"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }

private let canTranscribe = recordingsDirectory.map { FileManager.default.fileExists(atPath: $0.path) } == true
    && Transcriber.modelFilesPresent(model: "parakeet-tdt-0.6b-v2")

/// Transcribes every recording in `ALAUNCHER_TEST_AUDIO_DIR`. Recordings may be private, so only
/// transcript lengths are printed.
@Test(.enabled(if: canTranscribe), .timeLimit(.minutes(3)))
func transcribesRealRecordings() async throws {
    let directory = try #require(recordingsDirectory)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    try #require(!files.isEmpty)

    let transcriber = Transcriber(model: "parakeet-tdt-0.6b-v2", unloadAfter: .never)
    for file in files {
        let samples = try Transcriber.samples(fromFile: file)
        let output = try await transcriber.transcribe(samples)
        #expect(!output.text.isEmpty, "empty transcript for \(file.lastPathComponent)")
        print(String(
            format: "%@: %.2f s audio, model wait %.3f s, transcribe %.3f s, %d chars",
            file.lastPathComponent, Double(samples.count) / Transcriber.sampleRate,
            output.loadWait, output.transcription, output.text.count
        ))
    }

    // Shorter than FluidAudio's 0.3 s minimum: padded with silence instead of rejected.
    let short = try await transcriber.transcribe([Float](repeating: 0, count: 2_400))
    #expect(short.loadWait < 0.05)
    #expect(await transcriber.isLoaded)
    await transcriber.unload()
    #expect(await !transcriber.isLoaded)
}
