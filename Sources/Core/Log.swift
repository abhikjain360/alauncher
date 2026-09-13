import Foundation

/// Appends timestamped lines to `~/Library/Logs/alauncher/<name>.log`.
///
/// Writes happen on a private serial queue, so logging never blocks the caller.
/// The file is rotated to `<name>.log.1` once it passes 2 MB.
public final class Log: @unchecked Sendable {
    public static let main = Log(name: "alauncher")

    private let url: URL
    private let queue: DispatchQueue
    private let maxBytes = 2_000_000
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(name: String) {
        url = Paths.ensure(Paths.logDirectory).appendingPathComponent("\(name).log")
        queue = DispatchQueue(label: "alauncher.log.\(name)")
    }

    public func callAsFunction(_ message: @autoclosure () -> String) {
        let line = "\(formatter.string(from: Date())) \(message())\n"
        queue.async { [url, maxBytes] in
            let data = Data(line.utf8)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int, size > maxBytes {
                let rotated = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: rotated)
                try? FileManager.default.moveItem(at: url, to: rotated)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Blocks until queued lines are written. For CLI runs that exit right after logging.
    public func flush() {
        queue.sync {}
    }
}
