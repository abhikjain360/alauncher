import Core
import Foundation
import Overlay
import Search

/// Where script output goes: the pill, `TextPanel` and typing in the app, a recorder in tests.
@MainActor
protocol ScriptOutputSink: AnyObject {
    func flash(_ text: String, isError: Bool)
    func showOutput(title: String, body: String)
    /// `mode = "type"`: types the text into `targetPID`'s app.
    func type(_ text: String, targetPID: pid_t?)
}

/// The app's sink: `OverlayPill` for one line, `TextPanel` for full output, and the insert
/// path for typed output.
@MainActor
final class OverlayOutputSink: ScriptOutputSink {
    private let insert: InsertText

    init(insert: @escaping InsertText) {
        self.insert = insert
    }

    func flash(_ text: String, isError: Bool) {
        OverlayPill.shared.flash(text, isError: isError)
    }

    func showOutput(title: String, body: String) {
        let panel = TextPanel.shared
        panel.onEnter = nil
        panel.show(entries: [TextPanel.Entry(heading: title, body: body)], hint: "⌘C copy · esc close")
    }

    /// Command output may be a secret, so it never falls back to the clipboard.
    func type(_ text: String, targetPID: pid_t?) {
        insert(text, targetPID, false)
    }
}

/// A script or `[[launcher.commands]]` entry, ready to run.
struct ScriptInvocation: Sendable {
    enum Program: Sendable {
        /// Run directly when executable, so its shebang applies; otherwise through bash.
        case file(URL)
        /// `/bin/sh -c <command>`, with the arguments as `$1`, `$2`, …
        case shell(String)
    }

    var title: String
    var program: Program
    var mode: ScriptCommand.Mode
    /// `mode = "type"`, for config commands: the output is typed into `targetPID`'s app. A
    /// failure flashes as in silent mode, but never with stdout, which may be a secret.
    var typesOutput = false
    /// The app that was frontmost when Enter was pressed, where typed output goes.
    var targetPID: pid_t?
    /// Nil: the script's own folder, or the home folder for a command.
    var currentDirectory: String?
    /// By position: whether to percent-encode that argument.
    var percentEncoded: [Bool]

    init(title: String, program: Program, mode: ScriptCommand.Mode, currentDirectory: String? = nil, percentEncoded: [Bool] = []) {
        self.title = title
        self.program = program
        self.mode = mode
        self.currentDirectory = currentDirectory
        self.percentEncoded = percentEncoded
    }

    init(script: ScriptCommand) {
        let directory = script.currentDirectoryPath?.trimmingCharacters(in: .whitespaces)
        self.init(
            title: script.title,
            program: .file(script.path),
            mode: script.mode,
            currentDirectory: directory?.isEmpty == false ? directory : nil,
            percentEncoded: script.arguments.map(\.percentEncoded)
        )
    }

    init(command: CommandSettings) {
        let typesOutput = command.mode == "type"
        self.init(
            title: command.title,
            program: .shell(command.run),
            mode: typesOutput ? .silent : ScriptCommand.Mode(rawValue: command.mode) ?? .silent
        )
        self.typesOutput = typesOutput
    }
}

struct ScriptRunResult: Equatable, Sendable {
    /// The exit status; 128 + the signal number when killed by a signal.
    var exitCode: Int32
    var stdout: String
    var stderr: String
    /// More than the cap was written; the text holds the end of the output, or, for output
    /// kept whole, nothing.
    var stdoutTruncated = false
    var stderrTruncated = false
    /// The program couldn't start; `stderr` says why.
    var launchFailed = false
}

/// Runs scripts and commands off the main thread and shows their output per mode.
/// There's no timeout (scripts may open a GUI such as `choose` and wait on it), but
/// running processes are tracked.
@MainActor
final class ScriptRunner {
    static let outputCap = 64 * 1024
    /// Choices runs and `mode = "type"` need all of stdout; more than this is an error.
    nonisolated static let wholeOutputCap = 16 << 20

    var extraPath: [String]
    private let sink: ScriptOutputSink
    private let environment: [String: String]
    private let wholeCap: Int
    private let log: @Sendable (String) -> Void
    private var running: [ObjectIdentifier: ProcessCapture] = [:]

