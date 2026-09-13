import Foundation

struct ParsedExpression {
    var value: CalcValue
    var usedCalculationSyntax: Bool
    var containsConversion: Bool
}

enum ConversionTarget: Sendable {
    case unit(CalcUnit)
    case currency(String)
    case base(BaseFormat)
}

struct Parser {
    private let tokens: [Token]
    private let rates: (any CurrencyRateProvider)?
    private var position = 0
    private var depth = 0
    private var suppressQuantitySuffix = false
    private var unaryDepth = 0
    private var powerDepth = 0
    private(set) var usedCalculationSyntax = false
    private(set) var containsConversion = false

    init(tokens: [Token], rates: (any CurrencyRateProvider)?) {
        self.tokens = tokens
        self.rates = rates
    }

    mutating func parse() throws -> ParsedExpression {
        guard !isAtEnd else { throw CalcError.incomplete }
        let value = try parseOfExpression()
        var converted = false
        if conversionKeyword(current) != nil {
            usedCalculationSyntax = true
            containsConversion = true
            advance()
            guard !isAtEnd else { throw CalcError.incomplete }
            let target = try parseTarget(for: value)
            let result = try Evaluator.convert(value, to: target, rates: rates)
            converted = true
            guard isAtEnd else { throw CalcError.message("unexpected input") }
            return ParsedExpression(value: result, usedCalculationSyntax: usedCalculationSyntax, containsConversion: converted)
        }
        guard isAtEnd else {
            if case .invalid = current { throw CalcError.message("invalid character") }
            throw CalcError.message("unexpected input")
        }
        return ParsedExpression(value: value, usedCalculationSyntax: usedCalculationSyntax, containsConversion: converted)
    }

    private mutating func parseOfExpression() throws -> CalcValue {
        let lhs = try parseAdditive()
        guard isIdentifier(current, named: "of") else { return lhs }
        usedCalculationSyntax = true
        advance()
        guard !isAtEnd else { throw CalcError.incomplete }
        guard lhs.percentTerm, lhs.isScalar else { throw CalcError.message("percent-of needs a percent") }
        let rhs = try parseAdditive()
        return try Evaluator.multiply(lhs, rhs).clearingPercent()
    }

    private mutating func parseAdditive() throws -> CalcValue {
        var value = try parseBitwiseOr()
        while true {
            if consume("+") {
                let rhs = try parseBitwiseOr()
                value = try Evaluator.add(value, rhs, rates: rates)
            } else if consume("-") {
                let rhs = try parseBitwiseOr()
                value = try Evaluator.subtract(value, rhs, rates: rates)
            } else {
                break
            }
        }
        return value
    }

    private mutating func parseBitwiseOr() throws -> CalcValue {
        var value = try parseBitwiseAnd()
        while consume("|") {
            let rhs = try parseBitwiseAnd()
            value = try Evaluator.bitwise(value, rhs, operation: |)
        }
        return value
    }

    private mutating func parseBitwiseAnd() throws -> CalcValue {
        var value = try parseShift()
        while consume("&") {
            let rhs = try parseShift()
            value = try Evaluator.bitwise(value, rhs, operation: &)
        }
        return value
    }

    private mutating func parseShift() throws -> CalcValue {
        var value = try parseAdditiveShiftOperand()
        while true {
            if consume("<<") {
                let rhs = try parseAdditiveShiftOperand()
                value = try Evaluator.shift(value, rhs, right: false)
            } else if consume(">>") {
                let rhs = try parseAdditiveShiftOperand()
                value = try Evaluator.shift(value, rhs, right: true)
            } else {
                break
            }
        }
        return value
    }

    // The separate level keeps shifts below +/-, matching the contract's
    // table while avoiding a left-recursive descent.
    private mutating func parseAdditiveShiftOperand() throws -> CalcValue {
        var value = try parseMultiplicative()
        while true {
            if consume("+") {
                let rhs = try parseMultiplicative()
                value = try Evaluator.add(value, rhs, rates: rates)
            } else if consume("-") {
                let rhs = try parseMultiplicative()
                value = try Evaluator.subtract(value, rhs, rates: rates)
            } else {
                break
            }
        }
        return value
    }

