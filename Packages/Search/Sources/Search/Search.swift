import Foundation

// Public API of the launcher search package. See docs/search-spec.md.

/// Something the launcher can find and open.
public struct SearchItem: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case app
        case script
        case command
    }

    /// Stable identity used for frecency, e.g. `app:/Applications/Safari.app`.
    public var id: String
    public var title: String
    /// Secondary match strings: bundle name, file name.
    public var keywords: [String]
    /// Exact shortcuts from config or `@alauncher.alias`. An exact alias match ranks first.
    public var aliases: [String]
    public var subtitle: String?
    public var kind: Kind
    /// nil: takes no arguments. 0: undeclared, inline text becomes `$1`. N: declared count.
    public var argumentCount: Int?

    public init(
        id: String, title: String, keywords: [String] = [], aliases: [String] = [],
        subtitle: String? = nil, kind: Kind, argumentCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.aliases = aliases
        self.subtitle = subtitle
        self.kind = kind
        self.argumentCount = argumentCount
    }
}

/// How well a query matched one string. Higher is better.
public struct FuzzyMatch: Equatable, Sendable {
    public var score: Double
    /// `Character` offsets of the matched characters, for highlighting.
    public var positions: [Int]

    public init(score: Double, positions: [Int]) {
        self.score = score
        self.positions = positions
    }
}

/// The matcher is implemented in `FuzzyMatcher.swift`.
public enum FuzzyMatcher {}
