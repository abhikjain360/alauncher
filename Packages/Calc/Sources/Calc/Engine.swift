import Foundation

struct ExpressionEngine {
    let rates: (any CurrencyRateProvider)?

    func evaluate(_ input: String) -> CalcOutcome {
        // The launcher evaluates on every keystroke. A bounded lexer keeps a
        // pasted pathological string from consuming unbounded time or memory.
        if input.count > 1_024 {
            return input.contains(where: { "+-*/%^&|!~()".contains($0) }) ? .error("too large") : .notACalculation
        }
        var parenthesisDepth = 0
        for byte in input.utf8 {
            if byte == 40 { // (
                parenthesisDepth += 1
                if parenthesisDepth > 8 { return .error("too large") }
            } else if byte == 41, parenthesisDepth > 0 { // )
                parenthesisDepth -= 1
            }
        }
        var lexer = Lexer(input)
        let tokens = lexer.lex()
        if tokens.count == 1 { return .notACalculation }
        var parser = Parser(tokens: tokens, rates: rates)
        do {
            let parsed = try parser.parse()
            let isBaseLiteral = parsed.value.containsBaseLiteral && parsed.value.isScalar && parsed.value.baseFormat == nil
            guard parsed.usedCalculationSyntax || parsed.containsConversion || isBaseLiteral else { return .notACalculation }
            return .result(try Formatter.result(for: parsed.value))
        } catch CalcError.incomplete {
            return .incomplete
        } catch let CalcError.message(message) {
            return parser.usedCalculationSyntax || parser.containsConversion ? .error(message) : .notACalculation
        } catch {
            return parser.usedCalculationSyntax || parser.containsConversion ? .error("calculation failed") : .notACalculation
        }
    }
}
