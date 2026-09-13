import Foundation

enum CalcError: Error, Equatable {
    case incomplete
    case message(String)
}

extension JSONDecoder {
    static var calcDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var calcEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

enum BaseFormat: Sendable, Equatable {
    case hexadecimal
    case binary
    case octal
    case decimal
}

enum CalcNumber: Sendable, Equatable {
    case decimal(Decimal)
    case double(Double)
    case integer(SignedInt128)
    /// A bounded scientific value used for permitted factorials beyond Double's
    /// finite range. It retains a useful 15-digit mantissa without pretending
    /// that the full integer is representable by Foundation.Decimal.
    case scientific(mantissa: Double, exponent: Int)

    var asDouble: Double {
        switch self {
        case let .decimal(value): return NSDecimalNumber(decimal: value).doubleValue
        case let .double(value): return value
        case let .integer(value): return Double(value.decimalString()) ?? (value.negative ? -.infinity : .infinity)
        case let .scientific(mantissa, exponent): return mantissa * pow(10, Double(exponent))
        }
    }

    var isFinite: Bool {
        switch self {
        case .decimal: return true
        case let .double(value): return value.isFinite
        case .integer: return true
        case let .scientific(mantissa, exponent): return mantissa.isFinite && exponent >= -100_000 && exponent <= 100_000
        }
    }

    var isZero: Bool {
        switch self {
        case let .decimal(value): return value == 0
        case let .double(value): return value == 0
        case let .integer(value): return value.isZero
        case let .scientific(mantissa, _): return mantissa == 0
        }
    }

    var isInteger: Bool {
        switch self {
        case let .decimal(value): return decimalIsInteger(value)
        case let .double(value): return value.isFinite && value.rounded(.towardZero) == value
        case .integer: return true
        case .scientific: return true
        }
    }
}

struct CalcValue: Sendable, Equatable {
    var number: CalcNumber
    var unit: CalcUnit?
    var currency: String?
    var percentTerm: Bool = false
    var containsBaseLiteral: Bool = false
    var baseFormat: BaseFormat?
    var detail: String?

    init(
        number: CalcNumber,
        unit: CalcUnit? = nil,
        currency: String? = nil,
        percentTerm: Bool = false,
        containsBaseLiteral: Bool = false,
        baseFormat: BaseFormat? = nil,
        detail: String? = nil
    ) {
        self.number = number
        self.unit = unit
        self.currency = currency
        self.percentTerm = percentTerm
        self.containsBaseLiteral = containsBaseLiteral
        self.baseFormat = baseFormat
        self.detail = detail
    }

    var isScalar: Bool { unit == nil && currency == nil }
    var isTemperature: Bool { unit?.isTemperature == true }
}

struct BigUInt128: Equatable, Comparable, Sendable {
    var lo: UInt64 = 0
    var hi: UInt64 = 0

    static let zero = BigUInt128()

    var isZero: Bool { lo == 0 && hi == 0 }
    var bitWidth: Int {
        if hi != 0 { return 64 + (64 - hi.leadingZeroBitCount) }
        if lo != 0 { return 64 - lo.leadingZeroBitCount }
        return 0
    }

    static func < (lhs: BigUInt128, rhs: BigUInt128) -> Bool {
        lhs.hi == rhs.hi ? lhs.lo < rhs.lo : lhs.hi < rhs.hi
    }

    static func adding(_ lhs: BigUInt128, _ rhs: BigUInt128) -> BigUInt128? {
        let lo = lhs.lo.addingReportingOverflow(rhs.lo)
        let hi = lhs.hi.addingReportingOverflow(rhs.hi)
        let hiWithCarry = hi.partialValue.addingReportingOverflow(lo.overflow ? 1 : 0)
        guard !hi.overflow && !hiWithCarry.overflow else { return nil }
        return BigUInt128(lo: lo.partialValue, hi: hiWithCarry.partialValue)
    }

