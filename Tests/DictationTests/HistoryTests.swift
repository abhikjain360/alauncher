import Foundation
import Testing
@testable import Dictation

private func temporaryHistoryFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("alauncher-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("history.jsonl")
}

private func lines(in url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
}

private func record(_ index: Int) -> DictationRecord {
    DictationRecord(
        date: Date(timeIntervalSince1970: 1_789_000_000 + Double(index)), mode: .cleanup,
        rawText: "raw \(index)", filteredText: "filtered \(index)", cleanedText: "Cleaned \(index).",
        targetBundleID: "com.example.App", outcome: .inserted
    )
}

@Test func historyRotatesOncePastTwiceTheLimit() throws {
    let file = try temporaryHistoryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let history = DictationHistory(fileURL: file, limit: 3)
    for index in 1...6 { history.append(record(index)) }
    history.flush()
    #expect(lines(in: file).count == 6)
    #expect(history.records.map(\.rawText) == ["raw 4", "raw 5", "raw 6"])

    history.append(record(7))
    history.flush()
    #expect(lines(in: file).count == 3)
    #expect(history.records.map(\.rawText) == ["raw 5", "raw 6", "raw 7"])

    // A fresh store reads back the kept records.
    let reloaded = DictationHistory(fileURL: file, limit: 3)
    #expect(reloaded.records == history.records)

    // Appending after a reload counts the lines already in the file.
    for index in 8...10 { reloaded.append(record(index)) }
    reloaded.flush()
    #expect(lines(in: file).count == 6)
    reloaded.append(record(11))
    reloaded.flush()
    #expect(lines(in: file).count == 3)
    #expect(reloaded.records.map(\.rawText) == ["raw 9", "raw 10", "raw 11"])
}

@Test func historyLimitZeroWritesNothing() throws {
    let file = try temporaryHistoryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let history = DictationHistory(fileURL: file, limit: 0)
    history.append(record(1))
    history.flush()
    #expect(history.records.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func historySkipsDamagedLines() throws {
    let file = try temporaryHistoryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let writer = DictationHistory(fileURL: file, limit: 10)
    writer.append(record(1))
    writer.flush()
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{not json\n\n".utf8))
    try handle.close()
    writer.append(record(2))
    writer.flush()

    let reader = DictationHistory(fileURL: file, limit: 10)
    #expect(reader.records.map(\.rawText) == ["raw 1", "raw 2"])
}

@Test func recordEncodesEveryField() throws {
    var full = record(1)
    full.mode = .ask
    full.answer = "An answer."
    full.timings.firstBuffer = 0.15
    full.timings.transcription = 0.09
    full.note = "tools: websearch"
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(DictationRecord.self, from: encoder.encode(full))
    #expect(decoded == full)
}

@Test func bestTextPrefersTheProcessedResult() {
    var entry = DictationRecord(mode: .raw, rawText: "um, raw", filteredText: "raw", outcome: .inserted)
    #expect(entry.bestText == "raw")
    entry.cleanedText = "Cleaned."
    #expect(entry.bestText == "Cleaned.")
    entry.answer = "Answer."
    #expect(entry.bestText == "Answer.")
    #expect(DictationRecord(mode: .raw, rawText: "only raw", outcome: .failed).bestText == "only raw")
}
