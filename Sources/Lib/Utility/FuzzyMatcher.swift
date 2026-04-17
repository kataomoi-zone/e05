import Foundation

/// Result of a single fuzzy match: the computed score and the Character indices
/// in the candidate string that were matched.
///
/// `matchedIndices` are offsets into `Array(candidate)` — i.e. `Character`
/// positions — NOT `String.Index` and NOT UTF-16 offsets. This matters when
/// building highlighted `NSAttributedString`s: `NSRange` expects UTF-16
/// offsets, so callers must convert. Example:
///
///     let chars = Array(candidate)
///     for i in match.matchedIndices {
///         let charIndex = candidate.index(candidate.startIndex, offsetBy: i)
///         let utf16Start = charIndex.utf16Offset(in: candidate)
///         let utf16Len = String(chars[i]).utf16.count
///         // build NSRange(location: utf16Start, length: utf16Len)
///     }
///
/// Using indices directly as `NSRange` locations will desynchronize for URLs
/// or titles containing emoji, surrogate pairs, or combining characters.
public struct FuzzyMatch: Equatable {
    public let score: Int
    public let matchedIndices: [Int]

    public init(score: Int, matchedIndices: [Int]) {
        self.score = score
        self.matchedIndices = matchedIndices
    }
}

/// Pure, UI-agnostic fuzzy matching engine inspired by fzf v2.
///
/// Scoring model:
/// - Each matched character: +16
/// - Consecutive match (previous character also matched): +35. Set high enough
///   that a pure contiguous match always beats a scattered match that only
///   accumulates boundary bonuses. Without this, `a_b_c` outranks `abcdef`
///   against the query `abc`.
/// - Boundary match (previous character is `.` `/` `-` `_` ` ` or match is
///   at index 0): +30
/// - CamelCase boundary (previous candidate character is lowercase and the
///   matched character is uppercase, compared on the original — not
///   lowercased — string): +30
/// - Head-of-string bonus (match at index 0): +5
/// - Gap penalty: -2 per character of gap between matches, clamped at -20
///
/// Smart-case: if the query contains no uppercase ASCII, matching is
/// case-insensitive; otherwise the match is case-sensitive.
///
/// Match algorithm: subsequence match — query characters must appear in the
/// candidate in order, not necessarily contiguously. Among multiple valid
/// subsequences, a simple greedy left-to-right scan is used: for each query
/// character pick the earliest remaining match in the candidate. This is not
/// globally optimal (fzf v2 uses full dynamic programming) but is close
/// enough for URL-bar-sized candidates and costs O(|query| * |candidate|)
/// worst case.
public enum FuzzyMatcher {
    // MARK: - Scoring constants

    private static let scoreMatch = 16
    private static let scoreConsecutive = 35
    private static let scoreBoundary = 30
    private static let scoreCamelCase = 30
    private static let scoreHead = 5
    private static let penaltyGap = 2
    private static let penaltyGapMax = 20

    private static let boundaryChars: Set<Character> = [".", "/", "-", "_", " "]

    // MARK: - Public API

    /// Score a query against a single candidate string.
    /// Returns `nil` if the query is not a subsequence of the candidate.
    /// An empty query returns a zero-score match with no highlighted indices
    /// — callers can choose to treat that as "match everything".
    public static func match(query: String, against candidate: String) -> FuzzyMatch? {
        if query.isEmpty {
            return FuzzyMatch(score: 0, matchedIndices: [])
        }

        let queryChars = Array(query)
        let candidateChars = Array(candidate)
        let caseSensitive = queryChars.contains(where: isUppercaseASCII)

        // Greedy subsequence scan: for each query character find the earliest
        // matching candidate character. If any query character fails to
        // match, return nil.
        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(queryChars.count)
        var candidateIndex = 0
        for qChar in queryChars {
            while candidateIndex < candidateChars.count {
                let cChar = candidateChars[candidateIndex]
                if charactersEqual(qChar, cChar, caseSensitive: caseSensitive) {
                    matchedIndices.append(candidateIndex)
                    candidateIndex += 1
                    break
                }
                candidateIndex += 1
            }
        }
        guard matchedIndices.count == queryChars.count else {
            return nil
        }

        let score = computeScore(
            candidateChars: candidateChars,
            matchedIndices: matchedIndices
        )
        return FuzzyMatch(score: score, matchedIndices: matchedIndices)
    }

    /// Rank a list of items by best match across one or more string keys.
    /// - Parameters:
    ///   - query: search query. Empty query returns items unchanged (with
    ///     score 0).
    ///   - items: candidates to rank.
    ///   - keys: extracts one or more searchable strings per item. The best
    ///     (highest) score across keys is used for ranking. Passing multiple
    ///     keys lets callers search title + URL in one pass.
    /// - Returns: items paired with their match, sorted by score descending.
    ///   Sort is stable: items with equal scores preserve their input order.
    public static func rank<T>(
        query: String,
        items: [T],
        keys: (T) -> [String]
    ) -> [(item: T, match: FuzzyMatch)] {
        if query.isEmpty {
            return items.map { ($0, FuzzyMatch(score: 0, matchedIndices: [])) }
        }

        // Pair (originalIndex, item, bestMatch) so we can stable-sort.
        var scored: [(originalIndex: Int, item: T, match: FuzzyMatch)] = []
        scored.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            var best: FuzzyMatch?
            for key in keys(item) {
                guard let candidate = match(query: query, against: key) else { continue }
                if candidate.score > (best?.score ?? Int.min) {
                    best = candidate
                }
            }
            if let best {
                scored.append((index, item, best))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.match.score != rhs.match.score {
                return lhs.match.score > rhs.match.score
            }
            return lhs.originalIndex < rhs.originalIndex
        }

        return scored.map { ($0.item, $0.match) }
    }

    // MARK: - Scoring

    private static func computeScore(
        candidateChars: [Character],
        matchedIndices: [Int]
    ) -> Int {
        var score = 0
        var previousMatchIndex: Int? = nil

        for matchIndex in matchedIndices {
            score += scoreMatch

            if matchIndex == 0 {
                score += scoreHead
                score += scoreBoundary
            } else {
                let prevChar = candidateChars[matchIndex - 1]
                if boundaryChars.contains(prevChar) {
                    score += scoreBoundary
                }
                // CamelCase boundary: lowercase followed by uppercase.
                let curChar = candidateChars[matchIndex]
                if isLowercaseASCII(prevChar), isUppercaseASCII(curChar) {
                    score += scoreCamelCase
                }
            }

            if let previous = previousMatchIndex {
                if matchIndex == previous + 1 {
                    score += scoreConsecutive
                } else {
                    let gap = matchIndex - previous - 1
                    score -= min(gap * penaltyGap, penaltyGapMax)
                }
            }
            previousMatchIndex = matchIndex
        }
        return score
    }

    // MARK: - Character helpers

    private static func charactersEqual(_ a: Character, _ b: Character, caseSensitive: Bool) -> Bool {
        if caseSensitive {
            return a == b
        }
        // Lowercase only when ASCII — avoids expensive locale-aware folding
        // for non-ASCII characters, which we want to compare as-is.
        let aLower = isUppercaseASCII(a) ? Character(a.lowercased()) : a
        let bLower = isUppercaseASCII(b) ? Character(b.lowercased()) : b
        return aLower == bLower
    }

    private static func isUppercaseASCII(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else {
            return false
        }
        return scalar.value >= 0x41 && scalar.value <= 0x5A
    }

    private static func isLowercaseASCII(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else {
            return false
        }
        return scalar.value >= 0x61 && scalar.value <= 0x7A
    }
}
