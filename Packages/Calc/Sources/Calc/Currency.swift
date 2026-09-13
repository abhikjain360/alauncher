import Foundation

enum CurrencyFeedParser {
    static func parse(data: Data, fetchedAt: Date) -> CurrencyRates? {
        guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
            return nil
        }

        if let result = dictionary["result"] as? String, result.lowercased() == "success",
           let base = dictionary["base_code"] as? String,
           let rawRates = dictionary["rates"] as? [String: Any] {
            let rates = normalizedRates(rawRates)
            let published = unixDate(dictionary["time_last_update_unix"])
            let next = unixDate(dictionary["time_next_update_unix"])
            let source = "Rates by Exchange Rate API"
            let snapshot = CurrencyRates(base: base.uppercased(), rates: rates, publishedAt: published, fetchedAt: fetchedAt, source: source, nextUpdateAt: next)
            if isValid(snapshot) { return snapshot }
        }

        if let rawBase = dictionary["usd"] as? [String: Any] {
            let rates = normalizedRates(rawBase)
            let published = dateOnly(dictionary["date"] as? String)
            let source = "Rates by fawazahmed0 currency-api"
            let snapshot = CurrencyRates(base: "USD", rates: rates, publishedAt: published, fetchedAt: fetchedAt, source: source)
            if isValid(snapshot) { return snapshot }
        }
        return nil
    }

    static func isValid(_ snapshot: CurrencyRates) -> Bool {
        guard !snapshot.base.isEmpty, snapshot.rates.count >= 30 else { return false }
        return snapshot.rates.values.allSatisfy { $0 > 0 && $0.isFinite }
    }

    private static func normalizedRates(_ raw: [String: Any]) -> [String: Double] {
        var result: [String: Double] = [:]
        result.reserveCapacity(raw.count + 1)
        for (key, value) in raw {
            let number: Double?
            if let value = value as? Double { number = value }
            else if let value = value as? NSNumber { number = value.doubleValue }
            else { number = nil }
            if let number, number > 0, number.isFinite { result[key.uppercased()] = number }
        }
        return result
    }

    private static func unixDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        if let number = value as? Double { return Date(timeIntervalSince1970: number) }
        return nil
    }

    private static func dateOnly(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

extension CurrencyRates {
    func sameRateData(as other: CurrencyRates) -> Bool {
        base == other.base && rates == other.rates
    }
}
