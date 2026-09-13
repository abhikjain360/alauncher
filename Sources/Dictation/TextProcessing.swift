import Foundation

/// Pure text helpers for the dictation pipeline.
public enum TextProcessing {
    // MARK: - Ask prefix

    /// The question after a spoken Ask prefix, or nil when the text doesn't start with one.
    ///
    /// Matching is case- and punctuation-insensitive, and spaces and hyphens inside a prefix are
    /// optional, so "my lord" matches "My Lord,", "my lord." and "My-lord —", and "milord"
    /// matches "Milord". The prefix must end at a word boundary ("My lordship" doesn't match).
    /// The rest of the original text is returned with leading punctuation and whitespace
    /// trimmed; it is empty when only the prefix was spoken.
    public static func askQuestion(in text: String, prefixes: [String]) -> String? {
        for prefix in prefixes {
            if let rest = rest(of: text, afterPrefix: prefix) { return rest }
        }
        return nil
    }

    private static func rest(of text: String, afterPrefix prefix: String) -> String? {
        let wanted = prefix.lowercased().filter(isWordCharacter)
        guard !wanted.isEmpty else { return nil }

        var index = text.startIndex
        var remaining = wanted.startIndex
        while remaining < wanted.endIndex {
            guard index < text.endIndex else { return nil }
            let character = text[index]
            if isWordCharacter(character) {
                guard character.lowercased() == String(wanted[remaining]) else { return nil }
                remaining = wanted.index(after: remaining)
            }
            index = text.index(after: index)
        }
        if index < text.endIndex, isWordCharacter(text[index]) { return nil }

        let rest = text[index...].drop { $0.isPunctuation || $0.isWhitespace }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: - Fillers

    /// Removes whole filler words, case-insensitively, each taking one trailing comma with it:
    /// "um, so" → "so", "So, um, I think" → "So, I think". A filler that starts a sentence takes a
    /// following period too ("Uh. Okay." → "Okay."), and the next word is capitalized when the
    /// filler was. Leftover double spaces are collapsed.
    public static func removeFillers(_ text: String, fillers: [String]) -> String {
        let words = fillers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        guard !words.isEmpty else { return text }
        let alternation = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let boundary = "\\p{L}\\p{N}'’"
        let pattern = "(?<![\(boundary)])(?:\(alternation))(?![\(boundary)])(,?)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = 0
        var capitalizeNext = false

        func append(_ segment: String) {
            guard capitalizeNext, let letterIndex = segment.firstIndex(where: \.isLetter) else {
                output += segment
                return
            }
            output += segment[..<letterIndex] + segment[letterIndex].uppercased() + segment[segment.index(after: letterIndex)...]
            capitalizeNext = false
        }

        for match in matches {
            var range = match.range
            append(source.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            let tookComma = match.range(at: 1).length > 0
            let previous = output.last(where: { !$0.isWhitespace })
            let startsSentence = previous == nil || ".!?".contains(previous!)
            let end = range.location + range.length
            let next = end < source.length ? source.substring(with: NSRange(location: end, length: 1)) : ""

            if !tookComma, [".", "!", "?"].contains(next) {
                if startsSentence {
                    range.length += 1
                } else if let comma = output.lastIndex(where: { !$0.isWhitespace }), output[comma] == "," {
                    // "we should, um." → "we should."
                    output.removeSubrange(comma...)
                }
            }
            let filler = source.substring(with: match.range)
            if startsSentence, filler.first?.isUppercase == true { capitalizeNext = true }
            cursor = range.location + range.length
        }
        append(source.substring(from: cursor))

        let collapsed = output.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt

    /// Replaces every `${output}` with the transcript. A template without the placeholder gets the
    /// transcript appended after a blank line.
    public static func fillPrompt(_ template: String, transcript: String) -> String {
        let placeholder = "${output}"
        if template.contains(placeholder) {
            return template.replacingOccurrences(of: placeholder, with: transcript)
        }
        var base = template
        while base.last?.isWhitespace == true { base.removeLast() }
        return base.isEmpty ? transcript : base + "\n\n" + transcript
    }

    /// True when there's nothing but whitespace and punctuation.
    public static func isBlank(_ text: String) -> Bool {
        !text.contains(where: isWordCharacter)
    }
}
