import Foundation

/// A Raycast-format script command (`# @raycast.title …` headers).
public struct ScriptCommand: Equatable, Sendable {
    public enum Mode: String, Sendable {
        case silent
        case compact
        case fullOutput
        case inline
    }

    public struct Argument: Equatable, Sendable {
        public var type: String
        public var placeholder: String
        public var optional: Bool
        public var percentEncoded: Bool
        /// Choices for `dropdown` arguments.
        public var choices: [Choice]

        public struct Choice: Equatable, Sendable {
            public var title: String
            public var value: String

            public init(title: String, value: String) {
                self.title = title
                self.value = value
            }
        }

        public init(
            type: String,
            placeholder: String,
            optional: Bool = false,
            percentEncoded: Bool = false,
            choices: [Choice] = []
        ) {
            self.type = type
            self.placeholder = placeholder
            self.optional = optional
            self.percentEncoded = percentEncoded
            self.choices = choices
        }
    }

    public var path: URL
    public var title: String
    public var mode: Mode
    public var packageName: String?
    public var icon: String?
    public var description: String?
    public var arguments: [Argument]
    public var aliases: [String]
    public var needsConfirmation: Bool
    public var currentDirectoryPath: String?

    public init(
        path: URL,
        title: String,
        mode: Mode,
        packageName: String? = nil,
        icon: String? = nil,
        description: String? = nil,
        arguments: [Argument] = [],
        aliases: [String] = [],
        needsConfirmation: Bool = false,
        currentDirectoryPath: String? = nil
    ) {
        self.path = path
        self.title = title
        self.mode = mode
        self.packageName = packageName
        self.icon = icon
        self.description = description
        self.arguments = arguments
        self.aliases = aliases
        self.needsConfirmation = needsConfirmation
        self.currentDirectoryPath = currentDirectoryPath
    }
}

private struct HeaderLine {
    let namespace: String
    let key: String
    let value: String
}

private struct ParsedArgument: Decodable {
    struct ParsedChoice: Decodable {
        let title: String
        let value: String
    }

    let type: String
    let placeholder: String
    let optional: Bool
    let percentEncoded: Bool
    let choices: [ParsedChoice]

    enum CodingKeys: String, CodingKey {
        case type
        case placeholder
        case optional
        case percentEncoded
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        optional = try container.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        percentEncoded = try container.decodeIfPresent(Bool.self, forKey: .percentEncoded) ?? false
        choices = try container.decodeIfPresent([ParsedChoice].self, forKey: .data) ?? []
    }
}

public enum ScriptCommandParser {
    /// Reads the file's first 16 KB. Nil when it has no `@raycast.title`.
    public static func parse(contentsOf url: URL) -> ScriptCommand? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 16 * 1024) ?? Data()
            return parse(String(decoding: data, as: UTF8.self), path: url)
        } catch {
            return nil
        }
    }

    public static func parse(_ text: String, path: URL) -> ScriptCommand? {
        var title: String?
        var mode: ScriptCommand.Mode = .compact
        var packageName: String?
        var icon: String?
        var description: String?
        var arguments: [Int: ScriptCommand.Argument] = [:]
        var aliases: [String] = []
        var needsConfirmation = false
        var currentDirectoryPath: String?

        for line in text.components(separatedBy: .newlines) {
            guard let header = header(from: line) else { continue }

            switch header.key {
            case "title":
                title = header.value
            case "mode":
                mode = ScriptCommand.Mode(rawValue: header.value) ?? .compact
            case "packageName":
                packageName = header.value
            case "icon":
                icon = header.value
            case "description":
                description = header.value
            case "needsConfirmation":
                needsConfirmation = header.value.caseInsensitiveCompare("true") == .orderedSame
            case "currentDirectoryPath":
                currentDirectoryPath = NSString(string: header.value).expandingTildeInPath
            case "alias" where header.namespace == "alauncher":
                for alias in header.value.split(separator: ",", omittingEmptySubsequences: true) {
                    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !aliases.contains(trimmed) { aliases.append(trimmed) }
                }
            default:
                if let argumentNumber = argumentNumber(for: header.key),
                   let argument = parseArgument(header.value)
                {
                    arguments[argumentNumber] = argument
                }
            }
        }

        guard let title, !title.isEmpty else { return nil }
        return ScriptCommand(
            path: path,
            title: title,
            mode: mode,
            packageName: packageName,
            icon: icon,
            description: description,
            arguments: (1...3).compactMap { arguments[$0] },
            aliases: aliases,
            needsConfirmation: needsConfirmation,
            currentDirectoryPath: currentDirectoryPath
        )
    }

    private static func header(from line: String) -> HeaderLine? {
        let trimmed = line.drop(while: isWhitespace)
        let markers = ["//", "--", "#", ";", "%", "'"]
        let afterMarker: Substring

        if trimmed.count >= 3,
           trimmed.prefix(3).caseInsensitiveCompare("REM") == .orderedSame
        {
            let afterREM = trimmed.dropFirst(3)
            guard afterREM.isEmpty || afterREM.first.map(isWhitespace) == true else { return nil }
            afterMarker = afterREM.drop(while: isWhitespace)
        } else if let marker = markers.first(where: { trimmed.hasPrefix($0) }) {
            afterMarker = trimmed.dropFirst(marker.count).drop(while: isWhitespace)
        } else {
            return nil
        }

        let namespace: String
        let prefix: String
        if afterMarker.hasPrefix("@raycast.") {
            namespace = "raycast"
            prefix = "@raycast."
        } else if afterMarker.hasPrefix("@alauncher.") {
            namespace = "alauncher"
            prefix = "@alauncher."
        } else {
            return nil
        }

        let keyAndValue = afterMarker.dropFirst(prefix.count)
        guard let separator = keyAndValue.firstIndex(where: isWhitespace) else { return nil }
        let key = String(keyAndValue[..<separator])
        let value = String(keyAndValue[separator...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return HeaderLine(namespace: namespace, key: key, value: value)
    }

    private static func argumentNumber(for key: String) -> Int? {
        guard key.hasPrefix("argument1") || key.hasPrefix("argument2") || key.hasPrefix("argument3") else {
            return nil
        }
        guard let number = key.last.flatMap({ Int(String($0)) }), (1...3).contains(number), key.count == 9 else {
            return nil
        }
        return number
    }

    private static func parseArgument(_ value: String) -> ScriptCommand.Argument? {
        guard let data = value.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ParsedArgument.self, from: data),
              ["text", "password", "dropdown"].contains(parsed.type)
        else { return nil }

        let choices = parsed.choices.map {
            ScriptCommand.Argument.Choice(title: $0.title, value: $0.value)
        }
        return ScriptCommand.Argument(
            type: parsed.type,
            placeholder: parsed.placeholder,
            optional: parsed.optional,
            percentEncoded: parsed.percentEncoded,
            choices: choices
        )
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }
}
