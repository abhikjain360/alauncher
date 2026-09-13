// Generates Packages/Search/Sources/Search/EmojiData.swift, the launcher's emoji search data:
// every emoji this Mac draws, with its Unicode name and CLDR search words.
//
//   xcrun swift scripts/generate-emoji-data.swift <folder> > Packages/Search/Sources/Search/EmojiData.swift
//
// <folder> holds three downloads:
// - emoji-test.txt, from https://unicode.org/Public/emoji/latest/
// - annotations.json and annotationsDerived.json: the English files of cldr-json's
//   cldr-annotations-full and cldr-annotations-derived-full packages
//   (https://github.com/unicode-org/cldr-json)
//
// It keeps emoji-test.txt's fully-qualified emoji, in file order, minus the Component group and
// skin-tone variants, and minus any that CoreText doesn't draw as a single Apple Color Emoji
// (too new for this macOS). Rerun it after a macOS update that adds emoji.

import CoreText
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-emoji-data: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: generate-emoji-data.swift <folder with emoji-test.txt, annotations.json and annotationsDerived.json>")
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func contents(of name: String) -> Data {
    guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path) else {
        fail("can't read \(name) in \(folder.path)")
    }
    return data
}

/// CLDR's `default` keywords by emoji, from `{"<root>": {"annotations": {"😀": {"default": […]}}}}`.
func keywordTable(_ name: String, root: String) -> [String: [String]] {
    guard let json = try? JSONSerialization.jsonObject(with: contents(of: name)) as? [String: Any],
          let annotations = (json[root] as? [String: Any])?["annotations"] as? [String: Any]
    else { fail("\(name): no \(root).annotations") }
    var table: [String: [String]] = [:]
    for (emoji, value) in annotations {
        if let keywords = (value as? [String: Any])?["default"] as? [String] { table[emoji] = keywords }
    }
    return table
}

let annotations = keywordTable("annotations.json", root: "annotations")
let derivedAnnotations = keywordTable("annotationsDerived.json", root: "annotationsDerived")

/// Lowercase, diacritic-folded runs of letters and digits: the words EmojiIndex splits names and
/// queries into.
func words(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""
    func flush() {
        if !current.isEmpty {
            result.append(current.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        }
        current = ""
    }
    for character in text {
        if character.isLetter || character.isNumber { current.append(character) } else { flush() }
    }
    flush()
    return result
}

let emojiFont = CTFontCreateWithName("AppleColorEmoji" as CFString, 32, nil)

func emojiLine(_ text: String) -> CTLine {
    CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): emojiFont])
    )
}

/// The width of one emoji, from a plain one-character one.
let emojiWidth = CTLineGetTypographicBounds(emojiLine("😀"), nil, nil, nil)

/// Whether CoreText draws `emoji` as a single Apple Color Emoji: every glyph from that font, none
/// missing, and one emoji wide. A sequence this macOS doesn't know comes apart into its pieces side
/// by side, and a character it doesn't know falls back to another font. Glyphs aren't counted:
/// couples are drawn as two half-glyphs.
func drawsAsOneEmoji(_ emoji: String) -> Bool {
    let line = emojiLine(emoji)
    guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else { return false }
    for run in runs {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let font = attributes[kCTFontAttributeName as String],
              CTFontCopyPostScriptName(font as! CTFont) as String == "AppleColorEmoji" else { return false }
        var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
        CTRunGetGlyphs(run, CFRange(location: 0, length: glyphs.count), &glyphs)
        if glyphs.contains(0) { return false }
    }
    return CTLineGetTypographicBounds(line, nil, nil, nil) <= emojiWidth * 1.1
}

struct Emoji {
    let emoji: String
    let name: String
    let version: String
}

guard let emojiTest = String(data: contents(of: "emoji-test.txt"), encoding: .utf8) else {
    fail("emoji-test.txt isn't UTF-8")
}

