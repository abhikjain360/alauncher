import Foundation

enum Evaluator {
    static func unaryPlus(_ value: CalcValue) throws -> CalcValue {
        var result = value
        result.percentTerm = false
        try validate(result.number)
        return result
    }

    static func unaryMinus(_ value: CalcValue) throws -> CalcValue {
        try validate(value.number)
        var result = value
        result.number = negate(value.number)
        result.percentTerm = false
        result.baseFormat = nil
        return result
    }

    static func add(_ lhs: CalcValue, _ rhs: CalcValue, rates: (any CurrencyRateProvider)?) throws -> CalcValue {
        try rejectTemperatureArithmetic(lhs, rhs)
        if rhs.percentTerm, lhs.unit != nil || lhs.currency != nil || lhs.isScalar {
            if rhs.isScalar {
                var result = lhs
                let multiplier = addNumbers(.decimal(Decimal(1)), rhs.number)
                result.number = try multiplyNumbers(lhs.number, multiplier)
                result.percentTerm = false
                result.baseFormat = nil
                return result
            }
        }
        return try combine(lhs, rhs, operation: addNumbers, rates: rates)
    }

    static func subtract(_ lhs: CalcValue, _ rhs: CalcValue, rates: (any CurrencyRateProvider)?) throws -> CalcValue {
        try rejectTemperatureArithmetic(lhs, rhs)
        if rhs.percentTerm, rhs.isScalar {
            var result = lhs
            let multiplier = subtractNumbers(.decimal(Decimal(1)), rhs.number)
            result.number = try multiplyNumbers(lhs.number, multiplier)
            result.percentTerm = false
            result.baseFormat = nil
            return result
        }
        return try combine(lhs, rhs, operation: subtractNumbers, rates: rates)
    }

    static func multiply(_ lhs: CalcValue, _ rhs: CalcValue) throws -> CalcValue {
        try rejectTemperatureArithmetic(lhs, rhs)
        if lhs.currency != nil, rhs.currency != nil { throw CalcError.message("currency multiplication isn't supported") }
        if lhs.unit != nil, rhs.currency != nil || lhs.currency != nil, rhs.unit != nil {
            throw CalcError.message("incompatible values")
        }

        var result = CalcValue(number: try multiplyNumbers(lhs.number, rhs.number))
        result.containsBaseLiteral = lhs.containsBaseLiteral || rhs.containsBaseLiteral
        if let lhsUnit = lhs.unit, let rhsUnit = rhs.unit {
            result.unit = unitFromProduct(lhsUnit, rhsUnit)
        } else {
            result.unit = lhs.unit ?? rhs.unit
        }
        result.currency = lhs.currency ?? rhs.currency
        result.baseFormat = nil
        return result
    }

    static func divide(_ lhs: CalcValue, _ rhs: CalcValue) throws -> CalcValue {
        try rejectTemperatureArithmetic(lhs, rhs)
        if rhs.number.isZero { throw CalcError.message("division by zero") }
        if lhs.currency != nil, rhs.currency != nil {
            guard lhs.currency == rhs.currency else { throw CalcError.message("exchange rates not loaded yet") }
            return CalcValue(number: try divideNumbers(lhs.number, rhs.number), containsBaseLiteral: lhs.containsBaseLiteral || rhs.containsBaseLiteral)
        }
        if lhs.currency != nil, rhs.unit != nil || lhs.unit != nil, rhs.currency != nil {
            throw CalcError.message("incompatible values")
        }
        var result = CalcValue(number: try divideNumbers(lhs.number, rhs.number))
        result.containsBaseLiteral = lhs.containsBaseLiteral || rhs.containsBaseLiteral
        if let lhsUnit = lhs.unit, let rhsUnit = rhs.unit {
            result.unit = unitFromQuotient(lhsUnit, rhsUnit)
        } else if let lhsUnit = lhs.unit {
            result.unit = lhsUnit
        } else if let rhsUnit = rhs.unit {
            result.unit = .linear(dimension: rhsUnit.dimension.multiplied(by: -1), scale: 1 / rhsUnit.scale, symbol: "1/\(rhsUnit.symbol)")
        }
        result.currency = lhs.currency
        result.baseFormat = nil
        return result
    }

