import Core
import Foundation
import Overlay
import Search

/// Where script output goes: the pill and `TextPanel` in the app, a recorder in tests.
@MainActor
protocol ScriptOutputSink: AnyObject {
    func flash(_ text: String, isError: Bool)
    func showOutput(title: String, body: String)
}

/// The app's sink: `OverlayPill` for one line, `TextPanel` for full output.
@MainActor
final class OverlayOutputSink: ScriptOutputSink {
    func flash(_ text: String, isError: Bool) {
        OverlayPill.shared.flash(text, isError: isError)
    }

    func showOutput(title: String, body: String) {
        let panel = TextPanel.shared
        panel.onEnter = nil
        panel.show(entries: [TextPanel.Entry(heading: title, body: body)], hint: "⌘C copy · esc close")
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
        self.init(title: command.title, program: .shell(command.run), mode: ScriptCommand.Mode(rawValue: command.mode) ?? .silent)
    }
}

struct ScriptRunResult: Equatable, Sendable {
    /// The exit status; 128 + the signal number when killed by a signal.
    var exitCode: Int32
    var stdout: String
    var stderr: String
    /// More than the cap was written; the text holds the end of the output.
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

    var extraPath: [String]
    private let sink: ScriptOutputSink
    private let environment: [String: String]
    private let log: @Sendable (String) -> Void
    private var running: [ObjectIdentifier: ProcessCapture] = [:]

    init(
        sink: ScriptOutputSink,
        extraPath: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: @escaping @Sendable (String) -> Void = { Log.main($0) }
    ) {
        self.sink = sink
        self.extraPath = extraPath
        self.environment = environment
        self.log = log
    }

    var runningCount: Int { running.count }

    /// Starts the program and, when it exits, shows its output. The app doesn't await
    /// this; tests do.
    @discardableResult
    func run(_ invocation: ScriptInvocation, arguments: [String] = []) async -> ScriptRunResult {
        let launch = launchSpec(for: invocation, arguments: arguments)
        let capture = ProcessCapture(launch: launch, cap: Self.outputCap)
        let key = ObjectIdentifier(capture)
        running[key] = capture
        let started = Date()
        let result = await capture.run()
        running[key] = nil

        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        log("launcher: \(invocation.title) exited \(result.exitCode) after \(milliseconds) ms, stdout \(result.stdout.utf8.count) B, stderr \(result.stderr.utf8.count) B")
        present(result, for: invocation)
        return result
    }

    /// Sends SIGTERM to every running script.
    func terminateAll() {
        for capture in running.values {
            capture.terminate()
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

    private func present(_ result: ScriptRunResult, for invocation: ScriptInvocation) {
        switch invocation.mode {
        case .fullOutput:
            sink.showOutput(title: invocation.title, body: Self.fullOutputBody(result))
        case .silent, .compact, .inline:
            if result.exitCode == 0 {
                if let line = Self.lastLine(of: result.stdout) {
                    sink.flash(Self.pillText(line), isError: false)
                }
            } else {
                let line = Self.lastLine(of: result.stderr)
                    ?? Self.lastLine(of: result.stdout)
                    ?? "\(invocation.title) failed (exit \(result.exitCode))"
                sink.flash(Self.pillText(line), isError: true)
            }
        }
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
    private var buffers: [TailBuffer]
    private var closedStreams: Set<Int> = []
    private var exited = false
    private var finished = false
    private var continuation: CheckedContinuation<ScriptRunResult, Never>?

    init(launch: Launch, cap: Int) {
        self.launch = launch
        buffers = [TailBuffer(cap: cap), TailBuffer(cap: cap)]
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

/// Keeps the last `cap` bytes of a stream, so the final line is always there.
struct TailBuffer {
    let cap: Int
    private var data = Data()
    private var dropped = false

    init(cap: Int) {
        self.cap = cap
    }

    mutating func append(_ chunk: Data) {
        data.append(chunk)
        if data.count > cap * 2 {
            data = Data(data.suffix(cap))
            dropped = true
        }
    }

    /// Lossy UTF-8. When the start was cut, the partial first line is dropped too.
    func text() -> (text: String, truncated: Bool) {
        let truncated = dropped || data.count > cap
        var bytes = data.count > cap ? Data(data.suffix(cap)) : data
        if truncated, let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
            bytes = Data(bytes[bytes.index(after: newline)...])
        }
        return (String(decoding: bytes, as: UTF8.self), truncated)
    }
}