    private mutating func parseMultiplicative() throws -> CalcValue {
        var value = try parseUnary()
        while true {
            if consume("*") {
                let rhs = try parseUnary()
                value = try Evaluator.multiply(value, rhs)
            } else if consume("/") {
                let rhs = try parseUnary()
                value = try Evaluator.divide(value, rhs)
            } else if consume("//") {
                let rhs = try parseUnary()
                value = try Evaluator.floorDivide(value, rhs)
            } else if isIdentifier(current, named: "mod") {
                usedCalculationSyntax = true
                advance()
                let rhs = try parseUnary()
                value = try Evaluator.modulo(value, rhs)
            } else if isSymbol(current, "%"), startsModuloOperand(peek(1)) {
                usedCalculationSyntax = true
                advance()
                let rhs = try parseUnary()
                value = try Evaluator.modulo(value, rhs)
            } else if startsImplicitOperand(current) {
                usedCalculationSyntax = true
                let rhs = try parseUnary()
                value = try Evaluator.multiply(value, rhs)
            } else {
                break
            }
        }
        return value
    }

    private mutating func parseUnary() throws -> CalcValue {
        if consume("+") {
            guard unaryDepth < 32 else { throw CalcError.message("too large") }
            unaryDepth += 1
            defer { unaryDepth -= 1 }
            return try Evaluator.unaryPlus(parseUnary())
        }
        if consume("-") {
            guard unaryDepth < 32 else { throw CalcError.message("too large") }
            unaryDepth += 1
            defer { unaryDepth -= 1 }
            return try Evaluator.unaryMinus(parseUnary())
        }
        if consume("~") {
            guard unaryDepth < 32 else { throw CalcError.message("too large") }
            unaryDepth += 1
            defer { unaryDepth -= 1 }
            return try Evaluator.bitwiseNot(parseUnary())
        }
        return try parsePower()
    }

    private mutating func parsePower() throws -> CalcValue {
        var value = try parsePostfix()
        if consume("**") || consume("^") {
            guard powerDepth < 32 else { throw CalcError.message("too large") }
            powerDepth += 1
            defer { powerDepth -= 1 }
            let previous = suppressQuantitySuffix
            suppressQuantitySuffix = true
            let rhs: CalcValue
            do {
                rhs = try parseUnary()
            } catch {
                suppressQuantitySuffix = previous
                throw error
            }
            suppressQuantitySuffix = previous
            value = try Evaluator.power(value, rhs)
        }
        return value
    }

    private mutating func parsePostfix() throws -> CalcValue {
        var value = try parsePrimary()
        while true {
            if consume("!") {
                value = try Evaluator.factorial(value)
            } else if isSymbol(current, "%"), !startsModuloOperand(peek(1)) {
                usedCalculationSyntax = true
                advance()
                value = try Evaluator.percent(value)
            } else {
                break
            }
        }
        return value
    }

    private mutating func parsePrimary() throws -> CalcValue {
        guard depth < 8 else { throw CalcError.message("too large") }
        switch current {
        case let .number(spelling):
            advance()
            let parsed = try parseNumber(spelling)
            if !suppressQuantitySuffix, let suffix = currentIdentifier {
                if let unit = lookupUnit(suffix) {
                    advance()
                    let poweredUnit = try parseUnitExponent(unit)
                    return CalcValue(number: parsed.number, unit: poweredUnit, containsBaseLiteral: parsed.containsBaseLiteral)
                }
                if let currency = currencyCode(suffix) {
                    advance()
                    return CalcValue(number: parsed.number, currency: currency, containsBaseLiteral: parsed.containsBaseLiteral)
                }
            }
            return CalcValue(number: parsed.number, containsBaseLiteral: parsed.containsBaseLiteral)

        case let .symbol(symbol) where ["$", "€", "£", "¥", "₹", "₩"].contains(symbol):
            advance()
            let value = try parsePrimary()
            guard value.isScalar else { throw CalcError.message("invalid currency amount") }
            return CalcValue(number: value.number, currency: CurrencySymbols.code(for: symbol), containsBaseLiteral: value.containsBaseLiteral)

        case let .identifier(spelling):
            advance()
            let normalized = normalizedIdentifier(spelling)
            if isFunctionName(normalized) {
                guard consume("(") else { throw CalcError.incomplete }
                guard depth < 8 else { throw CalcError.message("too large") }
                usedCalculationSyntax = true
                depth += 1
                defer { depth -= 1 }
                let arguments = try parseArguments()
                return try Evaluator.function(normalized, arguments: arguments, rates: rates)
            }
            if isSymbol(current, "(") {
                usedCalculationSyntax = true
                throw CalcError.message("unknown function")
            }
            if let constant = constantValue(normalized) {
                return constant
            }
            if let unit = lookupUnit(spelling) {
                let poweredUnit = try parseUnitExponent(unit)
                return CalcValue(number: .decimal(Decimal(1)), unit: poweredUnit)
            }
            throw CalcError.message("unknown identifier")

        case .symbol("("):
            advance()
            depth += 1
            let value = try parseParenthesizedExpression()
            depth -= 1
            guard consume(")") else { throw CalcError.incomplete }
            return value

        case .end:
            throw CalcError.incomplete
        case let .invalid(value):
            throw CalcError.message("invalid character \(value)")
        default:
            throw CalcError.message("expected a value")
        }
    }

