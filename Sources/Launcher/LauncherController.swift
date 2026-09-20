import AppKit
import Calc
import Core
import Overlay
import Search

/// What the controller needs from the panel: `LauncherPanel` in the app, a fake in tests.
@MainActor
protocol LauncherPanelHost: AnyObject {
    var launcherDelegate: LauncherPanelDelegate? { get set }
    var isVisible: Bool { get }
    var text: String { get }
    /// Rows that fit on the panel's current screen.
    var rowCapacity: Int { get }
    func setText(_ text: String)
    func setArgumentMode(title: String?, placeholder: String?, secure: Bool)
    func display(_ rows: [LauncherRow], selection: Int?, hint: (index: Int, text: String)?)
    func select(_ index: Int?)
    /// Picks the screen under the mouse for the next `present()`, so `rowCapacity` counts
    /// that screen's rows.
    func prepareToShow()
    /// Shows the panel on that screen, key and focused, without activating the app.
    func present()
    /// Makes the already visible panel key again.
    func focus()
    func dismiss()
}

extension LauncherPanel: LauncherPanelHost {}

/// The controller's side effects. Tests record them instead of performing them.
struct LauncherEffects {
    var openApplication: @MainActor (String) -> Void
    var reveal: @MainActor (String) -> Void
    var copy: @MainActor (String) -> Void
    var flash: @MainActor (String, Bool) -> Void
    var run: @MainActor (ScriptInvocation, [String]) -> Void
    var recordLaunch: @MainActor (FrecencyStore, String) -> Void
    var beep: @MainActor () -> Void
    /// Types text: a picked emoji, into whatever app is frontmost.
    var insert: InsertText
    /// The frontmost app, taken at Enter: where `mode = "type"` output goes.
    var frontmostPID: @MainActor () -> pid_t?
    /// Starts a choices run. `completion` gets all of its output, unless the returned cancel
    /// runs first, which also terminates it.
    var capture: @MainActor (ScriptInvocation, [String], @escaping @MainActor (ScriptRunResult) -> Void) -> @MainActor () -> Void
    /// Shows or types a choices command's final text, per its mode.
    var deliver: @MainActor (ScriptInvocation, String) -> Void

    /// Frecency writes touch the disk, so they run here, in order. A store swap after
    /// a config change is queued here too, behind the writes it must see.
    static let frecencyQueue = DispatchQueue(label: "alauncher.frecency", qos: .utility)

    static func live(runner: ScriptRunner, insert: @escaping InsertText) -> LauncherEffects {
        LauncherEffects(
            openApplication: { path in
                // Activates the app that opens; alauncher itself never activates.
                let name = (path as NSString).lastPathComponent
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    guard let error else { return }
                    let message = "couldn't open \(name): \(error.localizedDescription)"
                    Log.main("launcher: \(message)")
                    Task { @MainActor in OverlayPill.shared.flash(message, isError: true) }
                }
            },
            reveal: { path in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            },
            copy: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            flash: { text, isError in
                OverlayPill.shared.flash(text, isError: isError)
            },
            run: { invocation, arguments in
                Task { await runner.run(invocation, arguments: arguments) }
            },
            recordLaunch: { store, id in
                LauncherEffects.frecencyQueue.async { store.recordLaunch(of: id) }
            },
            beep: {
                NSSound.beep()
            },
            insert: insert,
            frontmostPID: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            },
            capture: { invocation, arguments, completion in
                runner.capture(invocation, arguments: arguments, completion: completion)
            },
            deliver: { invocation, text in
                runner.deliver(text, for: invocation)
            }
        )
    }
}