    static func floorDivide(_ lhs: CalcValue, _ rhs: CalcValue) throws -> CalcValue {
        try rejectTemperatureArithmetic(lhs, rhs)
        guard lhs.isScalar, rhs.isScalar else { throw CalcError.message("floor division needs numbers") }
        if rhs.number.isZero { throw CalcError.message("division by zero") }
        let quotient = floor(lhs.number.asDouble / rhs.number.asDouble)
        try validate(.double(quotient))
        return CalcValue(number: .double(quotient), containsBaseLiteral: lhs.containsBaseLiteral || rhs.containsBaseLiteral)
    }

    static func modulo(_ lhs: CalcValue, _ rhs: CalcValue) throws -> CalcValue {
        guard lhs.isScalar, rhs.isScalar else { throw CalcError.message("modulo needs numbers") }
        if rhs.number.isZero { throw CalcError.message("division by zero") }
        let a = lhs.number.asDouble
        let b = rhs.number.asDouble
        var remainder = a.truncatingRemainder(dividingBy: b)
        if remainder != 0, (remainder < 0) != (b < 0) { remainder += b }
        try validate(.double(remainder))
        let number: CalcNumber
        if case .decimal = lhs.number, case .decimal = rhs.number,
           let decimal = Decimal(string: String(format: "%.38g", locale: Locale(identifier: "en_US_POSIX"), remainder), locale: Locale(identifier: "en_US_POSIX")) {
            number = .decimal(decimal)
        } else {
            number = .double(remainder)
        }
        return CalcValue(number: number, containsBaseLiteral: lhs.containsBaseLiteral || rhs.containsBaseLiteral)
    }

    static func percent(_ value: CalcValue) throws -> CalcValue {
        guard value.isScalar else { throw CalcError.message("percent needs a number") }
        return CalcValue(number: try divideNumbers(value.number, .decimal(Decimal(100))), percentTerm: true, containsBaseLiteral: value.containsBaseLiteral)
    }

    static func power(_ lhs: CalcValue, _ rhs: CalcValue) throws -> CalcValue {
        try rejectTemperatureArithmetic(lhs, rhs)
        if let unit = lhs.unit {
            guard rhs.isScalar, let exponent = integerValue(rhs.number), exponent.magnitude.bitWidth <= 7 else {
                throw CalcError.message("unit exponent must be an integer")
            }
            let signedExponent = exponent.negative ? -Int(exponent.magnitude.lo) : Int(exponent.magnitude.lo)
            return CalcValue(number: try numberPower(lhs.number, rhs.number), unit: unit.raised(to: signedExponent), containsBaseLiteral: lhs.containsBaseLiteral || rhs.containsBaseLiteral)
        }
        guard lhs.isScalar, rhs.isScalar else { throw CalcError.message("power needs numbers") }
        return CalcValue(number: try numberPower(lhs.number, rhs.number), containsBaseLiteral: lhs.containsBaseLiteral || rhs.containsBaseLiteral)
    }