    static func subtracting(_ lhs: BigUInt128, _ rhs: BigUInt128) -> BigUInt128? {
        guard lhs >= rhs else { return nil }
        let lo = lhs.lo.subtractingReportingOverflow(rhs.lo)
        let hi = lhs.hi.subtractingReportingOverflow(rhs.hi)
        let hiWithBorrow = hi.partialValue.subtractingReportingOverflow(lo.overflow ? 1 : 0)
        guard !hiWithBorrow.overflow else { return nil }
        return BigUInt128(lo: lo.partialValue, hi: hiWithBorrow.partialValue)
    }

    static func multipliedBySmall(_ value: BigUInt128, _ multiplier: UInt64) -> BigUInt128? {
        if multiplier == 0 || value.isZero { return .zero }
        let lowProduct = value.lo.multipliedFullWidth(by: multiplier)
        let highProduct = value.hi.multipliedFullWidth(by: multiplier)
        let carry = lowProduct.high
        let hi = highProduct.low.addingReportingOverflow(carry)
        guard highProduct.high == 0 && !hi.overflow else { return nil }
        return BigUInt128(lo: lowProduct.low, hi: hi.partialValue)
    }

    static func dividedBySmall(_ value: BigUInt128, _ divisor: UInt64) -> (quotient: BigUInt128, remainder: UInt64)? {
        guard divisor > 0 else { return nil }
        // Dividing a two-limb integer from the high limb keeps the intermediate
        // remainder below the divisor and avoids any arbitrary-precision dependency.
        let qHi = value.hi / divisor
        let remHi = value.hi % divisor
        let lowDivision = divisor.dividingFullWidth((high: remHi, low: value.lo))
        return (BigUInt128(lo: lowDivision.quotient, hi: qHi), lowDivision.remainder)
    }

    func shiftedLeft(_ count: Int) -> BigUInt128? {
        guard count >= 0, count < 128 else { return isZero ? .zero : nil }
        if count == 0 { return self }
        if count >= 64 {
            guard hi == 0 else { return nil }
            let shifted = lo << (count - 64)
            if count > 64 && lo >> (128 - count) != 0 { return nil }
            return BigUInt128(lo: 0, hi: shifted)
        }
        if hi >> (64 - count) != 0 { return nil }
        return BigUInt128(lo: lo << count, hi: (hi << count) | (lo >> (64 - count)))
    }

    static func multiplied(_ lhs: BigUInt128, _ rhs: BigUInt128) -> BigUInt128? {
        let low = lhs.lo.multipliedFullWidth(by: rhs.lo)
        let crossLeft = lhs.lo.multipliedFullWidth(by: rhs.hi)
        let crossRight = lhs.hi.multipliedFullWidth(by: rhs.lo)
        let middleFirst = low.high.addingReportingOverflow(crossLeft.low)
        let middle = middleFirst.partialValue.addingReportingOverflow(crossRight.low)
        let highCarry = (middleFirst.overflow ? 1 : 0) + (middle.overflow ? 1 : 0)
        let highFirst = crossLeft.high.addingReportingOverflow(crossRight.high)
        let high = highFirst.partialValue.addingReportingOverflow(UInt64(highCarry))
        guard !highFirst.overflow, !high.overflow, high.partialValue == 0 else { return nil }
        return BigUInt128(lo: low.low, hi: middle.partialValue)
    }

    func shiftedRight(_ count: Int) -> BigUInt128 {
        guard count >= 0 else { return self }
        if count >= 128 { return .zero }
        if count >= 64 { return BigUInt128(lo: hi >> (count - 64), hi: 0) }
        if count == 0 { return self }
        return BigUInt128(lo: (lo >> count) | (hi << (64 - count)), hi: hi >> count)
    }

    func bit(at index: Int) -> UInt64 {
        guard index >= 0, index < 128 else { return 0 }
        return index < 64 ? (lo >> index) & 1 : (hi >> (index - 64)) & 1
    }

