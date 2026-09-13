import Foundation
import Testing
@testable import Search

/// Emoji search over the bundled data.
struct EmojiTests {
    private let index = EmojiIndex.load()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func emoji(_ query: String, limit: Int = 8, frecency: FrecencyStore? = nil) -> [String] {
        index.search(query, limit: limit, frecency: frecency, now: now).map(\.entry.emoji)
    }

    @Test("the bundled data parses in file order, without skin tones or duplicates")
    func parse() throws {
        #expect(index.entries.count > 1_800)
        let first = try #require(index.entries.first)
        #expect(first.emoji == "😀")
        #expect(first.name == "grinning face")
        #expect(Set(index.entries.map(\.emoji)).count == index.entries.count)
        #expect(index.entries.enumerated().allSatisfy { $0.offset == $0.element.order })
        #expect(index.entries.allSatisfy { !$0.nameWords.isEmpty && $0.nameWords.count == $0.nameWordOffsets.count })
        #expect(!index.entries.contains { $0.emoji.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } })

        let india = try #require(index.entries.first { $0.emoji == "🇮🇳" })
        #expect(india.name == "flag: India")
        #expect(india.nameWords == ["flag", "india"])
        #expect(india.nameWordOffsets == [0, 6])
        #expect(india.keywords.contains("in"))
    }

    @Test("CLDR keywords and joined forms find emoji whose names don't say it")
    func keywords() {
        #expect(emoji("tada").first == "🎉")
        #expect(emoji("thumbs up").first == "👍")
        #expect(emoji("thumbsup").first == "👍")
        // An exact name word beats the prefix of a longer one: 😂 before "joystick".
        #expect(emoji("joy").first == "😂")
    }

    @Test("flags by name or region code")
    func flags() {
        #expect(emoji("india").first == "🇮🇳")
        #expect(emoji("flag in", limit: 3).contains("🇮🇳"))
    }

    @Test("the whole name ranks first, prefixes match as you type, and diacritics fold")
    func names() {
        #expect(emoji("red heart").first == "❤️")
        // A name ending in the query word, usually its head noun, comes first: hearts before "heart suit".
        let hearts = index.search("heart", limit: 8, frecency: nil, now: now)
        #expect(hearts.contains { $0.entry.emoji == "❤️" })
        #expect(hearts.prefix(4).allSatisfy { $0.entry.nameWords.last == "heart" })
        let prefix = index.search("hea", limit: 8, frecency: nil, now: now)
        #expect(prefix.count == 8)
        #expect(prefix.allSatisfy { match in
            match.entry.nameWords.contains { $0.hasPrefix("hea") } || match.entry.keywords.contains { $0.hasPrefix("hea") }
        })
        #expect(prefix.filter { $0.entry.name.contains("heart") }.count >= 4)
        #expect(emoji("pinata").first == "🪅")
        #expect(emoji("PIÑATA").first == "🪅")
        #expect(emoji("zzzzqx").isEmpty)
    }

    @Test("matches carry the title highlights, or the keyword that matched")
    func details() throws {
        let heart = try #require(index.search("red hea", limit: 1, frecency: nil, now: now).first)
        #expect(heart.entry.emoji == "❤️")
        #expect(heart.titlePositions == [0, 1, 2, 4, 5, 6])
        #expect(heart.matchedKeyword == nil)

        let party = try #require(index.search("tada", limit: 1, frecency: nil, now: now).first)
        #expect(party.titlePositions.isEmpty)
        #expect(party.matchedKeyword == "tada")
    }

    @Test("frecency lifts a recently used emoji to the top")
    func frecency() {
        let before = emoji("smiling", limit: 20)
        let target = before[5]
        let store = FrecencyStore(fileURL: nil)
        for _ in 0..<5 { store.recordLaunch(of: EmojiIndex.frecencyID(for: target), now: now) }
        #expect(emoji("smiling", limit: 20, frecency: store).first == target)
        #expect(emoji("smiling", limit: 20, frecency: store) != before)
    }

    @Test("the empty query lists frecent emoji first, then the data order")
    func emptyQuery() {
        let store = FrecencyStore(fileURL: nil)
        store.recordLaunch(of: EmojiIndex.frecencyID(for: "🎉"), now: now)
        for _ in 0..<2 { store.recordLaunch(of: EmojiIndex.frecencyID(for: "👍"), now: now) }
        #expect(emoji("", limit: 4, frecency: store) == ["👍", "🎉", "😀", "😃"])
        #expect(emoji("  ", limit: 2) == ["😀", "😃"])
        #expect(emoji("smile", limit: 0).isEmpty)
    }

    @Test("a search over every emoji fits the per-keystroke budget")
    func performance() {
        let keystrokes = ["h", "he", "hea", "hear", "heart", "s", "sm", "smi", "smil", "smile",
                          "t", "ta", "tad", "tada", "flag i", "flag in", "thumbs u", "thumbs up"]
        let store = FrecencyStore(fileURL: nil)
        store.recordLaunch(of: EmojiIndex.frecencyID(for: "❤️"), now: now)
        for query in keystrokes { _ = index.search(query, limit: 8, frecency: store, now: now) }

        let rounds = 10
        var start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<rounds {
            for query in keystrokes { _ = index.search(query, limit: 8, frecency: store, now: now) }
        }
        let search = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(rounds * keystrokes.count) / 1_000_000

        start = DispatchTime.now().uptimeNanoseconds
        let parsed = EmojiIndex.load()
        let parse = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "emoji: %.3f ms per keystroke over %d emoji; parsed in %.2f ms", search, parsed.entries.count, parse))
        #expect(search < 5)
        #expect(parse < 100)
    }
}