/// Owns the launcher: index, ranking, calculator, panel, hotkey and script runner.
/// Scanning, icons, scripts, rate refreshes and frecency writes all run off the
/// main thread; a keystroke only ranks and evaluates.
@MainActor
final class LauncherController {
    static let confirmationHint = "press ⏎ again to run"
    /// A choices command's placeholder while a run is in flight.
    static let runningPlaceholder = "Running…"
    /// A choices round's placeholder when the round names none.
    static let choicesPlaceholder = "Search"
    /// The longest list the panel scrolls through. Past it, typing narrows a list faster than
    /// ↓ walks it, so building more rows on every keystroke would be waste.
    nonisolated static let listLimit = 200

    private var config: Config
    private let builtIns: [BuiltInCommand]
    private let effects: LauncherEffects
    private let scan: @Sendable (LauncherSettings, [BuiltInCommand]) -> Catalog
    private let calculateOverride: (@Sendable (String) -> CalcOutcome)?
    private let usesLiveStores: Bool
    private let runner: ScriptRunner?
    private var frecency: FrecencyStore
    private var rates: CurrencyRateStore?
    private var builder: ResultBuilder
    private var catalog = Catalog.empty
    private let icons = IconCache()
    private var panel: LauncherPanelHost?
    private var hotKey: HotKey?
    /// The spec whose registration failure was last reported, so retries stay quiet.
    private var reportedHotKeyFailure: KeySpec?

    private var query = ""
    private var rows: [LauncherRow] = []
    private var selectedIndex: Int?
    /// The first row on screen: the panel shows `rowLimit` rows, and the list scrolls to keep
    /// the selection among them.
    private var scrollOffset = 0
    private var session: ArgumentSession?
    /// A `choices = true` command's rounds, while the panel shows them or its last run finishes.
    private var choices: ChoicesSession?
    /// Stops the choices run in flight.
    private var cancelChoicesRun: (@MainActor () -> Void)?
    private var pendingConfirmationID: String?
    private var isIndexing = false
    private var reindexRequested = false
    private var hasIndexed = false
    private var indexTask: Task<Void, Never>?
    /// Parsed on the first emoji search and dropped on hide, so it isn't kept in memory.
    private var emojiIndex: EmojiIndex?

    /// The app's controller: the real stores, panel and side effects. `insert` types a
    /// picked emoji, or a `mode = "type"` command's output.
    convenience init(config: Config, builtIns: [BuiltInCommand], insert: @escaping InsertText) {
        let runner = ScriptRunner(sink: OverlayOutputSink(insert: insert), extraPath: config.launcher.extraPath)
        self.init(
            config: config,
            builtIns: builtIns,
            frecency: Self.makeFrecency(config.launcher.ranking),
            rates: Self.makeRates(config.calculator),
            runner: runner,
            effects: .live(runner: runner, insert: insert),
            usesLiveStores: true
        )
    }

    /// Everything injectable, so tests touch no files, network, processes or windows.
    init(
        config: Config,
        builtIns: [BuiltInCommand],
        frecency: FrecencyStore,
        rates: CurrencyRateStore?,
        runner: ScriptRunner? = nil,
        effects: LauncherEffects,
        calculate: (@Sendable (String) -> CalcOutcome)? = nil,
        scan: @escaping @Sendable (LauncherSettings, [BuiltInCommand]) -> Catalog = { CatalogBuilder.scan(settings: $0, builtIns: $1) },
        usesLiveStores: Bool = false
    ) {
        self.config = config
        self.builtIns = builtIns
        self.frecency = frecency
        self.rates = rates
        self.runner = runner
        self.effects = effects
        self.calculateOverride = calculate
        self.scan = scan
        self.usesLiveStores = usesLiveStores
        builder = Self.makeBuilder(config: config, frecency: frecency, rates: rates, calculate: calculate)
    }

    nonisolated static func makeFrecency(_ ranking: RankingSettings) -> FrecencyStore {
        FrecencyStore(fileURL: Paths.supportDirectory.appendingPathComponent("frecency.json"), maxAge: ranking.maxAge)
    }

