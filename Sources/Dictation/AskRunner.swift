import Core
import Foundation

public enum AskError: Error, Equatable, CustomStringConvertible {
    case executableNotFound(String)
    case launchFailed(String)
    case processFailed(status: Int32, stderrTail: String)
    case backend(String)
    case emptyAnswer
    case cancelled
    case timedOut

    public var description: String {
        switch self {
        case .executableNotFound(let name): return "\(name) not found in PATH or launcher.extra_path"
        case .launchFailed(let reason): return "could not start opencode: \(reason)"
        case .processFailed(let status, let tail):
            return "opencode exited with status \(status)" + (tail.isEmpty ? "" : ": \(tail)")
        case .backend(let message): return message
        case .emptyAnswer: return "no answer"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed out"
        }
    }
}

// MARK: - opencode events

/// One event from `opencode run --format json`, reduced to what the popup needs.
///
/// Every line is a JSON object with `type`, `timestamp` and `sessionID`. The types seen with
/// opencode 1.18.30 (fixtures in Tests/DictationTests/OpencodeFixtures.swift):
/// - `step_start`: `part.type == "step-start"`.
/// - `text`: `part.id`, `part.text` (the part's whole text so far), `part.time`.
/// - `tool_use`: `part.tool` ("websearch", "webfetch"), `part.state.status`, `.input`, `.output`.
/// - `step_finish`: `part.reason` ("stop", "tool-calls"), `part.tokens`, `part.cost`.
/// - `error`: `error.name`, `error.data.message`; the process then exits with status 1.
enum OpencodeEvent: Equatable {
    case session(String)
    /// New answer text to append.
    case text(String)
    case tool(name: String, status: String)
    case stepFinish(reason: String)
    case error(String)
}

/// Turns opencode's JSON lines into answer deltas. Pure; fed one line at a time.
struct OpencodeEventParser {
    private(set) var sessionID: String?
    private(set) var answer = ""
    private var partTexts: [String: String] = [:]
    private var separatorPending = false

    mutating func consume(line: String) -> [OpencodeEvent] {
        guard let data = line.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = root["type"] as? String else { return [] }
        var events: [OpencodeEvent] = []
        if sessionID == nil, let id = root["sessionID"] as? String, !id.isEmpty {
            sessionID = id
            events.append(.session(id))
        }
        let part = root["part"] as? [String: Any]

        switch type {
        case "text":
            guard let part, let text = part["text"] as? String else { break }
            let id = part["id"] as? String ?? "part-\(partTexts.count)"
            let previous: String
            if let known = partTexts[id] {
                previous = known
            } else {
                previous = ""
                if !answer.isEmpty { separatorPending = true }
            }
            partTexts[id] = text
            // A part that grows emits only its new suffix; a rewritten part emits nothing more.
            guard text.count > previous.count, text.hasPrefix(previous) else { break }
            var delta = String(text.dropFirst(previous.count))
            if separatorPending {
                delta = "\n\n" + delta
                separatorPending = false
            }
            answer += delta
            events.append(.text(delta))
        case "tool_use":
            if let part, let tool = part["tool"] as? String {
                let status = (part["state"] as? [String: Any])?["status"] as? String ?? ""
                events.append(.tool(name: tool, status: status))
            }
        case "step_finish":
            events.append(.stepFinish(reason: part?["reason"] as? String ?? ""))
        case "error":
            let error = root["error"] as? [String: Any]
            let message = (error?["data"] as? [String: Any])?["message"] as? String
                ?? error?["name"] as? String
                ?? "opencode reported an error"
            events.append(.error(message))
        default:
            break
        }
        return events
    }
}

// MARK: - opencode launch

enum OpencodeLaunch {
    static let agentName = "alauncher-ask"

