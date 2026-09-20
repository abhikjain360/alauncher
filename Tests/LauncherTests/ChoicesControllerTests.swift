import Core
import Foundation
import Search
import Testing
@testable import Launcher

/// A `choices = true` command driven through the controller. The fake effects start no
/// process; each test finishes the runs itself.
@MainActor
struct ChoicesControllerTests {
    private let panel = FakePanel()
    private let log = EffectLog()
    private let frecency = FrecencyStore(fileURL: nil)

    static let vault = CommandSettings(title: "Vault", run: "vault-pick", mode: "type", aliases: ["vault"], choices: true)
    static let stamp = CommandSettings(title: "Stamp", run: "date +%s", mode: "type", aliases: ["stamp"])
    static let entries = #"{"id": "entry", "placeholder": "Pick an entry", "items": ["email/gmail", "work/vpn", {"title": "Bank", "subtitle": "bank/main", "value": "bank/main"}]}"#

    private func makeController() async -> LauncherController {
        let catalog = CatalogBuilder.build(
            apps: Fixture.apps,
            scripts: Fixture.scripts,
            commands: Fixture.commands + [Self.vault, Self.stamp],
            builtIns: [],
            settings: LauncherSettings()
        )
        let controller = LauncherController(
            config: Config(),
            builtIns: [],
            frecency: frecency,
            rates: nil,
            effects: log.effects,
            calculate: { _ in .notACalculation },
            scan: { _, _ in catalog }
        )
        controller.attach(panel)
        controller.show()
        await controller.indexSettled()
        return controller
    }

    /// Starts Vault and answers its first run with `entries`.
    private func openVault(_ controller: LauncherController) {
        panel.type("vault")
        #expect(panel.selectedTitle == "Vault")
        controller.panelActivate()
        log.finish(Self.entries)
    }

