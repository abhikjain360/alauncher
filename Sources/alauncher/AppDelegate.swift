import AppKit
import Core
import Dictation
import Launcher
import Overlay
import ServiceManagement
import UniformTypeIdentifiers
import Windows

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Log.main
    private var configStore: ConfigStore!
    private var statusItem: NSStatusItem?
    private var appliedLaunchAtLogin: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("started build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")

        let defaultConfig = Bundle.main.url(forResource: "default-config", withExtension: "toml")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        configStore = ConfigStore(defaultConfigText: defaultConfig)
        configStore.onError = { [log] message in
            log("config error: \(message)")
            OverlayPill.shared.flash("config: \(message)", isError: true, duration: 5)
        }
        // Set before the modules start: they chain onto this handler rather than replace it.
        configStore.onChange = { [weak self] config in self?.apply(config) }
        configStore.start()
        apply(configStore.current)

        Dictation.start(configStore: configStore)
        let store: ConfigStore = configStore
        Launcher.start(configStore: store, commands: builtInCommands()) { text, targetPID, copyIfNoPermission in
            Dictation.insert(text, targetPID: targetPID, settings: store.current.dictation.insert, copyIfNoPermission: copyIfNoPermission)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Launcher.stop()
        Dictation.stop()
        log.flush()
    }

    private func apply(_ config: Config) {
        if appliedLaunchAtLogin != config.app.launchAtLogin {
            appliedLaunchAtLogin = config.app.launchAtLogin
            do {
                if config.app.launchAtLogin {
                    try SMAppService.mainApp.register()
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log("launch at login: \(error.localizedDescription)")
            }
        }
        setMenuBarIcon(visible: config.app.showMenuBarIcon)
    }

    private func builtInCommands() -> [BuiltInCommand] {
        appCommands() + windowCommands()
    }

    /// The commands about alauncher itself. They also make up the menu-bar menu.
    private func appCommands() -> [BuiltInCommand] {
        [
            BuiltInCommand(title: "Reload config", aliases: ["reload"]) { [weak self] in
                self?.configStore.reload()
            },
            BuiltInCommand(title: "Open config", subtitle: Paths.configFile.path) {
                // The real file behind a symlink (Home Manager), so the editor's save doesn't
                // replace the link with a plain file.
                AppDelegate.openInTextEditor(Paths.configFile.resolvingSymlinksInPath())
            },
            BuiltInCommand(title: "Copy last dictation") { Dictation.copyLastDictation() },
            BuiltInCommand(title: "Retry last dictation") { Dictation.retryLastDictation() },
            BuiltInCommand(title: "Dictation history") { AppDelegate.showHistory() },
            BuiltInCommand(title: "Open logs", subtitle: Paths.logDirectory.path) {
                NSWorkspace.shared.open(Paths.logDirectory)
            },
            BuiltInCommand(title: "Quit alauncher") { NSApp.terminate(nil) },
        ]
    }

    /// Raycast's window commands, found by title or by "window …", so they stay out of the
    /// menu-bar menu: there are 29 of them.
    private func windowCommands() -> [BuiltInCommand] {
        WindowCommand.allCases.map { command in
            BuiltInCommand(
                title: command.title,
                subtitle: "Window Management",
                keywords: ["window \(command.title.lowercased())"],
                symbol: command.symbol
            ) {
                Windows.perform(command)
            }
        }
    }

    /// `.toml` often has no registered app, so use the default plain-text editor.
    private static func openInTextEditor(_ file: URL) {
        guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
            NSWorkspace.shared.open(file)
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func showHistory() {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        // Oldest first: the panel copies its last entry, which is then the newest dictation.
        let entries = Dictation.history.suffix(20).map { record in
            TextPanel.Entry(heading: "\(formatter.string(from: record.date)) · \(record.mode)", body: record.bestText)
        }
        guard !entries.isEmpty else {
            OverlayPill.shared.flash("no dictations yet", duration: 1.5)
            return
        }
        TextPanel.shared.onEnter = nil
        TextPanel.shared.show(entries: Array(entries), hint: "⌘C copies the newest (bottom) · esc close", scrollToLatest: true)
    }

    // MARK: - Optional menu-bar icon

    private func setMenuBarIcon(visible: Bool) {
        guard visible != (statusItem != nil) else { return }
        guard visible else {
            statusItem.map(NSStatusBar.system.removeStatusItem)
            statusItem = nil
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "command", accessibilityDescription: "alauncher")
        let menu = NSMenu()
        for command in appCommands() {
            let entry = NSMenuItem(title: command.title, action: #selector(runMenuCommand(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = MenuCommand(action: command.action)
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func runMenuCommand(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuCommand)?.action()
    }
}

private final class MenuCommand: NSObject {
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }
}