    /// `OPENCODE_CONFIG_CONTENT`: defines the `alauncher-ask` agent with `prompt`, every tool denied
    /// except `tools`. opencode merges it over the user's config (which stays untouched), agent
    /// rules take precedence, and the last matching rule wins; sorted keys put `"*"` first.
    static func agentConfigJSON(prompt: String, tools: [String]) -> String {
        var permission: [String: String] = ["*": "deny"]
        for tool in tools {
            let name = tool.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { permission[name] = "allow" }
        }
        let config: [String: Any] = [
            "agent": [
                agentName: [
                    "description": "Answers spoken questions for alauncher.",
                    "mode": "primary",
                    "prompt": prompt,
                    "permission": permission,
                ],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func arguments(question: String, model: String, variant: String, sessionID: String?, directory: String) -> [String] {
        var arguments = ["run", "--format", "json", "--agent", agentName, "-m", model]
        let variant = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        if !variant.isEmpty { arguments += ["--variant", variant] }
        if let sessionID { arguments += ["--session", sessionID] }
        arguments += ["--dir", directory, "--", question]
        return arguments
    }

    /// `launcher.extraPath` entries with `~` and `$USER` expanded, then the inherited PATH.
    static func searchPath(extraPath: [String], inheritedPath: String?, home: String, user: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let inherited = (inheritedPath ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for entry in extraPath.map({ expand($0, home: home, user: user) }) + inherited where !entry.isEmpty {
            if seen.insert(entry).inserted { result.append(entry) }
        }
        return result
    }

    static func expand(_ path: String, home: String, user: String) -> String {
        var expanded = path.replacingOccurrences(of: "$USER", with: user).replacingOccurrences(of: "${USER}", with: user)
        if expanded == "~" {
            expanded = home
        } else if expanded.hasPrefix("~/") {
            expanded = home + expanded.dropFirst(1)
        }
        return expanded
    }

    /// An absolute or `~` path is used as is; a bare name is looked up in `searchPath`.
    static func resolve(_ name: String, searchPath: [String], home: String, user: String, isExecutable: (String) -> Bool) -> String? {
        let expanded = expand(name, home: home, user: user)
        if expanded.contains("/") { return isExecutable(expanded) ? expanded : nil }
        for directory in searchPath {
            let candidate = (directory as NSString).appendingPathComponent(expanded)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}

// MARK: - Runner

/// One Ask conversation, the thread shown in the TextPanel. The first question starts it;
/// follow-ups continue it (opencode `--session`, or the resent thread for `direct`).
@MainActor
public final class AskRunner {
    public struct Answer: Sendable {
        public var text: String
        public var toolsUsed: [String]
    }

    private let ask: AskSettings
    private let cleanup: CleanupSettings
    private let extraPath: [String]
    private var sessionID: String?
    private var thread: [ChatMessage] = []
    private var process: OpencodeProcess?
    private var directTask: Task<Answer, Error>?

    public init(ask: AskSettings, cleanup: CleanupSettings, extraPath: [String]) {
        self.ask = ask
        self.cleanup = cleanup
        self.extraPath = extraPath
    }

    /// Asks `question`, streaming answer text to `onText` on the main actor.
    public func run(_ question: String, onText: @escaping @MainActor @Sendable (String) -> Void) async throws -> Answer {
        switch ask.backend {
        case .opencode: return try await runOpencode(question, onText: onText)
        case .direct: return try await runDirect(question, onText: onText)
        }
    }

    /// Terminates the running question, if any.
    public func cancel() {
        process?.terminate()
        directTask?.cancel()
    }

    private func runOpencode(_ question: String, onText: @escaping @MainActor @Sendable (String) -> Void) async throws -> Answer {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = environment["USER"] ?? NSUserName()
        let path = OpencodeLaunch.searchPath(extraPath: extraPath, inheritedPath: environment["PATH"], home: home, user: user)
        guard let executable = OpencodeLaunch.resolve(ask.opencode, searchPath: path, home: home, user: user, isExecutable: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw AskError.executableNotFound(ask.opencode) }

        let directory = Paths.ensure(Paths.supportDirectory.appendingPathComponent("ask", isDirectory: true))
        var childEnvironment = environment
        childEnvironment["PATH"] = path.joined(separator: ":")
        childEnvironment["OPENCODE_ENABLE_EXA"] = "1"
        childEnvironment["OPENCODE_DISABLE_CLAUDE_CODE_PROMPT"] = "1"
        childEnvironment["OPENCODE_DISABLE_CLAUDE_CODE_SKILLS"] = "1"
        childEnvironment["OPENCODE_CONFIG_CONTENT"] = OpencodeLaunch.agentConfigJSON(prompt: ask.prompt, tools: ask.tools)

        let process = OpencodeProcess(
            executable: executable,
            arguments: OpencodeLaunch.arguments(
                question: question, model: ask.model, variant: ask.reasoning,
                sessionID: sessionID, directory: directory.path
            ),
            environment: childEnvironment,
            directory: directory
        )
        self.process = process
        defer { if self.process === process { self.process = nil } }

        let result = try await process.run(onText: onText)
        if let id = result.sessionID { sessionID = id }
        guard !result.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AskError.emptyAnswer }
        return Answer(text: result.answer, toolsUsed: result.tools)
    }

    private func runDirect(_ question: String, onText: @escaping @MainActor @Sendable (String) -> Void) async throws -> Answer {
        let messages = [ChatMessage(role: "system", content: ask.prompt)] + thread + [ChatMessage(role: "user", content: question)]
        var request = try ChatCompletions.request(settings: cleanup, messages: messages, stream: true, reasoning: ask.reasoning)
        request.timeoutInterval = 60
        let session = CleanupClient.shared.session
        let task = Task.detached { () async throws -> Answer in
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > 4096 { break }
                }
                throw CleanupError.http(status: status, message: ChatCompletions.errorMessage(from: body))
            }
            var answer = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let delta = ChatCompletions.streamDelta(from: payload), !delta.isEmpty else { continue }
                answer += delta
                await onText(delta)
            }
            return Answer(text: answer, toolsUsed: [])
        }
        directTask = task
        defer { directTask = nil }
        let answer: Answer
        do {
            answer = try await task.value
        } catch is CancellationError {
            throw AskError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw AskError.cancelled
        }
        guard !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AskError.emptyAnswer }
        thread += [ChatMessage(role: "user", content: question), ChatMessage(role: "assistant", content: answer.text)]
        return answer
    }
}

/// One `opencode run`: stdin at /dev/null, stdout parsed as JSON lines on a background thread,
/// stderr kept for errors. Completion is driven by the process exit: stdout then gets a short
/// grace period to drain, so a descendant holding the pipe open can't hang the answer.
/// Termination is SIGTERM, then SIGKILL if the process lingers.
final class OpencodeProcess: @unchecked Sendable {
    struct Result: Sendable {
        var answer: String
        var sessionID: String?
        var tools: [String]
    }