    static func factorial(_ value: CalcValue) throws -> CalcValue {
        guard value.isScalar, let integer = integerValue(value.number), !integer.negative, integer.magnitude.hi == 0, integer.magnitude.lo <= 1000 else {
            if let integer = integerValue(value.number), integer.negative || integer.magnitude.lo > 1000 || integer.magnitude.hi != 0 { throw CalcError.message("too large") }
            throw CalcError.message("factorial needs an integer")
        }
        let n = Int(integer.magnitude.lo)
        if n <= 34 {
            var result = Decimal(1)
            if n >= 2 {
                for value in 2...n { result = decimalMultiply(result, Decimal(value)) }
            }
            return CalcValue(number: .decimal(result), containsBaseLiteral: value.containsBaseLiteral)
        }
        var result = 1.0
        if n >= 2 {
            if n <= 170 {
                for value in 2...n { result *= Double(value) }
            } else {
                var logarithm = 0.0
                for value in 2...n { logarithm += log10(Double(value)) }
                let exponent = Int(floor(logarithm))
                let mantissa = pow(10, logarithm - Double(exponent))
                return CalcValue(number: .scientific(mantissa: mantissa, exponent: exponent), containsBaseLiteral: value.containsBaseLiteral)
            }
        }
        try validate(.double(result))
        return CalcValue(number: .double(result), containsBaseLiteral: value.containsBaseLiteral)
    }

    static func bitwise(_ lhs: CalcValue, _ rhs: CalcValue, operation: (UInt64, UInt64) -> UInt64) throws -> CalcValue {
        guard lhs.isScalar, rhs.isScalar, let left = integerValue(lhs.number), let right = integerValue(rhs.number) else {
            throw CalcError.message("not an integer")
        }
        return CalcValue(number: numberFromInteger(SignedInt128.bitwise(left, right, operation: operation)), containsBaseLiteral: lhs.containsBaseLiteral || rhs.containsBaseLiteral)
    }

    static func bitwiseNot(_ value: CalcValue) throws -> CalcValue {
        guard value.isScalar, let integer = integerValue(value.number) else { throw CalcError.message("not an integer") }
        return CalcValue(number: numberFromInteger(~integer), containsBaseLiteral: value.containsBaseLiteral)
    }

    static func shift(_ lhs: CalcValue, _ rhs: CalcValue, right: Bool) throws -> CalcValue {
        guard lhs.isScalar, rhs.isScalar, let left = integerValue(lhs.number), let shift = integerValue(rhs.number), !shift.negative, shift.magnitude.hi == 0, shift.magnitude.lo <= 127 else {
            throw CalcError.message("not an integer")
        }
        guard let result = SignedInt128.shifted(left, count: Int(shift.magnitude.lo), right: right) else {
            throw CalcError.message("too large")
        }
        return CalcValue(number: numberFromInteger(result), containsBaseLiteral: lhs.containsBaseLiteral || rhs.containsBaseLiteral)
    }

