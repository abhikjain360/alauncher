import Core
import Foundation
import Testing

private func configError(for text: String, sourceLocation: SourceLocation = #_sourceLocation) -> ConfigError? {
    do {
        _ = try ConfigLoader.load(configText: text, secretsText: nil)
        return nil
    } catch let error as ConfigError {
        return error
    } catch {
        Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

private func defaultFixture() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "default-config", withExtension: "toml", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func defaultFixtureMatchesSwiftDefaults() throws {
    let config = try ConfigLoader.load(configText: defaultFixture(), secretsText: nil)
    #expect(config == Config())
}

@Test func partialConfigUsesDefaults() throws {
    let config = try ConfigLoader.load(configText: """
        [app]
        log_level = "debug"

        [launcher]
        max_results = 20
        """, secretsText: nil)
    #expect(config.app.logLevel == .debug)
    #expect(config.launcher.maxResults == 20)
    #expect(config.dictation == Config().dictation)
    #expect(config.cleanup == Config().cleanup)
}

@Test func unknownKeySuggestsNearestKey() {
    let error = configError(for: "[dictation]\nunload_afer = \"5m\"\n")
    #expect(error?.description == "dictation.unload_afer: unknown key, did you mean unload_after?")
}

@Test func validationErrorsNameTheirKey() {
    let cases = [
        ("[launcher]\nmax_results = 0\n", "launcher.max_results"),
        ("[dictation.insert]\ntype_chunk = 21\n", "dictation.insert.type_chunk"),
        ("[dictation]\nunload_after = \"soon\"\n", "dictation.unload_after"),
        ("[dictation]\nhold_key = \"not_a_key\"\n", "dictation.hold_key"),
        ("[app]\nlog_level = \"verbose\"\n", "app.log_level"),
        ("[dictation.insert]\nmethod = \"write\"\n", "dictation.insert.method"),
        ("[ask]\nbackend = \"other\"\n", "ask.backend"),
        ("[cleanup]\nbase_url = \"ftp://example.com\"\n", "cleanup.base_url"),
        ("[ask]\nprefixes = []\n", "ask.prefixes"),
        ("[dictation]\nhistory_limit = -1\n", "dictation.history_limit"),
    ]
    for (text, key) in cases {
        // The assertions intentionally check the public path, not a TOMLDecoder implementation detail.
        // This keeps all malformed-value diagnostics actionable.
        let error = configError(for: text)
        // `contains` is sufficient here because the rest of the message is explanatory text.
        #expect(error?.description.contains(key) == true)
    }
}

@Test func extraBodyMapsTomlValuesToJSONValues() throws {
    let config = try ConfigLoader.load(configText: """
        [cleanup.extra_body]
        temperature = 0.2
        enabled = true
        labels = ["one", "two"]
        nested = { answer = 42, text = "ok" }
        """, secretsText: nil)
    #expect(config.cleanup.extraBody == [
        "temperature": .number(0.2),
        "enabled": .bool(true),
        "labels": .array([.string("one"), .string("two")]),
        "nested": .object(["answer": .number(42), "text": .string("ok")]),
    ])
}

@Test func aliasesCommandsAndInsertAppsDecode() throws {
    let config = try ConfigLoader.load(configText: """
        [launcher.aliases]
        "Visual Studio Code" = ["vsc", "code"]

        [[launcher.commands]]
        title = "Lock screen"
        run = "pmset displaysleepnow"
        mode = "compact"
        aliases = ["lock"]

        [dictation.insert.apps]
        "com.example.App" = "paste"
        """, secretsText: nil)
    #expect(config.launcher.aliases["Visual Studio Code"] == ["vsc", "code"])
    #expect(config.launcher.commands == [CommandSettings(title: "Lock screen", run: "pmset displaysleepnow", mode: "compact", aliases: ["lock"])])
    #expect(config.dictation.insert.apps == ["com.example.App": .paste])
}

