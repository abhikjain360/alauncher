import Core
import Foundation
import Search
import Testing
@testable import Launcher

struct CLITests {
    private final class Output {
        var out: [String] = []
        var err: [String] = []
    }

    private func context(_ output: Output, frecency: FrecencyStore = FrecencyStore(fileURL: nil)) -> LauncherCLI.Context {
        LauncherCLI.Context(
            catalog: { Fixture.catalog() },
            frecency: frecency,
            calculator: fakeCalculate,
            now: { Fixture.now },
            out: { output.out.append($0) },
            err: { output.err.append($0) }
        )
    }

    @Test("search prints the calculator row first, then ranked rows with scores and ids")
    func searchOutput() throws {
        let output = Output()
        #expect(LauncherCLI.run(["search", "c"], context: context(output)) == 0)
        #expect(output.out.first == "= 299,792,458  copy: 299792458")
        #expect(output.out.count == 8)
        #expect(!output.out.contains { $0.contains("Safari") })
        let calculator = try #require(output.out.first { $0.contains("Calculator") })
        #expect(calculator.hasSuffix("  app      Calculator  app:/System/Applications/Calculator.app"))
        let score = try #require(Double(calculator.prefix(8).trimmingCharacters(in: .whitespaces)))
        #expect(score > 400)
        #expect(output.err.last?.hasPrefix("# 8 rows from 8 items in") == true)
    }

    @Test("search shows inline arguments and the empty query's frecent rows")
    func searchInlineAndEmpty() {
        let output = Output()
        #expect(LauncherCLI.run(["search", "gh", "swift", "testing"], context: context(output)) == 0)
        #expect(output.out.first?.contains("  script   GitHub Search — swift testing  script:/scripts/github.sh  args: \"swift testing\"") == true)

        let frecency = FrecencyStore(fileURL: nil)
        frecency.recordLaunch(of: "command:Lock screen", now: Fixture.now)
        let empty = Output()
        #expect(LauncherCLI.run(["search"], context: context(empty, frecency: frecency)) == 0)
        #expect(empty.out == ["     4.0  command  Lock screen  command:Lock screen"])
    }

    @Test("search lists emoji for `emoji <text>`, with the keyword that matched")
    func searchEmoji() throws {
        let output = Output()
        #expect(LauncherCLI.run(["search", "emoji", "tada"], context: context(output)) == 0)
        let first = try #require(output.out.first)
        #expect(first.hasSuffix("  emoji    🎉 Party popper  (tada)"))
        let score = try #require(Double(first.prefix(8).trimmingCharacters(in: .whitespaces)))
        #expect(score > 0)
        #expect(output.err.last?.contains(" emoji in ") == true)
    }

    @Test("calc prints the outcome, and fails when it isn't a result")
    func calcOutput() {
        let result = Output()
        #expect(LauncherCLI.run(["calc", "0xff", "+", "1"], context: context(result)) == 0)
        #expect(result.out == ["256", "0x100 · 0b100000000 · 0o400"])

        let grouped = Output()
        #expect(LauncherCLI.run(["calc", "c"], context: context(grouped)) == 0)
        #expect(grouped.out == ["299,792,458", "copy: 299792458"])

        for (input, expected) in [("1/0", "error: division by zero"), ("2 +", "incomplete"), ("hello", "not a calculation")] {
            let output = Output()
            #expect(LauncherCLI.run(["calc", input], context: context(output)) == 1)
            #expect(output.out == [expected])
        }

        let usage = Output()
        #expect(LauncherCLI.run(["calc"], context: context(usage)) == 2)
        #expect(usage.err.first?.hasPrefix("usage:") == true)
    }

    @Test("index lists every item with its id, aliases and arguments")
    func indexOutput() {
        let output = Output()
        #expect(LauncherCLI.run(["index"], context: context(output)) == 0)
        #expect(output.out.count == Fixture.catalog().items.count)
        #expect(output.out.contains("app:/Applications/Safari.app\tSafari"))
        #expect(output.out.contains("script:/scripts/github.sh\tGitHub Search\taliases: gh\targs: 1"))
        #expect(output.out.contains("script:/scripts/pass-choose.sh\tPass\targs: inline"))
        #expect(output.out.contains("command:Lock screen\tLock screen\taliases: lock\targs: inline"))
        #expect(output.out.contains("emoji-search\tSearch emoji\taliases: emoji\targs: inline"))
        #expect(output.err.last?.hasPrefix("# 8 items (4 apps, 2 scripts, 2 commands), scanned in") == true)
    }

    @Test("an unknown or missing subcommand prints usage")
    func usage() {
        for arguments in [["frobnicate"], []] {
            let output = Output()
            #expect(LauncherCLI.run(arguments, context: context(output)) == 2)
            #expect(output.out.isEmpty)
            #expect(output.err.first?.hasPrefix("usage:") == true)
        }
    }

    @Test("the public entry point indexes the configured folders")
    func liveIndex() async throws {
        let dir = try TemporaryDirectory()
        try dir.makeApp("Apps/Fixture Tool.app", bundleID: "test.alauncher.fixture")
        try dir.write("Scripts/hello.sh", "#!/bin/sh\n# @raycast.title Hello Fixture\n# @raycast.mode compact\n# @alauncher.alias hf\necho hi\n", executable: true)
        try dir.write("Scripts/notes.txt", "no header here\n")
        var config = Config()
        config.launcher.appDirs = [dir.path + "/Apps"]
        config.launcher.scriptDirs = [dir.path + "/Scripts"]
        config.launcher.commands = [CommandSettings(title: "Say", run: "say hi")]

        let status = await LauncherCLI.run(["index"], config: config)
        #expect(status == 0)
        let catalog = CatalogBuilder.scan(settings: config.launcher, builtIns: [])
        #expect(catalog.items.map(\.id) == [
            "app:\(dir.path)/Apps/Fixture Tool.app",
            "app:\(AppIndex.finderPath)",
            "script:\(dir.path)/Scripts/hello.sh",
            "command:Say",
            "emoji-search",
        ])
        #expect(catalog.entry(for: "script:\(dir.path)/Scripts/hello.sh")?.item.aliases == ["hf"])
    }
}
