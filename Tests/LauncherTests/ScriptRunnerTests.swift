import Core
import Foundation
import Search
import Testing
@testable import Launcher

/// Records what would have gone to the pill or the text panel.
@MainActor
final class RecordingSink: ScriptOutputSink {
    var flashes: [(text: String, isError: Bool)] = []
    var outputs: [(title: String, body: String)] = []

    func flash(_ text: String, isError: Bool) {
        flashes.append((text, isError))
    }

    func showOutput(title: String, body: String) {
        outputs.append((title, body))
    }
}

/// Every script here is a temporary file written by the test itself.
@MainActor
struct ScriptRunnerTests {
    private let dir: TemporaryDirectory
    private let sink = RecordingSink()

    init() throws {
        dir = try TemporaryDirectory()
    }

    private func runner(extraPath: [String] = [], environment: [String: String] = ProcessInfo.processInfo.environment) -> ScriptRunner {
        ScriptRunner(sink: sink, extraPath: extraPath, environment: environment, log: { _ in })
    }

    private func script(
        _ name: String,
        _ body: String,
        mode: ScriptCommand.Mode = .compact,
        executable: Bool = true,
        arguments: [ScriptCommand.Argument] = []
    ) throws -> ScriptCommand {
        let url = try dir.write(name, body, executable: executable)
        return ScriptCommand(path: url, title: name, mode: mode, arguments: arguments)
    }

    @Test("silent and compact flash the last stdout line; inline behaves like compact")
    func pillModes() async throws {
        for mode in [ScriptCommand.Mode.silent, .compact, .inline] {
            let script = try script("say-\(mode.rawValue).sh", "#!/bin/sh\necho first\necho '  last line  '\necho\n", mode: mode)
            let result = await runner().run(ScriptInvocation(script: script))
            #expect(result.exitCode == 0)
        }
        #expect(sink.flashes.map(\.text) == ["last line", "last line", "last line"])
        #expect(sink.flashes.allSatisfy { !$0.isError })
        #expect(sink.outputs.isEmpty)
    }

    @Test("a script with no output shows nothing")
    func quietScript() async throws {
        let script = try script("quiet.sh", "#!/bin/sh\ntrue\n", mode: .silent)
        await runner().run(ScriptInvocation(script: script))
        #expect(sink.flashes.isEmpty)
        #expect(sink.outputs.isEmpty)
    }

    @Test("fullOutput opens the text panel with stdout and stderr")
    func fullOutputMode() async throws {
        let script = try script("report.sh", "#!/bin/sh\necho one\necho two\necho warning >&2\n", mode: .fullOutput)
        await runner().run(ScriptInvocation(script: script))
        #expect(sink.flashes.isEmpty)
        #expect(sink.outputs.count == 1)
        #expect(sink.outputs.first?.title == "report.sh")
        #expect(sink.outputs.first?.body == "one\ntwo\n\nwarning")
    }

    @Test("a non-zero exit flashes the last stderr line as an error")
    func nonZeroExit() async throws {
        let failing = try script("fail.sh", "#!/bin/sh\necho progress\necho 'first problem' >&2\necho 'real problem' >&2\nexit 3\n")
        let result = await runner().run(ScriptInvocation(script: failing))
        #expect(result.exitCode == 3)
        #expect(result.stdout == "progress\n")
        #expect(sink.flashes.count == 1)
        #expect(sink.flashes.first?.text == "real problem")
        #expect(sink.flashes.first?.isError == true)

        let silentFailure = try script("silent-fail.sh", "#!/bin/sh\nexit 4\n", mode: .silent)
        await runner().run(ScriptInvocation(script: silentFailure))
        #expect(sink.flashes.last?.text == "silent-fail.sh failed (exit 4)")
        #expect(sink.flashes.last?.isError == true)

        let report = try script("fail-report.sh", "#!/bin/sh\necho partial\nexit 2\n", mode: .fullOutput)
        await runner().run(ScriptInvocation(script: report))
        #expect(sink.outputs.last?.body == "partial\n\n[exit status 2]")
    }

    @Test("arguments are passed in order, percent-encoded where the header says so")
    func argumentsAndEncoding() async throws {
        let specs = [
            ScriptCommand.Argument(type: "text", placeholder: "Query", percentEncoded: true),
            ScriptCommand.Argument(type: "text", placeholder: "Raw", optional: true),
        ]
        let script = try script("args.sh", "#!/bin/sh\nfor a in \"$@\"; do echo \"[$a]\"; done\n", mode: .silent, arguments: specs)
        let result = await runner().run(ScriptInvocation(script: script), arguments: ["a b&c/é?", "x y"])
        #expect(result.stdout == "[a%20b%26c%2F%C3%A9%3F]\n[x y]\n")

        let empty = await runner().run(ScriptInvocation(script: script), arguments: ["q", ""])
        #expect(empty.stdout == "[q]\n[]\n")
    }