    static func function(_ name: String, arguments: [CalcValue], rates: (any CurrencyRateProvider)?) throws -> CalcValue {
        switch name {
        case "sqrt":
            try requireCount(arguments, 1...1)
            let x = try scalar(arguments[0])
            guard x >= 0 else { throw CalcError.message("complex result") }
            return CalcValue(number: checkedDouble(sqrt(x)), containsBaseLiteral: arguments[0].containsBaseLiteral)
        case "cbrt":
            try requireCount(arguments, 1...1)
            let x = try scalar(arguments[0])
            return CalcValue(number: checkedDouble(x < 0 ? -pow(-x, 1.0 / 3.0) : pow(x, 1.0 / 3.0)), containsBaseLiteral: arguments[0].containsBaseLiteral)
        case "abs":
            try requireCount(arguments, 1...1)
            var result = arguments[0]
            switch arguments[0].number {
            case .double: result.number = .double(abs(arguments[0].number.asDouble))
            case .decimal: result.number = .decimal(decimalAbs(arguments[0].number))
            case let .integer(integer): result.number = .integer(SignedInt128(negative: false, magnitude: integer.magnitude))
            case let .scientific(mantissa, exponent): result.number = .scientific(mantissa: abs(mantissa), exponent: exponent)
            }
            result.percentTerm = false
            return result
        case "round":
            try requireCount(arguments, 1...2)
            guard arguments[0].isScalar else { throw CalcError.message("function needs a number") }
            let scale = arguments.count == 2 ? try signedIntegerArgument(arguments[1]) : 0
            guard scale >= -1000, scale <= 1000 else { throw CalcError.message("too large") }
            return CalcValue(number: roundNumber(arguments[0].number, scale: scale), containsBaseLiteral: arguments[0].containsBaseLiteral)
        case "floor": return try roundingFunction(arguments, mode: .down, towardZero: false)
        case "ceil": return try roundingFunction(arguments, mode: .up, towardZero: false)
        case "trunc", "int": return try roundingFunction(arguments, mode: .down, towardZero: true)
        case "ln": return try unaryMath(arguments, positiveInput: true, operation: log)
        case "log10": return try unaryMath(arguments, positiveInput: true, operation: log10)
        case "log2": return try unaryMath(arguments, positiveInput: true, operation: log2)
        case "exp": return try unaryMath(arguments, positiveInput: false, operation: exp)
        case "log":
            try requireCount(arguments, 1...2)
            let x = try scalar(arguments[0])
            let result: Double
            if arguments.count == 1 {
                result = log(x)
            } else {
                let base = try scalar(arguments[1])
                result = log(x) / log(base)
            }
            if arguments.count == 2 {
                let base = try scalar(arguments[1])
                guard base > 0, base != 1 else { throw CalcError.message("math domain error") }
            }
            guard x > 0, result.isFinite else { throw CalcError.message("math domain error") }
            return CalcValue(number: .double(result), containsBaseLiteral: arguments.contains(where: { $0.containsBaseLiteral }))
        case "sin": return try trig(arguments, operation: sin)
        case "cos": return try trig(arguments, operation: cos)
        case "tan": return try trig(arguments, operation: tan)
        case "asin": return try trig(arguments, operation: asin)
        case "acos": return try trig(arguments, operation: acos)
        case "atan": return try trig(arguments, operation: atan)
        case "sinh": return try trig(arguments, operation: sinh)
        case "cosh": return try trig(arguments, operation: cosh)
        case "tanh": return try trig(arguments, operation: tanh)
        case "atan2":
            try requireCount(arguments, 2...2)
            return CalcValue(number: checkedDouble(atan2(try scalar(arguments[0]), try scalar(arguments[1]))))
        case "hypot":
            try requireCount(arguments, 2...2)
            return CalcValue(number: checkedDouble(hypot(try scalar(arguments[0]), try scalar(arguments[1]))))
        case "min", "max":
            guard !arguments.isEmpty else { throw CalcError.message("invalid arguments") }
            let values = try arguments.map { try scalar($0) }
            let result = name == "min" ? values.min()! : values.max()!
            return CalcValue(number: .double(result))
        case "gcd", "lcm":
            guard arguments.count == 2, let lhs = integerValue(arguments[0].number), let rhs = integerValue(arguments[1].number), arguments.allSatisfy({ $0.isScalar }) else {
                throw CalcError.message("not an integer")
            }
            let result = name == "gcd" ? gcd(lhs, rhs) : lcm(lhs, rhs)
            return CalcValue(number: numberFromInteger(result))
        case "factorial":
            try requireCount(arguments, 1...1)
            return try factorial(arguments[0])
        case "degrees":
            try requireCount(arguments, 1...1)
            return CalcValue(number: checkedDouble(try scalar(arguments[0]) * 180.0 / Double.pi))
        case "radians":
            try requireCount(arguments, 1...1)
            return CalcValue(number: checkedDouble(try scalar(arguments[0]) * Double.pi / 180.0))
        case "pow":
            try requireCount(arguments, 2...2)
            return try power(arguments[0], arguments[1])
        case "hex", "bin", "oct":
            try requireCount(arguments, 1...1)
            guard let integer = integerValue(arguments[0].number), arguments[0].isScalar else { throw CalcError.message("not an integer") }
            let format: BaseFormat = name == "hex" ? .hexadecimal : (name == "bin" ? .binary : .octal)
            return CalcValue(number: numberFromInteger(integer), containsBaseLiteral: arguments[0].containsBaseLiteral, baseFormat: format)
        default:
            throw CalcError.message("unknown function")
        }
    }

