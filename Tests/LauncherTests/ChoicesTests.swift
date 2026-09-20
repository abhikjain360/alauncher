import Foundation
import Testing
@testable import Launcher

/// The choices protocol's parser, and filtering a round's items.
struct ChoicesTests {
    private func round(_ output: String) throws -> ChoicesRound {
        guard case .round(let round) = try ChoicesOutput.parse(output) else {
            throw ChoicesError("not a round")
        }
        return round
    }

    private func final(_ output: String) throws -> String {
        guard case .final(let text) = try ChoicesOutput.parse(output) else {
            throw ChoicesError("not a final")
        }
        return text
    }

    private func error(_ output: String) -> String? {
        do {
            _ = try ChoicesOutput.parse(output)
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test("a round: strings, items with a subtitle and a value, an id and a placeholder")
    func roundShapes() throws {
        let entries = try round(#"""
            {"id": "entry", "placeholder": "Pick an entry", "items": [
              "email/gmail",
              {"title": "Work VPN", "subtitle": "work/vpn", "value": "work/vpn"},
              {"title": "Bank"},
              {"title": "Nulls", "subtitle": null, "value": null}
            ], "extra": 1}
            """#)
        #expect(entries.id == "entry")
        #expect(entries.placeholder == "Pick an entry")
        #expect(entries.items == [
            ChoicesItem(title: "email/gmail", subtitle: nil, value: "email/gmail"),
            ChoicesItem(title: "Work VPN", subtitle: "work/vpn", value: "work/vpn"),
            ChoicesItem(title: "Bank", subtitle: nil, value: "Bank"),
            ChoicesItem(title: "Nulls", subtitle: nil, value: "Nulls"),
        ])
        #expect(entries.titles.count == 4)

        let bare = try round("  \n{\"items\": []}\n")
        #expect(bare.id == "")
        #expect(bare.placeholder == nil)
        #expect(bare.items.isEmpty)
    }

    @Test("final text is taken as is; empty output is done")
    func finalAndDone() throws {
        #expect(try final(#"{"final": "hunter2 \"quoted\"\n"}"# + "\n") == "hunter2 \"quoted\"\n")
        #expect(try final(#"{"final": ""}"#) == "")
        for output in ["", "  \n\t\n"] {
            guard case .done = try ChoicesOutput.parse(output) else {
                Issue.record("not done: \(output.debugDescription)")
                continue
            }
        }
    }

    @Test("anything else is an error that says what's wrong, never what the output holds")
    func errors() {
        let shape = ChoicesOutput.expectedShape
        #expect(error("hunter2") == shape)
        #expect(error("[1, 2]") == shape)
        #expect(error(#""just a string""#) == shape)
        #expect(error("{}") == shape)
        #expect(error(#"{"id": "x"}"#) == shape)
        #expect(error(#"{"final": "a"} {"final": "b"}"#) == shape)
        #expect(error(#"{"final": "hunter2""#) == shape)
        #expect(error(#"{"final": "a", "items": []}"#) == #"has both "final" and "items""#)
        #expect(error(#"{"final": 42}"#) == #""final" must be a string"#)
        #expect(error(#"{"final": null}"#) == #""final" must be a string"#)
        #expect(error(#"{"items": "a"}"#) == #""items" must be a list"#)
        #expect(error(#"{"items": [1]}"#) == #"items[0] must be a string or {"title": …}"#)
        #expect(error(#"{"items": ["a", {"subtitle": "s"}]}"#) == #"items[1] needs a "title" string"#)
        #expect(error(#"{"items": [{"title": 1}]}"#) == #"items[0] needs a "title" string"#)
        #expect(error(#"{"items": [{"title": "a", "subtitle": 2}]}"#) == #""items[0].subtitle" must be a string"#)
        #expect(error(#"{"items": [{"title": "a", "value": false}]}"#) == #""items[0].value" must be a string"#)
        #expect(error(#"{"id": 3, "items": []}"#) == #""id" must be a string"#)
        #expect(error(#"{"placeholder": [], "items": []}"#) == #""placeholder" must be a string"#)
    }

    @Test("a round's rows: every item in order up to the limit, or fuzzy matches best first, with subtitles")
    func rows() {
        let round = ChoicesRound(id: "entry", placeholder: nil, items: [
            ChoicesItem(title: "email/gmail", subtitle: nil, value: "email/gmail"),
            ChoicesItem(title: "work/vpn", subtitle: "office", value: "work/vpn"),
            ChoicesItem(title: "bank/chase", subtitle: nil, value: "bank/chase"),
            ChoicesItem(title: "Café", subtitle: nil, value: "cafe"),
        ])
        let all = ResultBuilder.pickRows(round, query: " ", limit: 3)
        #expect(all.map(\.title) == ["email/gmail", "work/vpn", "bank/chase"])
        #expect(all.map(\.id) == ["pick:0", "pick:1", "pick:2"])
        #expect(all[1].subtitle == "office")

        let vpn = ResultBuilder.pickRows(round, query: "vpn", limit: 8)
        #expect(vpn.map(\.title) == ["work/vpn"])
        #expect(vpn.first?.titlePositions == [5, 6, 7])
        #expect(ResultBuilder.pickRows(round, query: "cafe", limit: 8).map(\.title) == ["Café"])
        #expect(ResultBuilder.pickRows(round, query: "zzz", limit: 8).isEmpty)
        #expect(ResultBuilder.pickRows(round, query: "a", limit: 0).isEmpty)
        #expect(ResultBuilder.pickRows(ChoicesRound(id: "", placeholder: nil, items: []), query: "", limit: 8).isEmpty)
    }

    @Test("filtering 5,000 items per keystroke stays fast")
    func filterTiming() {
        let items = (0..<5_000).map { ChoicesItem(title: "group\($0 % 50)/entry-\($0)", subtitle: nil, value: "\($0)") }
        let round = ChoicesRound(id: "", placeholder: nil, items: items)
        let keystrokes = ["g", "gr", "gro", "group1", "group1/e", "entry-4", "e4", "zz"]
        // The limit the launcher itself uses, since it decides how much of the list is sorted.
        let limit = LauncherController.listLimit
        for query in keystrokes { _ = ResultBuilder.pickRows(round, query: query, limit: limit) }

        let rounds = 5
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<rounds {
            for query in keystrokes { _ = ResultBuilder.pickRows(round, query: query, limit: limit) }
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(rounds * keystrokes.count) / 1_000_000
        print(String(format: "choices: %.2f ms per keystroke over %d items", milliseconds, items.count))
        // A debug build; release is several times faster.
        #expect(milliseconds < 50)
    }
}
