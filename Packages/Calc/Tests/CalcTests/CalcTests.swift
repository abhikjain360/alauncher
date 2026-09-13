import Foundation
import Darwin
import Testing
@testable import Calc

private func result(_ calculator: Calculator, _ input: String) -> CalcResult? {
    if case let .result(value) = calculator.evaluate(input) { return value }
    return nil
}

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    return try Data(contentsOf: url)
}

private struct FixedRateProvider: CurrencyRateProvider {
    let snapshot: CurrencyRates

    func currentRates() -> CurrencyRates? { snapshot }
}

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite(.serialized)
struct CalcTestSuite {

@Test("contract arithmetic vectors")
func arithmeticVectors() {
    let calculator = Calculator()
    let vectors: [(String, String, String)] = [
        ("2+2", "4", "4"),
        ("2 ** 10", "1,024", "1024"),
        ("2 ^ 10", "1,024", "1024"),
        ("2 ** 3 ** 2", "512", "512"),
        ("-2 ** 2", "-4", "-4"),
        ("2 ** -1", "0.5", "0.5"),
        ("7 // 2", "3", "3"),
        ("-7 // 2", "-4", "-4"),
        ("17 % 5", "2", "2"),
        ("-7 % 3", "2", "2"),
        ("17 % -5", "-3", "-3"),
        ("17 mod 5", "2", "2"),
        ("200 + 15%", "230", "230"),
        ("200 - 10%", "180", "180"),
        ("15% of 80", "12", "12"),
        ("50 * 10%", "5", "5"),
        ("15% + 2", "2.15", "2.15"),
        ("0.1 + 0.2", "0.3", "0.3"),
        ("1/3", "0.333333333333", "0.33333333333333333333333333333333333333"),
        ("10/4", "2.5", "2.5"),
        ("1_000_000 * 3", "3,000,000", "3000000"),
        ("5!", "120", "120"),
        ("2pi", "6.28318530718", "6.28318530717959"),
        ("3(4+1)", "15", "15"),
        ("(1+2)(3+4)", "21", "21"),
        ("sqrt(2)*3", "4.24264068712", "4.24264068711929"),
        ("math.sqrt(16)", "4", "4"),
        ("log(100, 10)", "2", "2"),
        ("log(e)", "1", "1"),
        ("round(2.5)", "2", "2"),
        ("sin(30 deg)", "0.5", "0.5"),
        ("max(3, 9, 4)", "9", "9"),
        ("2**100", "1,267,650,600,228,229,401,496,703,205,376", "1267650600228229401496703205376")
    ]

    for (input, display, copy) in vectors {
        let actual = result(calculator, input)
        #expect(actual?.display == display, "\(input): \(String(describing: actual))")
        #expect(actual?.copyText == copy, "\(input): copy \(String(describing: actual))")
    }
}

@Test("contract base vectors")
func baseVectors() {
    let calculator = Calculator()
    let vectors: [(String, String, String)] = [
        ("0xff", "255", "255"),
        ("0xff + 1", "256", "256"),
        ("255 to hex", "0xff", "0xff"),
        ("0b1010 to hex", "0xa", "0xa"),
        ("0xff to bin", "0b11111111", "0b11111111"),
        ("10 to oct", "0o12", "0o12"),
        ("hex(255)", "0xff", "0xff"),
        ("0xf0 | 0x0f", "255", "255"),
        ("1 << 10", "1,024", "1024"),
        ("~5", "-6", "-6")
    ]
    for (input, display, copy) in vectors {
        let actual = result(calculator, input)
        #expect(actual?.display == display, "\(input): \(String(describing: actual))")
        #expect(actual?.copyText == copy)
    }
    #expect(result(calculator, "0xff + 1")?.detail == "0x100 · 0b100000000 · 0o400")
    #expect(calculator.evaluate("1.5 to hex") == .error("not an integer"))
}

@Test("contract units")
func unitVectors() {
    let calculator = Calculator()
    let vectors: [(String, String)] = [
        ("5 km to mi", "3.10685596119 mi"),
        ("5 km in mi", "3.10685596119 mi"),
        ("70 F to C", "21.1111111111 °C"),
        ("0 c to f", "32 °F"),
        ("5 ft + 3 in to cm", "160.02 cm"),
        ("5 ft + 3 in", "5.25 ft"),
        ("5 in to cm", "12.7 cm"),
        ("10 km / 2 h", "5 km/h"),
        ("100 kmh to mph", "62.1371192237 mph"),
        ("3 GB to MiB", "2,861.02294922 MiB"),
        ("1 GiB to MB", "1,073.741824 MB"),
        ("2 cup to ml", "473.176473 ml")
    ]
    for (input, display) in vectors {
        #expect(result(calculator, input)?.display == display, "\(input): \(String(describing: result(calculator, input)))")
    }
    #expect(calculator.evaluate("5 km to kg") == .error("can't convert length to mass"))
    #expect(calculator.evaluate("20 C + 5 C") == .error("temperature arithmetic isn't supported"))
    #expect(calculator.evaluate("5 km") == .notACalculation)
}

@Test("classification and limits")
func classificationAndLimits() {
    let calculator = Calculator()
    #expect(calculator.evaluate("100 usd") == .notACalculation)
    #expect(calculator.evaluate("42") == .notACalculation)
    #expect(calculator.evaluate("pi") == .notACalculation)
    #expect(calculator.evaluate("safari") == .notACalculation)
    #expect(calculator.evaluate("2 +") == .incomplete)
    #expect(calculator.evaluate("sqrt(") == .incomplete)
    #expect(calculator.evaluate("5 km to") == .incomplete)
    #expect(calculator.evaluate("1/0") == .error("division by zero"))
    #expect(calculator.evaluate("1001!") == .error("too large"))
    #expect(calculator.evaluate("2 ** 99999") == .error("too large"))
    #expect(calculator.evaluate("1e400 * 1e400") == .error("too large"))
    if case let .result(factorial) = calculator.evaluate("999!") {
        #expect(factorial.display.hasPrefix("4."))
        #expect(factorial.display.contains("e2564"))
    } else {
        Issue.record("999! should be a result")
    }
    #expect(calculator.evaluate("foo(1)") == .error("unknown function"))
    #expect(calculator.evaluate("100 usd to inr") == .error("exchange rates not loaded yet"))
}

@Test("additional grammar and unit edges")
func additionalGrammarEdges() {
    let calculator = Calculator()
    #expect(result(calculator, "floor(-1.5)")?.display == "-2")
    #expect(result(calculator, "ceil(-1.5)")?.display == "-1")
    #expect(result(calculator, "int(-1.9)")?.display == "-1")
    #expect(result(calculator, "round(1234.56, -2)")?.display == "1,200")
    #expect(result(calculator, "(2 m)^2")?.display == "4 m²")
    #expect(result(calculator, "2^2 m")?.display == "4 m")
    #expect(result(calculator, "10 m/s to km/h")?.display == "36 km/h")
    #expect(result(calculator, "gcd(84, 30)")?.display == "6")
    #expect(result(calculator, "lcm(6, 15)")?.display == "30")
    #expect(result(calculator, "min(1000, 2000)")?.display == "1,000")
    #expect(result(calculator, "0xffffffffffffffffffffffffffffffff")?.display == "340,282,366,920,938,463,463,374,607,431,768,211,455")
    #expect(result(calculator, "0xffffffffffffffffffffffffffffffff to hex")?.display == "0xffffffffffffffffffffffffffffffff")
    #expect(result(calculator, "factorial(0)")?.display == "1")
    #expect(calculator.evaluate("floor(2 C)") == .error("function needs a number"))
}

@Test("conversions inside parentheses")
func conversionsInsideParentheses() {
    let rates = CurrencyRates(base: "USD", rates: ["USD": 1, "EUR": 0.86, "INR": 95.5], publishedAt: nil, fetchedAt: Date())
    let calculator = Calculator(rates: FixedRateProvider(snapshot: rates))

    #expect(result(calculator, "(100 eur to inr) / 50")?.display == "222.09 INR")
    #expect(result(calculator, "((5 km to mi) * 2)")?.display == "6.21371192237 mi")
    #expect(result(calculator, "(1 GiB to MB) + 1 MB")?.display == "1,074.741824 MB")
    #expect(calculator.evaluate("2 * (70 f to c)") == .error("temperature arithmetic isn't supported"))
    #expect(result(calculator, "(5 in to cm) * 2")?.display == "25.4 cm")
}

@Test("currency feeds parse and store without networking")
func currencyFeeds() async throws {
    let primary = try fixture("open-er-api-latest-USD.json")
    let fallback = try fixture("fawazahmed0-currency-api-usd.json")
    let primaryURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("calc-primary-\(UUID().uuidString).json")
    let fallbackURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("calc-fallback-\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: primaryURL)
        try? FileManager.default.removeItem(at: fallbackURL)
    }

    let primaryStore = CurrencyRateStore(cacheFile: primaryURL, maxAge: 3600, fetch: { primary })
    #expect(await primaryStore.refreshIfStale())
    #expect(primaryStore.currentRates()?.base == "USD")
    #expect(primaryStore.currentRates()?.rates["INR"] == 95.579151)
    let primaryResult = result(Calculator(rates: primaryStore), "100 usd to inr")
    #expect(primaryResult?.display == "9,557.92 INR")
    #expect(primaryResult?.detail == "1 USD = 95.5792 INR · 2026-09-13 · Rates by Exchange Rate API")
    #expect(result(Calculator(rates: primaryStore), "$20 to eur")?.display == "17.24 EUR")

    let fallbackStore = CurrencyRateStore(cacheFile: fallbackURL, maxAge: 3600, fetch: { fallback })
    #expect(await fallbackStore.refreshIfStale())
    #expect(fallbackStore.currentRates()?.rates["BTC"] != nil)
    #expect(fallbackStore.currentRates()?.source?.contains("fawazahmed0") == true)

    let cachedStore = CurrencyRateStore(cacheFile: primaryURL, maxAge: 3600, fetch: { Data() })
    #expect(cachedStore.currentRates()?.base == "USD")
    #expect(await cachedStore.refreshIfStale() == false)

    let concurrentURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("calc-concurrent-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: concurrentURL) }
    let counter = FetchCounter()
    let concurrentStore = CurrencyRateStore(cacheFile: concurrentURL, maxAge: 3600, fetch: {
        counter.increment()
        try? await Task.sleep(nanoseconds: 20_000_000)
        return primary
    })
    let refreshResults = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for _ in 0..<8 { group.addTask { await concurrentStore.refreshIfStale() } }
        var results: [Bool] = []
        for await value in group { results.append(value) }
        return results
    }
    #expect(counter.count() == 1)
    #expect(refreshResults.allSatisfy { $0 })
}

@Test("random malformed input never crashes")
func malformedInputFuzz() {
    var generator = LCG(seed: 0xC0DECA1C)
    let calculator = Calculator()
    let alphabet = Array("0123456789+-*/%_^&|~(), abcdefghijklmnopqrstuvwxyz😀∑µ°")
    let start = ContinuousClock.now
    var slowestNanoseconds: UInt64 = 0
    _ = calculator.evaluate(String(repeating: "9", count: 2_000) + "+1")
    for index in 0..<20_000 {
        let length = index % 31 == 0 ? 2_000 : Int(generator.next() % 160)
        var string = ""
        string.reserveCapacity(length)
        for _ in 0..<length { string.append(alphabet[Int(generator.next() % UInt64(alphabet.count))]) }
        if index % 7 == 0 { string = String(repeating: "(", count: 200) + string + String(repeating: ")", count: 200) }
        let callStart = threadCPUTimeNanoseconds()
        _ = calculator.evaluate(string)
        slowestNanoseconds = max(slowestNanoseconds, threadCPUTimeNanoseconds() - callStart)
    }
    let elapsed = start.duration(to: .now)
    #expect(elapsed < .seconds(100), "fuzz duration: \(elapsed)")
    #expect(slowestNanoseconds < 5_000_000, "slowest call: \(slowestNanoseconds)ns")
}

@Test("typical expressions are fast")
func typicalExpressionsAreFast() {
    let calculator = Calculator()
    let inputs = ["2+2", "sqrt(2)*3", "5 km to mi", "1000000 * 3", "2 ** 10", "15% of 80"]
    let start = ContinuousClock.now
    for _ in 0..<1_000 { for input in inputs { _ = calculator.evaluate(input) } }
    let elapsed = start.duration(to: .now)
    #expect(elapsed < .seconds(2), "typical duration: \(elapsed)")
}

}

private func threadCPUTimeNanoseconds() -> UInt64 {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private struct LCG {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
