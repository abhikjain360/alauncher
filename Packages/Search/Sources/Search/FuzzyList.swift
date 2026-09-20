import Foundation

/// A fixed list of titles prepared once for fuzzy matching, so filtering it on every keystroke
/// doesn't normalize every title again. Matches score as `FuzzyMatcher.match` does.
public struct FuzzyList: Sendable {
    private enum Candidate: Sendable {
        case ascii(FastNormalizedCandidate)
        case unicode(NormalizedCandidate)
    }

    private let candidates: [Candidate]

    public init(_ titles: [String]) {
        candidates = titles.map { title in
            FuzzyMatcher.asciiCandidate(in: title).map(Candidate.ascii) ?? .unicode(FuzzyMatcher.normalizedCandidate(in: title))
        }
    }

    public var count: Int { candidates.count }

    /// The titles that match `query`, in list order. An empty query matches none.
    public func matches(_ query: String) -> [(index: Int, match: FuzzyMatch)] {
        var result: [(index: Int, match: FuzzyMatch)] = []
        forEachMatch(query) { index, match in result.append((index, match)) }
        return result
    }

    /// Every match, best first; equal scores keep list order.
    public func sortedMatches(_ query: String) -> [(index: Int, match: FuzzyMatch)] {
        var found = matches(query)
        found.sort { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.index < $1.index }
        return found
    }

    private func forEachMatch(_ query: String, _ body: (Int, FuzzyMatch) -> Void) {
        let queryCharacters = FuzzyMatcher.normalizedCharactersForMatching(query)
        guard !queryCharacters.isEmpty else { return }
        let queryBytes = FuzzyMatcher.asciiQueryBytes(for: String(queryCharacters))
        for (index, candidate) in candidates.enumerated() {
            let details: FuzzyMatchDetails?
            switch candidate {
            case .ascii(let fast):
                // A query with a non-ASCII character can't match an ASCII title.
                details = queryBytes.flatMap { FuzzyMatcher.fastMatch(query: $0, in: fast) }
            case .unicode(let normalized):
                details = FuzzyMatcher.matchDetails(queryCharacters: queryCharacters, in: normalized)
            }
            if let details { body(index, details.match) }
        }
    }
}
