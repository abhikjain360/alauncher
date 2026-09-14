import Foundation
import TOMLDecoder

enum ConfigParsing {
    static func load(configText: String, secretsText: String?) throws -> Config {
        let root = try parseTable(configText, fileName: "config.toml")
        try validateConfigKeys(root)

        var config = try decodeConfig(root)
        let secrets = try parseSecrets(secretsText)
        if let apiKey = secrets.apiKey {
            config.cleanup.apiKey = apiKey
        }
        return config
    }

    static func resolveSecrets(_ config: inout Config, secretsText: String?) throws {
        let secrets = try parseSecrets(secretsText)
        var apiKey = secrets.apiKey ?? config.cleanup.apiKey
        if let command = secrets.apiKeyCommand {
            apiKey = try runSecretCommand(command)
        }
        config.cleanup.apiKey = apiKey
    }

    private struct Secrets {
        var apiKey: String?
        var apiKeyCommand: String?
    }

    private static func parseTable(_ text: String, fileName: String) throws -> TOMLTable {
        do {
            return try TOMLTable(source: text)
        } catch {
            throw ConfigError("\(fileName): invalid TOML")
        }
    }

    private static func parseSecrets(_ text: String?) throws -> Secrets {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Secrets(apiKey: nil, apiKeyCommand: nil)
        }

        let root = try parseTable(text, fileName: "secrets.toml")
        try validateKeys(root, allowed: ["cleanup"], path: nil)
        guard root.contains(key: "cleanup") else {
            return Secrets(apiKey: nil, apiKeyCommand: nil)
        }

