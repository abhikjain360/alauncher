import Core
import Foundation

public enum CleanupError: Error, Equatable, CustomStringConvertible {
    case missingAPIKey
    case invalidBaseURL
    case http(status: Int, message: String)
    case invalidResponse
    case emptyResponse
    case timedOut

    public var description: String {
        switch self {
        case .missingAPIKey:
            return "no API key: set cleanup.api_key or api_key_command in ~/.config/alauncher/secrets.toml"
        case .invalidBaseURL: return "cleanup.base_url is not a valid http(s) URL"
        case .http(let status, let message): return "HTTP \(status)" + (message.isEmpty ? "" : ": \(message)")
        case .invalidResponse: return "unexpected response from the model API"
        case .emptyResponse: return "the model returned no text"
        case .timedOut: return "timed out"
        }
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// OpenAI-compatible `/chat/completions` request building and response parsing. Pure.
enum ChatCompletions {
    /// `{baseURL}/chat/completions`, without doubling slashes.
    static func endpoint(baseURL: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { throw CleanupError.invalidBaseURL }
        return url
    }

    /// `{model, messages, stream}`, plus `reasoning_effort` when set, then `extraBody` merged in
    /// (it wins on conflicts).
    static func body(
        model: String, messages: [ChatMessage], stream: Bool, reasoning: String, extraBody: [String: JSONValue]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": stream,
        ]
        let effort = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty { body["reasoning_effort"] = effort }
        for (key, value) in extraBody { body[key] = value.foundationValue }
        return body
    }

    static func request(
        settings: CleanupSettings, messages: [ChatMessage], stream: Bool, reasoning: String? = nil
    ) throws -> URLRequest {
        guard let key = settings.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw CleanupError.missingAPIKey
        }
        var request = URLRequest(url: try endpoint(baseURL: settings.baseURL))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        let json = body(
            model: settings.model, messages: messages, stream: stream,
            reasoning: reasoning ?? settings.reasoning, extraBody: settings.extraBody
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        if let timeout = settings.timeout.timeInterval, timeout > 0 { request.timeoutInterval = timeout }
        return request
    }

    /// `choices[0].message.content`.
    static func content(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw CleanupError.invalidResponse }
        return content
    }

    /// `choices[0].delta.content` from one SSE `data:` payload; nil for other chunks.
    static func streamDelta(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }

    /// The API's `error.message`, shortened, for error reports. Never contains the request.
    static func errorMessage(from data: Data) -> String {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (root?["error"] as? [String: Any])?["message"] as? String
            ?? (root?["error"] as? String)
            ?? String(data: data.prefix(200), encoding: .utf8)
            ?? ""
        let line = redactingKeys(message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    /// Some APIs echo (part of) the key in auth errors, e.g. "Your api key: ****abcd is invalid".
    static func redactingKeys(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)(sk-[A-Za-z0-9_\-]{4,}|\*{3,}[A-Za-z0-9_\-]*|bearer\s+\S+)"#,
            with: "[redacted]", options: .regularExpression
        )
    }

    /// Trims, then strips one layer of wrapping code fences or matching quotes, which models add
    /// despite being told not to.
    static func unwrap(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 6, trimmed.hasPrefix("```"), trimmed.hasSuffix("```") {
            var inner = trimmed.dropFirst(3).dropLast(3)
            if let newline = inner.firstIndex(of: "\n") {
                // The rest of the opening line is a language tag.
                let tag = inner[..<newline]
                if !tag.contains(" ") { inner = inner[inner.index(after: newline)...] }
            }
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»"), ("‘", "’"), ("'", "'"), ("`", "`")]
        if trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last,
           let pair = pairs.first(where: { $0.0 == first && $0.1 == last }) {
            let inner = trimmed.dropFirst().dropLast()
            // Leave `"a" and "b"` alone: the quotes don't wrap the whole text.
            if !inner.contains(pair.0), !inner.contains(pair.1) {
                return inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }
}

extension JSONValue {
    /// For JSONSerialization. Whole numbers stay integers ("max_tokens": 200, not 200.0).
    var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value == value.rounded(), abs(value) < 9e15 { return Int(value) }
            return value
        case .bool(let value): return value
        case .array(let values): return values.map(\.foundationValue)
        case .object(let values): return values.mapValues(\.foundationValue)
        }
    }
}

/// Runs `operation`, throwing `CleanupError.timedOut` after `seconds`.
func withTimeout<T: Sendable>(_ seconds: TimeInterval?, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard let seconds, seconds > 0 else { return try await operation() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CleanupError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CleanupError.timedOut }
        return result
    }
}

/// The cleanup model client: one shared URLSession, so the connection opened by `warmUp()` at
/// key-down is reused by the request at release.
public final class CleanupClient: Sendable {
    public static let shared = CleanupClient()

    let session: URLSession

    public init(configuration: URLSessionConfiguration = CleanupClient.defaultConfiguration()) {
        session = URLSession(configuration: configuration)
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// Cleans up a transcript with `settings.prompt`.
    public func cleanUp(_ transcript: String, settings: CleanupSettings) async throws -> String {
        try await complete(prompt: TextProcessing.fillPrompt(settings.prompt, transcript: transcript), settings: settings)
    }

    /// One non-streaming completion of `prompt` as a user message. Throws `CleanupError`.
    public func complete(prompt: String, settings: CleanupSettings) async throws -> String {
        let request = try ChatCompletions.request(
            settings: settings, messages: [ChatMessage(role: "user", content: prompt)], stream: false
        )
        let session = self.session
        let (data, status) = try await withTimeout(settings.timeout.timeInterval) { () async throws -> (Data, Int) in
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard (200..<300).contains(status) else {
            throw CleanupError.http(status: status, message: ChatCompletions.errorMessage(from: data))
        }
        let text = ChatCompletions.unwrap(try ChatCompletions.content(from: data))
        guard !text.isEmpty else { throw CleanupError.emptyResponse }
        return text
    }

    /// Opens the TLS connection cheaply while the user is still speaking (a HEAD on the base URL).
    /// Errors are ignored.
    public func warmUp(baseURL: String) {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased().hasPrefix("http") == true else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        session.dataTask(with: request).resume()
    }
}