    private mutating func parseArguments() throws -> [CalcValue] {
        if consume(")") { return [] }
        var result: [CalcValue] = []
        result.reserveCapacity(4)
        while true {
            guard !isAtEnd else { throw CalcError.incomplete }
            result.append(try parseOfExpression())
            if consume(")") { return result }
            guard consume(",") else { throw CalcError.message("expected comma") }
            if isAtEnd || isSymbol(current, ")") { throw CalcError.incomplete }
        }
    }

    private mutating func parseParenthesizedExpression() throws -> CalcValue {
        let value = try parseOfExpression()
        guard conversionKeyword(current) != nil else { return value }
        usedCalculationSyntax = true
        containsConversion = true
        advance()
        guard !isAtEnd else { throw CalcError.incomplete }
        return try Evaluator.convert(value, to: parseTarget(for: value), rates: rates)
    }

    private mutating func parseUnitExponent(_ unit: CalcUnit) throws -> CalcUnit {
        guard takeSymbol("^") else { return unit }
        var negative = false
        var signConsumed = false
        if isSymbol(current, "-") {
            negative = true
            signConsumed = true
            advance()
        } else if isSymbol(current, "+") {
            signConsumed = true
            advance()
        }
        guard case let .number(spelling) = current else {
            // It was a real power, not a unit exponent. Put the caret back by
            // moving the consumed tokens back; parsePower will consume it at
            // the outer level.
            position -= signConsumed ? 2 : 1
            return unit
        }
        let exponentValue = try parseNumber(spelling).number
        guard var exponent = integerValue(exponentValue), !exponent.negative, exponent.magnitude.bitWidth <= 7 else {
            throw CalcError.message("invalid unit exponent")
        }
        if negative { exponent = SignedInt128(negative: true, magnitude: exponent.magnitude) }
        return unit.raised(to: exponent.negative ? -Int(exponent.magnitude.lo) : Int(exponent.magnitude.lo))
    }

    private mutating func parseTarget(for source: CalcValue) throws -> ConversionTarget {
        switch current {
        case let .symbol(symbol) where ["$", "€", "£", "¥", "₹", "₩"].contains(symbol):
            advance()
            return .currency(CurrencySymbols.code(for: symbol))
        case let .identifier(spelling):
            let normalized = normalizedIdentifier(spelling)
            if let base = baseFormat(normalized) {
                advance()
                return .base(base)
            }
            let candidateCurrency = currencyCode(spelling)
            let candidateUnit = lookupUnit(spelling)
            if source.currency != nil, let candidateCurrency {
                advance()
                return .currency(candidateCurrency)
            }
            if let candidateUnit {
                advance()
                return .unit(try parseCompoundUnit(startingWith: candidateUnit))
            }
            if let candidateCurrency {
                advance()
                return .currency(candidateCurrency)
            }
            throw CalcError.message("unknown conversion target")
        default:
            throw CalcError.message("expected conversion target")
        }
    }

