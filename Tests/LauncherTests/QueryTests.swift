import Calc
import Core
import Foundation
import Search
import Testing
@testable import Launcher

/// Stands in for Calc, so these tests don't depend on its answers.
let fakeCalculate: @Sendable (String) -> CalcOutcome = { input in
    switch input {
    case "2+2": return .result(CalcResult(display: "4", copyText: "4"))
    case "0xff + 1": return .result(CalcResult(display: "256", copyText: "256", detail: "0x100 · 0b100000000 · 0o400"))
    case "c": return .result(CalcResult(display: "299,792,458", copyText: "299792458"))
    case "1/0": return .error("division by zero")
    case "2 +": return .incomplete
    default: return .notACalculation
    }
}

enum Fixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let apps = [
        app("/Applications/Safari.app", "Safari", "com.apple.Safari"),
        app("/System/Applications/Calculator.app", "Calculator", "com.apple.calculator"),
        app("/System/Applications/Chess.app", "Chess", "com.apple.Chess"),
        app("/Applications/Visual Studio Code.app", "Visual Studio Code", "com.microsoft.VSCode", keywords: ["Code"]),
    ]

    static let scripts = [
        ScriptCommand(
            path: URL(fileURLWithPath: "/scripts/github.sh"),
            title: "GitHub Search",
            mode: .silent,
            packageName: "Web",
            arguments: [.init(type: "text", placeholder: "Query", percentEncoded: true)],
            aliases: ["gh"]
        ),
        ScriptCommand(path: URL(fileURLWithPath: "/scripts/pass-choose.sh"), title: "Pass", mode: .silent, icon: "🔐"),
    ]

    static let commands = [CommandSettings(title: "Lock screen", run: "pmset displaysleepnow", aliases: ["lock"])]

    static func app(_ path: String, _ title: String, _ bundleID: String, keywords: [String] = []) -> AppEntry {
        AppEntry(path: path, resolvedPath: path, title: title, keywords: keywords, bundleID: bundleID)
    }

    static func catalog(_ settings: LauncherSettings = LauncherSettings(), builtIns: [BuiltInCommand] = []) -> Catalog {
        CatalogBuilder.build(apps: apps, scripts: scripts, commands: commands, builtIns: builtIns, settings: settings)
    }

    static func builder(
        _ frecency: FrecencyStore = FrecencyStore(fileURL: nil),
        maxResults: Int = 8,
        calculate: (@Sendable (String) -> CalcOutcome)? = fakeCalculate
    ) -> ResultBuilder {
        ResultBuilder(ranker: Ranker(frecency: frecency), calculate: calculate, maxResults: maxResults)
    }
}

struct QueryTests {
    private let now = Fixture.now

    private func rows(_ query: String, _ catalog: Catalog = Fixture.catalog(), builder: ResultBuilder = Fixture.builder()) -> [LauncherRow] {
        builder.rows(for: query, in: catalog, now: now)
    }

    @Test("a calculation's row goes on top; errors are dim; incomplete input shows no row")
    func calculatorRow() throws {
        let first = try #require(rows("2+2").first)
        guard case .calculation(let result) = first.content else {
            Issue.record("expected the calculator row first")
            return
        }
        #expect(result.copyText == "4")
        #expect(first.title == "4")
        #expect(first.subtitle == "2+2")
        #expect(first.hint == "⏎ copy")
        #expect(first.icon == .calculator)
        #expect(first.isEnabled)

        #expect(rows("0xff + 1").first?.subtitle == "0x100 · 0b100000000 · 0o400")

        let error = try #require(rows("1/0").first)
        #expect(error.title == "division by zero")
        #expect(error.id == "calc:error")
        #expect(!error.isEnabled)

        #expect(rows("2 +").isEmpty)
        #expect(rows("2+2", builder: Fixture.builder(calculate: nil)).isEmpty)
    }

    @Test("the calculator row comes before matching items and counts toward max_results")
    func calculatorRowWithItems() {
        let result = rows("c", builder: Fixture.builder(maxResults: 3))
        #expect(result.count == 3)
        #expect(result.first?.id == "calc:result")
        #expect(result.dropFirst().allSatisfy { $0.rankedItem != nil })
    }

    @Test("`<alias> <text>` puts the script first, with its arguments in the title")
    func inlineArguments() throws {
        let result = rows("gh swift testing")
        let first = try #require(result.first)
        #expect(first.rankedItem?.item.title == "GitHub Search")
        #expect(first.rankedItem?.arguments == ["swift testing"])
        #expect(first.title == "GitHub Search — swift testing")
        #expect(first.titlePositions.isEmpty)
        #expect(first.hint == "Script")
    }

