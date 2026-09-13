import Core
import Foundation
import Testing
@testable import Dictation

private func parse(_ fixture: String) -> (parser: OpencodeEventParser, events: [OpencodeEvent]) {
    var parser = OpencodeEventParser()
    var events: [OpencodeEvent] = []
    for line in fixture.split(separator: "\n") {
        events += parser.consume(line: String(line))
    }
    return (parser, events)
}

// MARK: - Event parsing from recorded fixtures

@Test func plainAnswerFixture() {
    let (parser, events) = parse(OpencodeFixtures.plain)
    #expect(parser.sessionID == "ses_f64300544ffeOhGDgoiqdeTBYW")
    #expect(parser.answer == "Paris")
    #expect(events == [
        .session("ses_f64300544ffeOhGDgoiqdeTBYW"),
        .text("Paris"),
        .stepFinish(reason: "stop"),
    ])
}

@Test func webSearchFixtureReportsToolsAndTheFinalText() {
    let (parser, events) = parse(OpencodeFixtures.search)
    let tools = events.compactMap { event -> String? in
        if case .tool(let name, let status) = event { return "\(name):\(status)" }
        return nil
    }
    #expect(tools == ["websearch:completed", "webfetch:completed", "websearch:completed"])
    #expect(parser.answer.hasPrefix("Yesterday was Saturday"))
    #expect(!parser.answer.hasPrefix("\n"))
    #expect(events.filter { if case .stepFinish = $0 { return true } else { return false } }.count == 3)
}

@Test func shellRequestFixtureHasNoToolCalls() {
    let (parser, events) = parse(OpencodeFixtures.bash)
    #expect(!events.contains { if case .tool = $0 { return true } else { return false } })
    #expect(parser.answer.contains("I can't run shell commands"))
    #expect(parser.answer.contains("webfetch"))
    #expect(parser.answer.contains("websearch"))
}

@Test func followUpFixtureContinuesTheSameSession() {
    let (parser, _) = parse(OpencodeFixtures.follow)
    #expect(parser.sessionID == parse(OpencodeFixtures.plain).parser.sessionID)
    #expect(parser.answer.contains("Paris"))
}

@Test func errorFixtureCarriesTheMessage() {
    let (_, events) = parse(OpencodeFixtures.err)
    #expect(events.contains(.error("Unexpected server error. Check server logs for details.")))
}

@Test func growingTextPartsEmitOnlyDeltas() {
    var parser = OpencodeEventParser()
    func text(_ id: String, _ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "type": "text", "sessionID": "ses_1", "part": ["id": id, "type": "text", "text": value],
        ])
        return String(decoding: data, as: UTF8.self)
    }
    #expect(parser.consume(line: text("p1", "Hel")) == [.session("ses_1"), .text("Hel")])
    #expect(parser.consume(line: text("p1", "Hello")) == [.text("lo")])
    #expect(parser.consume(line: text("p1", "Hello")) == [])
    // A second text part is a new paragraph.
    #expect(parser.consume(line: text("p2", "World")) == [.text("\n\nWorld")])
    // A rewritten (non-prefix) part emits nothing.
    #expect(parser.consume(line: text("p2", "Earth")) == [])
    #expect(parser.answer == "Hello\n\nWorld")
}

@Test func junkLinesAreIgnored() {
    var parser = OpencodeEventParser()
    #expect(parser.consume(line: "") == [])
    #expect(parser.consume(line: "not json") == [])
    #expect(parser.consume(line: "{}") == [])
    #expect(parser.consume(line: #"{"type":"mystery","sessionID":"ses_2"}"#) == [.session("ses_2")])
    #expect(parser.answer.isEmpty)
}

// MARK: - Launch configuration