    func remainder(dividingBy divisor: BigUInt128) -> BigUInt128 {
        guard !divisor.isZero else { return self }
        var remainder = BigUInt128.zero
        for index in stride(from: 127, through: 0, by: -1) {
            let shifted = BigUInt128(lo: remainder.lo << 1, hi: (remainder.hi << 1) | (remainder.lo >> 63))
            remainder = BigUInt128(lo: shifted.lo | bit(at: index), hi: shifted.hi)
            if remainder >= divisor { remainder = Self.subtracting(remainder, divisor) ?? .zero }
        }
        return remainder
    }

    func decimalString() -> String {
        if isZero { return "0" }
        var value = self
        var digits = ""
        while !value.isZero {
            guard let division = Self.dividedBySmall(value, 10) else { break }
            digits.append(String(division.remainder))
            value = division.quotient
        }
        return String(digits.reversed())
    }

    func radixString(_ radix: UInt64) -> String {
        if isZero { return "0" }
        var value = self
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var digits = ""
        while !value.isZero {
            guard let division = Self.dividedBySmall(value, radix) else { break }
            digits.append(alphabet[Int(division.remainder)])
            value = division.quotient
        }
        return String(digits.reversed())
    }
}

struct SignedInt128: Equatable, Sendable {
    var negative: Bool
    var magnitude: BigUInt128

    init(negative: Bool, magnitude: BigUInt128) {
        self.negative = magnitude.isZero ? false : negative
        self.magnitude = magnitude
    }

    var isZero: Bool { magnitude.isZero }

    static func fromDecimal(_ decimal: Decimal) -> SignedInt128? {
        guard decimalIsInteger(decimal) else { return nil }
        let string = NSDecimalNumber(decimal: decimal).stringValue
        return fromDecimalString(string)
    }

    static func fromDouble(_ value: Double) -> SignedInt128? {
        guard value.isFinite, value.rounded(.towardZero) == value else { return nil }
        guard abs(value) <= 1.7014118346046923e38 else { return nil }
        return fromDecimalString(String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value))
    }

