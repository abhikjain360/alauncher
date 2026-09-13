import Core
import Foundation
import Search
import Testing
@testable import Launcher

struct ArgumentSessionTests {
    private let specs = [
        ScriptCommand.Argument(type: "text", placeholder: "Repo"),
        ScriptCommand.Argument(type: "text", placeholder: "Branch", optional: true),
        ScriptCommand.Argument(type: "password", placeholder: "Token"),
    ]

    @Test("arguments are collected in order; optional ones may be empty, required ones may not")
    func collectsInOrder() {
        var session = ArgumentSession(entryID: "script:/deploy.sh", title: "Deploy", specs: specs)
        #expect(session.index == 0)
        #expect(session.placeholder == "Repo")

        var step = session.submit("")
        #expect(step == .rejected)
        step = session.submit("alauncher")
        #expect(step == .next)
        #expect(session.placeholder == "Branch (optional)")
        step = session.submit("")
        #expect(step == .next)
        #expect(session.current.type == "password")
        #expect(session.isLast)
        step = session.submit("secret")
        #expect(step == .run(["alauncher", "", "secret"]))
    }

    @Test("inline arguments prefill the session, which starts at the first missing one")
    func prefilled() {
        var session = ArgumentSession(
            entryID: "script:/deploy.sh", title: "Deploy", specs: specs,
            prefilled: ["repo", "main"], previousQuery: "dep repo main"
        )
        #expect(session.index == 2)
        #expect(session.values == ["repo", "main", ""])
        #expect(session.previousQuery == "dep repo main")
        let step = session.submit("token")
        #expect(step == .run(["repo", "main", "token"]))
    }

    @Test("Tab and Shift-Tab move between arguments, keeping what was typed")
    func tabbing() {
        var session = ArgumentSession(entryID: "script:/deploy.sh", title: "Deploy", specs: specs)
        var moved = session.moveForward(keeping: "a")
        #expect(moved)
        moved = session.moveForward(keeping: "b")
        #expect(moved)
        moved = session.moveForward(keeping: "c")
        #expect(!moved)
        #expect(session.values == ["a", "b", "c"])

        moved = session.moveBack(keeping: "c2")
        #expect(moved)
        #expect(session.currentValue == "b")
        #expect(session.values == ["a", "b", "c2"])
        moved = session.moveBack(keeping: "b")
        moved = session.moveBack(keeping: "a")
        #expect(!moved)
        #expect(session.index == 0)
    }

    @Test("scripts and commands without declared arguments get one optional argument; apps get none")
    func specsForActions() {
        let script = ScriptCommand(path: URL(fileURLWithPath: "/scripts/s.sh"), title: "S", mode: .compact)
        #expect(ArgumentSession.specs(for: .script(script)) == [ArgumentSession.undeclaredArgument])
        #expect(ArgumentSession.specs(for: .command(CommandSettings(title: "C", run: "true"))) == [ArgumentSession.undeclaredArgument])
        #expect(ArgumentSession.specs(for: .app(path: "/Applications/Safari.app")) == nil)

        var declared = script
        declared.arguments = specs
        #expect(ArgumentSession.specs(for: .script(declared)) == specs)
        #expect(ArgumentSession(entryID: "x", title: "S", specs: []).placeholder == "Argument (optional)")
    }
}
