import Core
import Foundation
import Testing
@testable import Dictation

private func settings(baseURL: String = "https://api.deepseek.com", key: String? = "sk-test-not-a-real-key") -> CleanupSettings {
    var settings = CleanupSettings()
    settings.baseURL = baseURL
    settings.apiKey = key
    return settings
}

private func body(of request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - Request building

@Test(arguments: [
    ("https://api.deepseek.com", "https://api.deepseek.com/chat/completions"),
    ("https://api.deepseek.com/", "https://api.deepseek.com/chat/completions"),
    ("https://api.openai.com/v1", "https://api.openai.com/v1/chat/completions"),
    ("https://example.test/v1//", "https://example.test/v1/chat/completions"),
    (" http://localhost:8080/api/ ", "http://localhost:8080/api/chat/completions"),
])
func endpointJoinsWithoutDoublingSlashes(base: String, expected: String) throws {
    #expect(try ChatCompletions.endpoint(baseURL: base).absoluteString == expected)
}

@Test func endpointRejectsNonHTTP() {
    #expect(throws: CleanupError.invalidBaseURL) { try ChatCompletions.endpoint(baseURL: "ftp://example.test") }
    #expect(throws: CleanupError.invalidBaseURL) { try ChatCompletions.endpoint(baseURL: "not a url") }
}

@Test func requestCarriesModelPromptKeyAndReasoning() throws {
    let request = try ChatCompletions.request(
        settings: settings(), messages: [ChatMessage(role: "user", content: "the prompt")], stream: false
    )
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-not-a-real-key")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.timeoutInterval == 12)
    let json = try body(of: request)
    #expect(json["model"] as? String == "deepseek-flash")
    #expect(json["stream"] as? Bool == false)
    #expect(json["reasoning_effort"] as? String == "low")
    let messages = try #require(json["messages"] as? [[String: String]])
    #expect(messages == [["role": "user", "content": "the prompt"]])
}

@Test func emptyReasoningLeavesReasoningEffortOut() throws {
    var cleanup = settings()
    cleanup.reasoning = "  "
    let json = try body(of: ChatCompletions.request(settings: cleanup, messages: [], stream: false))
    #expect(json["reasoning_effort"] == nil)
}

@Test func extraBodyIsMergedAndWinsConflicts() throws {
    var cleanup = settings()
    cleanup.extraBody = [
        "reasoning_effort": .string("high"),
        "temperature": .number(0.2),
        "max_tokens": .number(200),
        "thinking": .object(["type": .string("enabled")]),
        "stop": .array([.string("</transcript>")]),
        "logprobs": .bool(false),
    ]
    let request = try ChatCompletions.request(settings: cleanup, messages: [], stream: false)
    let json = try body(of: request)
    #expect(json["reasoning_effort"] as? String == "high")
    #expect(json["temperature"] as? Double == 0.2)
    #expect((json["thinking"] as? [String: String]) == ["type": "enabled"])
    #expect((json["stop"] as? [String]) == ["</transcript>"])
    #expect(json["logprobs"] as? Bool == false)
    let text = String(decoding: try #require(request.httpBody), as: UTF8.self)
    #expect(text.contains("\"max_tokens\":200"))
}

@Test func missingKeyIsAClearError() {
    #expect(throws: CleanupError.missingAPIKey) {
        try ChatCompletions.request(settings: settings(key: nil), messages: [], stream: false)
    }
    #expect(throws: CleanupError.missingAPIKey) {
        try ChatCompletions.request(settings: settings(key: "  "), messages: [], stream: false)
    }
    #expect(CleanupError.missingAPIKey.description.contains("secrets.toml"))
}

// MARK: - Response parsing

@Test(arguments: [
    ("```\nHello, world.\n```", "Hello, world."),
    ("```text\nHello world\n```", "Hello world"),
    ("```Hello```", "Hello"),
    ("\"Quoted text.\"", "Quoted text."),
    ("“Curly quotes.”", "Curly quotes."),
    ("«Guillemets»", "Guillemets"),
    ("\"a\" and \"b\"", "\"a\" and \"b\""),
    ("'It's fine'", "'It's fine'"),
    ("```\n\"one layer only\"\n```", "\"one layer only\""),
    ("  plain text \n", "plain text"),
])
func responseTextLosesOneWrapper(raw: String, expected: String) {
    #expect(ChatCompletions.unwrap(raw) == expected)
}

@Test func streamDeltaReadsChoiceContent() {
    #expect(ChatCompletions.streamDelta(from: #"{"choices":[{"delta":{"content":"Hel"}}]}"#) == "Hel")
    #expect(ChatCompletions.streamDelta(from: #"{"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#) == nil)
    #expect(ChatCompletions.streamDelta(from: "not json") == nil)
}

// MARK: - Client over a stub URLProtocol

/// Serves canned responses by host, so tests running in parallel don't share state.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (Int, Data)] = [:]

    static func register(status: Int, body: String) -> String {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        lock.lock()
        responses[host] = (status, Data(body.utf8))
        lock.unlock()
        return "https://\(host)"
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let canned = request.url?.host.flatMap { Self.responses[$0] }
        Self.lock.unlock()
        let (status, data) = canned ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubClient() -> CleanupClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return CleanupClient(configuration: configuration)
}

private func completion(_ content: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    return String(decoding: data, as: UTF8.self)
}

@Test func clientReturnsTrimmedUnfencedContent() async throws {
    let base = StubURLProtocol.register(status: 200, body: completion("```\nHello, world.\n```\n"))
    let text = try await stubClient().cleanUp("hello world", settings: settings(baseURL: base))
    #expect(text == "Hello, world.")
}

@Test func clientStripsMatchingQuotes() async throws {
    let base = StubURLProtocol.register(status: 200, body: completion("\"Ship it.\""))
    #expect(try await stubClient().complete(prompt: "p", settings: settings(baseURL: base)) == "Ship it.")
}

@Test func clientReportsHTTPErrorsWithTheAPIMessage() async {
    let base = StubURLProtocol.register(status: 401, body: #"{"error":{"message":"Authentication Fails","type":"auth"}}"#)
    await #expect(throws: CleanupError.http(status: 401, message: "Authentication Fails")) {
        try await stubClient().complete(prompt: "p", settings: settings(baseURL: base))
    }
}

@Test func errorMessagesNeverCarryKeys() {
    let body = Data(#"{"error":{"message":"Authentication Fails, Your api key: ****a1b2 is invalid"}}"#.utf8)
    #expect(ChatCompletions.errorMessage(from: body) == "Authentication Fails, Your api key: [redacted] is invalid")
    #expect(ChatCompletions.redactingKeys("bad key sk-abcdef123456 and Bearer xyz") == "bad key [redacted] and [redacted]")
}

@Test func clientRejectsMalformedAndEmptyResponses() async {
    let malformed = StubURLProtocol.register(status: 200, body: "<html>oops</html>")
    await #expect(throws: CleanupError.invalidResponse) {
        try await stubClient().complete(prompt: "p", settings: settings(baseURL: malformed))
    }
    let empty = StubURLProtocol.register(status: 200, body: completion("   "))
    await #expect(throws: CleanupError.emptyResponse) {
        try await stubClient().complete(prompt: "p", settings: settings(baseURL: empty))
    }
}

@Test func timeoutHelperThrowsTimedOut() async throws {
    await #expect(throws: CleanupError.timedOut) {
        try await withTimeout(0.05) { () async throws -> Int in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return 1
        }
    }
    #expect(try await withTimeout(nil) { 7 } == 7)
}
