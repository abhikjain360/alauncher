import Foundation

private struct InlineToken {
    let value: String
    let end: String.Index
}

public enum InlineArguments {
    /// Splits the text typed after an alias into `declaredCount` arguments:
    /// shell-style quoting, and the last argument takes the rest.
    public static func split(_ text: String, declaredCount: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard declaredCount >= 2 else { return [trimmed] }

        let tokens = tokenize(text)
        guard tokens.count >= declaredCount else {
            return tokens.map(\.value)
        }

        let firstArguments = tokens.prefix(declaredCount - 1).map(\.value)
        let restStart = tokens[declaredCount - 2].end
        let lastArgument = String(text[restStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return firstArguments + [lastArgument]
    }

    private static func tokenize(_ text: String) -> [InlineToken] {
        var tokens: [InlineToken] = []
        var index = text.startIndex

        while index < text.endIndex {
            while index < text.endIndex && isWhitespace(text[index]) {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            var value = ""
            var quote: Character?

            while index < text.endIndex {
                let character = text[index]

                if let activeQuote = quote {
                    if character == activeQuote {
                        self.advance(&index, in: text)
                        quote = nil
                    } else if character == "\\" && activeQuote == "\"" {
                        self.advance(&index, in: text)
                        if index < text.endIndex {
                            value.append(text[index])
                            self.advance(&index, in: text)
                        } else {
                            value.append("\\")
                        }
                    } else {
                        value.append(character)
                        self.advance(&index, in: text)
                    }
                    continue
                }

                if isWhitespace(character) { break }
                if character == "'" || character == "\"" {
                    quote = character
                    self.advance(&index, in: text)
                } else if character == "\\" {
                    self.advance(&index, in: text)
                    if index < text.endIndex {
                        value.append(text[index])
                        self.advance(&index, in: text)
                    } else {
                        value.append("\\")
                    }
                } else {
                    value.append(character)
                    self.advance(&index, in: text)
                }
            }

            tokens.append(InlineToken(value: value, end: index))
        }

        return tokens
    }

    private static func advance(_ index: inout String.Index, in text: String) {
        index = text.index(after: index)
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }
}
