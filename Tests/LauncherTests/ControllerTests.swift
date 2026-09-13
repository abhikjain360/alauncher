import Calc
import Core
import Foundation
import Search
import Testing
@testable import Launcher

/// Stands in for the panel and records what the controller shows. No window.
@MainActor
final class FakePanel: LauncherPanelHost {
    weak var launcherDelegate: LauncherPanelDelegate?
    var isVisible = false
    var text = ""
    var rowCapacity = 8
    var rows: [LauncherRow] = []
    var selection: Int?
    var hint: (index: Int, text: String)?
    var argumentTitle: String?
    var placeholder: String?
    var secure = false

    func setText(_ text: String) {
        self.text = text
    }

    func setArgumentMode(title: String?, placeholder: String?, secure: Bool) {
        argumentTitle = title
        self.placeholder = placeholder
        self.secure = secure
    }

    func display(_ rows: [LauncherRow], selection: Int?, hint: (index: Int, text: String)?) {
        self.rows = rows
        self.selection = selection
        self.hint = hint
    }

    func select(_ index: Int?) {
        selection = index
    }

    func prepareToShow() -> Int { rowCapacity }
    func present() { isVisible = true }
    func focus() {}
    func dismiss() { isVisible = false }

    /// What typing does: the field changes, then the controller hears about it.
    func type(_ text: String) {
        self.text = text
        launcherDelegate?.panelQueryChanged(text)
    }

    var titles: [String] { rows.map(\.title) }

    var selectedTitle: String? {
        guard let selection, rows.indices.contains(selection) else { return nil }
        return rows[selection].title
    }
}

/// Records side effects instead of performing them.
@MainActor
final class EffectLog {
    var events: [String] = []

    var effects: LauncherEffects {
        LauncherEffects(
            openApplication: { self.events.append("open \($0)") },
            reveal: { self.events.append("reveal \($0)") },
            copy: { self.events.append("copy \($0)") },
            flash: { text, isError in self.events.append(isError ? "flash error \(text)" : "flash \(text)") },
            run: { invocation, arguments in self.events.append("run \(invocation.title) \(arguments)") },
            recordLaunch: { store, id in
                store.recordLaunch(of: id)
                self.events.append("record \(id)")
            },
            beep: { self.events.append("beep") }
        )
    }
}

/// Hands out catalogs in order for successive scans, repeating the last.
final class ScanSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var catalogs: [Catalog]

    init(_ catalogs: [Catalog]) {
        self.catalogs = catalogs
    }

    func next() -> Catalog {
        lock.lock()
        defer { lock.unlock() }
        return catalogs.count > 1 ? catalogs.removeFirst() : catalogs[0]
    }
}

/// The controller's state machine, driven the way the panel drives it.
@MainActor
struct ControllerTests {
    private let panel = FakePanel()
    private let log = EffectLog()
    private let frecency = FrecencyStore(fileURL: nil)

    static let deploy = ScriptCommand(
        path: URL(fileURLWithPath: "/scripts/deploy.sh"),
        title: "Deploy",
        mode: .compact,
        arguments: [
            .init(type: "text", placeholder: "Repo"),
            .init(type: "dropdown", placeholder: "Env", choices: [.init(title: "Staging", value: "stg"), .init(title: "Production", value: "prod")]),
            .init(type: "password", placeholder: "Token", optional: true),
        ],
        aliases: ["dep"],
        needsConfirmation: true
    )
    static let reboot = ScriptCommand(path: URL(fileURLWithPath: "/scripts/reboot.sh"), title: "Reboot Router", mode: .silent, needsConfirmation: true)

    private func makeController(
        builtIns: [BuiltInCommand] = [],
        calculate: @escaping @Sendable (String) -> CalcOutcome = fakeCalculate,
        scans: ScanSequence? = nil
    ) async -> LauncherController {
        let catalog = CatalogBuilder.build(
            apps: Fixture.apps,
            scripts: Fixture.scripts + [Self.deploy, Self.reboot],
            commands: Fixture.commands,
            builtIns: builtIns,
            settings: LauncherSettings()
        )
        let sequence = scans ?? ScanSequence([catalog])
        let controller = LauncherController(
            config: Config(),
            builtIns: builtIns,
            frecency: frecency,
            rates: nil,
            effects: log.effects,
            calculate: calculate,
            scan: { _, _ in sequence.next() }
        )
        controller.attach(panel)
        controller.show()
        await controller.indexSettled()
        return controller
    }

