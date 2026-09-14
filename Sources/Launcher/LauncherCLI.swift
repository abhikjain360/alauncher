import Calc
import Core
import Foundation
import Search

/// `alauncher search|calc|index`, for checking the launcher from a terminal. It
/// shows no UI, runs nothing, records no launches and stays off the network:
/// currency conversions use the cached rates.
public enum LauncherCLI {
    /// `search <query>` prints ranked rows with scores (the calculator row first, if any);
    /// `calc <expr>` prints the calculator outcome; `index` lists every item with its id.
    public static func run(_ arguments: [String], config: Config) async -> Int32 {
        run(arguments, context: .live(config: config))
    }

    struct Context {
        var catalog: () -> Catalog
        var frecency: FrecencyStore
        var frecencyWeight = 1.0
        var calculator: @Sendable (String) -> CalcOutcome
        /// `calculator.enabled`: whether `search` shows the calculator row. `calc` always evaluates.
        var calculatorEnabled = true
        var maxResults = 8
        var now: () -> Date = { Date() }
        var out: (String) -> Void = { print($0) }
        var err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

        static func live(config: Config) -> Context {
            let settings = config.launcher
            let calculator = Calculator(rates: LauncherController.makeRates(config.calculator))
            return Context(
                catalog: { CatalogBuilder.scan(settings: settings, builtIns: []) },
                frecency: LauncherController.makeFrecency(settings.ranking),
                frecencyWeight: settings.ranking.frecencyWeight,
                calculator: { calculator.evaluate($0) },
                calculatorEnabled: config.calculator.enabled,
                maxResults: settings.maxResults
            )
        }
    }

    static func run(_ arguments: [String], context: Context) -> Int32 {
        guard let command = arguments.first else {
            printUsage(context)
            return 2
        }
        let rest = arguments.dropFirst().joined(separator: " ")
        switch command {
        case "search":
            return search(rest, context: context)
        case "calc":
            return calculate(rest, context: context)
        case "index":
            return index(context: context)
        default:
            printUsage(context)
            return 2
        }
    }

    private static func search(_ query: String, context: Context) -> Int32 {
        let catalog = context.catalog()
        let builder = ResultBuilder(
            ranker: Ranker(frecency: context.frecency, frecencyWeight: context.frecencyWeight),
            calculate: context.calculatorEnabled ? context.calculator : nil,
            maxResults: context.maxResults
        )
        // An emoji search parses the index first, timed on its own.
        var emoji: (index: EmojiIndex, milliseconds: Double)?
        if ResultBuilder.emojiQuery(query, in: catalog) != nil {
            let start = DispatchTime.now().uptimeNanoseconds
            let index = EmojiIndex.load()
            emoji = (index, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let rows = builder.rows(for: query, in: catalog, now: context.now(), emojiIndex: { emoji?.index ?? EmojiIndex.load() })
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        for row in rows {
            context.out(line(for: row))
        }
        if let emoji {
            context.err(String(
                format: "# %d rows from %d emoji in %.2f ms, after parsing them in %.2f ms",
                rows.count, emoji.index.entries.count, milliseconds, emoji.milliseconds
            ))
        } else {
            context.err(String(format: "# %d rows from %d items in %.2f ms", rows.count, catalog.items.count, milliseconds))
        }
        return 0
    }

    private static func calculate(_ expression: String, context: Context) -> Int32 {
        let input = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            printUsage(context)
            return 2
        }
        switch context.calculator(input) {
        case .result(let result):
            context.out(result.display)
            if let detail = result.detail, !detail.isEmpty { context.out(detail) }
            if result.copyText != result.display { context.out("copy: \(result.copyText)") }
            return 0
        case .error(let message):
            context.out("error: \(message)")
            return 1
        case .incomplete:
            context.out("incomplete")
            return 1
        case .notACalculation:
            context.out("not a calculation")
            return 1
        }
    }

    private static func index(context: Context) -> Int32 {
        let start = DispatchTime.now().uptimeNanoseconds
        let catalog = context.catalog()
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        for item in catalog.items {
            var line = "\(item.id)\t\(item.title)"
            if !item.aliases.isEmpty { line += "\taliases: \(item.aliases.joined(separator: ", "))" }
            if let count = item.argumentCount { line += "\targs: \(count > 0 ? String(count) : "inline")" }
            if case .command(let command)? = catalog.entry(for: item.id)?.action, command.choices { line += "\tchoices" }
            context.out(line)
        }
        let counts = Dictionary(grouping: catalog.items, by: \.kind).mapValues(\.count)
        let summary = [(SearchItem.Kind.app, "app"), (.script, "script"), (.command, "command")]
            .map { kind, noun -> String in
                let count = counts[kind] ?? 0
                return "\(count) \(noun)\(count == 1 ? "" : "s")"
            }
            .joined(separator: ", ")
        context.err("# \(catalog.items.count) items (\(summary)), scanned in \(String(format: "%.1f", milliseconds)) ms")
        return 0
    }

    static func line(for row: LauncherRow) -> String {
        switch row.content {
        case .calculation(let result):
            var line = "= \(result.display)"
            if let detail = result.detail, !detail.isEmpty { line += "  (\(detail))" }
            if result.copyText != result.display { line += "  copy: \(result.copyText)" }
            return line
        case .calculationError(let message):
            return "= error: \(message)"
        case .item(let ranked):
            let kind = ranked.item.kind.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
            var line = String(format: "%8.1f", ranked.score) + "  \(kind)  \(row.title)  \(ranked.item.id)"
            if let arguments = ranked.arguments {
                line += "  args: " + arguments.map { "\"\($0)\"" }.joined(separator: ", ")
            }
            return line
        case .choice(let choice):
            return "  \(choice.title)"
        case .pick:
            return "  \(row.title)"
        case .emoji(let match):
            let line = String(format: "%8.1f", match.score) + "  emoji    \(match.entry.emoji) \(row.title)"
            return match.matchedKeyword.map { line + "  (\($0))" } ?? line
        }
    }

    private static func printUsage(_ context: Context) {
        context.err("""
            usage: alauncher search <query>   ranked rows with scores, the calculator row first
                   alauncher calc <expression>
                   alauncher index            every item with its id
            """)
    }
}