@Test func commandsTakeChoicesAndTypeMode() throws {
    let config = try ConfigLoader.load(configText: """
        [[launcher.commands]]
        title = "pass"
        run = "pass-pick"
        mode = "type"
        choices = true

        [[launcher.commands]]
        title = "Lock screen"
        run = "pmset displaysleepnow"
        """, secretsText: nil)
    #expect(config.launcher.commands == [
        CommandSettings(title: "pass", run: "pass-pick", mode: "type", choices: true),
        CommandSettings(title: "Lock screen", run: "pmset displaysleepnow"),
    ])

    let command = "[[launcher.commands]]\ntitle = \"x\"\nrun = \"y\"\n"
    #expect(configError(for: command + "mode = \"paste\"\n")?.description
        == "launcher.commands[0].mode: invalid value (expected silent, compact, fullOutput, or type)")
    #expect(configError(for: command + "choices = \"yes\"\n")?.description.hasPrefix("launcher.commands[0].choices") == true)
    #expect(configError(for: command + "choice = true\n")?.description == "launcher.commands[0].choice: unknown key, did you mean choices?")
}

@Test func secretsAndApiKeyCommand() throws {
    var config = try ConfigLoader.load(configText: "", secretsText: "[cleanup]\napi_key = \"direct-secret\"\n")
    #expect(config.cleanup.apiKey == "direct-secret")

    let secrets = "[cleanup]\napi_key_command = \"printf 'command-secret\\n'\"\n"
    try ConfigLoader.resolveSecrets(&config, secretsText: secrets)
    #expect(config.cleanup.apiKey == "command-secret")
}

@Test func secretsRejectUnknownKeysAndBadCommands() throws {
    let unknown = configError(for: "", secrets: "[other]\nvalue = 1\n")
    #expect(unknown?.description == "other: unknown key")

    var config = Config()
    do {
        try ConfigLoader.resolveSecrets(&config, secretsText: "[cleanup]\napi_key_command = \"printf ''\"\n")
        Issue.record("empty secret command output should fail")
    } catch let error as ConfigError {
        #expect(error.description.contains("cleanup.api_key_command"))
        #expect(!error.description.contains("printf"))
    }
}

private func configError(for configText: String, secrets: String) -> ConfigError? {
    do {
        _ = try ConfigLoader.load(configText: configText, secretsText: secrets)
        return nil
    } catch let error as ConfigError {
        return error
    } catch {
        Issue.record("unexpected error: \(error)")
        return nil
    }
}

@Test func durationsAndKeySpecsRoundTrip() throws {
    #expect(DurationSetting.parse(" never ") == .never)
    #expect(DurationSetting.parse("0") == .seconds(0))
    #expect(DurationSetting.parse("250ms") == .seconds(0.25))
    #expect(DurationSetting.parse("0.3s") == .seconds(0.3))
    #expect(DurationSetting.parse("5m") == .seconds(300))
    #expect(DurationSetting.parse("12h") == .seconds(43_200))
    #expect(DurationSetting.parse("-1s") == nil)

    let names = ["a", "z", "0", "9", "f1", "f20", "space", "return", "tab", "escape", "delete", "forward_delete", "up", "down", "left", "right", "home", "end", "page_up", "page_down", "minus", "equal", "left_bracket", "right_bracket", "semicolon", "quote", "comma", "period", "slash", "backslash", "grave"]
    for name in names {
        let spec = try #require(KeySpec.parse(name))
        #expect(KeySpec.parse(spec.description) == spec)
    }
    let modified = try #require(KeySpec.parse("right_option+right_shift+m"))
    #expect(modified.description == "right_option+right_shift+m")
    #expect(KeySpec.parse("cmd+space")?.description == "cmd+space")
    #expect(KeySpec.parse("option_right+shift_right+m") == modified)
}