    @Test("Enter opens the selected app, records the launch and hides the panel")
    func openApp() async {
        let controller = await makeController()
        #expect(panel.isVisible)
        panel.type("saf")
        #expect(panel.selectedTitle == "Safari")
        controller.panelActivate()
        #expect(log.events == ["record app:/Applications/Safari.app", "open /Applications/Safari.app"])
        #expect(!panel.isVisible)
        #expect(frecency.score(for: "app:/Applications/Safari.app") > 0)
    }

    @Test("clicking a row activates it")
    func clickRow() async {
        let controller = await makeController()
        panel.type("c")
        let index = panel.titles.firstIndex(of: "Chess") ?? -1
        controller.panelClickedRow(at: index)
        #expect(log.events == ["record app:/System/Applications/Chess.app", "open /System/Applications/Chess.app"])
    }

    @Test("Enter on the calculator row copies, hides and flashes; no launch is recorded")
    func calculatorRow() async {
        let controller = await makeController()
        panel.type("2+2")
        #expect(panel.titles == ["4"])
        controller.panelActivate()
        #expect(log.events == ["copy 4", "flash copied"])
        #expect(!panel.isVisible)
    }

    @Test("an error row shows but is never selected or activated")
    func errorRow() async {
        let controller = await makeController(calculate: { $0 == "s" ? .error("bad input") : .notACalculation })
        panel.type("s")
        #expect(panel.rows.first?.title == "bad input")
        #expect(panel.selection == 1)
        controller.panelMoveSelection(by: -1)
        #expect(panel.selection == 1)
        controller.panelMoveSelection(by: 1)
        #expect(panel.selection == 2)
    }

    @Test("inline arguments run the script with them")
    func inlineArguments() async {
        let controller = await makeController()
        panel.type("gh swift testing")
        #expect(panel.selectedTitle == "GitHub Search — swift testing")
        controller.panelActivate()
        #expect(log.events == ["record script:/scripts/github.sh", #"run GitHub Search ["swift testing"]"#])
        #expect(!panel.isVisible)
    }

    @Test("a script that declares arguments but got none enters argument mode; Esc leaves it")
    func argumentMode() async {
        let controller = await makeController()
        panel.type("github")
        #expect(panel.selectedTitle == "GitHub Search")
        controller.panelActivate()
        #expect(panel.argumentTitle == "GitHub Search")
        #expect(panel.placeholder == "Query")
        #expect(panel.text == "")
        #expect(panel.rows.isEmpty)
        #expect(log.events.isEmpty)

        controller.panelActivate()
        #expect(log.events == ["beep"])

        controller.panelCancel()
        #expect(panel.argumentTitle == nil)
        #expect(panel.text == "github")
        #expect(panel.selectedTitle == "GitHub Search")
        #expect(panel.isVisible)

        controller.panelActivate()
        panel.type("swift")
        controller.panelActivate()
        #expect(log.events == ["beep", "record script:/scripts/github.sh", #"run GitHub Search ["swift"]"#])
        #expect(panel.argumentTitle == nil)
        #expect(!panel.isVisible)
    }

    @Test("needsConfirmation takes a second Enter, and typing in between starts over")
    func confirmation() async {
        let controller = await makeController()
        panel.type("reboot")
        controller.panelActivate()
        #expect(log.events.isEmpty)
        #expect(panel.hint?.index == 0)
        #expect(panel.hint?.text == "press ⏎ again to run")

        panel.type("reboo")
        #expect(panel.hint == nil)
        controller.panelActivate()
        #expect(log.events.isEmpty)
        controller.panelActivate()
        #expect(log.events == ["record script:/scripts/reboot.sh", "run Reboot Router []"])
    }

