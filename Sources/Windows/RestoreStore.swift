import ApplicationServices
import Foundation

/// A stable dictionary key for an accessibility element. AX elements are CF objects,
/// so pointer identity is not enough when the same window is wrapped more than once.
final class AXElementBox: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: AXElementBox, rhs: AXElementBox) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// Remembers, for a small number of windows, the frame each had before its run of
/// window commands began, so Restore undoes the whole run rather than its last step.
/// A window the user has moved or resized since starts a new run. Access is
/// main-thread only, because the live window manager is main-actor isolated.
final class RestoreStore {
    static let capacity = 32

    private struct Entry {
        var original: CGRect
        /// The frame the last command asked for, and the one read back afterwards. Either
        /// counts as "still where we left it": some apps apply a frame late.
        var requested: CGRect?
        var applied: CGRect?
        var lastUsed: UInt64

        func left(at current: CGRect) -> Bool {
            [applied, requested].contains { $0.map { Self.close($0, current) } ?? false }
        }

        /// Apps snap frames to their own grids, so a point of drift still counts as unmoved.
        private static func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
                && abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
        }
    }

    private var entries: [AXElementBox: Entry] = [:]
    private var clock: UInt64 = 0

    var count: Int { entries.count }

    /// Called with the window's frame just before a command moves it.
    func willMove(_ element: AXElementBox, from current: CGRect) {
        clock &+= 1
        if var entry = entries[element], entry.left(at: current) {
            entry.lastUsed = clock
            entries[element] = entry
        } else {
            entries[element] = Entry(original: current, lastUsed: clock)
        }
        guard entries.count > Self.capacity,
              let leastRecentlyUsed = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
        else { return }
        entries.removeValue(forKey: leastRecentlyUsed)
    }

    /// Called with the frame the window ended up with and the one that was asked for.
    func didMove(_ element: AXElementBox, to applied: CGRect, requested: CGRect) {
        entries[element]?.applied = applied
        entries[element]?.requested = requested
    }

    /// The frame to restore, if any.
    func original(for element: AXElementBox) -> CGRect? {
        entries[element]?.original
    }

    /// Forgets the window and hands back the frame to restore.
    func take(_ element: AXElementBox) -> CGRect? {
        entries.removeValue(forKey: element)?.original
    }
}
