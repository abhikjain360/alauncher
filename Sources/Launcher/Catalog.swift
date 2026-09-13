import Core
import Foundation
import Search

/// What an icon is drawn from. `IconCache` loads it lazily, off the main thread.
enum IconSource: Hashable, Sendable {
    /// The Finder icon of a file or bundle.
    case file(String)
    /// An emoji or short text from a script's `@raycast.icon`, drawn as a glyph.
    case glyph(String)
    /// An image file named by `@raycast.icon`; `fallback`'s file icon if it doesn't load.
    case image(String, fallback: String)
    /// An SF Symbol.
    case symbol(String)
    /// The calculator row's "=".
    case calculator
}

/// What activating an item does.
enum ItemAction: Sendable {
    case app(path: String)
    case script(ScriptCommand)
    case command(CommandSettings)
    case builtIn(BuiltInCommand)
}

/// An item with everything needed to draw and activate it.
struct CatalogEntry: Sendable {
    var item: SearchItem
    var action: ItemAction
    var icon: IconSource

    /// What ⌘Enter reveals in Finder: apps and scripts only.
    var revealPath: String? {
        switch action {
        case .app(let path): return path
        case .script(let script): return script.path.path
        case .command, .builtIn: return nil
        }
    }

    var needsConfirmation: Bool {
        if case .script(let script) = action { return script.needsConfirmation }
        return false
    }
}

/// Everything the launcher can find, keyed by item id.
struct Catalog: Sendable {
    private(set) var items: [SearchItem] = []
    private var entriesByID: [String: CatalogEntry] = [:]

    static let empty = Catalog()

    init() {}

    /// The first entry with a given id wins.
    init(entries: [CatalogEntry]) {
        items.reserveCapacity(entries.count)
        for entry in entries where entriesByID[entry.item.id] == nil {
            entriesByID[entry.item.id] = entry
            items.append(entry.item)
        }
    }

    func entry(for id: String) -> CatalogEntry? {
        entriesByID[id]
    }
}

/// Turns scanned apps and scripts, config commands and built-ins into a catalog,
/// applying `launcher.aliases` and `launcher.exclude`.
enum CatalogBuilder {
    static func build(
        apps: [AppEntry],
        scripts: [ScriptCommand],
        commands: [CommandSettings],
        builtIns: [BuiltInCommand],
        settings: LauncherSettings
    ) -> Catalog {
        let exclude = ExclusionList(settings.exclude)
        let configAliases = aliasTable(settings.aliases)
        func aliases(_ own: [String], title: String) -> [String] {
            unique(own + (configAliases[title.lowercased()] ?? []))
        }

        var entries: [CatalogEntry] = []
        entries.reserveCapacity(apps.count + scripts.count + commands.count + builtIns.count)

        for app in apps where !exclude.excludes(title: app.title, paths: [app.path, app.resolvedPath]) {
            let item = SearchItem(
                id: app.id,
                title: app.title,
                keywords: app.keywords,
                aliases: aliases([], title: app.title),
                kind: .app
            )
            entries.append(CatalogEntry(item: item, action: .app(path: app.path), icon: .file(app.resolvedPath)))
        }

        for script in scripts where !exclude.excludes(title: script.title, paths: [script.path.path]) {
            let item = SearchItem(
                id: "script:\(script.path.path)",
                title: script.title,
                keywords: [script.path.lastPathComponent],
                aliases: aliases(script.aliases, title: script.title),
                subtitle: nonEmpty(script.packageName) ?? nonEmpty(script.description),
                kind: .script,
                argumentCount: script.arguments.count
            )
            entries.append(CatalogEntry(item: item, action: .script(script), icon: icon(for: script)))
        }

        for command in commands where !exclude.excludes(title: command.title) {
            let item = SearchItem(
                id: "command:\(command.title)",
                title: command.title,
                aliases: aliases(command.aliases, title: command.title),
                subtitle: nonEmpty(command.run),
                kind: .command,
                argumentCount: 0
            )
            entries.append(CatalogEntry(item: item, action: .command(command), icon: .symbol("terminal")))
        }

        for builtIn in builtIns where !exclude.excludes(title: builtIn.title) {
            let item = SearchItem(
                id: "builtin:\(builtIn.title)",
                title: builtIn.title,
                aliases: aliases(builtIn.aliases, title: builtIn.title),
                subtitle: nonEmpty(builtIn.subtitle),
                kind: .command
            )
            entries.append(CatalogEntry(item: item, action: .builtIn(builtIn), icon: .symbol("command")))
        }

        return Catalog(entries: entries)
    }

    /// Scans `appDirs` and `scriptDirs`, then builds the catalog. File-system work
    /// only, with no AppKit, so it runs off the main thread.
    static func scan(settings: LauncherSettings, builtIns: [BuiltInCommand]) -> Catalog {
        let apps = AppIndex.scan(directories: settings.appDirs, exclude: ExclusionList(settings.exclude))
        let scripts = ScriptIndex.scan(directories: settings.scriptDirs)
        return build(apps: apps, scripts: scripts, commands: settings.commands, builtIns: builtIns, settings: settings)
    }

    /// `@raycast.icon`: an emoji, or an image path relative to the script's folder.
    /// Remote URLs aren't fetched; those scripts get their file icon.
    static func icon(for script: ScriptCommand) -> IconSource {
        let scriptPath = script.path.path
        guard let icon = nonEmpty(script.icon) else { return .file(scriptPath) }
        let lowercased = icon.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") { return .file(scriptPath) }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "icns", "tif", "tiff", "pdf", "heic", "webp", "bmp"]
        let isPath = icon.contains("/") || imageExtensions.contains((icon as NSString).pathExtension.lowercased())
        guard isPath else { return .glyph(icon) }

        let expanded = PathExpansion.expand(icon)
        let path = expanded.hasPrefix("/")
            ? expanded
            : script.path.deletingLastPathComponent().appendingPathComponent(expanded).path
        return .image(path, fallback: scriptPath)
    }

    private static func aliasTable(_ aliases: [String: [String]]) -> [String: [String]] {
        var table: [String: [String]] = [:]
        for (title, names) in aliases {
            table[title.lowercased(), default: []].append(contentsOf: names)
        }
        return table
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted { result.append(trimmed) }
        }
        return result
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