    @Test("a config command runs through sh with the inline text as $1")
    func commandArgument() async throws {
        let command = CommandSettings(title: "Echo", run: "echo \"got $1\"", mode: "compact")
        let result = await runner().run(ScriptInvocation(command: command), arguments: ["hello world"])
        #expect(result.stdout == "got hello world\n")
        #expect(sink.flashes.first?.text == "got hello world")
    }

    @Test("PATH is the expanded extra_path in front of the inherited PATH")
    func extraPath() async throws {
        let script = try script("path.sh", "#!/bin/sh\necho \"$PATH\"\n")
        let environment = ["PATH": "/usr/bin:/bin", "USER": "tester"]
        let result = await runner(extraPath: ["~/tools", "/opt/$USER/bin", "/usr/bin"], environment: environment)
            .run(ScriptInvocation(script: script))
        #expect(result.stdout == "\(NSHomeDirectory())/tools:/opt/tester/bin:/usr/bin:/bin\n")
    }

    @Test("the working folder is currentDirectoryPath, or else the script's own folder")
    func workingDirectory() async throws {
        var script = try script("pwd.sh", "#!/bin/sh\npwd -P\n")
        let first = await runner().run(ScriptInvocation(script: script))
        #expect(first.stdout == realPath(dir.path) + "\n")

        let elsewhere = try dir.makeFolder("elsewhere")
        script.currentDirectoryPath = elsewhere
        let second = await runner().run(ScriptInvocation(script: script))
        #expect(second.stdout == realPath(elsewhere) + "\n")

        script.currentDirectoryPath = dir.path + "/missing"
        let missing = await runner().run(ScriptInvocation(script: script))
        #expect(missing.launchFailed)
        #expect(missing.exitCode == 127)
        #expect(sink.flashes.last?.isError == true)
    }

    @Test("stdout is capped to its last 64 KB, keeping the final line")
    func outputCap() async throws {
        let body = "#!/bin/sh\ni=0\nwhile [ $i -lt 4000 ]; do echo \"line $i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"; i=$((i+1)); done\necho done\n"
        let script = try script("flood.sh", body)
        let result = await runner().run(ScriptInvocation(script: script))
        #expect(result.stdoutTruncated)
        #expect(!result.stderrTruncated)
        #expect(result.stdout.utf8.count <= ScriptRunner.outputCap)
        #expect(result.stdout.utf8.count > ScriptRunner.outputCap - 200)
        #expect(result.stdout.hasPrefix("line "))
        #expect(result.stdout.hasSuffix("line 3999 xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\ndone\n"))
        #expect(sink.flashes.first?.text == "done")
    }

    @Test("a file without the executable bit runs through bash")
    func nonExecutableRunsThroughBash() async throws {
        let script = try script("plain.sh", "echo \"bash ${BASH_VERSION%%.*}\"\n", executable: false)
        let result = await runner().run(ScriptInvocation(script: script))
        #expect(result.exitCode == 0)
        #expect(result.stdout.hasPrefix("bash "))
        #expect(result.stdout != "bash \n")
    }

    @Test("an executable file without a shebang falls back to bash")
    func executableWithoutShebang() async throws {
        let script = try script("noshebang.sh", "echo \"bash ${BASH_VERSION%%.*}\"\n", executable: true)
        let result = await runner().run(ScriptInvocation(script: script))
        #expect(result.exitCode == 0)
        #expect(result.stdout.hasPrefix("bash "))
        #expect(result.stdout != "bash \n")
    }

    @Test("a background child that keeps stdout open doesn't hold back the result")
    func backgroundChild() async throws {
        let script = try script("daemon.sh", "#!/bin/sh\nsleep 3 &\necho started\n")
        let start = Date()
        let result = await runner().run(ScriptInvocation(script: script))
        #expect(result.stdout == "started\n")
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("running scripts are tracked until they exit")
    func tracking() async throws {
        let script = try script("slow.sh", "#!/bin/sh\nsleep 0.5\necho ok\n")
        let runner = runner()
        let task = Task { await runner.run(ScriptInvocation(script: script)) }
        var waited = 0
        while runner.runningCount == 0, waited < 100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        #expect(runner.runningCount == 1)
        let result = await task.value
        #expect(result.stdout == "ok\n")
        #expect(runner.runningCount == 0)
    }
}