    static func convert(_ value: CalcValue, to target: ConversionTarget, rates: (any CurrencyRateProvider)?) throws -> CalcValue {
        switch target {
        case let .base(format):
            guard value.isScalar, integerValue(value.number) != nil else { throw CalcError.message("not an integer") }
            var result = value
            result.baseFormat = format == .decimal ? nil : format
            result.percentTerm = false
            return result
        case let .unit(targetUnit):
            guard let sourceUnit = value.unit else {
                if value.currency != nil { throw CalcError.message("can't convert currency to \(targetUnit.dimension.name)") }
                throw CalcError.message("can't convert number to \(targetUnit.symbol)")
            }
            guard sourceUnit.dimension == targetUnit.dimension else {
                throw CalcError.message("can't convert \(sourceUnit.dimension.name) to \(targetUnit.dimension.name)")
            }
            let canonical = value.number.asDouble * sourceUnit.scale + sourceUnit.offset
            let converted = (canonical - targetUnit.offset) / targetUnit.scale
            try validate(.double(converted))
            return CalcValue(number: .double(converted), unit: targetUnit, containsBaseLiteral: value.containsBaseLiteral)
        case let .currency(targetCode):
            var sourceCode = value.currency
            var sourceUnit = value.unit
            if sourceCode == nil, let ambiguous = sourceUnit?.ambiguousCurrencyCode {
                sourceCode = ambiguous
                sourceUnit = nil
            }
            guard let sourceCode, sourceUnit == nil else {
                throw CalcError.message("currency conversion needs a currency amount")
            }
            guard let snapshot = rates?.currentRates() else { throw CalcError.message("exchange rates not loaded yet") }
            let factor = try snapshot.conversionRate(from: sourceCode, to: targetCode)
            let converted = try multiplyNumbers(value.number, .double(factor))
            return CalcValue(
                number: converted,
                currency: targetCode,
                containsBaseLiteral: value.containsBaseLiteral,
                detail: currencyDetail(source: sourceCode, target: targetCode, rate: factor, snapshot: snapshot)
            )
        }
    }

    private static func combine(
        _ lhs: CalcValue,
        _ rhs: CalcValue,
        operation: (CalcNumber, CalcNumber) -> CalcNumber,
        rates: (any CurrencyRateProvider)?
    ) throws -> CalcValue {
        if let lhsCurrency = lhs.currency, let rhsCurrency = rhs.currency {
            let right = try convertCurrency(rhs.number, from: rhsCurrency, to: lhsCurrency, rates: rates)
            return CalcValue(number: operation(lhs.number, right), currency: lhsCurrency, containsBaseLiteral: lhs.containsBaseLiteral || rhs.containsBaseLiteral)
        }
        if lhs.currency != nil || rhs.currency != nil { throw CalcError.message("currency arithmetic needs two currencies") }
        if let lhsUnit = lhs.unit, let rhsUnit = rhs.unit {
            guard lhsUnit.dimension == rhsUnit.dimension else {
                throw CalcError.message("can't combine \(lhsUnit.dimension.name) and \(rhsUnit.dimension.name)")
            }
            if lhsUnit.isTemperature || rhsUnit.isTemperature { throw CalcError.message("temperature arithmetic isn't supported") }
            let rightCanonical = rhs.number.asDouble * rhsUnit.scale
            let rightInLeft = rightCanonical / lhsUnit.scale
            return CalcValue(number: operation(lhs.number, .double(rightInLeft)), unit: lhsUnit, containsBaseLiteral: lhs.containsBaseLiteral || rhs.containsBaseLiteral)
        }
        if lhs.unit != nil || rhs.unit != nil { throw CalcError.message("unit mismatch") }
        return CalcValue(number: operation(lhs.number, rhs.number), containsBaseLiteral: lhs.containsBaseLiteral || rhs.containsBaseLiteral)
    }

