import Foundation

enum Token: Equatable, Sendable {
    case number(String)
    case identifier(String)
    case symbol(String)
    case invalid(String)
    case end

    var text: String {
        switch self {
        case let .number(value), let .identifier(value), let .symbol(value), let .invalid(value): return value
        case .end: return ""
        }
    }
}

struct Lexer {
    private let characters: [Character]
    private var index = 0
    private(set) var sawBaseLiteral = false

    init(_ input: String) {
        characters = Array(input)
    }

    mutating func lex() -> [Token] {
        var tokens: [Token] = []
        tokens.reserveCapacity(min(characters.count + 1, 256))
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character.isNumber || (character == "." && peek(1)?.isNumber == true) {
                let token = lexNumber()
                tokens.append(token)
                if case let .number(value) = token, value.lowercased().hasPrefix("0x") || value.lowercased().hasPrefix("0o") || value.lowercased().hasPrefix("0b") {
                    sawBaseLiteral = true
                }
                continue
            }
            if isIdentifierStart(character) {
                tokens.append(.identifier(lexIdentifier()))
                continue
            }
            if ["$", "€", "£", "¥", "₹", "₩"].contains(character) {
                tokens.append(.symbol(String(character)))
                index += 1
                continue
            }

            let twoCharacter = index + 1 < characters.count ? String([character, characters[index + 1]]) : ""
            if ["**", "//", "<<", ">>"].contains(twoCharacter) {
                tokens.append(.symbol(twoCharacter))
                index += 2
            } else if ["+", "-", "*", "/", "%", "^", "(", ")", ",", "!", "&", "|", "~"].contains(character) {
                tokens.append(.symbol(String(character)))
                index += 1
            } else {
                tokens.append(.invalid(String(character)))
                index += 1
            }
        }
        tokens.append(.end)
        return tokens
    }

    private mutating func lexNumber() -> Token {
        let start = index
        if characters[index] == "0", let next = peek(1), ["x", "X", "o", "O", "b", "B"].contains(next) {
            index += 2
            while index < characters.count, isNumberPart(characters[index]) { index += 1 }
            return .number(String(characters[start..<index]))
        }

        var hasDot = false
        var hasExponent = false
        while index < characters.count {
            let character = characters[index]
            if character.isNumber || character == "_" {
                index += 1
            } else if character == ".", !hasDot, !hasExponent {
                hasDot = true
                index += 1
            } else if (character == "e" || character == "E"), !hasExponent {
                hasExponent = true
                index += 1
                if let sign = peek(0), sign == "+" || sign == "-" {
                    index += 1
                }
            } else {
                break
            }
        }
        return .number(String(characters[start..<index]))
    }

    private mutating func lexIdentifier() -> String {
        let start = index
        while index < characters.count, isIdentifierPart(characters[index]) {
            index += 1
        }
        return String(characters[start..<index])
    }

    private func peek(_ offset: Int) -> Character? {
        let position = index + offset
        return position < characters.count ? characters[position] : nil
    }

    private func isNumberPart(_ character: Character) -> Bool {
        character.isNumber || character == "_" || (character.isASCII && character.isLetter)
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "." || character == "°" || character == "µ" || character == "²" || character == "³"
    }

    private func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }
}
