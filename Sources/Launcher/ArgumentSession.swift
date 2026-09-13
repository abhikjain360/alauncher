import Search

/// Argument mode: the search field collects a script's arguments one at a time.
struct ArgumentSession: Sendable {
    enum Step: Equatable, Sendable {
        /// Moved on to the next argument.
        case next
        /// Every argument is in: run with these values.
        case run([String])
        /// The current argument is required and still empty.
        case rejected
    }

    let entryID: String
    let title: String
    let specs: [ScriptCommand.Argument]
    private(set) var values: [String]
    private(set) var index: Int
    /// The query before argument mode, which Esc puts back.
    let previousQuery: String
    /// Set after the last argument of a `needsConfirmation` script: the next Enter runs it.
    var awaitingConfirmation = false

    /// `prefilled` holds arguments already typed inline; entry starts at the first missing one.
    init(entryID: String, title: String, specs: [ScriptCommand.Argument], prefilled: [String] = [], previousQuery: String = "") {
        let specs = specs.isEmpty ? [Self.undeclaredArgument] : specs
        self.entryID = entryID
        self.title = title
        self.specs = specs
        self.previousQuery = previousQuery
        values = specs.indices.map { $0 < prefilled.count ? prefilled[$0] : "" }
        index = min(prefilled.count, specs.count - 1)
    }

    var current: ScriptCommand.Argument { specs[index] }
    var currentValue: String { values[index] }
    var isLast: Bool { index == specs.count - 1 }

    /// The field's placeholder for the current argument.
    var placeholder: String {
        let base = current.placeholder.isEmpty ? "Argument \(index + 1)" : current.placeholder
        return current.optional ? "\(base) (optional)" : base
    }

    /// Enter: stores `text`, then moves to the next argument or finishes.
    mutating func submit(_ text: String) -> Step {
        if text.isEmpty && !current.optional { return .rejected }
        values[index] = text
        guard isLast else {
            index += 1
            return .next
        }
        return .run(values)
    }

    /// Tab: stores `text` and moves to the next argument without running. False on the last.
    mutating func moveForward(keeping text: String) -> Bool {
        values[index] = text
        guard !isLast else { return false }
        index += 1
        return true
    }

    /// Shift-Tab: stores `text` and moves back. False on the first.
    mutating func moveBack(keeping text: String) -> Bool {
        values[index] = text
        guard index > 0 else { return false }
        index -= 1
        return true
    }

    /// The arguments to prompt for: a script's declared ones, or a single optional
    /// one for a script or command that doesn't declare any (it gets the text as `$1`).
    /// Nil for items that take no arguments.
    static func specs(for action: ItemAction) -> [ScriptCommand.Argument]? {
        switch action {
        case .script(let script):
            return script.arguments.isEmpty ? [undeclaredArgument] : script.arguments
        case .command:
            return [undeclaredArgument]
        case .app, .builtIn, .emojiSearch:
            return nil
        }
    }

    static let undeclaredArgument = ScriptCommand.Argument(type: "text", placeholder: "Argument", optional: true)
}
