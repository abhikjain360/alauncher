import Foundation

/// An application bundle found by `AppIndex`.
struct AppEntry: Equatable, Sendable {
    /// The path as found in the scanned folder. Launching and the frecency id use
    /// it, so a symlinked app keeps its id when its target moves (Nix store updates).
    var path: String
    /// `path` with symlinks resolved; Info.plist and the icon are read from here.
    var resolvedPath: String
    var title: String
    /// `CFBundleName`, `CFBundleDisplayName` and the file name, minus repeats of the title.
    var keywords: [String]
    var bundleID: String?

    var id: String { "app:\(path)" }
}

/// Finds `.app` bundles in `launcher.appDirs`. Pure file-system work with no
/// AppKit, so it runs off the main thread.
enum AppIndex {
    static let finderPath = "/System/Library/CoreServices/Finder.app"

    /// Scans each folder for bundles at depth 1, then at depth 2 inside its non-app
    /// folders, following symlinks. The first bundle with a given bundle id wins,
    /// in folder order; excluded bundles don't claim their bundle id.
    static func scan(
        directories: [String],
        exclude: ExclusionList,
        alwaysInclude: [String] = [finderPath],
        expand: (String) -> String = { PathExpansion.expand($0) }
    ) -> [AppEntry] {
        var scanner = Scanner(exclude: exclude)
        for directory in directories {
            let root = expand(directory)
            var folders: [String] = []
            for name in children(of: root) {
                let path = root + "/" + name
                if isAppName(name) {
                    scanner.consider(path)
                } else if isDirectory(path) {
                    folders.append(path)
                }
            }
            for folder in folders {
                for name in children(of: folder) where isAppName(name) {
                    scanner.consider(folder + "/" + name)
                }
            }
        }
        for path in alwaysInclude {
            scanner.consider(path)
        }
        return scanner.entries
    }

    private struct Scanner {
        let exclude: ExclusionList
        var entries: [AppEntry] = []
        var seenPaths = Set<String>()
        var seenBundleIDs = Set<String>()

        mutating func consider(_ path: String) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard !seenPaths.contains(resolved), AppIndex.isDirectory(resolved) else { return }
            seenPaths.insert(resolved)

            let entry = AppIndex.entry(path: path, resolvedPath: resolved)
            guard !exclude.excludes(title: entry.title, paths: [path, resolved]) else { return }
            if let bundleID = entry.bundleID {
                guard seenBundleIDs.insert(bundleID.lowercased()).inserted else { return }
            }
            entries.append(entry)
        }
    }

    static func entry(path: String, resolvedPath: String) -> AppEntry {
        let fileName = stripAppExtension((path as NSString).lastPathComponent)
        var title = stripAppExtension(FileManager.default.displayName(atPath: path))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = fileName }

        let info = infoDictionary(bundlePath: resolvedPath)
        var keywords: [String] = []
        var seen: Set<String> = [title.lowercased()]
        for candidate in [info?["CFBundleName"] as? String, info?["CFBundleDisplayName"] as? String, fileName] {
            guard let keyword = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !keyword.isEmpty, seen.insert(keyword.lowercased()).inserted else { continue }
            keywords.append(keyword)
        }

        let bundleID = (info?["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppEntry(
            path: path,
            resolvedPath: resolvedPath,
            title: title,
            keywords: keywords,
            bundleID: bundleID?.isEmpty == false ? bundleID : nil
        )
    }

    /// Reads Info.plist directly: `Bundle(url:)` would cache every bundle for the
    /// life of the process. iOS apps on Apple silicon keep theirs in `WrappedBundle`.
    private static func infoDictionary(bundlePath: String) -> [String: Any]? {
        let bundle = URL(fileURLWithPath: bundlePath, isDirectory: true)
        for relativePath in ["Contents/Info.plist", "WrappedBundle/Info.plist", "Info.plist"] {
            guard let data = try? Data(contentsOf: bundle.appendingPathComponent(relativePath)) else { continue }
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return plist
            }
        }
        return nil
    }

    private static func children(of directory: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    private static func isAppName(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".app")
    }

    /// Follows symlinks.
    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func stripAppExtension(_ name: String) -> String {
        name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