    nonisolated static func makeRates(_ calculator: CalculatorSettings) -> CurrencyRateStore {
        CurrencyRateStore(
            cacheFile: Paths.cacheDirectory.appendingPathComponent("rates.json"),
            maxAge: calculator.ratesMaxAge.timeInterval ?? .greatestFiniteMagnitude
        )
    }

    /// `calculate` replaces the real calculator (tests).
    nonisolated static func makeBuilder(
        config: Config,
        frecency: FrecencyStore,
        rates: CurrencyRateStore?,
        calculate override: (@Sendable (String) -> CalcOutcome)? = nil
    ) -> ResultBuilder {
        var calculate: (@Sendable (String) -> CalcOutcome)?
        if config.calculator.enabled {
            if let override {
                calculate = override
            } else {
                let calculator = Calculator(rates: rates)
                calculate = { calculator.evaluate($0) }
            }
        }
        return ResultBuilder(
            ranker: Ranker(frecency: frecency, frecencyWeight: config.launcher.ranking.frecencyWeight),
            calculate: calculate,
            maxResults: listLimit
        )
    }

    // MARK: Lifecycle

    /// Creates the panel (hidden) so the first show costs a single frame, registers
    /// the hotkey and builds the index in the background.
    func start() {
        attach(LauncherPanel(icons: icons))
        hotKey = HotKey { [weak self] in self?.toggle() }
        registerHotKey()
        rebuildIndex()
    }

    /// Uses `host` as the panel: the real one from `start()`, or a fake in tests.
    func attach(_ host: LauncherPanelHost) {
        host.launcherDelegate = self
        panel = host
    }

    func stop() {
        hide()
        hotKey?.invalidate()
        hotKey = nil
    }

    func apply(_ newConfig: Config) {
        let old = config
        config = newConfig
        // Also retried while it's failing (say Raycast was quit, then the config saved).
        if hotKey != nil, hotKey?.registeredSpec != newConfig.launcher.hotkey {
            registerHotKey()
        }
        if usesLiveStores, old.launcher.ranking.maxAge != newConfig.launcher.ranking.maxAge {
            let ranking = newConfig.launcher.ranking
            LauncherEffects.frecencyQueue.async { [weak self] in
                let store = Self.makeFrecency(ranking)
                Task { @MainActor in self?.useFrecency(store) }
            }
        }
        if usesLiveStores, old.calculator.ratesMaxAge != newConfig.calculator.ratesMaxAge {
            rates = Self.makeRates(newConfig.calculator)
        }
        builder = Self.makeBuilder(config: newConfig, frecency: frecency, rates: rates, calculate: calculateOverride)
        runner?.extraPath = newConfig.launcher.extraPath
        if old.calculator != newConfig.calculator, panel?.isVisible == true {
            refreshRatesIfStale()
        }

        let before = old.launcher
        let after = newConfig.launcher
        let indexChanged = before.appDirs != after.appDirs || before.scriptDirs != after.scriptDirs
            || before.exclude != after.exclude || before.aliases != after.aliases || before.commands != after.commands
        if indexChanged {
            rebuildIndex()
        } else if panel?.isVisible == true, !showsOwnRows {
            updateRows(keepSelection: true)
        } else if before.maxResults != after.maxResults, panel?.isVisible == true {
            // A taller or shorter window over the rows it already holds.
            display()
        }
    }

    private func useFrecency(_ store: FrecencyStore) {
        frecency = store
        builder = Self.makeBuilder(config: config, frecency: store, rates: rates, calculate: calculateOverride)
    }

    /// Reports a failure once per spec; `apply` retries quietly after that.
    private func registerHotKey() {
        guard let hotKey else { return }
        let spec = config.launcher.hotkey
        guard let message = hotKey.register(spec) else {
            reportedHotKeyFailure = nil
            return
        }
        guard reportedHotKeyFailure != spec else { return }
        reportedHotKeyFailure = spec
        Log.main("launcher: \(message)")
        OverlayPill.shared.flash(message, isError: true, duration: 4)
    }