@Test(.timeLimit(.minutes(1)))
func configStoreWritesReloadsAndKeepsLastGoodConfig() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alauncher-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configURL = directory.appendingPathComponent("config.toml")
    let secretsURL = directory.appendingPathComponent("secrets.toml")
    let store = ConfigStore(configFile: configURL, secretsFile: secretsURL, defaultConfigText: "[launcher]\nmax_results = 8\n")
    var changed: [Config] = []
    var errors: [String] = []
    store.onChange = { changed.append($0) }
    store.onError = { errors.append($0) }
    store.start()
    #expect(FileManager.default.fileExists(atPath: configURL.path))
    #expect(!FileManager.default.fileExists(atPath: secretsURL.path))

    let updated = "[launcher]\nmax_results = 12\n"
    let temporary = directory.appendingPathComponent("config.toml.tmp")
    try Data(updated.utf8).write(to: temporary)
    _ = try FileManager.default.replaceItemAt(configURL, withItemAt: temporary)
    try await waitForCondition { store.current.launcher.maxResults == 12 }
    #expect(store.current.launcher.maxResults == 12)

    let bad = "[launcher]\nmax_results = 0\n"
    let badTemporary = directory.appendingPathComponent("config.toml.bad.tmp")
    try Data(bad.utf8).write(to: badTemporary)
    _ = try FileManager.default.replaceItemAt(configURL, withItemAt: badTemporary)
    try await waitForCondition { !errors.isEmpty }
    #expect(store.current.launcher.maxResults == 12)

    let changeCount = changed.count
    store.reload()
    try await Task.sleep(for: .milliseconds(100))
    #expect(changed.count == changeCount)

    // Editors that write in place, like vim with backupcopy=yes, never touch the directory.
    try overwriteInPlace(configURL, with: "[launcher]\nmax_results = 14\n")
    try await waitForCondition { store.current.launcher.maxResults == 14 }
    #expect(store.current.launcher.maxResults == 14)
}

/// Home Manager's out-of-store links: config.toml is a symlink, and edits land on the real file.
@Test(.timeLimit(.minutes(1)))
func configStoreFollowsASymlinkedConfig() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("alauncher-symlink-\(UUID().uuidString)", isDirectory: true)
    let realDirectory = root.appendingPathComponent("dotfiles", isDirectory: true)
    let configDirectory = root.appendingPathComponent("config", isDirectory: true)
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let realURL = realDirectory.appendingPathComponent("config.toml")
    try Data("[launcher]\nmax_results = 5\n".utf8).write(to: realURL)
    let linkURL = configDirectory.appendingPathComponent("config.toml")
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

    let store = ConfigStore(configFile: linkURL, secretsFile: configDirectory.appendingPathComponent("secrets.toml"), defaultConfigText: "")
    store.start()
    #expect(store.current.launcher.maxResults == 5)

    // In place through the link, as vim saves a symlinked file.
    try overwriteInPlace(linkURL, with: "[launcher]\nmax_results = 7\n")
    try await waitForCondition { store.current.launcher.maxResults == 7 }
    #expect(store.current.launcher.maxResults == 7)

    // An atomic save of the real file, as editors do when it's opened directly.
    let temporary = realDirectory.appendingPathComponent("config.toml.tmp")
    try Data("[launcher]\nmax_results = 9\n".utf8).write(to: temporary)
    _ = try FileManager.default.replaceItemAt(realURL, withItemAt: temporary)
    try await waitForCondition { store.current.launcher.maxResults == 9 }
    #expect(store.current.launcher.maxResults == 9)

    // In place again: the watch must have moved to the replacement file.
    try overwriteInPlace(realURL, with: "[launcher]\nmax_results = 11\n")
    try await waitForCondition { store.current.launcher.maxResults == 11 }
    #expect(store.current.launcher.maxResults == 11)

    // A new link into another directory, as a switch can leave; saves there must be seen too.
    let otherDirectory = root.appendingPathComponent("generation2", isDirectory: true)
    try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
    let otherURL = otherDirectory.appendingPathComponent("config.toml")
    try Data("[launcher]\nmax_results = 13\n".utf8).write(to: otherURL)
    let newLink = configDirectory.appendingPathComponent("config.toml.new")
    try FileManager.default.createSymbolicLink(at: newLink, withDestinationURL: otherURL)
    #expect(rename(newLink.path, linkURL.path) == 0)
    try await waitForCondition { store.current.launcher.maxResults == 13 }
    #expect(store.current.launcher.maxResults == 13)

    let otherTemporary = otherDirectory.appendingPathComponent("config.toml.tmp")
    try Data("[launcher]\nmax_results = 15\n".utf8).write(to: otherTemporary)
    _ = try FileManager.default.replaceItemAt(otherURL, withItemAt: otherTemporary)
    try await waitForCondition { store.current.launcher.maxResults == 15 }
    #expect(store.current.launcher.maxResults == 15)
}

private func overwriteInPlace(_ url: URL, with text: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

private func waitForCondition(_ condition: @escaping () -> Bool) async throws {
    for _ in 0..<40 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("condition was not met within the test timeout")
}
