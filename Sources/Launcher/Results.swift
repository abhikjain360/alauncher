import Calc
import Foundation
import Search

/// One launcher row, computed from the query without touching AppKit.
struct LauncherRow: Sendable {
    enum Content: Sendable {
        /// The calculator's answer. Enter copies `copyText`.
        case calculation(CalcResult)
        /// A calculation that failed. Shown dim, and never activated.
        case calculationError(String)
        /// An app, script or command.
        case item(RankedItem)
        /// One choice of a dropdown argument, in argument mode.
        case choice(ScriptCommand.Argument.Choice)
        /// An emoji, in emoji search (`emoji <text>`). Enter types it.
        case emoji(EmojiMatch)
        /// An item of a choices command's round, by its index in the round. Enter picks it.
        case pick(Int)
    }

    var content: Content
    var title: String
    /// Character offsets in `title` drawn semibold.
    var titlePositions: [Int]
    var subtitle: String?
    /// Right-aligned: "Application", "Script", "Command" or "⏎ copy".
    var hint: String
    var icon: IconSource?
    var isEnabled: Bool

    /// Stable across index rebuilds, so a refreshed list keeps its selection.
    var id: String {
        switch content {
        case .calculation: return "calc:result"
        case .calculationError: return "calc:error"
        case .item(let ranked): return ranked.item.id
        case .choice(let choice): return "choice:\(choice.value)"
        case .emoji(let match): return EmojiIndex.frecencyID(for: match.entry.emoji)
        case .pick(let index): return "pick:\(index)"
        }
    }

    var rankedItem: RankedItem? {
        if case .item(let ranked) = content { return ranked }
        return nil
    }
}

/// Query → rows: the calculator row on top when the query is a calculation, then
/// the ranked items; or emoji, for `emoji <text>`. Runs on every keystroke.
struct ResultBuilder {
    var ranker: Ranker
    /// Nil when `calculator.enabled` is off.
    var calculate: (@Sendable (String) -> CalcOutcome)?
    /// `launcher.maxResults`, counting the calculator row.
    var maxResults: Int

    /// `emojiIndex` is only called for an emoji search, so the index loads when one starts.
    func rows(
        for query: String, in catalog: Catalog, now: Date = Date(), emojiIndex: () -> EmojiIndex = EmojiIndex.load
    ) -> [LauncherRow] {
        guard maxResults > 0 else { return [] }
        if let text = Self.emojiQuery(query, in: catalog) {
            return emojiIndex()
                .search(text, limit: maxResults, frecency: ranker.frecency, frecencyWeight: ranker.frecencyWeight, now: now)
                .map(Self.emojiRow)
        }
        var rows: [LauncherRow] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let calculate, let row = Self.calculatorRow(for: calculate(trimmed), input: trimmed) {
            rows.append(row)
        }

        let ranked = ranker.rank(query, in: catalog.items, limit: maxResults - rows.count, now: now)
        rows.reserveCapacity(rows.count + ranked.count)
        for rankedItem in ranked {
            rows.append(Self.itemRow(rankedItem, icon: catalog.entry(for: rankedItem.item.id)?.icon))
        }
        return rows
    }

    /// For `<alias> <text>` with an alias of Search emoji: the text, which may be empty. Nil for
    /// any other query, or when the item is excluded.
    static func emojiQuery(_ query: String, in catalog: Catalog) -> String? {
        guard let entry = catalog.entry(for: EmojiSearchItem.id) else { return nil }
        let text = query.drop(while: \.isWhitespace)
        guard let separator = text.firstIndex(where: \.isWhitespace) else { return nil }
        let word = FuzzyMatcher.normalizedKey(String(text[..<separator]))
        guard !word.isEmpty, entry.item.aliases.contains(where: { FuzzyMatcher.normalizedKey($0) == word }) else {
            return nil
        }
        return String(text[text.index(after: separator)...])
    }

    static func emojiRow(_ match: EmojiMatch) -> LauncherRow {
        LauncherRow(
            content: .emoji(match),
            title: sentenceCased(match.entry.name),
            titlePositions: match.titlePositions,
            subtitle: match.matchedKeyword,
            hint: "",
            icon: nil,
            isEnabled: true
        )
    }

    /// "Party popper". Only when the capital is one character, so the highlight offsets still hold.
    static func sentenceCased(_ name: String) -> String {
        guard let first = name.first else { return name }
        let capital = String(first).uppercased()
        return capital.count == 1 ? capital + name.dropFirst() : name
    }

    static func calculatorRow(for outcome: CalcOutcome, input: String) -> LauncherRow? {
        switch outcome {
        case .result(let result):
            let detail = result.detail.flatMap { $0.isEmpty ? nil : $0 }
            return LauncherRow(
                content: .calculation(result),
                title: result.display,
                titlePositions: [],
                subtitle: detail ?? input,
                hint: "⏎ copy",
                icon: .calculator,
                isEnabled: true
            )
        case .error(let message):
            return LauncherRow(
                content: .calculationError(message),
                title: message,
                titlePositions: [],
                subtitle: nil,
                hint: "",
                icon: .calculator,
                isEnabled: false
            )
        case .incomplete, .notACalculation:
            return nil
        }
    }

    static func itemRow(_ ranked: RankedItem, icon: IconSource?) -> LauncherRow {
        let item = ranked.item
        var title = item.title
        var positions = ranked.titlePositions
        if let arguments = ranked.arguments {
            title += " — " + arguments.joined(separator: " · ")
            positions = []
        }
        return LauncherRow(
            content: .item(ranked),
            title: title,
            titlePositions: positions,
            subtitle: item.subtitle,
            hint: hint(for: item.kind),
            icon: icon,
            isEnabled: true
        )
    }

    static func hint(for kind: SearchItem.Kind) -> String {
        switch kind {
        case .app: return "Application"
        case .script: return "Script"
        case .command: return "Command"
        }
    }

    /// A dropdown argument's choices, fuzzy-filtered by what's typed; all of them,
    /// in declared order, when nothing is.
    static func choiceRows(
        _ choices: [ScriptCommand.Argument.Choice],
        query: String,
        limit: Int
    ) -> [LauncherRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches: [(offset: Int, score: Double, positions: [Int])] = []
        for (offset, choice) in choices.enumerated() {
            if trimmed.isEmpty {
                matches.append((offset, 0, []))
            } else if let match = FuzzyMatcher.match(trimmed, in: choice.title) {
                matches.append((offset, match.score, match.positions))
            }
        }
        matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
        return matches.prefix(max(0, limit)).map { match in
            let choice = choices[match.offset]
            return LauncherRow(
                content: .choice(choice),
                title: choice.title,
                titlePositions: match.positions,
                subtitle: nil,
                hint: "",
                icon: nil,
                isEnabled: true
            )
        }
    }

    /// A choices round's items, fuzzy-filtered by what's typed, best first; all of them, in
    /// order, when nothing is.
    static func pickRows(_ round: ChoicesRound, query: String, limit: Int) -> [LauncherRow] {
        let limit = max(0, limit)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: [(index: Int, match: FuzzyMatch)] = trimmed.isEmpty
            ? round.items.indices.prefix(limit).map { (index: $0, match: FuzzyMatch(score: 0, positions: [])) }
            : round.titles.best(trimmed, limit: limit)
        return matches.map { found in
            let item = round.items[found.index]
            return LauncherRow(
                content: .pick(found.index),
                title: item.title,
                titlePositions: found.match.positions,
                subtitle: item.subtitle,
                hint: "",
                icon: nil,
                isEnabled: true
            )
        }
    }
}
