import Foundation

private struct PersistedFrecencyEntry: Codable {
    var rank: Double
    var last: Double
}

private struct PersistedFrecencyStore: Codable {
    var version: Int
    var entries: [String: PersistedFrecencyEntry]
}

private final class FrecencyState: @unchecked Sendable {
    let lock = NSLock()
    var entries: [String: PersistedFrecencyEntry]

    init(entries: [String: PersistedFrecencyEntry]) {
        self.entries = entries
    }
}

/// zoxide's frecency algorithm over launcher item ids, persisted as JSON. Thread-safe.
public final class FrecencyStore: Sendable {
    private let fileURL: URL?
    private let maxAge: Double
    private let state: FrecencyState

    /// `fileURL` nil keeps everything in memory (tests).
    public init(fileURL: URL?, maxAge: Double = 10_000) {
        self.fileURL = fileURL
        self.maxAge = maxAge
        self.state = FrecencyState(entries: Self.loadEntries(from: fileURL))
    }

    /// zoxide's score: rank times a multiplier for how recently the item was used.
    public func score(for id: String, now: Date = Date()) -> Double {
        state.lock.lock()
        defer { state.lock.unlock() }

        return score(for: id, nowSeconds: now.timeIntervalSince1970)
    }

    internal func scores(for ids: [String], now: Date) -> [Double] {
        state.lock.lock()
        defer { state.lock.unlock() }

        let nowSeconds = now.timeIntervalSince1970
        return ids.map { score(for: $0, nowSeconds: nowSeconds) }
    }

    private func score(for id: String, nowSeconds: Double) -> Double {
        guard let entry = state.entries[id] else { return 0 }
        let elapsed = max(0, nowSeconds - entry.last)
        if elapsed < 60 * 60 {
            return entry.rank * 4
        } else if elapsed < 24 * 60 * 60 {
            return entry.rank * 2
        } else if elapsed < 7 * 24 * 60 * 60 {
            return entry.rank * 0.5
        } else {
            return entry.rank * 0.25
        }
    }

    /// Adds 1 to the item's rank, stamps it with `now`, ages the store and saves it.
    public func recordLaunch(of id: String, now: Date = Date()) {
        state.lock.lock()
        defer { state.lock.unlock() }

        let timestamp = now.timeIntervalSince1970
        if var entry = state.entries[id] {
            entry.rank += 1
            entry.last = timestamp
            state.entries[id] = entry
        } else {
            state.entries[id] = PersistedFrecencyEntry(rank: 1, last: timestamp)
        }

        ageEntries()
        saveEntries()
    }

    private func ageEntries() {
        let totalRank = state.entries.values.reduce(0) { $0 + $1.rank }
        guard totalRank > maxAge else { return }

        let factor = 0.9 * maxAge / totalRank
        state.entries = state.entries.reduce(into: [:]) { result, pair in
            var entry = pair.value
            entry.rank *= factor
            if entry.rank >= 1 {
                result[pair.key] = entry
            }
        }
    }

    private func saveEntries() {
        guard let fileURL else { return }
        let persisted = PersistedFrecencyStore(version: 1, entries: state.entries)
        guard let data = try? JSONEncoder().encode(persisted) else { return }

        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func loadEntries(from fileURL: URL?) -> [String: PersistedFrecencyEntry] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(PersistedFrecencyStore.self, from: data),
              persisted.version == 1
        else {
            return [:]
        }
        return persisted.entries
    }
}