    // MARK: Showing

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    /// Clears the query, shows the most frecent items with the first selected, and
    /// focuses the field. Then refreshes the index and exchange rates in the background.
    func show() {
        guard let panel else { return }
        if panel.isVisible {
            panel.focus()
            refreshRatesIfStale()
            return
        }
        panel.prepareToShow()
        endArgumentMode(restoreQuery: false)
        // A run left going when the panel closed is abandoned now.
        endChoices(restoreQuery: false)
        pendingConfirmationID = nil
        query = ""
        panel.setText("")
        updateRows(keepSelection: false)
        panel.present()
        rebuildIndex()
        refreshRatesIfStale()
    }

    func hide() {
        endArgumentMode(restoreQuery: false)
        endChoices(restoreQuery: false)
        pendingConfirmationID = nil
        emojiIndex = nil
        guard let panel, panel.isVisible else { return }
        panel.dismiss()
    }

    /// Rows on screen at once: `launcher.max_results`, or fewer on a short screen. The list
    /// itself holds up to `listLimit` of them and scrolls.
    private var rowLimit: Int {
        min(config.launcher.maxResults, panel?.rowCapacity ?? config.launcher.maxResults)
    }

    /// In argument mode or a choices session the rows aren't search results, so index, rate and
    /// config updates leave them alone.
    private var showsOwnRows: Bool {
        session != nil || choices != nil
    }

    // MARK: Index and rates

    /// Scans in the background; a scan already running is followed by one more.
    func rebuildIndex() {
        guard !isIndexing else {
            reindexRequested = true
            return
        }
        isIndexing = true
        let settings = config.launcher
        let builtIns = builtIns
        let scan = scan
        let started = Date()
        indexTask = Task.detached(priority: .userInitiated) { [weak self] in
            let catalog = scan(settings, builtIns)
            await self?.install(catalog, started: started)
        }
    }

    /// Waits until no index build is running (tests).
    func indexSettled() async {
        while isIndexing, let task = indexTask {
            await task.value
        }
    }

    /// Swaps in a new catalog, keeping the selected item selected.
    private func install(_ newCatalog: Catalog, started: Date) {
        isIndexing = false
        catalog = newCatalog
        if !hasIndexed {
            hasIndexed = true
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            if usesLiveStores {
                Log.main("launcher: indexed \(newCatalog.items.count) items in \(milliseconds) ms")
                icons.prefetch(builder.rows(for: "", in: newCatalog).prefix(rowLimit).compactMap(\.icon))
            }
        }
        if panel?.isVisible == true, !showsOwnRows {
            updateRows(keepSelection: true)
        }
        if reindexRequested {
            reindexRequested = false
            rebuildIndex()
        }
    }