    /// A question that runs this long is terminated.
    static let maxRunTime: TimeInterval = 300
    static let killGrace: TimeInterval = 2
    static let drainGrace: TimeInterval = 1
    private static let stderrTailBytes = 600

    private let process = Process()
    private let lock = NSLock()
    private var terminatedByUs = false
    private var timedOut = false

    init(executable: String, arguments: [String], environment: [String: String], directory: URL) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
    }

    func terminate() {
        lock.lock()
        terminatedByUs = true
        lock.unlock()
        stop()
    }

    /// SIGTERM, then SIGKILL after `killGrace` if it is still running.
    private func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) { [self] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    func run(onText: @escaping @MainActor @Sendable (String) -> Void) async throws -> Result {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw AskError.launchFailed(error.localizedDescription)
        }
        let reader = StdoutReader(handle: stdout.fileHandleForReading, onText: onText)
        let errors = StderrCollector(handle: stderr.fileHandleForReading, limit: Self.stderrTailBytes)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.maxRunTime) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.lock.lock()
            self.timedOut = true
            self.lock.unlock()
            self.stop()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                // The single completion path: resumes the continuation exactly once.
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    exited.wait()
                    reader.waitForEnd(timeout: Self.drainGrace)
                    // Stop both readers and close the pipes, even if a descendant still holds them.
                    reader.stop()
                    errors.stop()
                    let output = reader.snapshot()
                    lock.lock()
                    let cancelled = terminatedByUs
                    let expired = timedOut
                    lock.unlock()
                    if cancelled {
                        continuation.resume(throwing: AskError.cancelled)
                    } else if expired {
                        continuation.resume(throwing: AskError.timedOut)
                    } else if let message = output.errorMessage {
                        continuation.resume(throwing: AskError.backend(message))
                    } else if process.terminationStatus != 0 {
                        continuation.resume(throwing: AskError.processFailed(status: process.terminationStatus, stderrTail: errors.tail()))
                    } else {
                        continuation.resume(returning: Result(answer: output.answer, sessionID: output.sessionID, tools: output.tools))
                    }
                }
            }
        } onCancel: {
            terminate()
        }
    }
}

