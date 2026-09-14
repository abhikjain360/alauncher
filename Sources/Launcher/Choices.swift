import Foundation
import Search

// The choices protocol, for `[[launcher.commands]]` with `choices = true`. Every run prints one
// JSON object: another list to pick from, or the final text. Picking an item runs the command
// again with the list's id as $1 and the item's value as $2, so a script keeps its state in the id.

/// One item to pick.
struct ChoicesItem: Equatable, Sendable {
    var title: String
    var subtitle: String?
    /// Handed back as `$2` when picked: the title, unless the item says otherwise.
    var value: String
}

/// One list to pick from.
struct ChoicesRound: Sendable {
    let id: String
    let placeholder: String?
    let items: [ChoicesItem]
    /// The titles, prepared once for filtering on every keystroke.
    let titles: FuzzyList
    /// What was typed in this round, put back when Esc returns to it.
    var filter = ""

    init(id: String, placeholder: String?, items: [ChoicesItem]) {
        self.id = id
        self.placeholder = placeholder
        self.items = items
        titles = FuzzyList(items.map(\.title))
    }
}

/// Why a run's output can't be used.
struct ChoicesError: Error, Equatable, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// What one run of a choices command printed.
enum ChoicesOutput {
    /// Another list to pick from.
    case round(ChoicesRound)
    /// Done: the command's `mode` decides what happens to the text.
    case final(String)
    /// Done, with nothing to show or type.
    case done

    static let expectedShape = #"expected {"items": …} or {"final": …}"#

    /// Parses one run's stdout. Errors say what's wrong with it, never what it holds, which may
    /// be a secret.
    static func parse(_ stdout: String) throws -> ChoicesOutput {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .done }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw ChoicesError(expectedShape)
        }
        switch (object["final"], object["items"]) {
        case (nil, nil):
            throw ChoicesError(expectedShape)
        case (.some, .some):
            throw ChoicesError(#"has both "final" and "items""#)
        case (let final?, nil):
            guard let text = final as? String else { throw ChoicesError(#""final" must be a string"#) }
            return .final(text)
        case (nil, let items?):
            guard let list = items as? [Any] else { throw ChoicesError(#""items" must be a list"#) }
            var parsed: [ChoicesItem] = []
            parsed.reserveCapacity(list.count)
            for (index, element) in list.enumerated() {
                parsed.append(try item(element, index: index))
            }
            return .round(ChoicesRound(
                id: try optionalString(object["id"], name: "id") ?? "",
                placeholder: try optionalString(object["placeholder"], name: "placeholder"),
                items: parsed
            ))
        }
    }

    private static func item(_ element: Any, index: Int) throws -> ChoicesItem {
        if let title = element as? String {
            return ChoicesItem(title: title, subtitle: nil, value: title)
        }
        guard let fields = element as? [String: Any] else {
            throw ChoicesError(#"items[\#(index)] must be a string or {"title": …}"#)
        }
        guard let title = fields["title"] as? String else {
            throw ChoicesError(#"items[\#(index)] needs a "title" string"#)
        }
        return ChoicesItem(
            title: title,
            subtitle: try optionalString(fields["subtitle"], name: "items[\(index)].subtitle"),
            value: try optionalString(fields["value"], name: "items[\(index)].value") ?? title
        )
    }

    /// Absent and null both leave it unset.
    private static func optionalString(_ value: Any?, name: String) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw ChoicesError(#""\#(name)" must be a string"#) }
        return string
    }
}

/// A choices command's back-and-forth, while the panel shows it.
struct ChoicesSession {
    let title: String
    /// The command. Its `targetPID` is the app that was frontmost at the last Enter.
    var invocation: ScriptInvocation
    /// The query before the session, which leaving it puts back.
    let previousQuery: String
    /// The rounds shown so far, oldest first. The last is on screen unless a run is in flight.
    var rounds: [ChoicesRound] = []
    var isRunning = false
    /// The panel closed while a run was in flight: a final is still delivered, a new round dropped.
    var isClosed = false
    /// Counts runs, so that a cancelled run's late result is ignored.
    var generation = 0
}
