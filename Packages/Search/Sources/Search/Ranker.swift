import Foundation

private final class MatcherCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: NormalizedCandidate] = [:]
    private var fastValues: [String: FastNormalizedCandidate] = [:]
    private var matches: [String: FuzzyMatchDetails?] = [:]
    private var queryKey: String?

    func begin(queryKey: String) {
        lock.lock()
        if self.queryKey != queryKey {
            self.queryKey = queryKey
            matches.removeAll(keepingCapacity: true)
        }
        lock.unlock()
    }

    func candidate(for text: String) -> NormalizedCandidate {
        lock.lock()
        if let cached = values[text] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let candidate = FuzzyMatcher.normalizedCandidate(in: text)
        lock.lock()
        values[text] = candidate
        lock.unlock()
        return candidate
    }

    func match(queryCharacters: [Character], queryKey: String, candidate: String) -> FuzzyMatchDetails? {
        begin(queryKey: queryKey)
        lock.lock()
        if let cached = matches[candidate] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result: FuzzyMatchDetails?
        if let queryBytes = FuzzyMatcher.asciiQueryBytes(for: queryKey), FuzzyMatcher.isASCII(candidate) {
            if FuzzyMatcher.asciiMayContain(queryBytes, in: candidate),
               let fastCandidate = fastCandidate(for: candidate)
            {
                result = FuzzyMatcher.fastMatch(query: queryBytes, in: fastCandidate)
            } else {
                result = nil
            }
        } else {
            result = FuzzyMatcher.matchDetails(
                queryCharacters: queryCharacters,
                in: self.candidate(for: candidate)
            )
        }
        lock.lock()
        matches[candidate] = result
        lock.unlock()
        return result
    }

    private func fastCandidate(for text: String) -> FastNormalizedCandidate? {
        guard FuzzyMatcher.isASCII(text) else { return nil }
        lock.lock()
        if let cached = fastValues[text] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let candidate = FuzzyMatcher.asciiCandidate(in: text) else { return nil }
        lock.lock()
        fastValues[text] = candidate
        lock.unlock()
        return candidate
    }
}

/// One launcher row, in final order.
public struct RankedItem: Sendable {
    public var item: SearchItem
    public var score: Double
    /// Matched character offsets in `item.title`; empty when the match came from a keyword or alias.
    public var titlePositions: [Int]
    /// Set when the query was `<alias> <text>` for an item that takes arguments.
    public var arguments: [String]?

    public init(item: SearchItem, score: Double, titlePositions: [Int], arguments: [String]? = nil) {
        self.item = item
        self.score = score
        self.titlePositions = titlePositions
        self.arguments = arguments
    }
}

/// Orders items by fuzzy-match quality blended with frecency.
public struct Ranker: Sendable {
    /// Emoji search blends in the same frecency.
    public let frecency: FrecencyStore
    public let frecencyWeight: Double
    private let matcherCache: MatcherCache

    public init(frecency: FrecencyStore, frecencyWeight: Double = 1) {
        self.frecency = frecency
        self.frecencyWeight = frecencyWeight
        self.matcherCache = MatcherCache()
    }

    /// Empty query: the most frecent items. Otherwise matching items, best first.
    public func rank(_ query: String, in items: [SearchItem], limit: Int, now: Date = Date()) -> [RankedItem] {
        guard limit > 0, !items.isEmpty else { return [] }

        let frecencyScores = frecency.scores(for: items.map(\.id), now: now)
        let effectiveQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryCharacters = FuzzyMatcher.normalizedCharactersForMatching(effectiveQuery)
        let queryKey = String(queryCharacters)
        guard !queryKey.isEmpty else {
            let frecent = items.enumerated().compactMap { index, item -> FrecentItem? in
                let score = frecencyScores[index]
                guard score > 0 else { return nil }
                return FrecentItem(index: index, item: item, score: score, sortTitle: sortTitle(for: item))
            }
            return frecent
                .sorted(by: frecentItemComesFirst)
                .prefix(limit)
                .map { RankedItem(item: $0.item, score: $0.score, titlePositions: []) }
        }
        matcherCache.begin(queryKey: queryKey)

        let inline = inlineInvocation(
            in: effectiveQuery,
            items: items,
            frecencyScores: frecencyScores
        )

        var result: [RankedItem] = []
        var excludedIndex: Int?
        if let inline {
            let frecencyScore = frecencyScores[inline.index]
            result.append(
                RankedItem(
                    item: items[inline.index],
                    score: 500 + frecencyBonus(for: frecencyScore),
                    titlePositions: [],
                    arguments: InlineArguments.split(
                        inline.rest,
                        declaredCount: items[inline.index].argumentCount ?? 0
                    )
                )
            )
            excludedIndex = inline.index
        }

        let ranked = rankedMatches(
            queryCharacters: queryCharacters,
            queryKey: queryKey,
            items: items,
            excludedIndex: excludedIndex,
            frecencyScores: frecencyScores
        )
        result.append(contentsOf: ranked)
        return Array(result.prefix(limit))
    }