    private mutating func parseCompoundUnit(startingWith first: CalcUnit) throws -> CalcUnit {
        var unit = try parseUnitExponent(first)
        while isSymbol(current, "/") || isSymbol(current, "*") {
            let division = isSymbol(current, "/")
            advance()
            guard let spelling = currentIdentifier, let next = lookupUnit(spelling) else {
                throw CalcError.message("invalid compound unit")
            }
            advance()
            let powered = try parseUnitExponent(next)
            unit = division ? unit.divided(by: powered) : unit.multiplied(by: powered)
        }
        return unit
    }

    private func parseNumber(_ spelling: String) throws -> ParsedNumber {
        let lower = spelling.lowercased()
        if lower.hasPrefix("0x") || lower.hasPrefix("0o") || lower.hasPrefix("0b") {
            let radix: UInt64 = lower.hasPrefix("0x") ? 16 : (lower.hasPrefix("0o") ? 8 : 2)
            var digits = String(spelling.dropFirst(2))
            guard !digits.isEmpty, validUnderscores(digits), !digits.contains(where: { character in
                guard let value = character.wholeNumberValue else {
                    let lowerCharacter = character.lowercased()
                    return !(radix == 16 && ["a", "b", "c", "d", "e", "f"].contains(lowerCharacter))
                }
                return UInt64(value) >= radix
            }) else { throw CalcError.message("invalid number") }
            digits.removeAll(where: { $0 == "_" })
            var integer = BigUInt128.zero
            for character in digits {
                let digit: UInt64
                if let value = character.wholeNumberValue {
                    digit = UInt64(value)
                } else {
                    digit = UInt64(character.lowercased().unicodeScalars.first!.value - UnicodeScalar("a").value + 10)
                }
                guard let multiplied = BigUInt128.multipliedBySmall(integer, radix),
                      let added = BigUInt128.adding(multiplied, BigUInt128(lo: digit, hi: 0))
                else { throw CalcError.message("too large") }
                integer = added
            }
            return ParsedNumber(number: numberFromInteger(SignedInt128(negative: false, magnitude: integer)), containsBaseLiteral: true)
        }

        guard validDecimalNumber(spelling) else { throw CalcError.message("invalid number") }
        let cleaned = spelling.replacingOccurrences(of: "_", with: "")
        if let decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) {
            return ParsedNumber(number: .decimal(decimal), containsBaseLiteral: false)
        }
        guard let double = Double(cleaned) else { throw CalcError.message("invalid number") }
        return ParsedNumber(number: .double(double), containsBaseLiteral: false)
    }

    private func validDecimalNumber(_ spelling: String) -> Bool {
        let characters = Array(spelling)
        guard !characters.isEmpty else { return false }
        var digitCount = 0
        var underscoreAllowed = false
        var decimalPoint = false
        var exponent = false
        var exponentDigits = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isNumber {
                digitCount += 1
                if exponent { exponentDigits += 1 }
                underscoreAllowed = true
            } else if character == "_" {
                guard underscoreAllowed, index + 1 < characters.count, characters[index + 1].isNumber else { return false }
                underscoreAllowed = false
            } else if character == ".", !decimalPoint, !exponent {
                decimalPoint = true
                underscoreAllowed = false
            } else if (character == "e" || character == "E"), !exponent, digitCount > 0 {
                exponent = true
                underscoreAllowed = false
                if index + 1 < characters.count, characters[index + 1] == "+" || characters[index + 1] == "-" { index += 1 }
            } else {
                return false
            }
            index += 1
        }
        return digitCount > 0 && (!exponent || exponentDigits > 0) && underscoreAllowed
    }

    private func validUnderscores(_ digits: String) -> Bool {
        let characters = Array(digits)
        guard !characters.isEmpty else { return false }
        for index in characters.indices where characters[index] == "_" {
            guard index > characters.startIndex, index < characters.index(before: characters.endIndex), characters[characters.index(before: index)] != "_", characters[characters.index(after: index)] != "_" else { return false }
        }
        return true
    }

    private func currencyCode(_ spelling: String) -> String? {
        let upper = spelling.uppercased()
        if spelling.count == 3, spelling.allSatisfy({ $0.isLetter }), !isReservedWord(upper) {
            return upper
        }
        if let rates, rates.currentRates()?.rates[upper] != nil { return upper }
        return ["BTC", "ETH", "AAVE", "DOGE", "USDT", "USDC"].contains(upper) ? upper : nil
    }

    private func isReservedWord(_ word: String) -> Bool {
        ["THE", "AND", "FOR", "NOT", "MOD", "OF", "TO", "IN", "AS"].contains(word)
    }

    private func constantValue(_ name: String) -> CalcValue? {
        switch name {
        case "pi": return CalcValue(number: .double(Double.pi))
        case "e": return CalcValue(number: .double(M_E))
        case "tau": return CalcValue(number: .double(2 * Double.pi))
        default: return nil
        }
    }

    private func normalizedIdentifier(_ spelling: String) -> String {
        let lower = spelling.lowercased()
        return lower.hasPrefix("math.") ? String(lower.dropFirst(5)) : lower
    }

    private func isFunctionName(_ name: String) -> Bool {
        ["sqrt", "cbrt", "abs", "round", "floor", "ceil", "trunc", "int", "ln", "log10", "log2", "exp", "log", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "hypot", "min", "max", "gcd", "lcm", "factorial", "degrees", "radians", "pow", "hex", "bin", "oct"].contains(name)
    }

    private func baseFormat(_ name: String) -> BaseFormat? {
        switch name {
        case "hex", "hexadecimal": return .hexadecimal
        case "bin", "binary": return .binary
        case "oct", "octal": return .octal
        case "dec", "decimal": return .decimal
        default: return nil
        }
    }

    private var current: Token { tokens[min(position, tokens.count - 1)] }
    private var currentIdentifier: String? {
        if case let .identifier(value) = current { return value }
        return nil
    }
    private var isAtEnd: Bool { if case .end = current { return true }; return false }
    private func peek(_ offset: Int) -> Token {
        tokens[min(position + offset, tokens.count - 1)]
    }

    @discardableResult
    private mutating func advance() -> Token {
        let token = current
        if position < tokens.count - 1 { position += 1 }
        return token
    }

    private mutating func consume(_ symbol: String) -> Bool {
        guard isSymbol(current, symbol) else { return false }
        usedCalculationSyntax = true
        advance()
        return true
    }

    private mutating func takeSymbol(_ symbol: String) -> Bool {
        guard isSymbol(current, symbol) else { return false }
        advance()
        return true
    }

    private func isSymbol(_ token: Token, _ symbol: String) -> Bool {
        if case let .symbol(value) = token { return value == symbol }
        return false
    }

    private func isIdentifier(_ token: Token, named name: String) -> Bool {
        if case let .identifier(value) = token { return normalizedIdentifier(value) == name }
        return false
    }

    private func conversionKeyword(_ token: Token) -> String? {
        guard case let .identifier(value) = token else { return nil }
        let name = normalizedIdentifier(value)
        return ["to", "in", "as"].contains(name) ? name : nil
    }

    private func startsModuloOperand(_ token: Token) -> Bool {
        switch token {
        case .number: return true
        case let .identifier(value):
            return !["of", "to", "in", "as"].contains(normalizedIdentifier(value))
        case .symbol("("), .symbol("$"), .symbol("€"), .symbol("£"), .symbol("¥"), .symbol("₹"), .symbol("₩"), .symbol("-"), .symbol("~"): return true
        case .symbol("+"): return false
        default: return false
        }
    }

    private func startsImplicitOperand(_ token: Token) -> Bool {
        switch token {
        case let .identifier(value):
            return !["of", "to", "in", "as", "mod"].contains(normalizedIdentifier(value))
        case .symbol("("): return true
        case .symbol("$"), .symbol("€"), .symbol("£"), .symbol("¥"), .symbol("₹"), .symbol("₩"): return true
        default: return false
        }
    }
}

private struct ParsedNumber {
    var number: CalcNumber
    var containsBaseLiteral: Bool
}

private extension CalcValue {
    func clearingPercent() -> CalcValue {
        var result = self
        result.percentTerm = false
        return result
    }
}

enum CurrencySymbols {
    static func code(for symbol: String) -> String {
        switch symbol {
        case "$": return "USD"
        case "€": return "EUR"
        case "£": return "GBP"
        case "¥": return "JPY"
        case "₹": return "INR"
        case "₩": return "KRW"
        default: return symbol.uppercased()
        }
    }
}