var emojiVersion = "?"
var group = ""
var candidates: [Emoji] = []
for line in emojiTest.split(separator: "\n") {
    if line.hasPrefix("# Version:") {
        emojiVersion = line.dropFirst("# Version:".count).trimmingCharacters(in: .whitespaces)
    } else if line.hasPrefix("# group:") {
        group = line.dropFirst("# group:".count).trimmingCharacters(in: .whitespaces)
    }
    guard !line.hasPrefix("#"), group != "Component" else { continue }
    // 1F600 ; fully-qualified # 😀 E1.0 grinning face
    let halves = line.split(separator: "#", maxSplits: 1)
    let fields = halves.first?.split(separator: ";") ?? []
    guard halves.count == 2, fields.count == 2,
          fields[1].trimmingCharacters(in: .whitespaces) == "fully-qualified" else { continue }
    let scalars = fields[0].split(separator: " ").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
    guard !scalars.contains(where: { (0x1F3FB...0x1F3FF).contains($0.value) }) else { continue }
    let comment = halves[1].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
    guard comment.count == 3, comment[1].hasPrefix("E") else { fail("unexpected line: \(line)") }
    candidates.append(Emoji(emoji: String(String.UnicodeScalarView(scalars)), name: String(comment[2]), version: String(comment[1])))
}
guard !candidates.isEmpty else { fail("emoji-test.txt has no fully-qualified emoji") }

var kept: [Emoji] = []
var dropped: [String: Int] = [:]
for candidate in candidates {
    if drawsAsOneEmoji(candidate.emoji) {
        kept.append(candidate)
    } else {
        dropped[candidate.version, default: 0] += 1
    }
}

let regionalIndicators: ClosedRange<UInt32> = 0x1F1E6...0x1F1FF

/// CLDR keyword words that aren't name words, the joined forms of multi-word keywords and names
/// ("ta-da" → "tada", "thumbs up" → "thumbsup"), and a flag's region code ("in" for 🇮🇳).
func searchWords(for emoji: Emoji) -> [String] {
    let nameWords = words(emoji.name)
    let bare = String(String.UnicodeScalarView(emoji.emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
    let keywords = annotations[emoji.emoji] ?? annotations[bare]
        ?? derivedAnnotations[emoji.emoji] ?? derivedAnnotations[bare] ?? []
    var result: [String] = []
    for keyword in keywords {
        let parts = words(keyword)
        result += parts
        if parts.count > 1 { result.append(parts.joined()) }
    }
    if nameWords.count > 1 { result.append(nameWords.joined()) }
    let scalars = emoji.emoji.unicodeScalars.map(\.value)
    if scalars.count == 2, scalars.allSatisfy(regionalIndicators.contains) {
        result.append(String(String.UnicodeScalarView(scalars.compactMap { Unicode.Scalar($0 - 0x1F1E6 + 0x61) })))
    }
    var seen = Set(nameWords)
    return result.filter { seen.insert($0).inserted }
}

let os = ProcessInfo.processInfo.operatingSystemVersion
var output = [
    "// Generated by scripts/generate-emoji-data.swift; don't edit. That script says how to regenerate it.",
    "//",
    "// Sources: Unicode's emoji-test.txt (Emoji \(emojiVersion)) and CLDR's English annotations",
    "// (cldr-json annotations and annotationsDerived). \(kept.count) emoji: the fully-qualified ones, without",
    "// skin-tone variants, that macOS \(os.majorVersion).\(os.minorVersion) draws as a single Apple Color Emoji.",
    "//",
    "// Unicode and CLDR data: Copyright © 1991-2026 Unicode, Inc. Used under the Unicode License v3;",
    "// see LICENSES/Unicode-3.0.txt.",
    "",
    "/// One emoji per line, in emoji-test.txt order: the emoji, its name, and its other search words",
    "/// (folded CLDR keywords and joined forms, without the name's own words), separated by tabs.",
    "enum EmojiData {",
    "    static let text = #\"\"\"",
]
for emoji in kept {
    let extra = searchWords(for: emoji)
    output.append(extra.isEmpty ? "\(emoji.emoji)\t\(emoji.name)" : "\(emoji.emoji)\t\(emoji.name)\t\(extra.joined(separator: " "))")
}
output += ["\"\"\"#", "}", ""]
print(output.joined(separator: "\n"), terminator: "")

let droppedSummary = dropped
    .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    .map { "\($0.key): \($0.value)" }
    .joined(separator: ", ")
FileHandle.standardError.write(Data(
    "kept \(kept.count) of \(candidates.count) emoji; dropped by version: \(droppedSummary.isEmpty ? "none" : droppedSummary)\n".utf8
))