    private static func convertCurrency(_ number: CalcNumber, from: String, to: String, rates: (any CurrencyRateProvider)?) throws -> CalcNumber {
        guard let snapshot = rates?.currentRates() else { throw CalcError.message("exchange rates not loaded yet") }
        return try multiplyNumbers(number, .double(snapshot.conversionRate(from: from, to: to)))
    }

    private static func currencyDetail(source: String, target: String, rate: Double, snapshot: CurrencyRates) -> String {
        let rateText = normalizedExponent(String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), rate))
        let date: String
        if let publishedAt = snapshot.publishedAt {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            date = formatter.string(from: publishedAt)
        } else {
            date = "unknown date"
        }
        return "1 \(source) = \(rateText) \(target) · \(date) · \(snapshot.source ?? "Rates")"
    }

    private static func rejectTemperatureArithmetic(_ lhs: CalcValue, _ rhs: CalcValue) throws {
        if lhs.isTemperature || rhs.isTemperature { throw CalcError.message("temperature arithmetic isn't supported") }
    }

    private static func scalar(_ value: CalcValue) throws -> Double {
        if let unit = value.unit {
            if unit.dimension == UnitDimension(angle: 1) {
                return value.number.asDouble * unit.scale + unit.offset
            }
            throw CalcError.message("function needs a number")
        }
        guard value.currency == nil else { throw CalcError.message("function needs a number") }
        let result = value.number.asDouble
        try validate(.double(result))
        return result
    }

    private static func signedIntegerArgument(_ value: CalcValue) throws -> Int {
        guard value.isScalar, let integer = integerValue(value.number), integer.magnitude.hi == 0,
              integer.magnitude.lo <= UInt64(Int.max) else { throw CalcError.message("not an integer") }
        let magnitude = Int(integer.magnitude.lo)
        return integer.negative ? -magnitude : magnitude
    }

    private static func requireCount(_ arguments: [CalcValue], _ range: ClosedRange<Int>) throws {
        guard range.contains(arguments.count) else { throw CalcError.message("invalid arguments") }
    }

    private static func unaryMath(_ arguments: [CalcValue], positiveInput: Bool, operation: (Double) -> Double) throws -> CalcValue {
        try requireCount(arguments, 1...1)
        let input = try scalar(arguments[0])
        if positiveInput, input <= 0 { throw CalcError.message("math domain error") }
        let result = operation(input)
        guard result.isFinite else { throw CalcError.message("math domain error") }
        return CalcValue(number: .double(result), containsBaseLiteral: arguments[0].containsBaseLiteral)
    }

    private static func trig(_ arguments: [CalcValue], operation: (Double) -> Double) throws -> CalcValue {
        try requireCount(arguments, 1...1)
        let result = operation(try scalar(arguments[0]))
        guard result.isFinite else { throw CalcError.message("math domain error") }
        return CalcValue(number: .double(result), containsBaseLiteral: arguments[0].containsBaseLiteral)
    }

    private static func roundingFunction(_ arguments: [CalcValue], mode: Decimal.RoundingMode, towardZero: Bool) throws -> CalcValue {
        try requireCount(arguments, 1...1)
        let value = arguments[0]
        guard value.isScalar else { throw CalcError.message("function needs a number") }
        if case let .decimal(decimal) = value.number {
            var result = Decimal()
            var input = decimal
            let decimalMode: Decimal.RoundingMode
            if towardZero {
                decimalMode = decimal < 0 ? .up : .down
            } else {
                decimalMode = mode
            }
            NSDecimalRound(&result, &input, 0, decimalMode)
            return CalcValue(number: .decimal(result), containsBaseLiteral: value.containsBaseLiteral)
        }
        let double = value.number.asDouble
        let rounded: Double
        switch mode {
        case .down: rounded = floor(double)
        case .up: rounded = ceil(double)
        default: rounded = double.rounded(.towardZero)
        }
        return CalcValue(number: .double(rounded), containsBaseLiteral: value.containsBaseLiteral)
    }

    private static func gcd(_ lhs: SignedInt128, _ rhs: SignedInt128) -> SignedInt128 {
        var a = lhs.magnitude
        var b = rhs.magnitude
        while !b.isZero {
            let remainder = a.remainder(dividingBy: b)
            a = remainder
            swap(&a, &b)
        }
        return SignedInt128(negative: false, magnitude: a)
    }

    private static func lcm(_ lhs: SignedInt128, _ rhs: SignedInt128) -> SignedInt128 {
        let divisor = gcd(lhs, rhs).magnitude.lo
        guard divisor != 0, let quotient = BigUInt128.dividedBySmall(lhs.magnitude, divisor)?.quotient,
              let product = BigUInt128.multipliedBySmall(quotient, rhs.magnitude.lo)
        else { return SignedInt128(negative: false, magnitude: .zero) }
        return SignedInt128(negative: false, magnitude: product)
    }

    private static func roundNumber(_ number: CalcNumber, scale: Int) -> CalcNumber {
        switch number {
        case let .decimal(value):
            var result = Decimal()
            var input = value
            NSDecimalRound(&result, &input, scale, .bankers)
            return .decimal(result)
        case let .integer(integer):
            if scale == 0 { return .integer(integer) }
            let factor = pow(10, Double(scale))
            let value = Double(integer.decimalString()) ?? (integer.negative ? -.infinity : .infinity)
            return .double((value * factor).rounded(.toNearestOrEven) / factor)
        case let .double(value):
            let factor = pow(10, Double(scale))
            return .double((value * factor).rounded(.toNearestOrEven) / factor)
        case .scientific:
            return number
        }
    }

    private static func numberPower(_ lhs: CalcNumber, _ rhs: CalcNumber) throws -> CalcNumber {
        let exponent = rhs.asDouble
        guard exponent.isFinite else { throw CalcError.message("too large") }
        if exponent == 0 { return .decimal(Decimal(1)) }
        let base = lhs.asDouble
        if base == 0, exponent < 0 { throw CalcError.message("division by zero") }
        if base < 0, exponent.rounded(.towardZero) != exponent { throw CalcError.message("complex result") }
        if abs(base) > 1, abs(exponent) * log10(abs(base)) >= 1000 { throw CalcError.message("too large") }
        if abs(exponent) > 100_000 { throw CalcError.message("too large") }

        if let exponentInteger = integerValue(rhs), exponentInteger.magnitude.hi == 0, exponentInteger.magnitude.lo <= 1000 {
            let signedExponent = exponentInteger.negative ? -Int(exponentInteger.magnitude.lo) : Int(exponentInteger.magnitude.lo)
            if case let .decimal(decimalBase) = lhs,
               signedExponent <= 0 || abs(NSDecimalNumber(decimal: decimalBase).doubleValue) <= 1 || Double(abs(signedExponent)) * log10(abs(NSDecimalNumber(decimal: decimalBase).doubleValue)) < 38 {
                var result = Decimal(1)
                let count = abs(signedExponent)
                if count > 0 {
                    for _ in 0..<count { result = decimalMultiply(result, decimalBase) }
                }
                if signedExponent < 0 {
                    guard result != 0 else { throw CalcError.message("division by zero") }
                    result = decimalDivide(Decimal(1), result)
                }
                if let exact = Decimal(string: NSDecimalNumber(decimal: result).stringValue, locale: Locale(identifier: "en_US_POSIX")) {
                    return .decimal(exact)
                }
            }
        }
        let result = pow(base, exponent)
        guard result.isFinite else { throw CalcError.message("too large") }
        return .double(result)
    }

    private static func checkedDouble(_ value: Double) -> CalcNumber {
        .double(value)
    }

    fileprivate static func validate(_ number: CalcNumber) throws {
        switch number {
        case .decimal: return
        case let .double(value):
            guard value.isFinite else { throw CalcError.message("too large") }
        case .integer: return
        case let .scientific(mantissa, exponent):
            guard mantissa.isFinite, exponent >= -100_000, exponent <= 100_000 else { throw CalcError.message("too large") }
        }
    }
}