    @Test("argument mode handles a dropdown, an optional password and the confirmation")
    func fullArgumentFlow() async {
        let controller = await makeController()
        panel.type("deploy")
        controller.panelActivate()
        #expect(panel.argumentTitle == "Deploy")
        #expect(panel.placeholder == "Repo")
        panel.type("alauncher")
        controller.panelActivate()

        #expect(panel.placeholder == "Env")
        #expect(panel.titles == ["Staging", "Production"])
        panel.type("prod")
        #expect(panel.titles == ["Production"])
        controller.panelActivate()

        #expect(panel.placeholder == "Token (optional)")
        #expect(panel.secure)
        #expect(panel.rows.isEmpty)
        controller.panelActivate()

        #expect(panel.titles == ["Deploy — alauncher · prod · "])
        #expect(panel.hint?.text == "press ⏎ again to run")
        #expect(log.events.isEmpty)
        controller.panelActivate()
        #expect(log.events == ["record script:/scripts/deploy.sh", #"run Deploy ["alauncher", "prod", ""]"#])
        #expect(!panel.secure)
        #expect(!panel.isVisible)
    }

    @Test("Tab fills in the alias, then enters argument mode; Tab and Shift-Tab move between arguments")
    func tab() async {
        let controller = await makeController()
        panel.type("github")
        controller.panelTab(backward: false)
        #expect(panel.text == "gh ")
        #expect(panel.selectedTitle == "GitHub Search")
        controller.panelTab(backward: false)
        #expect(panel.argumentTitle == "GitHub Search")

        controller.panelCancel()
        panel.type("saf")
        controller.panelTab(backward: false)
        #expect(panel.text == "saf")
        #expect(panel.argumentTitle == nil)

        panel.type("deploy")
        controller.panelTab(backward: false)
        #expect(panel.text == "dep ")
        panel.type("deploy")
        controller.panelActivate()
        panel.type("repo")
        controller.panelTab(backward: false)
        #expect(panel.placeholder == "Env")
        controller.panelTab(backward: true)
        #expect(panel.placeholder == "Repo")
        #expect(panel.text == "repo")
    }

    @Test("⌘Enter reveals apps and scripts in Finder, but not commands")
    func reveal() async {
        let controller = await makeController()
        panel.type("lock")
        controller.panelReveal()
        #expect(log.events.isEmpty)
        #expect(panel.isVisible)

        panel.type("saf")
        controller.panelReveal()
        #expect(log.events == ["reveal /Applications/Safari.app"])
        #expect(!panel.isVisible)
    }

    @Test("a built-in command runs its action and records the launch")
    func builtInCommand() async {
        let log = log
        let reload = BuiltInCommand(title: "Reload config", aliases: ["rc"]) { log.events.append("reloaded") }
        let controller = await makeController(builtIns: [reload])
        panel.type("rc")
        controller.panelActivate()
        #expect(log.events == ["record builtin:Reload config", "reloaded"])
        #expect(!panel.isVisible)
    }

    @Test("a rebuilt index keeps the selected item selected")
    func selectionSurvivesReindex() async {
        let first = CatalogBuilder.build(apps: Fixture.apps, scripts: [], commands: [], builtIns: [], settings: LauncherSettings())
        let calendar = Fixture.app("/System/Applications/Calendar.app", "Calendar", "com.apple.iCal")
        let second = CatalogBuilder.build(apps: [calendar] + Fixture.apps, scripts: [], commands: [], builtIns: [], settings: LauncherSettings())
        let controller = await makeController(calculate: { _ in .notACalculation }, scans: ScanSequence([first, second]))

        panel.type("c")
        for _ in 0..<5 where panel.selectedTitle != "Chess" {
            controller.panelMoveSelection(by: 1)
        }
        #expect(panel.selectedTitle == "Chess")
        #expect(!panel.titles.contains("Calendar"))

        controller.rebuildIndex()
        await controller.indexSettled()
        #expect(panel.titles.contains("Calendar"))
        #expect(panel.selectedTitle == "Chess")
    }

    @Test("losing focus hides; showing again starts from an empty query with the frecent items")
    func hideAndShow() async {
        let controller = await makeController()
        panel.type("saf")
        controller.panelActivate()
        #expect(!panel.isVisible)

        controller.show()
        #expect(panel.isVisible)
        #expect(panel.text == "")
        #expect(panel.titles == ["Safari"])
        #expect(panel.selection == 0)

        controller.panelDidResignKey()
        #expect(!panel.isVisible)
        controller.toggle()
        #expect(panel.isVisible)
        controller.toggle()
        #expect(!panel.isVisible)
        controller.show()
        controller.panelCancel()
        #expect(!panel.isVisible)
    }
}
