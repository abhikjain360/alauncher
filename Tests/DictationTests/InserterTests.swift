import Core
import Testing
@testable import Dictation

// MARK: - Method selection

@Test func newlinesAlwaysPaste() {
    var settings = InsertSettings()
    settings.apps = ["com.example.Editor": .type]
    #expect(InsertPlanner.method(for: "line one\nline two", bundleID: nil, settings: settings) == .paste)
    #expect(InsertPlanner.method(for: "line one\r\nline two", bundleID: "com.example.Editor", settings: settings) == .paste)
}

@Test func perAppOverrideThenDefault() {
    var settings = InsertSettings()
    settings.apps = ["com.apple.ScreenSharing": .paste, "com.example.Editor": .type]
    #expect(InsertPlanner.method(for: "one line", bundleID: "com.apple.ScreenSharing", settings: settings) == .paste)
    #expect(InsertPlanner.method(for: "one line", bundleID: "com.apple.TextEdit", settings: settings) == .type)
    #expect(InsertPlanner.method(for: "one line", bundleID: nil, settings: settings) == .type)
    settings.method = .paste
    #expect(InsertPlanner.method(for: "one line", bundleID: "com.apple.TextEdit", settings: settings) == .paste)
    #expect(InsertPlanner.method(for: "one line", bundleID: "com.example.Editor", settings: settings) == .type)
}

// MARK: - Typing chunks

@Test func oneCharacterPerEventByDefault() {
    #expect(InsertPlanner.typingChunks("hello", chunkSize: 1) == ["h", "e", "l", "l", "o"])
    #expect(InsertPlanner.typingChunks("hello", chunkSize: 2) == ["he", "ll", "o"])
    #expect(InsertPlanner.typingChunks("hello", chunkSize: 0) == ["h", "e", "l", "l", "o"])
    #expect(InsertPlanner.typingChunks("", chunkSize: 5) == [])
}

@Test func chunksFollowGraphemeClusters() {
    // "é" is one character whether precomposed or combining; 🚀 is two UTF-16 units.
    #expect(InsertPlanner.typingChunks("cafe\u{301} 🚀!", chunkSize: 3) == ["caf", "e\u{301} 🚀", "!"])
    let family = "👨‍👩‍👧‍👦"
    #expect(InsertPlanner.typingChunks("a\(family)b", chunkSize: 1) == ["a", family, "b"])
}

@Test func twentyUnitLimitPerEvent() {
    let ascii = String(repeating: "a", count: 45)
    #expect(InsertPlanner.typingChunks(ascii, chunkSize: 20).map(\.count) == [20, 20, 5])

    // A surrogate pair that would straddle the limit moves to the next event.
    let edge = String(repeating: "a", count: 19) + "🚀"
    #expect(InsertPlanner.typingChunks(edge, chunkSize: 20) == [String(repeating: "a", count: 19), "🚀"])

    // Six flags of four units each: five fit in one event.
    let flags = String(repeating: "🇺🇸", count: 6)
    #expect(InsertPlanner.typingChunks(flags, chunkSize: 20).map { $0.utf16.count } == [20, 4])
}

@Test func oversizedClusterSplitsBetweenScalars() {
    // One grapheme cluster of 26 UTF-16 units: "e" plus 25 combining acute accents.
    let accents = "e" + String(repeating: "\u{301}", count: 25)
    #expect(accents.count == 1)
    let chunks = InsertPlanner.typingChunks("x" + accents + "y", chunkSize: 5)
    #expect(chunks.joined() == "x" + accents + "y")
    #expect(chunks.allSatisfy { $0.utf16.count <= 20 })

    // Emoji scalars (surrogate pairs) inside an oversized cluster are never cut in half.
    let thumbs = "👍🏽" + String(repeating: "\u{20E3}", count: 20)
    let pieces = InsertPlanner.typingChunks(thumbs, chunkSize: 1)
    #expect(pieces.map { $0.utf16.count } == [20, 4])
    #expect(pieces.joined() == thumbs)
    for piece in pieces {
        #expect(!piece.unicodeScalars.contains { $0.value >= 0xD800 && $0.value <= 0xDFFF })
    }
}

@Test(arguments: [1, 3, 7, 20])
func chunksReassembleTheText(chunkSize: Int) {
    let text = "Typing test: café ñ 🚀 \"quotes\" (parens) 👨‍👩‍👧‍👦 🇺🇸 $HOME ~/path `tick` 100% end."
    let chunks = InsertPlanner.typingChunks(text, chunkSize: chunkSize)
    #expect(chunks.joined() == text)
    #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= chunkSize && $0.utf16.count <= 20 })
}