private func decimalMultiply(_ lhs: Decimal, _ rhs: Decimal) -> Decimal {
    var result = Decimal()
    var left = lhs
    var right = rhs
    NSDecimalMultiply(&result, &left, &right, .plain)
    return result
}

private func decimalDivide(_ lhs: Decimal, _ rhs: Decimal) -> Decimal {
    var result = Decimal()
    var left = lhs
    var right = rhs
    NSDecimalDivide(&result, &left, &right, .plain)
    return result
}

private func addNumbers(_ lhs: CalcNumber, _ rhs: CalcNumber) -> CalcNumber {
    if case let .decimal(left) = lhs, case let .decimal(right) = rhs {
        var result = Decimal()
        var lhs = left
        var rhs = right
        NSDecimalAdd(&result, &lhs, &rhs, .plain)
        return .decimal(result)
    }
    return .double(lhs.asDouble + rhs.asDouble)
}

private func subtractNumbers(_ lhs: CalcNumber, _ rhs: CalcNumber) -> CalcNumber {
    if case let .decimal(left) = lhs, case let .decimal(right) = rhs {
        var result = Decimal()
        var lhs = left
        var rhs = right
        NSDecimalSubtract(&result, &lhs, &rhs, .plain)
        return .decimal(result)
    }
    return .double(lhs.asDouble - rhs.asDouble)
}