    private func refreshRatesIfStale() {
        guard let rates, config.calculator.enabled, config.calculator.ratesMaxAge != .never else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard await rates.refreshIfStale() else { return }
            await self?.ratesDidChange(rates)
        }
    }

    private func ratesDidChange(_ store: CurrencyRateStore) {
        guard store === rates, panel?.isVisible == true, !showsOwnRows else { return }
        updateRows(keepSelection: true)
    }

    // MARK: Rows

    private var selectedRow: LauncherRow? {
        guard let selectedIndex, rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex]
    }

    private func updateRows(keepSelection: Bool) {
        let previousID = keepSelection ? selectedRow?.id : nil
        if let choices {
            // No rows while a run is in flight; what's typed meanwhile filters the next round.
            if !choices.isRunning, let round = choices.rounds.last {
                rows = ResultBuilder.pickRows(round, query: query, limit: builder.maxResults)
            } else {
                rows = []
            }
        } else if let session {
            if session.awaitingConfirmation, let entry = catalog.entry(for: session.entryID) {
                let ranked = RankedItem(item: entry.item, score: 0, titlePositions: [], arguments: session.values)
                rows = [ResultBuilder.itemRow(ranked, icon: entry.icon)]
            } else if session.current.type == "dropdown" {
                rows = ResultBuilder.choiceRows(session.current.choices, query: query, limit: builder.maxResults)
            } else {
                rows = []
            }
        } else {
            rows = builder.rows(for: query, in: catalog, emojiIndex: { self.loadedEmojiIndex() })
        }

        if let previousID, let index = rows.firstIndex(where: { $0.id == previousID && $0.isEnabled }) {
            selectedIndex = index
        } else {
            selectedIndex = rows.firstIndex(where: \.isEnabled)
            scrollOffset = 0
        }
        display()
    }

    /// Shows the rows that fit on screen, scrolled far enough down to hold the selection.
    private func display() {
        let limit = rowLimit
        scrollOffset = Self.offset(showing: selectedIndex, from: scrollOffset, of: rows.count, visible: limit)
        let onScreen = Array(rows[scrollOffset..<min(rows.count, scrollOffset + limit)])
        let hint = pendingConfirmationID
            .flatMap { id in rows.firstIndex { $0.id == id } }
            .map { (index: $0 - scrollOffset, text: Self.confirmationHint) }
        panel?.display(onScreen, selection: selectedIndex.map { $0 - scrollOffset }, hint: hint)
    }

    /// Scrolls the window of `visible` rows by as little as it takes to hold `selection`.
    static func offset(showing selection: Int?, from offset: Int, of count: Int, visible: Int) -> Int {
        guard visible > 0 else { return 0 }
        var offset = min(offset, count - visible)
        if let selection {
            offset = min(offset, selection)
            offset = max(offset, selection - visible + 1)
        }
        return max(0, offset)
    }

    private func loadedEmojiIndex() -> EmojiIndex {
        if let emojiIndex { return emojiIndex }
        let index = EmojiIndex.load()
        emojiIndex = index
        return index
    }

    // MARK: Activation

    private func activate(_ row: LauncherRow) {
        guard row.isEnabled else { return }
        switch row.content {
        case .calculation(let result):
            effects.copy(result.copyText)
            hide()
            effects.flash("copied", false)
        case .item(let ranked):
            guard let entry = catalog.entry(for: ranked.item.id) else { return }
            activate(entry, arguments: ranked.arguments)
        case .emoji(let match):
            let emoji = match.entry.emoji
            effects.recordLaunch(frecency, EmojiIndex.frecencyID(for: emoji))
            hide()
            effects.insert(emoji, nil, true)
        case .calculationError, .choice, .pick:
            return
        }
    }

    private func activate(_ entry: CatalogEntry, arguments: [String]?) {
        switch entry.action {
        case .app(let path):
            effects.recordLaunch(frecency, entry.item.id)
            hide()
            effects.openApplication(path)
        case .builtIn(let command):
            effects.recordLaunch(frecency, entry.item.id)
            hide()
            command.action()
        case .emojiSearch:
            effects.recordLaunch(frecency, entry.item.id)
            startEmojiSearch(entry)
        case .command(let command) where command.choices:
            // Text typed inline after the alias filters the first round.
            beginChoices(for: entry, command: command, filter: arguments?.joined(separator: " ") ?? "")
        case .script, .command:
            let declared = entry.item.argumentCount ?? 0
            if declared > 0, (arguments?.count ?? 0) < declared {
                beginArgumentMode(for: entry, prefilled: arguments ?? [])
            } else if entry.needsConfirmation, pendingConfirmationID != entry.item.id {
                pendingConfirmationID = entry.item.id
                display()
            } else {
                run(entry, arguments: arguments ?? [])
            }
        }
    }

    private func run(_ entry: CatalogEntry, arguments: [String]) {
        var invocation: ScriptInvocation
        switch entry.action {
        case .script(let script): invocation = ScriptInvocation(script: script)
        case .command(let command): invocation = ScriptInvocation(command: command)
        case .app, .builtIn, .emojiSearch: return
        }
        invocation.targetPID = effects.frontmostPID()
        effects.recordLaunch(frecency, entry.item.id)
        hide()
        effects.run(invocation, arguments)
    }

    /// Search emoji: fills in `<alias> `, which lists emoji.
    private func startEmojiSearch(_ entry: CatalogEntry) {
        pendingConfirmationID = nil
        query = (entry.item.aliases.first ?? EmojiSearchItem.alias) + " "
        panel?.setText(query)
        updateRows(keepSelection: false)
    }

    // MARK: Argument mode

    private func beginArgumentMode(for entry: CatalogEntry, prefilled: [String]) {
        guard let specs = ArgumentSession.specs(for: entry.action) else { return }
        pendingConfirmationID = nil
        session = ArgumentSession(entryID: entry.item.id, title: entry.item.title, specs: specs, prefilled: prefilled, previousQuery: query)
        showCurrentArgument()
    }

    private func showCurrentArgument() {
        guard let session else { return }
        let argument = session.current
        panel?.setArgumentMode(title: session.title, placeholder: session.placeholder, secure: argument.type == "password")
        query = argument.type == "dropdown" ? "" : session.currentValue
        panel?.setText(query)
        updateRows(keepSelection: false)
    }

    private func submitArgument() {
        guard var session else { return }
        guard let entry = catalog.entry(for: session.entryID) else {
            // The script went away in a rebuild.
            endArgumentMode(restoreQuery: true)
            return
        }
        if session.awaitingConfirmation {
            endArgumentMode(restoreQuery: false)
            run(entry, arguments: session.values)
            return
        }

        var text = panel?.text ?? query
        if session.current.type == "dropdown" {
            if case .choice(let choice)? = selectedRow?.content {
                text = choice.value
            } else if session.current.optional {
                text = ""
            } else {
                effects.beep()
                return
            }
        }

        switch session.submit(text) {
        case .rejected:
            effects.beep()
        case .next:
            self.session = session
            showCurrentArgument()
        case .run(let values):
            if entry.needsConfirmation {
                session.awaitingConfirmation = true
                self.session = session
                pendingConfirmationID = entry.item.id
                updateRows(keepSelection: false)
            } else {
                endArgumentMode(restoreQuery: false)
                run(entry, arguments: values)
            }
        }
    }

    private func endArgumentMode(restoreQuery: Bool) {
        guard let session else { return }
        self.session = nil
        pendingConfirmationID = nil
        panel?.setArgumentMode(title: nil, placeholder: nil, secure: false)
        guard restoreQuery else { return }
        query = session.previousQuery
        panel?.setText(query)
        updateRows(keepSelection: false)
    }

    // MARK: Choices

    /// Enter or Tab on a `choices = true` command: its first run, with no arguments.
    private func beginChoices(for entry: CatalogEntry, command: CommandSettings, filter: String) {
        effects.recordLaunch(frecency, entry.item.id)
        pendingConfirmationID = nil
        var invocation = ScriptInvocation(command: command)
        invocation.targetPID = effects.frontmostPID()
        choices = ChoicesSession(title: entry.item.title, invocation: invocation, previousQuery: query)
        startChoicesRun(arguments: [], filter: filter)
    }

    /// Runs the command. Until it answers there are no rows, and the field starts from `filter`.
    private func startChoicesRun(arguments: [String], filter: String) {
        guard var session = choices else { return }
        session.generation += 1
        session.isRunning = true
        let generation = session.generation
        choices = session
        panel?.setArgumentMode(title: session.title, placeholder: Self.runningPlaceholder, secure: false)
        query = filter
        panel?.setText(filter)
        updateRows(keepSelection: false)
        let cancel = effects.capture(session.invocation, arguments) { [weak self] result in
            self?.choicesRunFinished(result, generation: generation)
        }
        if choices?.isRunning == true, choices?.generation == generation {
            cancelChoicesRun = cancel
        }
    }

    private func choicesRunFinished(_ result: ScriptRunResult, generation: Int) {
        guard var session = choices, session.isRunning, session.generation == generation else { return }
        session.isRunning = false
        choices = session
        cancelChoicesRun = nil

        guard result.exitCode == 0 else {
            return choicesFailed(ScriptRunner.pillText(ScriptRunner.failureText(result, title: session.title, showsStdout: false)))
        }
        guard !result.stdoutTruncated else {
            return choicesFailed("\(session.title): output too large")
        }
        let output: ChoicesOutput
        do {
            output = try ChoicesOutput.parse(result.stdout)
        } catch {
            return choicesFailed("\(session.title): \(error)")
        }

        switch output {
        case .done:
            endChoices(restoreQuery: false)
            hide()
        case .final(let text):
            endChoices(restoreQuery: false)
            hide()
            effects.deliver(session.invocation, text)
        case .round(var round):
            guard !session.isClosed else {
                endChoices(restoreQuery: false)
                effects.flash("\(session.title) closed", false)
                return
            }
            // What was typed while it ran is this round's filter.
            round.filter = query
            session.rounds.append(round)
            choices = session
            showChoicesRound()
        }
    }

    /// Flashes why a run failed, types nothing, and goes back to the round it came from; after
    /// the first run, back to search.
    private func choicesFailed(_ message: String) {
        effects.flash(message, true)
        guard choices?.isClosed == false else {
            endChoices(restoreQuery: false)
            return
        }
        returnToLastRound()
    }

    /// Shows the last round again with the filter it had; with none left, leaves the session.
    private func returnToLastRound() {
        guard let round = choices?.rounds.last else {
            endChoices(restoreQuery: true)
            return
        }
        query = round.filter
        panel?.setText(query)
        showChoicesRound()
    }

    private func showChoicesRound() {
        guard let session = choices, let round = session.rounds.last else { return }
        let placeholder = round.placeholder.flatMap { $0.isEmpty ? nil : $0 } ?? Self.choicesPlaceholder
        panel?.setArgumentMode(title: session.title, placeholder: placeholder, secure: false)
        updateRows(keepSelection: false)
    }

    /// Enter on an item: the next run, with the round's id and the item's value.
    private func pickChoice() {
        guard var session = choices, !session.isRunning, let round = session.rounds.last,
              case .pick(let index)? = selectedRow?.content, round.items.indices.contains(index) else {
            effects.beep()
            return
        }
        session.rounds[session.rounds.count - 1].filter = query
        session.invocation.targetPID = effects.frontmostPID()
        choices = session
        startChoicesRun(arguments: [round.id, round.items[index].value], filter: "")
    }

    /// Esc: abandons the run in flight, or leaves the round on screen, for the round before it.
    /// From the first, back to search.
    private func choicesBack() {
        guard var session = choices else { return }
        if session.isRunning {
            cancelChoicesRun?()
            cancelChoicesRun = nil
            session.isRunning = false
        } else if !session.rounds.isEmpty {
            session.rounds.removeLast()
        }
        choices = session
        returnToLastRound()
    }

    /// Ends the session, abandoning a run in flight.
    private func endChoices(restoreQuery: Bool) {
        guard let session = choices else { return }
        cancelChoicesRun?()
        cancelChoicesRun = nil
        choices = nil
        panel?.setArgumentMode(title: nil, placeholder: nil, secure: false)
        guard restoreQuery else { return }
        query = session.previousQuery
        panel?.setText(query)
        updateRows(keepSelection: false)
    }
}

