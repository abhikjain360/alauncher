import Foundation

/// Where alauncher keeps its files.
public enum Paths {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// `$XDG_CONFIG_HOME/alauncher`, or `~/.config/alauncher`.
    public static let configDirectory: URL = {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("alauncher", isDirectory: true)
        }
        return home.appendingPathComponent(".config/alauncher", isDirectory: true)
    }()

    public static let configFile = configDirectory.appendingPathComponent("config.toml")
    public static let secretsFile = configDirectory.appendingPathComponent("secrets.toml")

    public static let supportDirectory = home.appendingPathComponent("Library/Application Support/alauncher", isDirectory: true)
    public static let cacheDirectory = home.appendingPathComponent("Library/Caches/alauncher", isDirectory: true)
    public static let logDirectory = home.appendingPathComponent("Library/Logs/alauncher", isDirectory: true)

    /// Creates the directory if needed and returns it.
    @discardableResult
    public static func ensure(_ directory: URL) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
