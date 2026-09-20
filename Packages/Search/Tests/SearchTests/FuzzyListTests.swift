import Foundation
import Testing
@testable import Search

struct FuzzyListTests {
    private let titles = ["Safari", "email/gmail", "work/gmail-admin", "Visual Studio Code", "Café Crème", "日本語 notes", "", "  spaced  "]

    @Test("matches score exactly as FuzzyMatcher.match does, ASCII or not, in list order")
    func parity() {
        let list = FuzzyList(titles)
        #expect(list.count == titles.count)
        for query in ["s", "gm", "gmail", "vsc", "cafe", "crème", "日本", "notes", "zz", "SAF", " sp "] {
            let expected = titles.enumerated().compactMap { index, title in
                FuzzyMatcher.match(query, in: title).map { (index: index, match: $0) }
            }
            let matches = list.matches(query)
            #expect(matches.map(\.index) == expected.map(\.index), "\(query)")
            #expect(matches.map(\.match) == expected.map(\.match), "\(query)")

            let sorted = expected.sorted { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.index < $1.index }
            #expect(list.sortedMatches(query).map(\.index) == sorted.map(\.index), "\(query)")
        }
        #expect(list.matches("").isEmpty)
        #expect(list.matches("   ").isEmpty)
        #expect(list.sortedMatches("zz").isEmpty)
    }

    @Test("equal scores keep list order")
    func ties() {
        let list = FuzzyList(["alpha one", "alpha two", "alpha three"])
        #expect(list.sortedMatches("alpha").map(\.index) == [0, 1, 2])
    }

    @Test("sorting every match of 5,000 titles per keystroke stays fast")
    func timing() {
        let list = FuzzyList((0..<5_000).map { "group\($0 % 50)/entry-\($0)" })
        let keystrokes = ["g", "gr", "gro", "group1", "group1/e", "entry-4", "e4", "zz"]
        for query in keystrokes { _ = list.sortedMatches(query) }

        let rounds = 5
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<rounds {
            for query in keystrokes { _ = list.sortedMatches(query) }
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(rounds * keystrokes.count) / 1_000_000
        print(String(format: "fuzzy list: %.2f ms per keystroke over 5000 titles", milliseconds))
        // A debug build; release is several times faster.
        #expect(milliseconds < 50)
    }
}