    @Test("Enter runs the command with no arguments, lists its round, and a pick runs it again with the id and value")
    func roundAndPick() async {
        let controller = await makeController()
        panel.type("vault")
        controller.panelActivate()
        #expect(log.events == ["record command:Vault", "capture Vault []"])
        #expect(frecency.score(for: "command:Vault") > 0)
        #expect(panel.argumentTitle == "Vault")
        #expect(panel.placeholder == "Running…")
        #expect(panel.text == "")
        #expect(panel.rows.isEmpty)
        #expect(panel.isVisible)

        log.finish(Self.entries)
        #expect(panel.placeholder == "Pick an entry")
        #expect(panel.titles == ["email/gmail", "work/vpn", "Bank"])
        #expect(panel.rows.last?.subtitle == "bank/main")
        #expect(panel.selection == 0)

        panel.type("vpn")
        #expect(panel.titles == ["work/vpn"])
        log.frontmostPID = 777
        controller.panelActivate()
        #expect(log.events.last == #"capture Vault ["entry", "work/vpn"]"#)
        #expect(panel.placeholder == "Running…")
        #expect(panel.text == "")
        #expect(panel.rows.isEmpty)

        log.finish(#"{"final": "hunter2"}"#)
        #expect(log.events.last == "deliver type hunter2 → 777")
        #expect(!panel.isVisible)
        #expect(panel.argumentTitle == nil)
    }

    @Test("a round longer than the panel scrolls, and a click picks the row on screen")
    func scrollsALongRound() async {
        panel.rowCapacity = 2
        let controller = await makeController()
        openVault(controller)
        #expect(panel.titles == ["email/gmail", "work/vpn"])

        #expect(panel.scroll == ScrollPosition(first: 0, total: 3))
        // Filtered down to what fits, the indicator goes away; cleared, it is back.
        panel.type("bank")
        #expect(panel.scroll == nil)
        panel.type("")
        #expect(panel.scroll == ScrollPosition(first: 0, total: 3))

        controller.panelMoveSelection(by: 1)
        #expect(panel.titles == ["email/gmail", "work/vpn"])
        #expect(panel.selection == 1)
        controller.panelMoveSelection(by: 1)
        #expect(panel.titles == ["work/vpn", "Bank"])
        #expect(panel.selection == 1)
        #expect(panel.scroll == ScrollPosition(first: 1, total: 3))
        // The end of the list holds.
        controller.panelMoveSelection(by: 1)
        #expect(panel.titles == ["work/vpn", "Bank"])
        #expect(panel.selection == 1)

        controller.panelClickedRow(at: 1)
        #expect(log.events.last == #"capture Vault ["entry", "bank/main"]"#)
    }

    @Test("several rounds pass each round's id and the pick's value; subtitles don't matter, values do")
    func manyRounds() async {
        let controller = await makeController()
        openVault(controller)
        panel.type("bank")
        controller.panelActivate()
        #expect(log.events.last == #"capture Vault ["entry", "bank/main"]"#)
        log.finish(#"{"id": "field:bank/main", "items": ["password", "username", "otp"]}"#)
        #expect(panel.placeholder == "Search")
        #expect(panel.titles == ["password", "username", "otp"])
        controller.panelMoveSelection(by: 1)
        controller.panelActivate()
        #expect(log.events.last == #"capture Vault ["field:bank/main", "username"]"#)
        log.finish(#"{"final": "abhik"}"#)
        #expect(log.events.last == "deliver type abhik → 4242")
        #expect(log.captures.count == 3)
    }

    @Test("text typed after the alias filters the first round, and text typed during a run filters the next")
    func typedFilters() async {
        let controller = await makeController()
        panel.type("vault gm")
        #expect(panel.selectedTitle == "Vault — gm")
        controller.panelActivate()
        #expect(log.events == ["record command:Vault", "capture Vault []"])
        #expect(panel.text == "gm")
        log.finish(Self.entries)
        #expect(panel.titles == ["email/gmail"])

        controller.panelActivate()
        panel.type("user")
        #expect(panel.rows.isEmpty)
        log.finish(#"{"id": "field", "items": ["password", "username"]}"#)
        #expect(panel.text == "user")
        #expect(panel.titles == ["username"])
    }

    @Test("Esc steps back: it cancels a run, returns to the round before with its filter, and from the first to search")
    func escapeStepsBack() async {
        let controller = await makeController()
        panel.type("vault")
        controller.panelActivate()
        controller.panelCancel()
        #expect(log.events == ["record command:Vault", "capture Vault []", "cancel Vault"])
        #expect(panel.argumentTitle == nil)
        #expect(panel.text == "vault")
        #expect(panel.selectedTitle == "Vault")
        // The cancelled run's late answer is ignored.
        log.finish(Self.entries)
        #expect(panel.argumentTitle == nil)
        #expect(panel.selectedTitle == "Vault")

        controller.panelActivate()
        log.finish(Self.entries)
        panel.type("work")
        controller.panelActivate()
        controller.panelCancel()
        #expect(Array(log.events.suffix(2)) == [#"capture Vault ["entry", "work/vpn"]"#, "cancel Vault"])
        #expect(panel.placeholder == "Pick an entry")
        #expect(panel.text == "work")
        #expect(panel.titles == ["work/vpn"])

        controller.panelActivate()
        log.finish(#"{"id": "field:work/vpn", "items": ["password", "username"]}"#)
        #expect(panel.titles == ["password", "username"])
        controller.panelCancel()
        #expect(panel.text == "work")
        #expect(panel.titles == ["work/vpn"])
        controller.panelCancel()
        #expect(panel.argumentTitle == nil)
        #expect(panel.text == "vault")
        #expect(panel.selectedTitle == "Vault")
        #expect(panel.isVisible)
    }

    @Test("a failed run flashes its last stderr line, a bad reply says what's wrong, and neither types or shows stdout")
    func failures() async {
        let controller = await makeController()
        panel.type("vault")
        controller.panelActivate()
        log.finish("hunter2", stderr: "gpg: decryption failed\n", exitCode: 2)
        #expect(log.events.last == "flash error gpg: decryption failed")
        #expect(panel.argumentTitle == nil)
        #expect(panel.text == "vault")

        controller.panelActivate()
        log.finish(Self.entries)
        controller.panelActivate()
        log.finish("hunter2", exitCode: 1)
        #expect(log.events.last == "flash error Vault failed (exit 1)")
        #expect(panel.titles == ["email/gmail", "work/vpn", "Bank"])

        controller.panelActivate()
        log.finish("hunter2")
        #expect(log.events.last == #"flash error Vault: expected {"items": …} or {"final": …}"#)
        #expect(panel.isVisible)
        #expect(!log.events.contains { $0.contains("hunter2") })
    }

    @Test("empty output ends the session quietly")
    func emptyOutput() async {
        let controller = await makeController()
        openVault(controller)
        controller.panelActivate()
        log.finish("  \n")
        #expect(!panel.isVisible)
        #expect(panel.argumentTitle == nil)
        #expect(!log.events.contains { $0.hasPrefix("deliver") || $0.hasPrefix("flash") })
    }

    @Test("Enter beeps while a run is in flight or nothing matches; Tab starts the command but does nothing in it; ⌘C copies nothing")
    func keys() async {
        let controller = await makeController()
        panel.type("vault")
        controller.panelTab(backward: false)
        #expect(log.events == ["record command:Vault", "capture Vault []"])
        controller.panelActivate()
        #expect(log.events.last == "beep")
        controller.panelTab(backward: false)
        log.finish(Self.entries)
        #expect(!controller.panelCopySelection())
        panel.type("zzz")
        #expect(panel.rows.isEmpty)
        controller.panelActivate()
        #expect(log.events.last == "beep")
        #expect(log.captures.count == 1)
        #expect(!log.events.contains { $0.hasPrefix("copy") })
    }

    @Test("losing the keyboard mid-run hides the panel but still delivers a final; a new round is dropped")
    func closedMidRun() async {
        let controller = await makeController()
        openVault(controller)
        controller.panelActivate()
        controller.panelDidResignKey()
        #expect(!panel.isVisible)
        #expect(!log.events.contains { $0.hasPrefix("cancel") })
        log.finish(#"{"final": "hunter2"}"#)
        #expect(log.events.last == "deliver type hunter2 → 4242")
        #expect(panel.argumentTitle == nil)

        controller.show()
        openVault(controller)
        controller.panelActivate()
        controller.panelDidResignKey()
        log.finish(#"{"items": ["password"]}"#)
        #expect(log.events.last == "flash Vault closed")
        #expect(!panel.isVisible)

        // With no run in flight, losing the keyboard ends the session as always.
        controller.show()
        openVault(controller)
        controller.panelDidResignKey()
        #expect(!panel.isVisible)
        controller.show()
        #expect(panel.argumentTitle == nil)
        #expect(panel.text == "")
    }

    @Test("the hotkey, or showing again after the panel closed, abandons a run in flight")
    func hotkeyAbandons() async {
        let controller = await makeController()
        openVault(controller)
        controller.panelActivate()
        controller.toggle()
        #expect(log.events.last == "cancel Vault")
        #expect(!panel.isVisible)
        log.finish(#"{"final": "hunter2"}"#)
        #expect(!log.events.contains { $0.hasPrefix("deliver") })

        controller.show()
        openVault(controller)
        controller.panelActivate()
        controller.panelDidResignKey()
        controller.show()
        #expect(log.events.last == "cancel Vault")
        #expect(panel.argumentTitle == nil)
        log.finish(#"{"final": "hunter2"}"#)
        #expect(!log.events.contains { $0.hasPrefix("deliver") })
    }

    @Test(#"a plain `mode = "type"` command runs with the frontmost app as its target"#)
    func typeModeCommand() async {
        let controller = await makeController()
        panel.type("stamp")
        #expect(panel.selectedTitle == "Stamp")
        controller.panelActivate()
        #expect(log.events == ["record command:Stamp", "run Stamp []"])
        #expect(log.lastRun?.typesOutput == true)
        #expect(log.lastRun?.targetPID == 4242)
        #expect(!panel.isVisible)
    }
}
