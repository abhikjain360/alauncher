import Core
import FluidAudio
import Foundation

/// CLI subcommands for testing dictation with files. Results go to stdout, timings and errors to
/// stderr. Nothing is ever inserted.
///
/// Await `run` from top-level code or a Task; don't block the main thread on it, because Ask
/// streaming delivers text on the main queue.
public enum DictationCLI {
    public static let usage = """
        usage:
          transcribe <wav>      transcribe a file with the speech model
          cleanup <text>        run the cleanup model over text (alias: postprocess)
          ask <text>            ask the Ask backend, streaming the answer
          dictate-file <wav>    transcribe, then ask or clean up, then print
        """

    /// `transcribe <wav>`, `cleanup <text>`, `ask <text>`, `dictate-file <wav>` (transcribe, then
    /// ask or clean up, then print; nothing is inserted). Prints results and timings; returns an exit code.
    public static func run(_ arguments: [String], config: Config) async -> Int32 {
        guard let command = arguments.first else {
            printError(usage)
            return 2
        }
        let argument = arguments.dropFirst().joined(separator: " ")
        do {
            switch command {
            case "transcribe":
                guard !argument.isEmpty else { throw CLIError.usage }
                let output = try await transcribe(path: argument, config: config)
                print(output.text)
            case "cleanup", "postprocess":
                guard !argument.isEmpty else { throw CLIError.usage }
                print(try await cleanUp(argument, config: config))
            case "ask":
                guard !argument.isEmpty else { throw CLIError.usage }
                try await ask(argument, config: config)
            case "dictate-file":
                guard !argument.isEmpty else { throw CLIError.usage }
                try await dictateFile(path: argument, config: config)
            case "-h", "--help", "help":
                print(usage)
            default:
                throw CLIError.usage
            }
            return 0
        } catch CLIError.usage {
            printError(usage)
            return 2
        } catch {
            printError("error: \(error)")
            return 1
        }
    }

    private enum CLIError: Error, CustomStringConvertible {
        case usage
        case noSuchFile(String)

        var description: String {
            switch self {
            case .usage: return "usage"
            case .noSuchFile(let path): return "no such file: \(path)"
            }
        }
    }

    private static func transcribe(path: String, config: Config) async throws -> Transcriber.Output {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError.noSuchFile(url.path) }
        let readStart = Date()
        let samples = try AudioConverter().resampleAudioFile(url)
        let readTime = Date().timeIntervalSince(readStart)
        let transcriber = Transcriber(model: config.dictation.model, unloadAfter: .never) { status in
            if case .downloading = status { printError("downloading speech model…") }
        }
        let output = try await transcriber.transcribe(samples)
        printError(String(
            format: "audio %.2f s (read %.3f s) · model load %.3f s · transcribe %.3f s · %d chars",
            Double(samples.count) / Transcriber.sampleRate, readTime, output.loadWait, output.transcription, output.text.count
        ))
        await transcriber.unload()
        return output
    }

    private static func cleanUp(_ text: String, config: Config) async throws -> String {
        let start = Date()
        let cleaned = try await CleanupClient.shared.cleanUp(text, settings: config.cleanup)
        printError(String(format: "cleanup %.3f s (%@, reasoning %@)", Date().timeIntervalSince(start), config.cleanup.model,
                          config.cleanup.reasoning.isEmpty ? "unset" : config.cleanup.reasoning))
        return cleaned
    }

    private static func ask(_ question: String, config: Config) async throws {
        let start = Date()
        let runner = await AskRunner(ask: config.ask, cleanup: config.cleanup, extraPath: config.launcher.extraPath)
        let firstText = FirstTextClock()
        let answer = try await runner.run(question) { delta in
            firstText.mark()
            FileHandle.standardOutput.write(Data(delta.utf8))
        }
        print("")
        let first = firstText.elapsed(since: start).map { String(format: "%.3f s", $0) } ?? "-"
        printError(String(format: "ask %.3f s (first text %@, backend %@, tools: %@)", Date().timeIntervalSince(start), first,
                          config.ask.backend.rawValue, answer.toolsUsed.isEmpty ? "none" : answer.toolsUsed.joined(separator: ", ")))
    }

    private static func dictateFile(path: String, config: Config) async throws {
        let output = try await transcribe(path: path, config: config)
        let settings = config.dictation
        let filtered = settings.removeFillers ? TextProcessing.removeFillers(output.text, fillers: settings.fillerWords) : output.text
        guard !TextProcessing.isBlank(filtered) else {
            printError("no speech")
            return
        }
        if config.ask.enabled, let question = TextProcessing.askQuestion(in: filtered, prefixes: config.ask.prefixes) {
            printError("ask: \(question.count) chars")
            try await ask(question, config: config)
            return
        }
        guard config.cleanup.enabled else {
            print(filtered)
            return
        }
        do {
            print(try await cleanUp(filtered, config: config))
        } catch {
            printError("cleanup failed (\(error)); raw text follows")
            print(filtered)
        }
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Records when the first streamed text arrived.
private final class FirstTextClock: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Date?

    func mark() {
        lock.lock()
        if first == nil { first = Date() }
        lock.unlock()
    }

    func elapsed(since start: Date) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return first.map { $0.timeIntervalSince(start) }
    }
}