    private struct FrecentItem {
        let index: Int
        let item: SearchItem
        let score: Double
        let sortTitle: String
    }

    private struct AliasHit {
        let index: Int
        let item: SearchItem
        let matchScore: Double
        let frecencyScore: Double
        let sortTitle: String
    }

    private struct MatchCandidate {
        let matchScore: Double
        let titlePositions: [Int]
        let exactTitle: Bool
    }

    private struct RankedMatch {
        let index: Int
        let item: SearchItem
        let finalScore: Double
        let titlePositions: [Int]
        let sortTitle: String
    }

    private struct InlineInvocation {
        let index: Int
        let rest: String
    }

    private func inlineInvocation(
        in query: String,
        items: [SearchItem],
        frecencyScores: [Double]
    ) -> InlineInvocation? {
        guard let separator = query.firstIndex(where: { $0.unicodeScalars.allSatisfy { $0.properties.isWhitespace } }) else {
            return nil
        }

        let word = String(query[..<separator])
        let restStart = query.index(after: separator)
        let rest = String(query[restStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !rest.isEmpty else { return nil }

        let wordKey = FuzzyMatcher.normalizedKey(word)
        guard !wordKey.isEmpty else { return nil }

        let candidates = items.enumerated().compactMap { index, item -> FrecentItem? in
            guard item.argumentCount != nil,
                  item.aliases.contains(where: { FuzzyMatcher.normalizedKey($0) == wordKey })
            else { return nil }
            return FrecentItem(
                index: index,
                item: item,
                score: frecencyScores[index],
                sortTitle: sortTitle(for: item)
            )
        }
        guard let selected = candidates.sorted(by: frecentItemComesFirst).first else { return nil }
        return InlineInvocation(index: selected.index, rest: rest)
    }

    private func rankedMatches(
        queryCharacters: [Character],
        queryKey: String,
        items: [SearchItem],
        excludedIndex: Int?,
        frecencyScores: [Double]
    ) -> [RankedItem] {
        var aliasHits: [AliasHit] = []
        var matches: [RankedMatch] = []
        aliasHits.reserveCapacity(items.count)
        matches.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            if index == excludedIndex { continue }
            let frecencyScore = frecencyScores[index]

            if let aliasMatch = exactAliasMatch(queryCharacters: queryCharacters, queryKey: queryKey, item: item) {
                aliasHits.append(
                    AliasHit(
                        index: index,
                        item: item,
                        matchScore: aliasMatch.match.score,
                        frecencyScore: frecencyScore,
                        sortTitle: sortTitle(for: item)
                    )
                )
                continue
            }

            guard let candidate = bestMatch(queryCharacters: queryCharacters, queryKey: queryKey, item: item) else { continue }
            var finalScore = candidate.matchScore + frecencyBonus(for: frecencyScore)
            if candidate.exactTitle { finalScore += 1_000 }
            matches.append(
                RankedMatch(
                    index: index,
                    item: item,
                    finalScore: finalScore,
                    titlePositions: candidate.titlePositions,
                    sortTitle: sortTitle(for: item)
                )
            )
        }

        aliasHits.sort(by: aliasHitComesFirst)
        matches.sort(by: rankedMatchComesFirst)

        var result = aliasHits.map {
            RankedItem(item: $0.item, score: $0.matchScore, titlePositions: [])
        }
        result.append(contentsOf: matches.map {
            RankedItem(item: $0.item, score: $0.finalScore, titlePositions: $0.titlePositions)
        })
        return result
    }

    private func exactAliasMatch(
        queryCharacters: [Character],
        queryKey: String,
        item: SearchItem
    ) -> FuzzyMatchDetails? {
        for alias in item.aliases where FuzzyMatcher.normalizedKey(alias) == queryKey {
            if let match = matcherCache.match(
                queryCharacters: queryCharacters,
                queryKey: queryKey,
                candidate: alias
            ) { return match }
        }
        return nil
    }

    private func bestMatch(queryCharacters: [Character], queryKey: String, item: SearchItem) -> MatchCandidate? {
        var best: MatchCandidate?

        if let title = matcherCache.match(
            queryCharacters: queryCharacters,
            queryKey: queryKey,
            candidate: item.title
        ) {
            best = MatchCandidate(
                matchScore: title.match.score,
                titlePositions: title.match.positions,
                exactTitle: title.tier == 5
            )
        }

        for keyword in item.keywords {
            guard let keywordMatch = matcherCache.match(
                queryCharacters: queryCharacters,
                queryKey: queryKey,
                candidate: keyword
            ) else { continue }
            let candidate = MatchCandidate(
                matchScore: keywordMatch.match.score - 50,
                titlePositions: [],
                exactTitle: false
            )
            if best == nil || candidate.matchScore > best!.matchScore { best = candidate }
        }

        for alias in item.aliases {
            let aliasKey = FuzzyMatcher.normalizedKey(alias)
            guard aliasKey.hasPrefix(queryKey), aliasKey != queryKey,
                  let aliasMatch = matcherCache.match(
                      queryCharacters: queryCharacters,
                      queryKey: queryKey,
                      candidate: alias
                  ), aliasMatch.tier == 4
            else { continue }
            let candidate = MatchCandidate(
                matchScore: aliasMatch.match.score - 50,
                titlePositions: [],
                exactTitle: false
            )
            if best == nil || candidate.matchScore > best!.matchScore { best = candidate }
        }

        return best
    }

    private func frecencyBonus(for score: Double) -> Double {
        guard score > 0 else { return 0 }
        return min(150, frecencyWeight * 40 * log(1 + score))
    }

    private var frecentItemComesFirst: (FrecentItem, FrecentItem) -> Bool {
        { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return sortedByTitleAndID(lhs.item, rhs.item, lhs.sortTitle, rhs.sortTitle, lhs.index, rhs.index)
        }
    }

    private var aliasHitComesFirst: (AliasHit, AliasHit) -> Bool {
        { lhs, rhs in
            if lhs.frecencyScore != rhs.frecencyScore { return lhs.frecencyScore > rhs.frecencyScore }
            return sortedByTitleAndID(lhs.item, rhs.item, lhs.sortTitle, rhs.sortTitle, lhs.index, rhs.index)
        }
    }

    private var rankedMatchComesFirst: (RankedMatch, RankedMatch) -> Bool {
        { lhs, rhs in
            if lhs.finalScore != rhs.finalScore { return lhs.finalScore > rhs.finalScore }
            return sortedByTitleAndID(lhs.item, rhs.item, lhs.sortTitle, rhs.sortTitle, lhs.index, rhs.index)
        }
    }

    private func sortTitle(for item: SearchItem) -> String {
        if FuzzyMatcher.isASCII(item.title) {
            return item.title.lowercased()
        }
        return item.title.folding(options: .caseInsensitive, locale: nil)
    }

    private func sortedByTitleAndID(
        _ lhs: SearchItem,
        _ rhs: SearchItem,
        _ lhsTitle: String,
        _ rhsTitle: String,
        _ lhsIndex: Int,
        _ rhsIndex: Int
    ) -> Bool {
        if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhsIndex < rhsIndex
    }
}
