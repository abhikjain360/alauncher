import Foundation

/// A calculator answer, ready for the launcher's top row.
public struct CalcResult: Equatable, Sendable {
    /// Main line, e.g. `1,234.5`, `9,557.92 INR`, `0xff`.
    public var display: String
    /// What Enter copies: the value without grouping separators, e.g. `1234.5`.
    public var copyText: String
    /// Optional second line, e.g. `0xff · 0b11111111 · 0o377`, or the rate and its date for currency.
    public var detail: String?

    public init(display: String, copyText: String, detail: String? = nil) {
        self.display = display
        self.copyText = copyText
        self.detail = detail
    }
}

/// Exchange rates as units of each currency per one unit of `base`.
public struct CurrencyRates: Codable, Equatable, Sendable {
    /// ISO 4217 code, uppercase.
    public var base: String
    /// Uppercase ISO code → units per one `base`.
    public var rates: [String: Double]
    /// When the feed says the rates were published, if it says.
    public var publishedAt: Date?
    /// When they were fetched.
    public var fetchedAt: Date
    /// Human-readable attribution supplied by the feed.
    public var source: String?
    /// The feed's next scheduled update, when supplied.
    public var nextUpdateAt: Date?

    public init(
        base: String,
        rates: [String: Double],
        publishedAt: Date?,
        fetchedAt: Date,
        source: String? = nil,
        nextUpdateAt: Date? = nil
    ) {
        self.base = base
        self.rates = rates
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
        self.source = source
        self.nextUpdateAt = nextUpdateAt
    }
}

/// Supplies exchange rates without blocking the caller.
public protocol CurrencyRateProvider: Sendable {
    /// Rates currently in memory, or nil when none are loaded yet.
    func currentRates() -> CurrencyRates?
}

/// What the calculator made of the launcher input. See docs/calc-grammar.md.
public enum CalcOutcome: Equatable, Sendable {
    case result(CalcResult)
    /// A valid prefix of a calculation, such as `2 +` or `5 km to`.
    case incomplete
    /// Clearly a calculation, but invalid, such as `1/0`.
    case error(String)
    /// Plain words, a bare number, constant or quantity.
    case notACalculation
}

/// Evaluates launcher input: math, unit conversions, base conversions and currency.
public struct Calculator: Sendable {
    let rates: (any CurrencyRateProvider)?

    public init(rates: (any CurrencyRateProvider)? = nil) {
        self.rates = rates
    }

    public func evaluate(_ input: String) -> CalcOutcome {
        ExpressionEngine(rates: rates).evaluate(input)
    }
}

/// Keeps exchange rates in memory, cached on disk and refreshed from free keyless feeds.
public final class CurrencyRateStore: CurrencyRateProvider, @unchecked Sendable {
    private let cacheFile: URL
    private let maxAge: TimeInterval
    private let fetch: @Sendable () async throws -> Data
    private let lock = NSLock()
    private var rates: CurrencyRates?
    private var inFlight: Task<Bool, Never>?

    public convenience init(cacheFile: URL, maxAge: TimeInterval) {
        self.init(cacheFile: cacheFile, maxAge: maxAge, fetch: CurrencyRateStore.defaultFetch)
    }

    /// Creates a store with an injectable feed fetcher. The closure is useful for
    /// deterministic tests and may return either supported feed format.
    public init(
        cacheFile: URL,
        maxAge: TimeInterval,
        fetch: @escaping @Sendable () async throws -> Data
    ) {
        self.cacheFile = cacheFile
        self.maxAge = maxAge
        self.fetch = fetch
        self.rates = CurrencyRateStore.loadCache(from: cacheFile)
    }

    public func currentRates() -> CurrencyRates? {
        lock.lock()
        defer { lock.unlock() }
        return rates
    }

    /// Fetches fresh rates when the cached ones are older than `maxAge`. Cheap to call
    /// often; concurrent calls share one fetch. Returns true when the rates changed.
    @discardableResult
    public func refreshIfStale() async -> Bool {
        if let inFlight = beginRefreshIfNeeded() {
            let result = await inFlight.value
            finishRefresh()
            return result
        } else {
            return false
        }
    }

    private func beginRefreshIfNeeded() -> Task<Bool, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if let inFlight {
            return inFlight
        }

        let now = Date()
        if let rates, !CurrencyRateStore.isStale(rates, now: now, maxAge: maxAge) {
            return nil
        }

        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.fetchAndStore()
        }
        inFlight = task
        return task
    }

    private func finishRefresh() {
        lock.lock()
        inFlight = nil
        lock.unlock()
    }

    private func updateRates(_ fetched: CurrencyRates) -> Bool {
        lock.lock()
        let changed = rates == nil || rates?.sameRateData(as: fetched) == false
        rates = fetched
        lock.unlock()
        return changed
    }

    private func fetchAndStore() async -> Bool {
        do {
            let data = try await fetch()
            guard let fetched = CurrencyFeedParser.parse(data: data, fetchedAt: Date()) else {
                return false
            }

            let changed = updateRates(fetched)
            CurrencyRateStore.saveCache(fetched, to: cacheFile)
            return changed
        } catch {
            return false
        }
    }

    private static let defaultFetch: @Sendable () async throws -> Data = {
        guard let primary = URL(string: "https://open.er-api.com/v6/latest/USD") else {
            throw CalcError.message("invalid rates URL")
        }
        do {
            let request = URLRequest(url: primary, cachePolicy: .reloadIgnoringLocalCacheData)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw CalcError.message("rates request failed")
            }
            return data
        } catch {
            guard let fallback = URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json") else {
                throw CalcError.message("invalid rates URL")
            }
            let request = URLRequest(url: fallback, cachePolicy: .reloadIgnoringLocalCacheData)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw CalcError.message("rates request failed")
            }
            return data
        }
    }

    private static func loadCache(from url: URL) -> CurrencyRates? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.calcDecoder.decode(CurrencyRates.self, from: data),
              CurrencyFeedParser.isValid(decoded)
        else { return nil }
        return decoded
    }

    private static func saveCache(_ rates: CurrencyRates, to url: URL) {
        guard let data = try? JSONEncoder.calcEncoder.encode(rates) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func isStale(_ rates: CurrencyRates, now: Date, maxAge: TimeInterval) -> Bool {
        if maxAge <= 0 || now.timeIntervalSince(rates.fetchedAt) >= maxAge { return true }
        if let next = rates.nextUpdateAt, now >= next { return true }
        return false
    }
}