    init(
        sink: ScriptOutputSink,
        extraPath: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        wholeOutputCap: Int = ScriptRunner.wholeOutputCap,
        log: @escaping @Sendable (String) -> Void = { Log.main($0) }
    ) {
        self.sink = sink
        self.extraPath = extraPath
        self.environment = environment
        wholeCap = wholeOutputCap
        self.log = log
    }

    var runningCount: Int { running.count }

    /// Starts the program and, when it exits, shows its output. The app doesn't await
    /// this; tests do.
    @discardableResult
    func run(_ invocation: ScriptInvocation, arguments: [String] = []) async -> ScriptRunResult {
        let capture = makeCapture(invocation, arguments: arguments, keepsWholeStdout: invocation.typesOutput)
        let result = await finish(capture, title: invocation.title)
        present(result, for: invocation)
        return result
    }

    /// A choices run: all of stdout, up to `wholeOutputCap`, goes to `completion` rather than
    /// being shown. The returned cancel terminates the process and drops its result.
    func capture(
        _ invocation: ScriptInvocation,
        arguments: [String],
        completion: @escaping @MainActor (ScriptRunResult) -> Void
    ) -> @MainActor () -> Void {
        let capture = makeCapture(invocation, arguments: arguments, keepsWholeStdout: true)
        let cancellation = Cancellation()
        Task {
            let result = await finish(capture, title: invocation.title)
            if !cancellation.isCancelled { completion(result) }
        }
        return {
            cancellation.isCancelled = true
            capture.terminate()
        }
    }

    /// Sends SIGTERM to every running script.
    func terminateAll() {
        for capture in running.values {
            capture.terminate()
        }
    }

    /// Shows or types a result's text per the invocation's mode: a choices command's final
    /// text, or a `mode = "type"` command's output. Empty text shows nothing.
    func deliver(_ text: String, for invocation: ScriptInvocation) {
        guard !text.isEmpty else { return }
        if invocation.typesOutput {
            sink.type(text, targetPID: invocation.targetPID)
            return
        }
        switch invocation.mode {
        case .fullOutput:
            sink.showOutput(title: invocation.title, body: text)
        case .silent, .compact, .inline:
            if let line = Self.lastLine(of: text) {
                sink.flash(Self.pillText(line), isError: false)
            }
        }
    }

