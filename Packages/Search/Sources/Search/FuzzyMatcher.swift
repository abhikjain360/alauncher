import Foundation

internal struct FuzzyMatchDetails: Sendable {
    let match: FuzzyMatch
    let tier: Int
}

internal struct NormalizedUnit: Sendable {
    let value: Character
    let originalOffset: Int
    let isWordStart: Bool
}

internal struct NormalizedCandidate: Sendable {
    let units: [NormalizedUnit]
    let characters: [Character]
    let wordStarts: [Int]
}

internal struct FastNormalizedUnit: Sendable {
    let value: UInt8
    let originalOffset: Int
    let isWordStart: Bool
}

internal struct FastNormalizedCandidate: Sendable {
    let units: [FastNormalizedUnit]
    let values: [UInt8]
    let wordStarts: [Int]
}

extension FuzzyMatcher {
    /// Nil when `query` is not a case- and diacritic-insensitive subsequence of `candidate`.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        matchDetails(query, in: candidate)?.match
    }

    internal static func matchDetails(_ query: String, in candidate: String) -> FuzzyMatchDetails? {
        matchDetails(queryCharacters: normalizedCharacters(in: query), in: candidate)
    }

    internal static func matchDetails(
        queryCharacters: [Character],
        in candidate: String
    ) -> FuzzyMatchDetails? {
        matchDetails(queryCharacters: queryCharacters, in: normalizedCandidate(in: candidate))
    }

    internal static func matchDetails(
        queryCharacters: [Character],
        in candidate: NormalizedCandidate
    ) -> FuzzyMatchDetails? {
        guard !queryCharacters.isEmpty else {
            return FuzzyMatchDetails(match: FuzzyMatch(score: 0, positions: []), tier: 0)
        }

        let candidateUnits = candidate.units
        guard !candidateUnits.isEmpty else { return nil }

        let candidateCharacters = candidate.characters
        guard candidateCharacters.count >= queryCharacters.count else { return nil }
        guard queryCharacters.allSatisfy({ candidateCharacters.contains($0) }) else { return nil }

        let positions: [Int]
        let tier: Int

        if candidateCharacters == queryCharacters {
            positions = Array(candidateUnits.indices)
            tier = 5
        } else if hasPrefix(queryCharacters, candidateCharacters) {
            positions = Array(candidateUnits.indices.prefix(queryCharacters.count))
            tier = 4
        } else if let wordPrefix = wordPrefixPath(
            queryCharacters,
            in: candidateUnits,
            wordStarts: candidate.wordStarts
        ) {
            positions = wordPrefix
            tier = 3
        } else if let acronym = acronymPath(queryCharacters, in: candidateUnits, wordStarts: candidate.wordStarts) {
            positions = acronym
            tier = 3
        } else if let substring = substringPath(queryCharacters, in: candidateCharacters) {
            positions = substring
            tier = 2
        } else if let subsequence = subsequencePath(queryCharacters, in: candidateUnits) {
            positions = subsequence
            tier = 1
        } else {
            return nil
        }

        let fine = fineScore(
            queryLength: queryCharacters.count,
            candidateLength: candidateUnits.count,
            positions: positions,
            units: candidateUnits
        )
        let originalPositions = originalOffsets(for: positions, in: candidateUnits)
        return FuzzyMatchDetails(
            match: FuzzyMatch(score: Double(tier * 100) + fine, positions: originalPositions),
            tier: tier
        )
    }

    /// The same folded key is used for aliases and for the space-insensitive query check.
    public static func normalizedKey(_ text: String) -> String {
        String(normalizedCharacters(in: text))
    }

    internal static func normalizedCharactersForMatching(_ text: String) -> [Character] {
        normalizedCharacters(in: text)
    }

    internal static func normalizedCandidate(in candidate: String) -> NormalizedCandidate {
        let units = normalizedUnits(in: candidate)
        let wordStarts = units.indices.filter { units[$0].isWordStart }
        return NormalizedCandidate(units: units, characters: units.map(\.value), wordStarts: wordStarts)
    }

    internal static func asciiQueryBytes(for normalizedKey: String) -> [UInt8]? {
        guard normalizedKey.unicodeScalars.allSatisfy({ $0.value < 128 }) else { return nil }
        return Array(normalizedKey.utf8)
    }

    internal static func isASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value < 128 }
    }

    internal static func asciiCandidate(in candidate: String) -> FastNormalizedCandidate? {
        guard isASCII(candidate) else { return nil }

        let bytes = Array(candidate.utf8)
        var units: [FastNormalizedUnit] = []
        units.reserveCapacity(bytes.count)
        var values: [UInt8] = []
        values.reserveCapacity(bytes.count)
        var wordStarts: [Int] = []
        wordStarts.reserveCapacity(bytes.count / 2)
        var previous: UInt8?

        for (offset, byte) in bytes.enumerated() {
            let wordStart = offset == 0
                || previous.map(isASCIIWordSeparator) == true
                || isASCIILowercaseToUppercase(previous, byte)
                || isASCIILetterToDigitBoundary(previous, byte)
            if !isASCIIWhitespace(byte) {
                let normalizedIndex = units.count
                units.append(
                    FastNormalizedUnit(
                        value: asciiLowercased(byte),
                        originalOffset: offset,
                        isWordStart: wordStart
                    )
                )
                values.append(asciiLowercased(byte))
                if wordStart { wordStarts.append(normalizedIndex) }
            }
            previous = byte
        }

        return FastNormalizedCandidate(
            units: units,
            values: values,
            wordStarts: wordStarts
        )
    }

    internal static func asciiMayContain(_ query: [UInt8], in candidate: String) -> Bool {
        let bytes = candidate.utf8
        for queryByte in query {
            var found = false
            for byte in bytes where asciiLowercased(byte) == queryByte {
                found = true
                break
            }
            if !found { return false }
        }
        return true
    }

    internal static func fastMatch(
        query: [UInt8],
        in candidate: FastNormalizedCandidate
    ) -> FuzzyMatchDetails? {
        guard !query.isEmpty, candidate.values.count >= query.count,
              query.allSatisfy({ candidate.values.contains($0) })
        else { return nil }

        let positions: [Int]
        let tier: Int
        if candidate.values == query {
            positions = Array(candidate.values.indices)
            tier = 5
        } else if candidate.values.starts(with: query) {
            positions = Array(candidate.values.indices.prefix(query.count))
            tier = 4
        } else if let word = asciiWordPrefixPath(query, candidate: candidate) {
            positions = word
            tier = 3
        } else if let acronym = asciiAcronymPath(query, candidate: candidate) {
            positions = acronym
            tier = 3
        } else if let substring = asciiSubstringPath(query, values: candidate.values) {
            positions = substring
            tier = 2
        } else if let subsequence = asciiSubsequencePath(query, values: candidate.values) {
            positions = subsequence
            tier = 1
        } else {
            return nil
        }

        let fine = asciiFineScore(
            queryLength: query.count,
            candidate: candidate,
            positions: positions
        )
        let originalPositions = positions.map { candidate.units[$0].originalOffset }
        return FuzzyMatchDetails(
            match: FuzzyMatch(score: Double(tier * 100) + fine, positions: originalPositions),
            tier: tier
        )
    }

    private static func normalizedCharacters(in text: String) -> [Character] {
        if text.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            return Array(text.lowercased().filter { !$0.unicodeScalars.allSatisfy { $0.properties.isWhitespace } })
        }

        var result: [Character] = []
        result.reserveCapacity(text.count)

        for character in text {
            let folded = String(character).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            )
            for foldedCharacter in folded where !isWhitespace(foldedCharacter) {
                result.append(foldedCharacter)
            }
        }
        return result
    }

    private static func normalizedUnits(in candidate: String) -> [NormalizedUnit] {
        if candidate.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            let originalCharacters = Array(candidate)
            let foldedCharacters = Array(candidate.lowercased())
            var result: [NormalizedUnit] = []
            result.reserveCapacity(foldedCharacters.count)

            var previous: Character?
            for (offset, character) in foldedCharacters.enumerated() {
                let original = originalCharacters[offset]
                let wordStart = offset == 0
                    || previous.map(isWordSeparator) == true
                    || isLowercaseToUppercase(previous, original)
                    || isLetterToDigitBoundary(previous, original)
                if !isWhitespace(character) {
                    result.append(
                        NormalizedUnit(value: character, originalOffset: offset, isWordStart: wordStart)
                    )
                }
                previous = original
            }
            return result
        }

        var result: [NormalizedUnit] = []
        result.reserveCapacity(candidate.count)

        var previous: Character?
        var originalOffset = 0

        for character in candidate {
            let wordStart = originalOffset == 0
                || previous.map(isWordSeparator) == true
                || isLowercaseToUppercase(previous, character)
                || isLetterToDigitBoundary(previous, character)

            let folded = String(character).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            )
            var firstFoldedCharacter = true
            for foldedCharacter in folded where !isWhitespace(foldedCharacter) {
                result.append(
                    NormalizedUnit(
                        value: foldedCharacter,
                        originalOffset: originalOffset,
                        isWordStart: wordStart && firstFoldedCharacter
                    )
                )
                firstFoldedCharacter = false
            }

            previous = character
            originalOffset += 1
        }

        return result
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 11 || byte == 12 || byte == 13 || byte == 32
    }

    private static func isASCIIWordSeparator(_ byte: UInt8) -> Bool {
        isASCIIWhitespace(byte) || byte == 45 || byte == 95 || byte == 46 || byte == 47 || byte == 40
    }

    private static func isASCIILowercaseToUppercase(_ previous: UInt8?, _ current: UInt8) -> Bool {
        guard let previous else { return false }
        return previous >= 97 && previous <= 122 && current >= 65 && current <= 90
    }

    private static func isASCIILetterToDigitBoundary(_ previous: UInt8?, _ current: UInt8) -> Bool {
        guard let previous else { return false }
        let previousIsLetter = (previous >= 65 && previous <= 90) || (previous >= 97 && previous <= 122)
        let currentIsLetter = (current >= 65 && current <= 90) || (current >= 97 && current <= 122)
        let previousIsDigit = previous >= 48 && previous <= 57
        let currentIsDigit = current >= 48 && current <= 57
        return (previousIsLetter && currentIsDigit) || (previousIsDigit && currentIsLetter)
    }

    private static func isWordSeparator(_ character: Character) -> Bool {
        isWhitespace(character) || character == "-" || character == "_" || character == "."
            || character == "/" || character == "("
    }

    private static func isLowercaseToUppercase(_ previous: Character?, _ current: Character) -> Bool {
        guard let previous else { return false }
        return previous.isLowercase && current.isUppercase
    }

    private static func isLetterToDigitBoundary(_ previous: Character?, _ current: Character) -> Bool {
        guard let previous else { return false }
        return previous.isLetter != current.isLetter && (previous.isLetter || current.isLetter)
            && (previous.isNumber || current.isNumber)
    }

    private static func hasPrefix(_ query: [Character], _ candidate: [Character]) -> Bool {
        guard query.count <= candidate.count else { return false }
        return candidate.starts(with: query)
    }

    private static func asciiWordPrefixPath(
        _ query: [UInt8],
        candidate: FastNormalizedCandidate
    ) -> [Int]? {
        var best: [Int]?
        for start in candidate.wordStarts where start > 0 && candidate.values[start] == query[0] {
            let end = start + query.count
            guard end <= candidate.values.count else { continue }
            var matches = true
            for offset in 0..<query.count where candidate.values[start + offset] != query[offset] {
                matches = false
                break
            }
            guard matches else { continue }

            let path = Array(start..<end)
            if best == nil || asciiPathQuality(path, candidate: candidate, queryLength: query.count)
                > asciiPathQuality(best!, candidate: candidate, queryLength: query.count)
            {
                best = path
            }
        }
        return best
    }

    private static func asciiAcronymPath(
        _ query: [UInt8],
        candidate: FastNormalizedCandidate
    ) -> [Int]? {
        var path: [Int] = []
        path.reserveCapacity(query.count)
        var wordStartIndex = 0

        for queryByte in query {
            var match: Int?
            while wordStartIndex < candidate.wordStarts.count {
                let candidateIndex = candidate.wordStarts[wordStartIndex]
                wordStartIndex += 1
                if candidate.values[candidateIndex] == queryByte {
                    match = candidateIndex
                    break
                }
            }
            guard let match else { return nil }
            path.append(match)
        }
        return path
    }

    private static func asciiSubstringPath(_ query: [UInt8], values: [UInt8]) -> [Int]? {
        guard query.count <= values.count else { return nil }
        for start in 0...(values.count - query.count) {
            var matches = true
            for offset in 0..<query.count where values[start + offset] != query[offset] {
                matches = false
                break
            }
            if matches { return Array(start..<(start + query.count)) }
        }
        return nil
    }

    private static func asciiSubsequencePath(_ query: [UInt8], values: [UInt8]) -> [Int]? {
        var path: [Int] = []
        path.reserveCapacity(query.count)
        var searchStart = 0
        for queryByte in query {
            guard let index = values[searchStart...].firstIndex(of: queryByte) else { return nil }
            path.append(index)
            searchStart = index + 1
        }
        return path
    }

    private static func asciiPathQuality(
        _ path: [Int],
        candidate: FastNormalizedCandidate,
        queryLength: Int
    ) -> Double {
        var pairCount = 0
        if path.count > 1 {
            for index in 1..<path.count where path[index] == path[index - 1] + 1 {
                pairCount += 1
            }
        }
        var wordStartCount = 0
        for index in path where candidate.units[index].isWordStart { wordStartCount += 1 }
        let firstBonus = 1.0 - Double(path[0]) / Double(max(candidate.values.count - 1, 1))
        let consecutiveBonus = Double(pairCount) / Double(max(queryLength - 1, 1))
        let wordStartBonus = Double(wordStartCount) / Double(max(queryLength, 1))
        return firstBonus * 25 + consecutiveBonus * 35 + wordStartBonus * 14
    }

    private static func asciiFineScore(
        queryLength: Int,
        candidate: FastNormalizedCandidate,
        positions: [Int]
    ) -> Double {
        let lengthBonus = 25 * Double(queryLength) / Double(max(candidate.values.count, queryLength))
        let firstBonus = 25 * (1 - Double(positions[0]) / Double(max(candidate.values.count - 1, 1)))
        var pairCount = 0
        if positions.count > 1 {
            for index in 1..<positions.count where positions[index] == positions[index - 1] + 1 {
                pairCount += 1
            }
        }
        let consecutiveBonus = 35 * Double(pairCount) / Double(max(queryLength - 1, 1))
        var wordStartCount = 0
        for index in positions where candidate.units[index].isWordStart { wordStartCount += 1 }
        let wordStartBonus = 14 * Double(wordStartCount) / Double(queryLength)
        return min(99, max(0, lengthBonus + firstBonus + consecutiveBonus + wordStartBonus))
    }

    private static func wordPrefixPath(
        _ query: [Character],
        in candidate: [NormalizedUnit],
        wordStarts: [Int]
    ) -> [Int]? {
        guard let first = query.first else { return nil }
        var best: [Int]?

        for start in wordStarts where start > 0
            && candidate[start].value == first
        {
            let end = start + query.count
            guard end <= candidate.count else { continue }
            var matches = true
            for offset in 0..<query.count where candidate[start + offset].value != query[offset] {
                matches = false
                break
            }
            guard matches else { continue }

            let path = Array(start..<end)
            if best == nil || pathQuality(path, candidate: candidate, queryLength: query.count)
                > pathQuality(best!, candidate: candidate, queryLength: query.count)
            {
                best = path
            }
        }
        return best
    }

    private static func acronymPath(
        _ query: [Character],
        in candidate: [NormalizedUnit],
        wordStarts: [Int]
    ) -> [Int]? {
        guard !query.isEmpty else { return nil }
        var path: [Int] = []
        path.reserveCapacity(query.count)
        var wordStartIndex = 0

        for queryCharacter in query {
            var match: Int?
            while wordStartIndex < wordStarts.count {
                let candidateIndex = wordStarts[wordStartIndex]
                wordStartIndex += 1
                if candidate[candidateIndex].value == queryCharacter {
                    match = candidateIndex
                    break
                }
            }
            guard let index = match else {
                return nil
            }
            path.append(index)
        }
        return path
    }

    private static func substringPath(
        _ query: [Character],
        in candidate: [Character]
    ) -> [Int]? {
        guard query.count <= candidate.count else { return nil }
        var best: [Int]?

        for start in 0...(candidate.count - query.count) {
            guard candidate[start..<(start + query.count)].elementsEqual(query) else { continue }
            let path = Array(start..<(start + query.count))
            if best == nil { best = path }
        }
        return best
    }

    private static func subsequencePath(
        _ query: [Character],
        in candidate: [NormalizedUnit]
    ) -> [Int]? {
        guard !query.isEmpty else { return nil }
        var previous = Array<[Int]?>(repeating: nil, count: candidate.count)

        for (queryIndex, queryCharacter) in query.enumerated() {
            var next = Array<[Int]?>(repeating: nil, count: candidate.count)
            var bestPrevious: [Int]?

            for index in candidate.indices {
                if let path = previous[index], betterPath(path, than: bestPrevious, candidate: candidate, queryLength: query.count) {
                    bestPrevious = path
                }
                guard candidate[index].value == queryCharacter else { continue }

                if queryIndex == 0 {
                    next[index] = [index]
                } else if let bestPrevious {
                    var path = bestPrevious
                    path.append(index)
                    next[index] = path
                }
            }
            previous = next
        }

        return bestPath(in: previous, candidate: candidate, queryLength: query.count)
    }

    private static func bestPath(
        in paths: [[Int]?],
        candidate: [NormalizedUnit],
        queryLength: Int
    ) -> [Int]? {
        var best: [Int]?
        for path in paths.compactMap({ $0 }) {
            if betterPath(path, than: best, candidate: candidate, queryLength: queryLength) {
                best = path
            }
        }
        return best
    }

    private static func betterPath(
        _ lhs: [Int],
        than rhs: [Int]?,
        candidate: [NormalizedUnit],
        queryLength: Int
    ) -> Bool {
        guard let rhs else { return true }
        let lhsQuality = pathQuality(lhs, candidate: candidate, queryLength: queryLength)
        let rhsQuality = pathQuality(rhs, candidate: candidate, queryLength: queryLength)
        if lhsQuality != rhsQuality { return lhsQuality > rhsQuality }
        if lhs.first! != rhs.first! { return lhs.first! < rhs.first! }
        if lhs.last! != rhs.last! { return lhs.last! < rhs.last! }
        return lhs.lexicographicallyPrecedes(rhs)
    }

    private static func pathQuality(
        _ path: [Int],
        candidate: [NormalizedUnit],
        queryLength: Int
    ) -> Double {
        let pairCount = zip(path, path.dropFirst()).reduce(into: 0) { count, pair in
            if pair.1 == pair.0 + 1 { count += 1 }
        }
        let wordStartCount = path.reduce(into: 0) { count, index in
            if candidate[index].isWordStart { count += 1 }
        }
        let first = path.first ?? 0
        let firstBonus = 1.0 - Double(first) / Double(max(candidate.count - 1, 1))
        let consecutiveBonus = Double(pairCount) / Double(max(queryLength - 1, 1))
        let wordStartBonus = Double(wordStartCount) / Double(max(queryLength, 1))
        return firstBonus * 25 + consecutiveBonus * 35 + wordStartBonus * 14
    }

    private static func fineScore(
        queryLength: Int,
        candidateLength: Int,
        positions: [Int],
        units: [NormalizedUnit]
    ) -> Double {
        guard !positions.isEmpty else { return 0 }
        let lengthBonus = 25 * Double(queryLength) / Double(max(candidateLength, queryLength))
        let firstBonus = 25 * (1 - Double(positions[0]) / Double(max(candidateLength - 1, 1)))
        let pairCount = zip(positions, positions.dropFirst()).reduce(into: 0) { count, pair in
            if pair.1 == pair.0 + 1 { count += 1 }
        }
        let consecutiveBonus = 35 * Double(pairCount) / Double(max(queryLength - 1, 1))
        let wordStartCount = positions.reduce(into: 0) { count, index in
            if units[index].isWordStart { count += 1 }
        }
        let wordStartBonus = 14 * Double(wordStartCount) / Double(queryLength)
        return min(99, max(0, lengthBonus + firstBonus + consecutiveBonus + wordStartBonus))
    }

    private static func originalOffsets(for positions: [Int], in units: [NormalizedUnit]) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(positions.count)
        for position in positions {
            let offset = units[position].originalOffset
            if offsets.last != offset { offsets.append(offset) }
        }
        return offsets
    }
}
