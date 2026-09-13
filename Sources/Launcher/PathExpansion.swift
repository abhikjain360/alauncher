import Foundation

/// Expands the `~` and `$VAR` forms that config paths may use, such as
/// `~/Applications` and `/etc/profiles/per-user/$USER/bin`.
enum PathExpansion {
    static func expand(
        _ path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        var text = path.trimmingCharacters(in: .whitespaces)
        if text == "~" {
            text = home
        } else if text.hasPrefix("~/") {
            text = home + text.dropFirst()
        }
        if text.contains("$") {
            text = expandVariables(in: text, environment: environment, home: home)
        }
        while text.count > 1, text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    /// `$NAME` and `${NAME}`. Unknown variables stay as written.
    private static func expandVariables(in text: String, environment: [String: String], home: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let nameStart = text.index(after: index)
            guard character == "$", nameStart < text.endIndex else {
                result.append(character)
                index = nameStart
                continue
            }

            var name = ""
            var end = nameStart
            if text[nameStart] == "{" {
                if let close = text[nameStart...].firstIndex(of: "}") {
                    name = String(text[text.index(after: nameStart)..<close])
                    end = text.index(after: close)
                }
            } else {
                while end < text.endIndex, isNameCharacter(text[end], first: end == nameStart) {
                    end = text.index(after: end)
                }
                name = String(text[nameStart..<end])
            }

            if !name.isEmpty, let value = value(of: name, environment: environment, home: home) {
                result += value
                index = end
            } else {
                result.append(character)
                index = nameStart
            }
        }
        return result
    }

    private static func isNameCharacter(_ character: Character, first: Bool) -> Bool {
        guard character.isASCII else { return false }
        if character == "_" || character.isLetter { return true }
        return !first && character.isNumber
    }

    private static func value(of name: String, environment: [String: String], home: String) -> String? {
        if let value = environment[name], !value.isEmpty { return value }
        switch name {
        case "USER": return NSUserName()
        case "HOME": return home
        default: return nil
        }
    }
}

/// `launcher.exclude`: hides items by title (case-insensitive) or by path, where
/// a path pattern also hides everything inside it.
struct ExclusionList: Sendable {
    private let titles: Set<String>
    private let paths: [String]

    init(_ patterns: [String], expand: (String) -> String = { PathExpansion.expand($0) }) {
        var titles = Set<String>()
        var paths: [String] = []
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            titles.insert(trimmed.lowercased())
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("$") {
                paths.append(expand(trimmed).lowercased())
            }
        }
        self.titles = titles
        self.paths = paths
    }

    /// Paths compare case-insensitively, like the default APFS volume.
    func excludes(title: String, paths candidates: [String] = []) -> Bool {
        if titles.contains(title.lowercased()) { return true }
        for candidate in candidates.map({ $0.lowercased() }) {
            for path in paths where candidate == path || candidate.hasPrefix(path == "/" ? path : path + "/") {
                return true
            }
        }
        return false
    }
}
