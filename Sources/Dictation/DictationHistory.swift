import Core
import Foundation

public enum DictationMode: String, Codable, Sendable {
    case cleanup
    case raw
    case ask
}

public enum DictationOutcome: String, Codable, Sendable {
    /// Typed or pasted into the target app.
    case inserted
    /// Shown in the TextPanel: the target app changed, or an Ask answer.
    case shownInPanel
    case cancelled
    /// A new key-down replaced it before it finished.
    case superseded
    case droppedShort
    case droppedSilent
    case droppedEmpty
    case failed
}

/// Seconds per stage; nil for stages that didn't run.
public struct DictationTimings: Codable, Equatable, Sendable {
    public var firstBuffer: Double?
    public var recording: Double?
    public var modelWait: Double?
    public var transcription: Double?
    public var postProcessing: Double?
    public var insertion: Double?

    public init() {}
}

public struct DictationRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var mode: DictationMode
    /// The transcript as recognized, before filler removal.
    public var rawText: String
    /// After filler removal; what cleanup, Ask or raw insertion used.
    public var filteredText: String
    public var cleanedText: String?
    public var answer: String?
    public var targetBundleID: String?
    public var timings: DictationTimings
    public var outcome: DictationOutcome
    /// A short error such as "cleanup failed: timed out". Never contains the text.
    public var note: String?

    public init(
        id: UUID = UUID(), date: Date = Date(), mode: DictationMode, rawText: String = "", filteredText: String = "",
        cleanedText: String? = nil, answer: String? = nil, targetBundleID: String? = nil,
        timings: DictationTimings = DictationTimings(), outcome: DictationOutcome, note: String? = nil
    ) {
        self.id = id
        self.date = date
        self.mode = mode
        self.rawText = rawText
        self.filteredText = filteredText
        self.cleanedText = cleanedText
        self.answer = answer
        self.targetBundleID = targetBundleID
        self.timings = timings
        self.outcome = outcome
        self.note = note
    }

    /// What "Copy last dictation" copies: the answer, the cleaned text, or the transcript.
    public var bestText: String {
        answer ?? cleanedText ?? (filteredText.isEmpty ? rawText : filteredText)
    }
}

/// The last `limit` dictations, as JSONL at `Paths.supportDirectory/history.jsonl`.
///
/// Records are appended one line at a time; once the file holds more than twice the limit, it is
/// rewritten with the last `limit`. Used from the main thread; file writes happen on a private
/// serial queue.
final class DictationHistory: @unchecked Sendable {
    static let defaultFile = Paths.supportDirectory.appendingPathComponent("history.jsonl")

    private let fileURL: URL
    private let queue = DispatchQueue(label: "alauncher.dictation-history")
    private let log = Log.main
    private(set) var records: [DictationRecord] = []
    private var fileLines = 0
    var limit: Int {
        didSet { trimMemory() }
    }

    init(fileURL: URL = DictationHistory.defaultFile, limit: Int) {
        self.fileURL = fileURL
        self.limit = max(0, limit)
        load()
    }

    func append(_ record: DictationRecord) {
        guard limit > 0 else { return }
        records.append(record)
        trimMemory()
        fileLines += 1
        if fileLines > 2 * limit {
            let snapshot = records
            fileLines = snapshot.count
            queue.async { [self] in rewrite(snapshot) }
        } else {
            queue.async { [self] in appendLine(record) }
        }
    }

    /// Waits for pending writes. For tests and shutdown.
    func flush() {
        queue.sync {}
    }

    private func trimMemory() {
        if records.count > limit { records.removeFirst(records.count - limit) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = Self.decoder()
        var loaded: [DictationRecord] = []
        var lines = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            lines += 1
            if let record = try? decoder.decode(DictationRecord.self, from: Data(line)) { loaded.append(record) }
        }
        fileLines = lines
        records = loaded
        trimMemory()
    }

    private func appendLine(_ record: DictationRecord) {
        guard let line = Self.encode(record) else { return }
        Paths.ensure(fileURL.deletingLastPathComponent())
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            do {
                try line.write(to: fileURL, options: .atomic)
            } catch {
                log("history: could not write \(fileURL.lastPathComponent)")
            }
        }
    }

    private func rewrite(_ snapshot: [DictationRecord]) {
        var data = Data()
        for record in snapshot {
            if let line = Self.encode(record) { data.append(line) }
        }
        Paths.ensure(fileURL.deletingLastPathComponent())
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log("history: could not rewrite \(fileURL.lastPathComponent)")
        }
    }

    private static func encode(_ record: DictationRecord) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(record) else { return nil }
        line.append(UInt8(ascii: "\n"))
        return line
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
