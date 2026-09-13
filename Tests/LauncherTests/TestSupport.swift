import Foundation
@testable import Launcher

/// A temporary folder, removed when the test that made it finishes.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path }

    /// A fake bundle: a folder holding only `Contents/Info.plist`.
    @discardableResult
    func makeApp(_ relativePath: String, bundleID: String?, name: String? = nil, displayName: String? = nil) throws -> String {
        let contents = url.appendingPathComponent(relativePath, isDirectory: true).appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [:]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        if let name { info["CFBundleName"] = name }
        if let displayName { info["CFBundleDisplayName"] = displayName }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return url.appendingPathComponent(relativePath).path
    }

    @discardableResult
    func write(_ relativePath: String, _ text: String, executable: Bool = false) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
        return file
    }

    func makeFolder(_ relativePath: String) throws -> String {
        let folder = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }

    func link(_ relativePath: String, to destination: String) throws {
        let link = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }
}

/// `realpath(3)`, which keeps `/private` (unlike `resolvingSymlinksInPath`).
func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