    static func fromDecimalString(_ raw: String) -> SignedInt128? {
        var string = raw
        var negative = false
        if string.first == "-" {
            negative = true
            string.removeFirst()
        } else if string.first == "+" {
            string.removeFirst()
        }
        if string.isEmpty { return nil }

        var digits = string
        var exponent = 0
        if let eIndex = digits.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let exponentString = String(digits[digits.index(after: eIndex)...])
            exponent = Int(exponentString) ?? Int.min
            digits = String(digits[..<eIndex])
        }
        guard exponent != Int.min else { return nil }
        if let dot = digits.firstIndex(of: ".") {
            exponent -= digits.distance(from: dot, to: digits.endIndex) - 1
            digits.remove(at: dot)
        }
        digits = digits.filter { $0 != "_" }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber && $0.isASCII }) else { return nil }
        if exponent < 0 {
            let remove = min(digits.count, -exponent)
            if digits.suffix(remove).contains(where: { $0 != "0" }) { return nil }
            digits.removeLast(remove)
        } else if exponent > 0 {
            if digits.count + exponent > 39 { return nil }
            digits.append(contentsOf: repeatElement("0", count: exponent))
        }
        while digits.first == "0", digits.count > 1 { digits.removeFirst() }
        guard digits.count <= 39 else { return nil }

        var magnitude = BigUInt128.zero
        for character in digits {
            guard let digit = character.wholeNumberValue,
                  let next = BigUInt128.multipliedBySmall(magnitude, 10),
                  let sum = BigUInt128.adding(next, BigUInt128(lo: UInt64(digit), hi: 0))
            else { return nil }
            magnitude = sum
        }
        // Signed 128-bit values have an asymmetric range.
        let maximum = negative ? BigUInt128(lo: 0, hi: 0x8000_0000_0000_0000) : BigUInt128(lo: UInt64.max, hi: 0x7fff_ffff_ffff_ffff)
        guard magnitude <= maximum else { return nil }
        return SignedInt128(negative: negative, magnitude: magnitude)
    }

    func decimalString() -> String {
        negative ? "-" + magnitude.decimalString() : magnitude.decimalString()
    }

    func radixString(_ radix: UInt64, prefix: String) -> String {
        (negative ? "-" : "") + prefix + magnitude.radixString(radix)
    }

    func twosComplement() -> BigUInt128 {
        guard negative else { return magnitude }
        let (lo, loBorrow) = (0 as UInt64).subtractingReportingOverflow(magnitude.lo)
        let (hiAfter, _) = (0 as UInt64).subtractingReportingOverflow(magnitude.hi)
        let hi = hiAfter.subtractingReportingOverflow(loBorrow ? 1 : 0).partialValue
        return BigUInt128(lo: lo, hi: hi)
    }

    static func fromTwosComplement(_ bits: BigUInt128) -> SignedInt128 {
        guard bits.hi & 0x8000_0000_0000_0000 != 0 else {
            return SignedInt128(negative: false, magnitude: bits)
        }
        let (lo, loBorrow) = (0 as UInt64).subtractingReportingOverflow(bits.lo)
        let (hiAfter, _) = (0 as UInt64).subtractingReportingOverflow(bits.hi)
        let hi = hiAfter.subtractingReportingOverflow(loBorrow ? 1 : 0).partialValue
        return SignedInt128(negative: true, magnitude: BigUInt128(lo: lo, hi: hi))
    }

    static func bitwise(_ lhs: SignedInt128, _ rhs: SignedInt128, operation: (UInt64, UInt64) -> UInt64) -> SignedInt128 {
        let a = lhs.twosComplement()
        let b = rhs.twosComplement()
        return fromTwosComplement(BigUInt128(lo: operation(a.lo, b.lo), hi: operation(a.hi, b.hi)))
    }

    static prefix func ~ (value: SignedInt128) -> SignedInt128 {
        fromTwosComplement(BigUInt128(lo: ~value.twosComplement().lo, hi: ~value.twosComplement().hi))
    }

    static func shifted(_ value: SignedInt128, count: Int, right: Bool) -> SignedInt128? {
        guard count >= 0 else { return nil }
        if !right {
            guard let shifted = value.twosComplement().shiftedLeft(count) else { return nil }
            return fromTwosComplement(shifted)
        }
        if count >= 128 {
            return value.negative ? SignedInt128(negative: true, magnitude: BigUInt128(lo: 1, hi: 0)) : .init(negative: false, magnitude: .zero)
        }
        if !value.negative {
            return SignedInt128(negative: false, magnitude: value.magnitude.shiftedRight(count))
        }
        // Python shifts negative integers toward negative infinity. Add one
        // only when a discarded low bit is non-zero, avoiding overflow at the
        // -2^127 boundary.
        let quotient = value.magnitude.shiftedRight(count)
        let hasRemainder = count > 0 && (0..<min(count, 128)).contains(where: { value.magnitude.bit(at: $0) != 0 })
        let adjusted = hasRemainder ? BigUInt128.adding(quotient, BigUInt128(lo: 1, hi: 0)) ?? quotient : quotient
        return SignedInt128(negative: true, magnitude: adjusted)
    }
}

func decimalIsInteger(_ value: Decimal) -> Bool {
    var rounded = Decimal()
    var input = value
    NSDecimalRound(&rounded, &input, 0, .down)
    return rounded == value
}

func numberFromInteger(_ integer: SignedInt128) -> CalcNumber {
    .integer(integer)
}

func integerValue(_ number: CalcNumber) -> SignedInt128? {
    switch number {
    case let .decimal(value): return SignedInt128.fromDecimal(value)
    case let .double(value): return SignedInt128.fromDouble(value)
    case let .integer(value): return value
    case .scientific: return nil
    }
}

func normalizedExponent(_ string: String) -> String {
    guard let e = string.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return string }
    let mantissa = String(string[..<e])
    var exponent = String(string[string.index(after: e)...])
    var sign = ""
    if exponent.first == "+" || exponent.first == "-" {
        sign = exponent.removeFirst() == "-" ? "-" : ""
    }
    while exponent.first == "0", exponent.count > 1 { exponent.removeFirst() }
    return mantissa + "e" + sign + exponent
}