        let cleanup = try requiredTable(root, key: "cleanup", path: "cleanup")
        try validateKeys(cleanup, allowed: ["api_key", "api_key_command"], path: "cleanup")
        return Secrets(
            apiKey: try optionalString(cleanup, key: "api_key", path: "cleanup.api_key"),
            apiKeyCommand: try optionalString(cleanup, key: "api_key_command", path: "cleanup.api_key_command")
        )
    }

    private static func validateConfigKeys(_ root: TOMLTable) throws {
        try validateKeys(root, allowed: ["app", "launcher", "calculator", "dictation", "cleanup", "ask"], path: nil)

        if root.contains(key: "app") {
            let table = try requiredTable(root, key: "app", path: "app")
            try validateKeys(table, allowed: ["launch_at_login", "show_menu_bar_icon", "log_level"], path: "app")
        }
        if root.contains(key: "launcher") {
            let table = try requiredTable(root, key: "launcher", path: "launcher")
            try validateKeys(table, allowed: [
                "hotkey", "max_results", "app_dirs", "script_dirs", "extra_path", "exclude",
                "ranking", "aliases", "commands",
            ], path: "launcher")
            if table.contains(key: "ranking") {
                let ranking = try requiredTable(table, key: "ranking", path: "launcher.ranking")
                try validateKeys(ranking, allowed: ["frecency_weight", "max_age"], path: "launcher.ranking")
            }
            if table.contains(key: "aliases") {
                _ = try requiredTable(table, key: "aliases", path: "launcher.aliases")
            }
            if table.contains(key: "commands") {
                let commands = try requiredArray(table, key: "commands", path: "launcher.commands")
                for index in 0..<commands.count {
                    let command = try commands.table(atIndex: index)
                    let path = "launcher.commands[\(index)]"
                    try validateKeys(command, allowed: ["title", "run", "mode", "aliases", "choices"], path: path)
                }
            }
        }
        if root.contains(key: "calculator") {
            let table = try requiredTable(root, key: "calculator", path: "calculator")
            try validateKeys(table, allowed: ["enabled", "rates_max_age"], path: "calculator")
        }
        if root.contains(key: "dictation") {
            let table = try requiredTable(root, key: "dictation", path: "dictation")
            try validateKeys(table, allowed: [
                "enabled", "hold_key", "raw_chord", "cancel_key", "model", "unload_after",
                "min_duration", "start_delay", "max_duration", "input_device", "remove_fillers", "filler_words",
                "history_limit", "insert",
            ], path: "dictation")
            if table.contains(key: "insert") {
                let insert = try requiredTable(table, key: "insert", path: "dictation.insert")
                try validateKeys(insert, allowed: ["method", "type_chunk", "type_delay", "paste_restore", "paste_restore_delay", "apps"], path: "dictation.insert")
                if insert.contains(key: "apps") {
                    _ = try requiredTable(insert, key: "apps", path: "dictation.insert.apps")
                }
            }
        }
        if root.contains(key: "cleanup") {
            let table = try requiredTable(root, key: "cleanup", path: "cleanup")
            try validateKeys(table, allowed: ["enabled", "base_url", "model", "reasoning", "extra_body", "timeout", "prompt"], path: "cleanup")
            if table.contains(key: "extra_body") {
                _ = try requiredTable(table, key: "extra_body", path: "cleanup.extra_body")
            }
        }
        if root.contains(key: "ask") {
            let table = try requiredTable(root, key: "ask", path: "ask")
            try validateKeys(table, allowed: ["enabled", "prefixes", "backend", "opencode", "model", "reasoning", "tools", "prompt"], path: "ask")
        }
    }

    private static func validateKeys(_ table: TOMLTable, allowed: [String], path: String?) throws {
        let allowedSet = Set(allowed)
        for key in table.keys where !allowedSet.contains(key) {
            let fullPath = path.map { "\($0).\(key)" } ?? key
            if let suggestion = nearestKey(to: key, in: allowed), editDistance(key, suggestion) <= 2 {
                throw ConfigError("\(fullPath): unknown key, did you mean \(suggestion)?")
            }
            throw ConfigError("\(fullPath): unknown key")
        }
    }

    private static func nearestKey(to key: String, in candidates: [String]) -> String? {
        var matches: [(String, Int)] = []
        for candidate in candidates {
            let distance = editDistance(key, candidate)
            if distance <= 2 { matches.append((candidate, distance)) }
        }
        matches.sort { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
        }
        return matches.first?.0
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (row, leftCharacter) in Array(lhs).enumerated() {
            var current = [row + 1]
            for (column, rightCharacter) in right.enumerated() {
                let substitution = previous[column] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(substitution, previous[column + 1] + 1, current[column] + 1))
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func decodeConfig(_ root: TOMLTable) throws -> Config {
        var config = Config()

        if root.contains(key: "app") {
            let app = try requiredTable(root, key: "app", path: "app")
            if let value = try optionalBool(app, key: "launch_at_login", path: "app.launch_at_login") { config.app.launchAtLogin = value }
            if let value = try optionalBool(app, key: "show_menu_bar_icon", path: "app.show_menu_bar_icon") { config.app.showMenuBarIcon = value }
            if let value = try optionalString(app, key: "log_level", path: "app.log_level") {
                guard let logLevel = LogLevel(rawValue: value) else {
                    throw ConfigError("app.log_level: invalid value (expected debug, info, or error)")
                }
                config.app.logLevel = logLevel
            }
        }

        if root.contains(key: "launcher") {
            let launcher = try requiredTable(root, key: "launcher", path: "launcher")
            if let value = try optionalString(launcher, key: "hotkey", path: "launcher.hotkey") {
                guard let hotkey = KeySpec.parse(value) else { throw ConfigError("launcher.hotkey: invalid key spec") }
                config.launcher.hotkey = hotkey
            }
            if let value = try optionalInt(launcher, key: "max_results", path: "launcher.max_results") {
                guard (1...50).contains(value) else { throw ConfigError("launcher.max_results: must be 1...50") }
                config.launcher.maxResults = value
            }
            if launcher.contains(key: "app_dirs") { config.launcher.appDirs = try stringArray(launcher, key: "app_dirs", path: "launcher.app_dirs") }
            if launcher.contains(key: "script_dirs") { config.launcher.scriptDirs = try stringArray(launcher, key: "script_dirs", path: "launcher.script_dirs") }
            if launcher.contains(key: "extra_path") { config.launcher.extraPath = try stringArray(launcher, key: "extra_path", path: "launcher.extra_path") }
            if launcher.contains(key: "exclude") { config.launcher.exclude = try stringArray(launcher, key: "exclude", path: "launcher.exclude") }

            if launcher.contains(key: "ranking") {
                let ranking = try requiredTable(launcher, key: "ranking", path: "launcher.ranking")
                if let value = try optionalNumber(ranking, key: "frecency_weight", path: "launcher.ranking.frecency_weight") { config.launcher.ranking.frecencyWeight = value }
                if let value = try optionalNumber(ranking, key: "max_age", path: "launcher.ranking.max_age") { config.launcher.ranking.maxAge = value }
            }
            if launcher.contains(key: "aliases") {
                let aliases = try requiredTable(launcher, key: "aliases", path: "launcher.aliases")
                config.launcher.aliases = try stringArrayMap(aliases, path: "launcher.aliases")
            }
            if launcher.contains(key: "commands") {
                config.launcher.commands = try commandArray(launcher)
            }
        }

        if root.contains(key: "calculator") {
            let calculator = try requiredTable(root, key: "calculator", path: "calculator")
            if let value = try optionalBool(calculator, key: "enabled", path: "calculator.enabled") { config.calculator.enabled = value }
            if let value = try optionalDuration(calculator, key: "rates_max_age", path: "calculator.rates_max_age") { config.calculator.ratesMaxAge = value }
        }

        if root.contains(key: "dictation") {
            let dictation = try requiredTable(root, key: "dictation", path: "dictation")
            if let value = try optionalBool(dictation, key: "enabled", path: "dictation.enabled") { config.dictation.enabled = value }
            if let value = try optionalKeySpec(dictation, key: "hold_key", path: "dictation.hold_key") { config.dictation.holdKey = value }
            if let value = try optionalKeySpec(dictation, key: "raw_chord", path: "dictation.raw_chord") { config.dictation.rawChord = value }
            if let value = try optionalKeySpec(dictation, key: "cancel_key", path: "dictation.cancel_key") { config.dictation.cancelKey = value }
            if let value = try optionalString(dictation, key: "model", path: "dictation.model") { config.dictation.model = value }
            if let value = try optionalDuration(dictation, key: "unload_after", path: "dictation.unload_after") { config.dictation.unloadAfter = value }
            if let value = try optionalDuration(dictation, key: "min_duration", path: "dictation.min_duration") { config.dictation.minDuration = value }
            if let value = try optionalDuration(dictation, key: "start_delay", path: "dictation.start_delay") { config.dictation.startDelay = value }
            if let value = try optionalDuration(dictation, key: "max_duration", path: "dictation.max_duration") { config.dictation.maxDuration = value }
            if let value = try optionalString(dictation, key: "input_device", path: "dictation.input_device") { config.dictation.inputDevice = value }
            if let value = try optionalBool(dictation, key: "remove_fillers", path: "dictation.remove_fillers") { config.dictation.removeFillers = value }
            if dictation.contains(key: "filler_words") { config.dictation.fillerWords = try stringArray(dictation, key: "filler_words", path: "dictation.filler_words") }
            if let value = try optionalInt(dictation, key: "history_limit", path: "dictation.history_limit") {
                guard value >= 0 else { throw ConfigError("dictation.history_limit: must be >= 0") }
                config.dictation.historyLimit = value
            }

            if dictation.contains(key: "insert") {
                let insert = try requiredTable(dictation, key: "insert", path: "dictation.insert")
                if let value = try optionalString(insert, key: "method", path: "dictation.insert.method") {
                    guard let method = InsertMethod(rawValue: value) else {
                        throw ConfigError("dictation.insert.method: invalid value (expected type or paste)")
                    }
                    config.dictation.insert.method = method
                }
                if let value = try optionalInt(insert, key: "type_chunk", path: "dictation.insert.type_chunk") {
                    guard (1...20).contains(value) else { throw ConfigError("dictation.insert.type_chunk: must be 1...20") }
                    config.dictation.insert.typeChunk = value
                }
                if let value = try optionalDuration(insert, key: "type_delay", path: "dictation.insert.type_delay") { config.dictation.insert.typeDelay = value }
                if let value = try optionalBool(insert, key: "paste_restore", path: "dictation.insert.paste_restore") { config.dictation.insert.pasteRestore = value }
                if let value = try optionalDuration(insert, key: "paste_restore_delay", path: "dictation.insert.paste_restore_delay") { config.dictation.insert.pasteRestoreDelay = value }
                if insert.contains(key: "apps") {
                    let apps = try requiredTable(insert, key: "apps", path: "dictation.insert.apps")
                    config.dictation.insert.apps = try insertMethodMap(apps, path: "dictation.insert.apps")
                }
            }
        }

        if root.contains(key: "cleanup") {
            let cleanup = try requiredTable(root, key: "cleanup", path: "cleanup")
            if let value = try optionalBool(cleanup, key: "enabled", path: "cleanup.enabled") { config.cleanup.enabled = value }
            if let value = try optionalString(cleanup, key: "base_url", path: "cleanup.base_url") {
                guard isHTTPURL(value) else { throw ConfigError("cleanup.base_url: must be an http(s) URL") }
                config.cleanup.baseURL = value
            }
            if let value = try optionalString(cleanup, key: "model", path: "cleanup.model") { config.cleanup.model = value }
            if let value = try optionalString(cleanup, key: "reasoning", path: "cleanup.reasoning") { config.cleanup.reasoning = value }
            if cleanup.contains(key: "extra_body") {
                let body = try requiredTable(cleanup, key: "extra_body", path: "cleanup.extra_body")
                config.cleanup.extraBody = try jsonObject(body, path: "cleanup.extra_body")
            }
            if let value = try optionalDuration(cleanup, key: "timeout", path: "cleanup.timeout") { config.cleanup.timeout = value }
            if let value = try optionalString(cleanup, key: "prompt", path: "cleanup.prompt") { config.cleanup.prompt = value }
        }

        if root.contains(key: "ask") {
            let ask = try requiredTable(root, key: "ask", path: "ask")
            if let value = try optionalBool(ask, key: "enabled", path: "ask.enabled") { config.ask.enabled = value }
            if ask.contains(key: "prefixes") {
                let prefixes = try stringArray(ask, key: "prefixes", path: "ask.prefixes")
                guard !prefixes.isEmpty else { throw ConfigError("ask.prefixes: must not be empty") }
                config.ask.prefixes = prefixes
            }
            if let value = try optionalString(ask, key: "backend", path: "ask.backend") {
                guard let backend = AskBackend(rawValue: value) else {
                    throw ConfigError("ask.backend: invalid value (expected opencode or direct)")
                }
                config.ask.backend = backend
            }
            if let value = try optionalString(ask, key: "opencode", path: "ask.opencode") { config.ask.opencode = value }
            if let value = try optionalString(ask, key: "model", path: "ask.model") { config.ask.model = value }
            if let value = try optionalString(ask, key: "reasoning", path: "ask.reasoning") { config.ask.reasoning = value }
            if ask.contains(key: "tools") { config.ask.tools = try stringArray(ask, key: "tools", path: "ask.tools") }
            if let value = try optionalString(ask, key: "prompt", path: "ask.prompt") { config.ask.prompt = value }
        }

        return config
    }

    private static func commandArray(_ launcher: TOMLTable) throws -> [CommandSettings] {
        let array = try requiredArray(launcher, key: "commands", path: "launcher.commands")
        var commands: [CommandSettings] = []
        commands.reserveCapacity(array.count)
        for index in 0..<array.count {
            let path = "launcher.commands[\(index)]"
            let table: TOMLTable
            do {
                table = try array.table(atIndex: index)
            } catch {
                throw ConfigError("\(path): expected a table")
            }
            let title = try requiredString(table, key: "title", path: "\(path).title")
            let run = try requiredString(table, key: "run", path: "\(path).run")
            let mode = try optionalString(table, key: "mode", path: "\(path).mode") ?? "silent"
            guard ["silent", "compact", "fullOutput", "type"].contains(mode) else {
                throw ConfigError("\(path).mode: invalid value (expected silent, compact, fullOutput, or type)")
            }
            let aliases = table.contains(key: "aliases")
                ? try stringArray(table, key: "aliases", path: "\(path).aliases")
                : []
            let choices = try optionalBool(table, key: "choices", path: "\(path).choices") ?? false
            commands.append(CommandSettings(title: title, run: run, mode: mode, aliases: aliases, choices: choices))
        }
        return commands
    }

    private static func requiredTable(_ table: TOMLTable, key: String, path: String) throws -> TOMLTable {
        do {
            return try table.table(forKey: key)
        } catch {
            throw ConfigError("\(path): expected a table")
        }
    }

    private static func requiredArray(_ table: TOMLTable, key: String, path: String) throws -> TOMLArray {
        do {
            return try table.array(forKey: key)
        } catch {
            throw ConfigError("\(path): expected an array")
        }
    }

    private static func requiredString(_ table: TOMLTable, key: String, path: String) throws -> String {
        guard table.contains(key: key) else { throw ConfigError("\(path): missing required key") }
        return try string(table, key: key, path: path)
    }

    private static func string(_ table: TOMLTable, key: String, path: String) throws -> String {
        do {
            return try table.string(forKey: key)
        } catch {
            throw ConfigError("\(path): expected a string")
        }
    }

    private static func optionalString(_ table: TOMLTable, key: String, path: String) throws -> String? {
        table.contains(key: key) ? try string(table, key: key, path: path) : nil
    }

    private static func bool(_ table: TOMLTable, key: String, path: String) throws -> Bool {
        do {
            return try table.bool(forKey: key)
        } catch {
            throw ConfigError("\(path): expected a boolean")
        }
    }

    private static func optionalBool(_ table: TOMLTable, key: String, path: String) throws -> Bool? {
        table.contains(key: key) ? try bool(table, key: key, path: path) : nil
    }

    private static func int(_ table: TOMLTable, key: String, path: String) throws -> Int {
        do {
            let value = try table.integer(forKey: key)
            guard let result = Int(exactly: value) else { throw ConfigError("\(path): integer is out of range") }
            return result
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError("\(path): expected an integer")
        }
    }

    private static func optionalInt(_ table: TOMLTable, key: String, path: String) throws -> Int? {
        table.contains(key: key) ? try int(table, key: key, path: path) : nil
    }

    private static func number(_ table: TOMLTable, key: String, path: String) throws -> Double {
        if table.contains(key: key) {
            if let value = try? table.float(forKey: key) { return value }
            if let value = try? table.integer(forKey: key) { return Double(value) }
        }
        throw ConfigError("\(path): expected a number")
    }

    private static func optionalNumber(_ table: TOMLTable, key: String, path: String) throws -> Double? {
        table.contains(key: key) ? try number(table, key: key, path: path) : nil
    }

    private static func stringArray(_ table: TOMLTable, key: String, path: String) throws -> [String] {
        let array = try requiredArray(table, key: key, path: path)
        var values: [String] = []
        values.reserveCapacity(array.count)
        for index in 0..<array.count {
            do {
                values.append(try array.string(atIndex: index))
            } catch {
                throw ConfigError("\(path)[\(index)]: expected a string")
            }
        }
        return values
    }

    private static func optionalDuration(_ table: TOMLTable, key: String, path: String) throws -> DurationSetting? {
        guard let text = try optionalString(table, key: key, path: path) else { return nil }
        guard let duration = DurationSetting.parse(text) else {
            throw ConfigError("\(path): invalid duration")
        }
        return duration
    }

    private static func optionalKeySpec(_ table: TOMLTable, key: String, path: String) throws -> KeySpec? {
        guard let text = try optionalString(table, key: key, path: path) else { return nil }
        guard let keySpec = KeySpec.parse(text) else {
            throw ConfigError("\(path): invalid key spec")
        }
        return keySpec
    }

    private static func stringArrayMap(_ table: TOMLTable, path: String) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for key in table.keys {
            result[key] = try stringArray(table, key: key, path: "\(path).\(key)")
        }
        return result
    }

    private static func insertMethodMap(_ table: TOMLTable, path: String) throws -> [String: InsertMethod] {
        var result: [String: InsertMethod] = [:]
        for key in table.keys {
            let value = try string(table, key: key, path: "\(path).\(key)")
            guard let method = InsertMethod(rawValue: value) else {
                throw ConfigError("\(path).\(key): invalid value (expected type or paste)")
            }
            result[key] = method
        }
        return result
    }

    private static func jsonObject(_ table: TOMLTable, path: String) throws -> [String: JSONValue] {
        do {
            return try jsonObject(try [String: Any](table), path: path)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError("\(path): invalid TOML value")
        }
    }

    private static func jsonObject(_ value: [String: Any], path: String) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in value {
            result[key] = try jsonValue(value, path: "\(path).\(key)")
        }
        return result
    }

    private static func jsonValue(_ value: Any, path: String) throws -> JSONValue {
        switch value {
        case let value as String: return .string(value)
        case let value as Bool: return .bool(value)
        case let value as Int64: return .number(Double(value))
        case let value as Int: return .number(Double(value))
        case let value as UInt64: return .number(Double(value))
        case let value as UInt: return .number(Double(value))
        case let value as Double where value.isFinite: return .number(value)
        case let value as Float where value.isFinite: return .number(Double(value))
        case let value as [Any]:
            return .array(try value.enumerated().map { try jsonValue($0.element, path: "\(path)[\($0.offset)]") })
        case let value as [String: Any]:
            return .object(try jsonObject(value, path: path))
        default:
            throw ConfigError("\(path): invalid JSON value")
        }
    }

    private static func isHTTPURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else { return false }
        return !value.contains(where: { $0.isWhitespace })
    }

    private static func runSecretCommand(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        let output = Pipe()
        process.standardOutput = output

        do {
            try process.run()
        } catch {
            throw ConfigError("cleanup.api_key_command: could not start command")
        }

        var outputData = Data()
        let outputRead = DispatchGroup()
        outputRead.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = output.fileHandleForReading.readDataToEndOfFile()
            outputRead.leave()
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            _ = outputRead.wait(timeout: .now() + 1)
            throw ConfigError("cleanup.api_key_command: command timed out")
        }
        _ = outputRead.wait(timeout: .now() + 1)
        guard process.terminationStatus == 0 else {
            throw ConfigError("cleanup.api_key_command: command failed")
        }

        guard let result = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else {
            throw ConfigError("cleanup.api_key_command: command returned empty output")
        }
        return result
    }
}