    @Test("a script without declared arguments still takes inline text, through a config alias")
    func inlineArgumentForUndeclaredScript() throws {
        var settings = LauncherSettings()
        settings.aliases = ["visual studio code": ["vsc"], "Pass": ["pw"]]
        let catalog = Fixture.catalog(settings)
        #expect(rows("vsc", catalog).first?.title == "Visual Studio Code")

        let first = try #require(rows("pw work/email", catalog).first?.rankedItem)
        #expect(first.item.title == "Pass")
        #expect(first.arguments == ["work/email"])
    }

    @Test("the empty query lists the most frecent items and no calculator row")
    func emptyQuery() {
        let frecency = FrecencyStore(fileURL: nil)
        for _ in 0..<3 { frecency.recordLaunch(of: "app:/Applications/Safari.app", now: now) }
        frecency.recordLaunch(of: "script:/scripts/pass-choose.sh", now: now)

        let result = rows("", builder: Fixture.builder(frecency))
        #expect(result.map(\.id) == ["app:/Applications/Safari.app", "script:/scripts/pass-choose.sh"])
        #expect(rows("   ").isEmpty)
    }

    @Test("excluded items never show, by title or by path")
    func excludedItems() {
        var settings = LauncherSettings()
        settings.exclude = ["chess", "/scripts/pass-choose.sh", "Lock Screen"]
        let catalog = Fixture.catalog(settings)

        #expect(catalog.entry(for: "app:/System/Applications/Chess.app") == nil)
        #expect(rows("chess", catalog).isEmpty)
        #expect(!rows("pass", catalog).contains { $0.title == "Pass" })
        #expect(rows("lock", catalog).isEmpty)
        #expect(rows("safari", catalog).first?.title == "Safari")
    }

    @Test("built-in commands match by title and alias, and take no arguments")
    func builtInCommands() throws {
        let reload = BuiltInCommand(title: "Reload config", subtitle: "Read config.toml again", aliases: ["rc"]) {}
        let catalog = Fixture.catalog(builtIns: [reload])

        let first = try #require(rows("rc", catalog).first)
        #expect(first.id == "builtin:Reload config")
        #expect(first.title == "Reload config")
        #expect(first.subtitle == "Read config.toml again")
        #expect(first.hint == "Command")
        #expect(first.rankedItem?.item.argumentCount == nil)
        #expect(rows("reload", catalog).first?.id == "builtin:Reload config")
        #expect(rows("rc now", catalog).allSatisfy { $0.rankedItem?.arguments == nil })
    }

    @Test("rows carry kind hints, subtitles, icons and title highlights")
    func rowDetails() throws {
        let catalog = Fixture.catalog()
        let github = try #require(catalog.entry(for: "script:/scripts/github.sh"))
        #expect(github.item.subtitle == "Web")
        #expect(github.item.argumentCount == 1)
        #expect(github.item.keywords == ["github.sh"])
        #expect(github.icon == .file("/scripts/github.sh"))

        let pass = try #require(catalog.entry(for: "script:/scripts/pass-choose.sh"))
        #expect(pass.item.argumentCount == 0)
        #expect(pass.icon == .glyph("🔐"))

        let lock = try #require(catalog.entry(for: "command:Lock screen"))
        #expect(lock.item.argumentCount == 0)
        #expect(lock.item.subtitle == "pmset displaysleepnow")

        let safari = try #require(rows("saf", catalog).first)
        #expect(safari.hint == "Application")
        #expect(safari.titlePositions == [0, 1, 2])
        #expect(safari.icon == .file("/Applications/Safari.app"))
    }

    @Test("a dropdown argument's choices filter by what's typed")
    func choiceRows() {
        let choices = [
            ScriptCommand.Argument.Choice(title: "Work", value: "w"),
            ScriptCommand.Argument.Choice(title: "Personal", value: "p"),
            ScriptCommand.Argument.Choice(title: "Wiki", value: "k"),
        ]
        #expect(ResultBuilder.choiceRows(choices, query: "", limit: 8).map(\.title) == ["Work", "Personal", "Wiki"])
        #expect(ResultBuilder.choiceRows(choices, query: "wi", limit: 8).map(\.title) == ["Wiki"])
        #expect(ResultBuilder.choiceRows(choices, query: "", limit: 2).count == 2)
    }