private func multiplyNumbers(_ lhs: CalcNumber, _ rhs: CalcNumber) throws -> CalcNumber {
    let result: CalcNumber
    if case let .decimal(left) = lhs, case let .decimal(right) = rhs {
        result = .decimal(decimalMultiply(left, right))
    } else {
        result = .double(lhs.asDouble * rhs.asDouble)
    }
    try Evaluator.validate(result)
    return result
}

private func divideNumbers(_ lhs: CalcNumber, _ rhs: CalcNumber) throws -> CalcNumber {
    guard !rhs.isZero else { throw CalcError.message("division by zero") }
    let result: CalcNumber
    if case let .decimal(left) = lhs, case let .decimal(right) = rhs {
        result = .decimal(decimalDivide(left, right))
    } else {
        result = .double(lhs.asDouble / rhs.asDouble)
    }
    try Evaluator.validate(result)
    return result
}

private func negate(_ number: CalcNumber) -> CalcNumber {
        switch number {
        case let .decimal(value): return .decimal(-value)
        case let .double(value): return .double(-value)
        case let .integer(value): return .integer(SignedInt128(negative: !value.negative, magnitude: value.magnitude))
        case let .scientific(mantissa, exponent): return .scientific(mantissa: -mantissa, exponent: exponent)
    }
}

private func decimalAbs(_ number: CalcNumber) -> Decimal {
    switch number {
        case let .decimal(value): return value < 0 ? -value : value
        case let .double(value): return Decimal(value)
        case let .integer(value): return Decimal(string: value.decimalString(), locale: Locale(identifier: "en_US_POSIX")) ?? 0
        case let .scientific(mantissa, _): return Decimal(mantissa)
    }
}

private extension CurrencyRates {
    func conversionRate(from: String, to: String) throws -> Double {
        let source = from.uppercased()
        let destination = to.uppercased()
        let sourceRate = source == base.uppercased() ? 1 : rates[source]
        let targetRate = destination == base.uppercased() ? 1 : rates[destination]
        guard let sourceRate, let targetRate, sourceRate > 0, targetRate > 0, sourceRate.isFinite, targetRate.isFinite else {
            throw CalcError.message("unknown currency")
        }
        return targetRate / sourceRate
    }
}
