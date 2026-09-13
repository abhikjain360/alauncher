import Foundation

enum Formatter {
    static func result(for value: CalcValue) throws -> CalcResult {
        try validate(value.number)
        if let base = value.baseFormat {
            guard let integer = integerValue(value.number) else { throw CalcError.message("not an integer") }
            let text: String
            switch base {
            case .hexadecimal: text = integer.radixString(16, prefix: "0x")
            case .binary: text = integer.radixString(2, prefix: "0b")
            case .octal: text = integer.radixString(8, prefix: "0o")
            case .decimal: text = integer.decimalString()
            }
            return CalcResult(display: text, copyText: text, detail: value.detail)
        }

        if let currency = value.currency {
            let displayNumber = currencyDisplay(value.number)
            let copyNumber = currencyCopy(value.number)
            return CalcResult(display: "\(displayNumber) \(currency)", copyText: "\(copyNumber) \(currency)", detail: value.detail)
        }

        let displayNumber = numberDisplay(value.number)
        let copyNumber = numberCopy(value.number)
        let suffix = value.unit.map { " \($0.symbol)" } ?? ""
        var detail = value.detail
        if detail == nil, value.containsBaseLiteral, value.unit == nil, value.currency == nil, let integer = integerValue(value.number) {
            detail = "\(integer.radixString(16, prefix: "0x")) · \(integer.radixString(2, prefix: "0b")) · \(integer.radixString(8, prefix: "0o"))"
        }
        return CalcResult(display: displayNumber + suffix, copyText: copyNumber + suffix, detail: detail)
    }

    static func numberDisplay(_ number: CalcNumber) -> String {
        switch number {
        case let .decimal(decimal):
            if decimalIsInteger(decimal) {
                let plain = NSDecimalNumber(decimal: decimal).stringValue
                return grouped(plain)
            }
            return displaySignificant(number.asDouble, significantDigits: 12)
        case let .integer(integer):
            return grouped(integer.decimalString())
        case let .double(value):
            return displaySignificant(value, significantDigits: 12)
        case let .scientific(mantissa, exponent):
            return scientific(mantissa: mantissa, exponent: exponent, significantDigits: 12)
        }
    }

    static func numberCopy(_ number: CalcNumber) -> String {
        switch number {
        case let .decimal(decimal): return NSDecimalNumber(decimal: decimal).stringValue
        case let .integer(integer): return integer.decimalString()
        case let .double(value): return significantString(value, significantDigits: 15)
        case let .scientific(mantissa, exponent): return scientific(mantissa: mantissa, exponent: exponent, significantDigits: 15)
        }
    }

    private static func currencyDisplay(_ number: CalcNumber) -> String {
        let value = number.asDouble
        if value != 0, abs(value) < 0.01 {
            return displaySignificant(value, significantDigits: 4)
        }
        return grouped(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value))
    }

    private static func currencyCopy(_ number: CalcNumber) -> String {
        let value = number.asDouble
        if value != 0, abs(value) < 0.01 { return significantString(value, significantDigits: 15) }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func displaySignificant(_ value: Double, significantDigits: Int) -> String {
        guard value != 0 else { return "0" }
        let absolute = abs(value)
        let scientific = absolute >= 1e15 || absolute < 1e-9
        let text = significantString(value, significantDigits: significantDigits)
        return scientific ? normalizedExponent(text) : grouped(trimmedFixed(text))
    }

    private static func significantString(_ value: Double, significantDigits: Int) -> String {
        normalizedExponent(String(format: "%.*g", locale: Locale(identifier: "en_US_POSIX"), significantDigits, value))
    }

    private static func scientific(mantissa: Double, exponent: Int, significantDigits: Int) -> String {
        let digitsAfterDecimal = max(0, significantDigits - 1)
        let text = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digitsAfterDecimal, mantissa)
        return trimmedFixed(text) + "e\(exponent)"
    }

    private static func trimmedFixed(_ value: String) -> String {
        guard !value.contains("e") else { return value }
        guard value.contains(".") else { return value }
        var result = value
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        if result == "-0" { return "0" }
        return result
    }

    private static func grouped(_ value: String) -> String {
        guard !value.contains("e"), !value.contains("E") else { return value }
        var value = value
        let sign = value.first == "-" || value.first == "+" ? String(value.removeFirst()) : ""
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(parts[0])
        var groupedInteger = ""
        for (index, character) in integer.enumerated() {
            if index > 0, (integer.count - index) % 3 == 0 { groupedInteger.append(",") }
            groupedInteger.append(character)
        }
        return sign + groupedInteger + (parts.count > 1 ? "." + parts[1] : "")
    }

    private static func validate(_ number: CalcNumber) throws {
        guard number.isFinite else { throw CalcError.message("too large") }
    }
}
