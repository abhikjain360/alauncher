import Foundation
import Search

/// Finds Raycast-format script commands in `launcher.scriptDirs`.
enum ScriptIndex {
    /// Parses the regular files (after following symlinks) directly inside each
    /// folder, in folder order then by name. Files without an `@raycast.title`
    /// header are skipped. Only headers are read; nothing is run.
    static func scan(
        directories: [String],
        expand: (String) -> String = { PathExpansion.expand($0) }
    ) -> [ScriptCommand] {
        var scripts: [ScriptCommand] = []
        var seen = Set<String>()
        for directory in directories {
            let root = expand(directory)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = root + "/" + name
                guard isRegularFile(path), seen.insert(path).inserted,
                      let script = ScriptCommandParser.parse(contentsOf: URL(fileURLWithPath: path))
                else { continue }
                scripts.append(script)
            }
        }
        return scripts
    }

    /// `stat` follows symlinks, so a link to a script counts and a link to a folder doesn't.
    private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }
}