    @Test("a keystroke turns into rows in under 5 ms with 300 items")
    func keystrokeBudget() {
        let benchmark = Fixture.benchmark()
        #expect(benchmark.catalog.items.count == 301)
        let milliseconds = Fixture.millisecondsPerKeystroke(benchmark.keystrokes) { query in
            _ = benchmark.builder.rows(for: query, in: benchmark.catalog, now: now)
        }
        print("keystroke → rows: \(String(format: "%.3f", milliseconds)) ms per keystroke, \(benchmark.catalog.items.count) items")
        #expect(milliseconds < 5)
    }

    @Test("`emoji <text>` lists matching emoji instead of items, with no calculator row")
    func emojiRows() throws {
        let hearts = rows("emoji hea")
        #expect(hearts.count == 8)
        #expect(hearts.allSatisfy { $0.isEmoji })
        let first = try #require(hearts.first)
        #expect(first.hint.isEmpty)
        #expect(first.icon == nil)
        #expect(first.title.first?.isUppercase == true)

        let party = try #require(rows("emoji tada").first)
        #expect(party.title == "Party popper")
        #expect(party.subtitle == "tada")
        #expect(party.id == "emoji:🎉")

        let heart = try #require(rows("  Emoji red hea").first)
        #expect(heart.title == "Red heart")
        #expect(heart.titlePositions == [0, 1, 2, 4, 5, 6])

        let browse = rows("emoji ")
        #expect(browse.count == 8)
        #expect(browse.first?.title == "Grinning face")
        #expect(rows("emoji").first?.id == "emoji-search")
        #expect(!rows("emoji").contains { $0.isEmoji })
        #expect(!rows("emojis hea").contains { $0.isEmoji })
    }

    @Test("excluding Search emoji turns emoji search off; its config aliases work like `emoji`")
    func emojiItemSettings() {
        var excluded = LauncherSettings()
        excluded.exclude = ["Search emoji"]
        let catalog = Fixture.catalog(excluded)
        #expect(catalog.entry(for: "emoji-search") == nil)
        #expect(!rows("emoji tada", catalog).contains { $0.isEmoji })

        var aliased = LauncherSettings()
        aliased.aliases = ["Search emoji": ["e"]]
        let withAlias = Fixture.catalog(aliased)
        #expect(withAlias.entry(for: "emoji-search")?.item.aliases == ["emoji", "e"])
        #expect(rows("e tada", withAlias).first?.title == "Party popper")
    }
}

extension LauncherRow {
    var isEmoji: Bool {
        if case .emoji = content { return true }
        return false
    }
}

extension Fixture {
    /// 301 items (290 apps with overlapping words, 10 scripts and Search emoji), some
    /// frecency, the real calculator, and a sequence of keystrokes.
    static func benchmark() -> (catalog: Catalog, builder: ResultBuilder, keystrokes: [String]) {
        let words = ["Visual", "Studio", "Code", "Safari", "Mail", "Music", "Photos", "Terminal", "Activity",
                     "Monitor", "System", "Settings", "Preview", "Notes", "Calendar", "Finder", "Xcode"]
        var apps: [AppEntry] = []
        for index in 0..<290 {
            let title = "\(words[index % words.count]) \(words[(index * 7 + 3) % words.count]) \(index)"
            apps.append(app("/Applications/App\(index).app", title, "test.app\(index)", keywords: [words[(index * 5) % words.count]]))
        }
        let scripts = (0..<10).map { index in
            ScriptCommand(path: URL(fileURLWithPath: "/scripts/s\(index).sh"), title: "Script \(words[index])", mode: .compact, aliases: ["s\(index)"])
        }
        let catalog = CatalogBuilder.build(apps: apps, scripts: scripts, commands: [], builtIns: [], settings: LauncherSettings())

        let frecency = FrecencyStore(fileURL: nil)
        for index in stride(from: 0, to: 290, by: 9) { frecency.recordLaunch(of: "app:/Applications/App\(index).app", now: now) }
        let calculator = Calculator()
        let builder = ResultBuilder(ranker: Ranker(frecency: frecency), calculate: { calculator.evaluate($0) }, maxResults: 8)
        let keystrokes = ["v", "vi", "vis", "visu", "visual", "visual s", "visual st", "s", "sa", "saf", "safa", "safar", "safari",
                          "m", "mo", "mon", "2", "2+", "2+2", "s3 hello", "x", "xc", "xco"]
        return (catalog, builder, keystrokes)
    }

    /// Runs `body` over the keystrokes once to warm up, then `rounds` more times, and
    /// returns the average per keystroke.
    static func millisecondsPerKeystroke(_ keystrokes: [String], rounds: Int = 20, _ body: (String) -> Void) -> Double {
        for query in keystrokes { body(query) }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<rounds {
            for query in keystrokes { body(query) }
        }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(rounds * keystrokes.count) / 1_000_000
    }
}
