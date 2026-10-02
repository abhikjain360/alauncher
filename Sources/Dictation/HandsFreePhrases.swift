import Foundation

enum HandsFreePhrases {
    static func afterWakePhrase(in text: String, wakePhrases: [String]) -> String? {
        for phrase in wakePhrases {
            if let rest = TextProcessing.rest(of: text, afterPrefix: phrase) { return rest }
        }
        return nil
    }

    static func isOnly(_ text: String, phrases: [String]) -> Bool {
        let textWords = text.lowercased().filter(TextProcessing.isWordCharacter)
        guard !textWords.isEmpty else { return false }
        return phrases.contains { phrase in
            let phraseWords = phrase.lowercased().filter(TextProcessing.isWordCharacter)
            return !phraseWords.isEmpty && phraseWords == textWords
        }
    }

    static func strippingSendPhrase(from text: String, sendPhrases: [String]) -> (text: String, sendIt: Bool) {
        for phrase in sendPhrases {
            let wanted = Array(phrase.lowercased().filter(TextProcessing.isWordCharacter))
            guard !wanted.isEmpty else { continue }
            var cursor = text.endIndex
            while cursor > text.startIndex, text[text.index(before: cursor)].isPunctuationOrWhitespace {
                cursor = text.index(before: cursor)
            }
            var wantedIndex = wanted.count - 1
            var matched = false
            while cursor > text.startIndex {
                let index = text.index(before: cursor)
                let character = text[index]
                if TextProcessing.isWordCharacter(character) {
                    guard character.lowercased() == String(wanted[wantedIndex]) else { break }
                    cursor = index
                    if wantedIndex == 0 {
                        matched = true
                        break
                    }
                    wantedIndex -= 1
                } else {
                    cursor = index
                }
            }
            guard matched else { continue }
            let before = cursor == text.startIndex ? cursor : text.index(before: cursor)
            if cursor != text.startIndex, TextProcessing.isWordCharacter(text[before]) { continue }
            return (String(text[..<cursor]).trimmingCharacters(in: .whitespacesAndNewlines), true)
        }
        return (text, false)
    }
}

private extension Character {
    var isPunctuationOrWhitespace: Bool { isPunctuation || isWhitespace }
}