extension LauncherController: LauncherPanelDelegate {
    func panelQueryChanged(_ text: String) {
        query = text
        pendingConfirmationID = nil
        session?.awaitingConfirmation = false
        updateRows(keepSelection: false)
    }

    func panelMoveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        var index = selectedIndex ?? (delta > 0 ? -1 : rows.count)
        repeat {
            index += delta
        } while rows.indices.contains(index) && !rows[index].isEnabled
        guard rows.indices.contains(index) else { return }
        selectedIndex = index
        let scrolls = Self.offset(showing: index, from: scrollOffset, of: rows.count, visible: rowLimit) != scrollOffset
        if pendingConfirmationID != nil, session == nil {
            pendingConfirmationID = nil
            display()
        } else if scrolls {
            display()
        } else {
            panel?.select(index - scrollOffset)
        }
    }

    func panelActivate() {
        if choices != nil {
            pickChoice()
        } else if session != nil {
            submitArgument()
        } else if let row = selectedRow {
            activate(row)
        }
    }

    /// ⌘Enter: reveal an app or script in Finder.
    func panelReveal() {
        guard !showsOwnRows, let ranked = selectedRow?.rankedItem,
              let path = catalog.entry(for: ranked.item.id)?.revealPath else { return }
        hide()
        effects.reveal(path)
    }

    /// On a script that takes arguments: fills in `<alias> ` for inline arguments, or
    /// enters argument mode. On Search emoji: fills in `emoji `. On a choices command: its
    /// first run, like Enter. In argument mode: the next or previous argument.
    func panelTab(backward: Bool) {
        guard choices == nil else { return }
        if var session {
            guard !session.awaitingConfirmation else { return }
            var text = panel?.text ?? query
            if session.current.type == "dropdown" {
                if case .choice(let choice)? = selectedRow?.content {
                    text = choice.value
                } else {
                    text = session.currentValue
                }
            }
            let moved = backward ? session.moveBack(keeping: text) : session.moveForward(keeping: text)
            self.session = session
            if moved { showCurrentArgument() }
            return
        }
        guard !backward, let ranked = selectedRow?.rankedItem, ranked.item.argumentCount != nil,
              let entry = catalog.entry(for: ranked.item.id) else { return }
        if case .emojiSearch = entry.action {
            // Even with the alias typed exactly: the text after it is the search.
            activate(entry, arguments: nil)
            return
        }
        if case .command(let command) = entry.action, command.choices {
            activate(entry, arguments: ranked.arguments)
            return
        }
        let typed = query.trimmingCharacters(in: .whitespaces)
        if ranked.arguments == nil, let alias = ranked.item.aliases.first, typed.caseInsensitiveCompare(alias) != .orderedSame {
            query = alias + " "
            panel?.setText(query)
            pendingConfirmationID = nil
            updateRows(keepSelection: false)
        } else {
            beginArgumentMode(for: entry, prefilled: ranked.arguments ?? [])
        }
    }

    func panelCancel() {
        if choices != nil {
            choicesBack()
        } else if session != nil {
            endArgumentMode(restoreQuery: true)
        } else {
            hide()
        }
    }

    func panelDidResignKey() {
        // A choices run in flight keeps going when the panel closes, since a gpg prompt may be
        // what took the keyboard: its final text is still delivered, to the same target app.
        if var choices, choices.isRunning {
            choices.isClosed = true
            self.choices = choices
            panel?.dismiss()
            return
        }
        hide()
    }

    /// `index` counts the rows on screen, so the rows scrolled past come before it.
    func panelClickedRow(at index: Int) {
        let index = scrollOffset + index
        guard rows.indices.contains(index), rows[index].isEnabled else { return }
        selectedIndex = index
        panelActivate()
    }

    /// ⌘C on an emoji row copies the emoji and closes the panel.
    func panelCopySelection() -> Bool {
        guard !showsOwnRows, case .emoji(let match)? = selectedRow?.content else { return false }
        let emoji = match.entry.emoji
        effects.copy(emoji)
        effects.recordLaunch(frecency, EmojiIndex.frecencyID(for: emoji))
        hide()
        effects.flash("copied \(emoji)", false)
        return true
    }
}