    func launchSpec(for invocation: ScriptInvocation, arguments: [String]) -> ProcessCapture.Launch {
        let values = arguments.enumerated().map { index, value in
            index < invocation.percentEncoded.count && invocation.percentEncoded[index] ? Self.percentEncode(value) : value
        }
        var environment = environment
        environment["PATH"] = Self.searchPath(extraPath: extraPath, environment: environment)

        switch invocation.program {
        case .file(let url):
            let directory = invocation.currentDirectory ?? url.deletingLastPathComponent().path
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return .init(executable: url, arguments: values, environment: environment, currentDirectory: directory, bashFallback: true)
            }
            return .init(executable: Self.bash, arguments: [url.path] + values, environment: environment, currentDirectory: directory, bashFallback: false)
        case .shell(let command):
            let directory = invocation.currentDirectory ?? NSHomeDirectory()
            return .init(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", command, "alauncher"] + values,
                environment: environment,
                currentDirectory: directory,
                bashFallback: false
            )
        }
    }

    nonisolated static let bash = URL(fileURLWithPath: "/bin/bash")

    /// `launcher.extraPath` (expanded) in front of the inherited PATH, without repeats.
    static func searchPath(extraPath: [String], environment: [String: String]) -> String {
        let inherited = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let entries = extraPath.map { PathExpansion.expand($0, environment: environment) }
            + inherited.split(separator: ":").map(String.init)
        var seen = Set<String>()
        return entries.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// RFC 3986 unreserved characters stay; everything else is encoded, as for a URL query value.
    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func makeCapture(_ invocation: ScriptInvocation, arguments: [String], keepsWholeStdout: Bool) -> ProcessCapture {
        ProcessCapture(
            launch: launchSpec(for: invocation, arguments: arguments),
            cap: Self.outputCap,
            wholeStdoutCap: keepsWholeStdout ? wholeCap : nil
        )
    }

    /// Runs `capture` to the end, tracked meanwhile. Logs sizes and timing, never output.
    private func finish(_ capture: ProcessCapture, title: String) async -> ScriptRunResult {
        let key = ObjectIdentifier(capture)
        running[key] = capture
        let started = Date()
        let result = await capture.run()
        running[key] = nil

        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        log("launcher: \(title) exited \(result.exitCode) after \(milliseconds) ms, stdout \(result.stdout.utf8.count) B, stderr \(result.stderr.utf8.count) B")
        return result
    }

    private func present(_ result: ScriptRunResult, for invocation: ScriptInvocation) {
        if invocation.typesOutput {
            if result.exitCode != 0 {
                sink.flash(Self.pillText(Self.failureText(result, title: invocation.title, showsStdout: false)), isError: true)
            } else if result.stdoutTruncated {
                sink.flash("\(invocation.title): output too large", isError: true)
            } else {
                deliver(Self.droppingTrailingNewline(result.stdout), for: invocation)
            }
            return
        }
        switch invocation.mode {
        case .fullOutput:
            sink.showOutput(title: invocation.title, body: Self.fullOutputBody(result))
        case .silent, .compact, .inline:
            if result.exitCode == 0 {
                if let line = Self.lastLine(of: result.stdout) {
                    sink.flash(Self.pillText(line), isError: false)
                }
            } else {
                sink.flash(Self.pillText(Self.failureText(result, title: invocation.title, showsStdout: true)), isError: true)
            }
        }
    }

    /// What a failed run flashes: its last stderr line; else its last stdout line, when stdout
    /// may be shown; else its exit status.
    static func failureText(_ result: ScriptRunResult, title: String, showsStdout: Bool) -> String {
        lastLine(of: result.stderr)
            ?? (showsStdout ? lastLine(of: result.stdout) : nil)
            ?? "\(title) failed (exit \(result.exitCode))"
    }

    /// A command's output as typed: without the newline that ends it.
    static func droppingTrailingNewline(_ text: String) -> String {
        // "\r\n" is one Character, so `dropLast` takes all of it.
        text.hasSuffix("\n") || text.hasSuffix("\r\n") ? String(text.dropLast()) : text
    }

    static func lastLine(of text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func pillText(_ line: String) -> String {
        line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    static func fullOutputBody(_ result: ScriptRunResult) -> String {
        var parts: [String] = []
        if result.stdoutTruncated || result.stderrTruncated {
            parts.append("[earlier output cut; showing the last 64 KB]")
        }
        let stdout = result.stdout.trimmingCharacters(in: .newlines)
        let stderr = result.stderr.trimmingCharacters(in: .newlines)
        if !stdout.isEmpty { parts.append(stdout) }
        if !stderr.isEmpty { parts.append(stderr) }
        if result.exitCode != 0 { parts.append("[exit status \(result.exitCode)]") }
        return parts.isEmpty ? "(no output)" : parts.joined(separator: "\n\n")
    }
}

/// Set when a choices run is cancelled, so that its late result is dropped.
@MainActor
private final class Cancellation {
    var isCancelled = false
}

/// One running process and its captured output. Spawning, reading and waiting all
/// happen on background queues.
final class ProcessCapture: @unchecked Sendable {
    struct Launch: Equatable, Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: String
        /// Retry as `/bin/bash <executable> …` if spawning fails, e.g. an executable
        /// script without a shebang.
        var bashFallback: Bool
    }

    /// How long to wait for output to end after the process exits. A background child
    /// that inherited stdout would otherwise hold the result back until it exits.
    static let drainGrace: TimeInterval = 0.5
    private static let queue = DispatchQueue(label: "alauncher.scripts", qos: .userInitiated, attributes: .concurrent)

    private let launch: Launch
    private let lock = NSLock()
    private var process: Process?
    private var handles: [FileHandle] = []
    private var buffers: [OutputBuffer]
    private var closedStreams: Set<Int> = []
    private var exited = false
    private var finished = false
    private var continuation: CheckedContinuation<ScriptRunResult, Never>?

    /// `cap` bounds the tail kept of each stream. With `wholeStdoutCap`, stdout is kept whole
    /// up to that size instead.
    init(launch: Launch, cap: Int, wholeStdoutCap: Int? = nil) {
        self.launch = launch
        buffers = [
            wholeStdoutCap.map { OutputBuffer(cap: $0, keepsWhole: true) } ?? OutputBuffer(cap: cap),
            OutputBuffer(cap: cap),
        ]
    }

    func run() async -> ScriptRunResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            Self.queue.async { self.start() }
        }
    }

    func terminate() {
        lock.lock()
        let process = process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    private func start() {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: launch.currentDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            fail("folder \(launch.currentDirectory) doesn't exist")
            return
        }
        do {
            try spawn(launch)
        } catch {
            guard launch.bashFallback else {
                fail(error.localizedDescription)
                return
            }
            var bash = launch
            bash.executable = ScriptRunner.bash
            bash.arguments = [launch.executable.path] + launch.arguments
            do {
                try spawn(bash)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func spawn(_ launch: Launch) throws {
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = URL(fileURLWithPath: launch.currentDirectory, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        let pipes = [Pipe(), Pipe()]
        process.standardOutput = pipes[0]
        process.standardError = pipes[1]
        // Weak: the capture holds the process, and `run()` keeps the capture alive until it finishes.
        process.terminationHandler = { [weak self] _ in self?.processExited() }
        try process.run()

        let handles = pipes.map(\.fileHandleForReading)
        lock.lock()
        self.process = process
        self.handles = handles
        lock.unlock()
        for (stream, handle) in handles.enumerated() {
            handle.readabilityHandler = { [weak self] handle in self?.read(handle, stream: stream) }
        }
    }

    private func read(_ handle: FileHandle, stream: Int) {
        let data = handle.availableData
        lock.lock()
        guard !finished, !closedStreams.contains(stream) else {
            lock.unlock()
            return
        }
        if data.isEmpty {
            closedStreams.insert(stream)
            lock.unlock()
            handle.readabilityHandler = nil
            finishIfDone()
        } else {
            buffers[stream].append(data)
            lock.unlock()
        }
    }

    private func processExited() {
        lock.lock()
        exited = true
        lock.unlock()
        finishIfDone()
        Self.queue.asyncAfter(deadline: .now() + Self.drainGrace) { self.finish() }
    }

    private func finishIfDone() {
        lock.lock()
        let done = exited && closedStreams.count == 2
        lock.unlock()
        if done { finish() }
    }

    private func fail(_ reason: String) {
        lock.lock()
        buffers[1].append(Data("can't run \(launch.executable.lastPathComponent): \(reason)".utf8))
        exited = true
        lock.unlock()
        finish(launchFailed: true)
    }

    private func finish(launchFailed: Bool = false) {
        lock.lock()
        guard !finished, exited else {
            lock.unlock()
            return
        }
        finished = true
        let status: Int32
        if launchFailed {
            status = 127
        } else if let process {
            status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
        } else {
            status = 127
        }
        let stdout = buffers[0].text()
        let stderr = buffers[1].text()
        let result = ScriptRunResult(
            exitCode: status,
            stdout: stdout.text,
            stderr: stderr.text,
            stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated,
            launchFailed: launchFailed
        )
        let handles = handles
        let continuation = continuation
        self.handles = []
        self.continuation = nil
        lock.unlock()

        for handle in handles {
            handle.readabilityHandler = nil
        }
        continuation?.resume(returning: result)
    }
}

/// A stream's captured output: its last `cap` bytes, so the final line is always there. Or,
/// kept whole, all of it up to `cap`; past that it keeps nothing and only notes the overflow.
struct OutputBuffer {
    let cap: Int
    let keepsWhole: Bool
    private var data = Data()
    private var dropped = false

    init(cap: Int, keepsWhole: Bool = false) {
        self.cap = cap
        self.keepsWhole = keepsWhole
    }

    mutating func append(_ chunk: Data) {
        if keepsWhole {
            guard !dropped else { return }
            if data.count + chunk.count > cap {
                dropped = true
                data = Data()
            } else {
                data.append(chunk)
            }
            return
        }
        data.append(chunk)
        if data.count > cap * 2 {
            data = Data(data.suffix(cap))
            dropped = true
        }
    }

    /// Lossy UTF-8. When the start was cut, the partial first line is dropped too.
    func text() -> (text: String, truncated: Bool) {
        if keepsWhole {
            return (String(decoding: data, as: UTF8.self), dropped)
        }
        let truncated = dropped || data.count > cap
        var bytes = data.count > cap ? Data(data.suffix(cap)) : data
        if truncated, let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
            bytes = Data(bytes[bytes.index(after: newline)...])
        }
        return (String(decoding: bytes, as: UTF8.self), truncated)
    }
}