@Test func agentConfigDeniesEverythingButTheConfiguredTools() throws {
    let prompt = AskSettings.defaultPrompt
    let json = OpencodeLaunch.agentConfigJSON(prompt: prompt, tools: ["websearch", "webfetch", " "])
    let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let agents = try #require(root["agent"] as? [String: Any])
    #expect(Array(agents.keys) == ["alauncher-ask"])
    let agent = try #require(agents["alauncher-ask"] as? [String: Any])
    #expect(agent["prompt"] as? String == prompt)
    #expect(agent["mode"] as? String == "primary")
    #expect(agent["permission"] as? [String: String] == ["*": "deny", "websearch": "allow", "webfetch": "allow"])
    #expect(Set(root.keys) == ["agent"])
    // The last matching rule wins, so the catch-all deny must come first.
    let star = try #require(json.range(of: "\"*\":\"deny\""))
    let web = try #require(json.range(of: "\"webfetch\":\"allow\""))
    #expect(star.lowerBound < web.lowerBound)
}

@Test func agentConfigWithNoToolsDeniesAll() throws {
    let json = OpencodeLaunch.agentConfigJSON(prompt: "p", tools: [])
    #expect(json == #"{"agent":{"alauncher-ask":{"description":"Answers spoken questions for alauncher.","mode":"primary","permission":{"*":"deny"},"prompt":"p"}}}"#)
}

@Test func runArguments() {
    #expect(OpencodeLaunch.arguments(question: "why?", model: "deepseek/deepseek-flash", variant: "high", sessionID: nil, directory: "/d") == [
        "run", "--format", "json", "--agent", "alauncher-ask", "-m", "deepseek/deepseek-flash",
        "--variant", "high", "--dir", "/d", "--", "why?",
    ])
    #expect(OpencodeLaunch.arguments(question: "-rf and more", model: "m", variant: "", sessionID: "ses_9", directory: "/d") == [
        "run", "--format", "json", "--agent", "alauncher-ask", "-m", "m",
        "--session", "ses_9", "--dir", "/d", "--", "-rf and more",
    ])
}

@Test func searchPathExpandsHomeAndUserAndDeduplicates() {
    let path = OpencodeLaunch.searchPath(
        extraPath: ["~/bin", "/etc/profiles/per-user/$USER/bin", "/usr/local/bin", ""],
        inheritedPath: "/usr/bin:/usr/local/bin", home: "/Users/u", user: "u"
    )
    #expect(path == ["/Users/u/bin", "/etc/profiles/per-user/u/bin", "/usr/local/bin", "/usr/bin"])
}

@Test func executableResolution() {
    let executables: Set<String> = ["/b/opencode", "/Users/u/.opencode/bin/opencode"]
    let isExecutable = { (path: String) in executables.contains(path) }
    #expect(OpencodeLaunch.resolve("opencode", searchPath: ["/a", "/b"], home: "/Users/u", user: "u", isExecutable: isExecutable) == "/b/opencode")
    #expect(OpencodeLaunch.resolve("~/.opencode/bin/opencode", searchPath: [], home: "/Users/u", user: "u", isExecutable: isExecutable) == "/Users/u/.opencode/bin/opencode")
    #expect(OpencodeLaunch.resolve("/nowhere/opencode", searchPath: ["/b"], home: "/Users/u", user: "u", isExecutable: isExecutable) == nil)
    #expect(OpencodeLaunch.resolve("missing", searchPath: ["/a", "/b"], home: "/Users/u", user: "u", isExecutable: isExecutable) == nil)
}

// MARK: - Live (opt-in): ALAUNCHER_LIVE_ASK=1

/// Runs the real opencode through AskRunner and asks it to run `ls`. Costs a fraction of a cent.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ALAUNCHER_LIVE_ASK"] == "1"), .timeLimit(.minutes(2)))
func liveAgentCannotRunShellCommands() async throws {
    let settings = Config()
    let runner = AskRunner(ask: settings.ask, cleanup: settings.cleanup, extraPath: settings.launcher.extraPath)
    var streamed = ""
    let start = Date()
    let answer = try await runner.run("Run the shell command `ls` in the current directory and show me its output. If you cannot, list the tools you do have.") { delta in
        streamed += delta
    }
    print(String(format: "live ask: %.2f s, tools used: %@", Date().timeIntervalSince(start), answer.toolsUsed.isEmpty ? "none" : answer.toolsUsed.joined(separator: ",")))
    print("live ask answer: \(answer.text)")
    #expect(!answer.toolsUsed.contains("bash"))
    #expect(Set(answer.toolsUsed).isSubset(of: ["websearch", "webfetch"]))
    #expect(streamed == answer.text)
}
