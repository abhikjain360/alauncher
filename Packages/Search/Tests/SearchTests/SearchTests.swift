import Foundation
import Testing
@testable import Search

struct SearchTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func item(
        _ title: String,
        id: String? = nil,
        keywords: [String] = [],
        aliases: [String] = [],
        argumentCount: Int? = nil
    ) -> SearchItem {
        SearchItem(
            id: id ?? "app:\(title)",
            title: title,
            keywords: keywords,
            aliases: aliases,
            kind: .app,
            argumentCount: argumentCount
        )
    }

    @Test("fuzzy matcher covers every tier")
    func fuzzyTiers() {
        let exact = FuzzyMatcher.match("Safari", in: "Safari")
        #expect(exact != nil)
        #expect(exact!.score >= 500 && exact!.score < 600)

        let prefix = FuzzyMatcher.match("saf", in: "Safari")
        #expect(prefix != nil)
        #expect(prefix!.score >= 400 && prefix!.score < 500)

        let word = FuzzyMatcher.match("code", in: "Visual Studio Code")
        #expect(word != nil)
        #expect(word!.score >= 300 && word!.score < 400)

        let substring = FuzzyMatcher.match("tud", in: "Visual Studio")
        #expect(substring != nil)
        #expect(substring!.score >= 200 && substring!.score < 300)

        let subsequence = FuzzyMatcher.match("acm", in: "Activity Monitor")
        #expect(subsequence != nil)
        #expect(subsequence!.score >= 100 && subsequence!.score < 200)

        #expect(FuzzyMatcher.match("xyz", in: "Safari") == nil)
    }

    @Test("fuzzy matching folds diacritics and ignores query spaces")
    func fuzzyNormalization() {
        #expect(FuzzyMatcher.match("cafe", in: "Café") != nil)
        #expect(FuzzyMatcher.match("vs code", in: "Visual Studio Code") != nil)
        #expect(FuzzyMatcher.match("visual studio code", in: "VisualStudioCode") != nil)
    }

    @Test("word starts include camel case, acronyms, and digit transitions")
    func fuzzyWordStarts() {
        let camel = FuzzyMatcher.match("term", in: "iTerm")
        #expect(camel != nil)
        #expect(camel!.score >= 300 && camel!.score < 400)
        #expect(camel!.positions == [1, 2, 3, 4])

        let acronym = FuzzyMatcher.match("vsc", in: "Visual Studio Code")
        #expect(acronym != nil)
        #expect(acronym!.score >= 300 && acronym!.score < 400)
        #expect(acronym!.positions == [0, 7, 14])

        let digits = FuzzyMatcher.match("2x", in: "Version2X")
        #expect(digits != nil)
        #expect(digits!.score >= 300 && digits!.score < 400)
        #expect(digits!.positions == [7, 8])
    }

    @Test("fuzzy positions are Character offsets in the original candidate")
    func fuzzyPositions() {
        let match = FuzzyMatcher.match("cafe", in: "Café au lait")
        #expect(match?.positions == [0, 1, 2, 3])

        let matchWithEmoji = FuzzyMatcher.match("ab", in: "🧪Ab")
        #expect(matchWithEmoji?.positions == [1, 2])
    }

    @Test("frecency uses zoxide score buckets")
    func frecencyBuckets() {
        let store = FrecencyStore(fileURL: nil)
        store.recordLaunch(of: "item", now: now)
        #expect(store.score(for: "item", now: now) == 4)
        #expect(store.score(for: "item", now: now.addingTimeInterval(60 * 60)) == 2)
        #expect(store.score(for: "item", now: now.addingTimeInterval(24 * 60 * 60)) == 0.5)
        #expect(store.score(for: "item", now: now.addingTimeInterval(7 * 24 * 60 * 60)) == 0.25)
        #expect(store.score(for: "unknown", now: now) == 0)
    }

    @Test("frecency ages at the strict threshold and drops ranks below one")
    func frecencyAging() {
        let store = FrecencyStore(fileURL: nil, maxAge: 10)
        for _ in 0..<9 { store.recordLaunch(of: "a", now: now) }
        store.recordLaunch(of: "b", now: now)
        #expect(store.score(for: "a", now: now) == 36)
        #expect(store.score(for: "b", now: now) == 4)

        store.recordLaunch(of: "a", now: now)
        #expect(abs(store.score(for: "a", now: now) - (4 * 10 * 9 / 11)) < 0.0000001)
        #expect(store.score(for: "b", now: now) == 0)

        let dropAll = FrecencyStore(fileURL: nil, maxAge: 1)
        dropAll.recordLaunch(of: "a", now: now)
        dropAll.recordLaunch(of: "b", now: now)
        #expect(dropAll.score(for: "a", now: now) == 0)
        #expect(dropAll.score(for: "b", now: now) == 0)
    }

    @Test("frecency persists and recovers from corrupt JSON")
    func frecencyPersistence() throws {
        let url = temporaryURL("frecency.json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FrecencyStore(fileURL: url)
        store.recordLaunch(of: "persisted", now: now)
        let reloaded = FrecencyStore(fileURL: url)
        #expect(reloaded.score(for: "persisted", now: now) == 4)

        try Data("not json".utf8).write(to: url, options: .atomic)
        let recovered = FrecencyStore(fileURL: url)
        #expect(recovered.score(for: "persisted", now: now) == 0)
    }

    @Test("frecency is safe for concurrent records")
    func frecencyThreadSafety() {
        let store = FrecencyStore(fileURL: nil, maxAge: 100_000)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            store.recordLaunch(of: "concurrent", now: now)
        }
        #expect(store.score(for: "concurrent", now: now) == 400)
    }

    @Test("ranking puts exact aliases first")
    func rankingAliases() {
        let store = FrecencyStore(fileURL: nil)
        let aliasItem = item("Open Slack", aliases: ["s"])
        let normalItem = item("Safari")
        let ranked = Ranker(frecency: store).rank("s", in: [normalItem, aliasItem], limit: 10, now: now)
        #expect(ranked.map(\.item.id) == [aliasItem.id, normalItem.id])
        #expect(ranked[0].titlePositions.isEmpty)
    }

    @Test("exact title matches are protected from fuzzy and frecency matches")
    func rankingExactTitle() {
        let store = FrecencyStore(fileURL: nil)
        let exact = item("Code")
        let fuzzy = item("Code Search")
        for _ in 0..<100 { store.recordLaunch(of: fuzzy.id, now: now) }
        let ranked = Ranker(frecency: store).rank("code", in: [fuzzy, exact], limit: 2, now: now)
        #expect(ranked.first?.item.id == exact.id)
        #expect(ranked.first!.score > ranked.last!.score)
    }

    @Test("ranking blends frecency with a capped bonus")
    func rankingFrecencyBonus() {
        let store = FrecencyStore(fileURL: nil)
        let exact = item("Safari")
        let scattered = item("S___a___f___a___r___i")
        for _ in 0..<1_000 { store.recordLaunch(of: scattered.id, now: now) }
        let ranked = Ranker(frecency: store).rank("safari", in: [scattered, exact], limit: 2, now: now)
        #expect(ranked.first?.item.id == exact.id)
        #expect(ranked[1].score < ranked[0].score)
        #expect(ranked[1].score - 1_000 < 200)
    }

    @Test("frecency cannot move a low-tier match past a higher tier")
    func rankingFrecencyTierCap() {
        let store = FrecencyStore(fileURL: nil)
        let lowTier = item("am q x", id: "app:low")
        let prefix = item("mxplore", id: "app:prefix")
        for _ in 0..<10_000 { store.recordLaunch(of: lowTier.id, now: now) }
        let ranked = Ranker(frecency: store).rank("mx", in: [lowTier, prefix], limit: 2, now: now)
        #expect(ranked.first?.item.id == prefix.id)
    }

    @Test("keywords match with an offset score and no title positions")
    func rankingKeywords() {
        let keywordItem = item("Launch utility", keywords: ["Safari"])
        let ranked = Ranker(frecency: FrecencyStore(fileURL: nil)).rank("safari", in: [keywordItem], limit: 1, now: now)
        #expect(ranked.count == 1)
        #expect(ranked[0].titlePositions.isEmpty)
        #expect(ranked[0].score >= 500 && ranked[0].score < 550)
    }

    @Test("empty ranking uses frecency, title, id, and limit")
    func rankingEmptyQuery() {
        let store = FrecencyStore(fileURL: nil)
        let beta = item("Beta", id: "app:b")
        let alpha = item("Alpha", id: "app:a")
        let zero = item("Zero", id: "app:z")
        store.recordLaunch(of: beta.id, now: now)
        store.recordLaunch(of: alpha.id, now: now)
        let ranked = Ranker(frecency: store).rank("   ", in: [beta, zero, alpha], limit: 2, now: now)
        #expect(ranked.map(\.item.title) == ["Alpha", "Beta"])
    }

    @Test("ranking ties are deterministic by title and id")
    func rankingTies() {
        let store = FrecencyStore(fileURL: nil)
        let z = item("Same", id: "app:z")
        let a = item("same", id: "app:a")
        let ranked = Ranker(frecency: store).rank("same", in: [z, a], limit: 2, now: now)
        #expect(ranked.map(\.item.id) == [a.id, z.id])
    }

    @Test("inline invocation is checked before ordinary ranking")
    func rankingInlineInvocation() {
        let store = FrecencyStore(fileURL: nil)
        let github = item("GitHub Search", aliases: ["gh"], argumentCount: 1)
        let visual = item("Visual Studio Code")
        let ranked = Ranker(frecency: store).rank("gh foo bar", in: [visual, github], limit: 2, now: now)
        #expect(ranked.first?.item.id == github.id)
        #expect(ranked.first?.arguments == ["foo bar"])
    }

    @Test("an alias prefix behaves as a tier four keyword match")
    func rankingAliasPrefix() {
        let aliased = item("Some command", aliases: ["gho"])
        let ranked = Ranker(frecency: FrecencyStore(fileURL: nil)).rank("gh", in: [aliased], limit: 1, now: now)
        #expect(ranked.count == 1)
        #expect(ranked[0].titlePositions.isEmpty)
        #expect(ranked[0].score >= 350 && ranked[0].score < 450)
    }

    @Test("inline arguments keep the last argument's original quoting")
    func inlineArguments() {
        #expect(InlineArguments.split(" foo bar ", declaredCount: 1) == ["foo bar"])
        #expect(InlineArguments.split("foo bar", declaredCount: 2) == ["foo", "bar"])
        #expect(InlineArguments.split("foo \"bar baz\" qux", declaredCount: 2) == ["foo", "\"bar baz\" qux"])
        #expect(InlineArguments.split("foo \"bar baz\" qux", declaredCount: 3) == ["foo", "bar baz", "qux"])
        #expect(InlineArguments.split("foo", declaredCount: 3) == ["foo"])
        #expect(InlineArguments.split("foo\\ bar 'baz qux'", declaredCount: 3) == ["foo bar", "baz qux"])
    }

    @Test("a sample Raycast script header is parsed")
    func scriptFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "pass-choose", withExtension: "sh", subdirectory: "Fixtures"))
        let command = try #require(ScriptCommandParser.parse(contentsOf: url))
        #expect(command.path == url)
        #expect(command.title == "Pass")
        #expect(command.mode == .silent)
        #expect(command.icon == "🔐")
        #expect(command.arguments.isEmpty)
    }

    @Test("script headers support comment styles, aliases, arguments, and defaults")
    func scriptHeaders() throws {
        let text = """
        // @raycast.title Demo
        -- @raycast.mode unknown
        ; @raycast.packageName Tools
        % @raycast.icon 🛠️
        ' @raycast.description A demo command
        REM @raycast.needsConfirmation true
        # @raycast.currentDirectoryPath ~/demo
        # @alauncher.alias d, demo
        # @alauncher.alias launch
        # @raycast.argument1 {"type":"text","placeholder":"Name","optional":true}
        # @raycast.argument2 not-json
        # @raycast.argument3 {"type":"dropdown","placeholder":"Choice","percentEncoded":true,"data":[{"title":"One","value":"1"}]}
        # @raycast.schemaVersion 1
        """
        let command = try #require(ScriptCommandParser.parse(text, path: URL(fileURLWithPath: "/tmp/demo.sh")))
        #expect(command.mode == .compact)
        #expect(command.packageName == "Tools")
        #expect(command.icon == "🛠️")
        #expect(command.description == "A demo command")
        #expect(command.needsConfirmation)
        #expect(command.currentDirectoryPath == NSString(string: "~/demo").expandingTildeInPath)
        #expect(command.aliases == ["d", "demo", "launch"])
        #expect(command.arguments.count == 2)
        #expect(command.arguments[0].type == "text")
        #expect(command.arguments[0].optional)
        #expect(command.arguments[1].choices == [.init(title: "One", value: "1")])
        #expect(command.arguments[1].percentEncoded)
    }

    @Test("script parsing is bounded to the first 16 KB")
    func scriptReadLimit() throws {
        let url = temporaryURL("large-script.sh")
        defer { try? FileManager.default.removeItem(at: url) }
        let contents = "# @raycast.title Bounded\n" + String(repeating: "x", count: 16 * 1024) + "\n# @raycast.mode silent\n"
        try contents.data(using: .utf8)!.write(to: url)
        let command = try #require(ScriptCommandParser.parse(contentsOf: url))
        #expect(command.title == "Bounded")
        #expect(command.mode == .compact)
    }

    @Test("ranking 500 items stays under the per-keystroke budget")
    func rankingPerformance() {
        let store = FrecencyStore(fileURL: nil)
        let items = (0..<500).map { index in
            item("Application \(index) Visual Studio Code", id: "app:\(index)", keywords: ["code", "application"])
        }
        let ranker = Ranker(frecency: store)
        for _ in 0..<5 { _ = ranker.rank("vsc", in: items, limit: .max, now: now) }

        let iterations = 100
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            _ = ranker.rank("vsc", in: items, limit: .max, now: now)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let averageNanoseconds = Double(elapsed) / Double(iterations)
        #expect(averageNanoseconds < 2_000_000)
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchTests-\(UUID().uuidString)-\(name)")
    }
}