/// Reads a pipe with a readability handler (a dispatch source, so no thread ever blocks on it),
/// one `read(2)` per callback so data arrives as soon as it is written.
private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let ended = DispatchSemaphore(value: 0)

    /// `onData` and `onEnd` run on the handle's serial queue.
    init(handle: FileHandle, onData: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void = {}) {
        self.handle = handle
        let ended = self.ended
        handle.readabilityHandler = { handle in
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                onData(Data(buffer[0..<count]))
                return
            }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            handle.readabilityHandler = nil
            onEnd()
            ended.signal()
        }
    }

    func waitForEnd(timeout: TimeInterval) {
        _ = ended.wait(timeout: .now() + timeout)
    }

    func stop() {
        handle.readabilityHandler = nil
        try? handle.close()
    }
}

/// Parses opencode's stdout as JSON lines as they arrive and hands answer text to the main queue
/// in order.
private final class StdoutReader: @unchecked Sendable {
    struct Snapshot {
        var answer: String
        var sessionID: String?
        var tools: [String]
        var errorMessage: String?
    }

    private let lock = NSLock()
    private var buffer = Data()
    private var parser = OpencodeEventParser()
    private var tools: [String] = []
    private var errorMessage: String?
    private var pipe: PipeReader?

    init(handle: FileHandle, onText: @escaping @MainActor @Sendable (String) -> Void) {
        pipe = PipeReader(
            handle: handle,
            onData: { [unowned self] data in receive(data, onText: onText) },
            onEnd: { [unowned self] in receiveEnd(onText: onText) }
        )
    }

    private func receive(_ data: Data, onText: @escaping @MainActor @Sendable (String) -> Void) {
        lock.lock()
        buffer.append(data)
        var events: [OpencodeEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            events += consume(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        deliver(events, onText: onText)
    }

    private func receiveEnd(onText: @escaping @MainActor @Sendable (String) -> Void) {
        lock.lock()
        let events = buffer.isEmpty ? [] : consume(buffer)
        buffer.removeAll()
        lock.unlock()
        deliver(events, onText: onText)
    }

    /// Call with the lock held.
    private func consume(_ line: Data) -> [OpencodeEvent] {
        let events = parser.consume(line: String(decoding: line, as: UTF8.self))
        for event in events {
            switch event {
            case .tool(let name, let status):
                if status == "completed" || status == "error" { tools.append(name) }
            case .error(let message):
                errorMessage = message
            case .session, .text, .stepFinish:
                break
            }
        }
        return events
    }

    private func deliver(_ events: [OpencodeEvent], onText: @escaping @MainActor @Sendable (String) -> Void) {
        for case .text(let delta) in events {
            DispatchQueue.main.async { MainActor.assumeIsolated { onText(delta) } }
        }
    }

    func waitForEnd(timeout: TimeInterval) {
        pipe?.waitForEnd(timeout: timeout)
    }

    func stop() {
        pipe?.stop()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(answer: parser.answer, sessionID: parser.sessionID, tools: tools, errorMessage: errorMessage)
    }
}

/// Keeps only the last `limit` bytes of stderr.
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pipe: PipeReader?

    init(handle: FileHandle, limit: Int) {
        pipe = PipeReader(handle: handle, onData: { [unowned self] chunk in
            lock.lock()
            data.append(chunk)
            if data.count > limit * 4 { data = Data(data.suffix(limit)) }
            lock.unlock()
        })
    }

    func stop() {
        pipe?.stop()
    }

    func tail() -> String {
        lock.lock()
        let snapshot = data.suffix(600)
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
