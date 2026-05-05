import Foundation

/// Result of matching a query against a (title, url) candidate. Score
/// drives ranking; ranges drive bold-highlighting in the suggestion
/// list. Ranges are character (not UTF-16) offsets so callers must
/// convert before feeding `NSRange`.
public struct URLMatch: Equatable {
  public let score: Int
  /// Character ranges in the candidate title where query tokens were
  /// matched. Empty when no token landed in the title.
  public let titleRanges: [Range<Int>]
  /// Character ranges in the candidate URL where query tokens were
  /// matched. Empty when no token landed in the URL.
  public let urlRanges: [Range<Int>]

  public init(score: Int, titleRanges: [Range<Int>], urlRanges: [Range<Int>]) {
    self.score = score
    self.titleRanges = titleRanges
    self.urlRanges = urlRanges
  }
}

/// URL-bar suggestion matcher. Tokenizes the query by whitespace and
/// requires each token to appear at the start of a recognisable word
/// in the candidate (host segment, path segment, title token, etc.).
/// Mid-word substring hits — `co` landing inside `attmcojp` — don't
/// count, matching Chrome / Brave / Safari omnibox behaviour where a
/// URL bar match should anchor on a real URL part rather than any
/// coincidental substring.
///
/// Match positions are scored in tiers so a hostname hit always
/// outranks a path hit even when the path candidate has a high
/// frecency bonus. The TLD label of a URL host (`com`, `org`, `jp`,
/// etc. — the last `.label` of the host) is excluded from word-start
/// matching so a query like `co` doesn't latch onto every `.com`
/// page in history.
///
/// Partial credit is granted across multiple tokens: a candidate
/// matching some-but-not-all tokens still ranks (lower) than one
/// matching every token, but a candidate where no token lines up
/// with any word boundary is dropped entirely.
///
/// Smart case: matching is case-insensitive unless the query
/// contains an uppercase character, in which case the user's
/// intent is honoured exactly.
public enum URLMatcher {
  /// Characters that introduce a new "word" inside a URL or title.
  /// A match starting right after one of these is treated as a
  /// boundary hit — almost as strong as the candidate-prefix
  /// position. Includes the URL grammar separators plus dash /
  /// underscore that pages and titles tokenise on visually, and
  /// `|` because page titles often use it as a section delimiter
  /// (e.g. `Title | Site Name`).
  private static let wordSeparators: Set<Character> = [
    ".", "/", "-", "_", " ", "?", "=", "&", "#", ":", ",", "+", "@", "|",
  ]

  /// Score for a match at the absolute start of a non-URL haystack
  /// (a title that begins with the query) or right after `://`. The
  /// host-start tier sits well above any path-level hit so that
  /// frecency cannot flip a domain match below a noisy path match.
  private static let scoreHostStart = 300
  /// Score for a match landing at a host-internal label boundary
  /// — the start of a non-TLD `.label` segment of the host
  /// (`gist` in `gist.github.com`, `github` in `gist.github.com`).
  private static let scoreHostLabelStart = 200
  /// Score for a match at the absolute start of a haystack (title
  /// that begins with the query, or — uncommon — a URL with no
  /// scheme).
  private static let scorePrefix = 150
  /// Score for a match at any other word-start position inside a
  /// title.
  private static let scoreTitleWordStart = 100
  /// Score for a match at a word-start position inside a URL path,
  /// query string, or fragment. Kept well below host-level scoring
  /// because a `con` landing inside a long URL path almost never
  /// represents what the user is navigating toward.
  private static let scorePathWordStart = 50

  /// Match `query` against the (`title`, `url`) candidate. Returns
  /// `nil` when no token matched anywhere — the caller should drop
  /// the candidate from the suggestion list.
  ///
  /// Empty queries return a zero-score match with no ranges so the
  /// caller can pass items through unchanged.
  public static func match(query: String, title: String, url: String) -> URLMatch? {
    let rawTokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !rawTokens.isEmpty else {
      return URLMatch(score: 0, titleRanges: [], urlRanges: [])
    }

    let smartCase = rawTokens.contains { $0.contains(where: { $0.isUppercase }) }
    let titleHaystack = smartCase ? title : title.lowercased()
    let urlHaystack = smartCase ? url : url.lowercased()
    let titleChars = Array(titleHaystack)
    let urlChars = Array(urlHaystack)
    let urlMeta = URLMeta(haystack: urlChars)

    var totalScore = 0
    var titleRanges: [Range<Int>] = []
    var urlRanges: [Range<Int>] = []

    for rawToken in rawTokens {
      let token = smartCase ? rawToken : rawToken.lowercased()
      let titleHit = bestMatch(needle: token, haystack: titleChars, urlMeta: nil)
      let urlHit = bestMatch(needle: token, haystack: urlChars, urlMeta: urlMeta)

      if titleHit == nil && urlHit == nil {
        continue
      }

      // Score by whichever surface gave the better position; record
      // ranges from BOTH so highlighting reflects every substring
      // hit, not just the one that won.
      let best = max(titleHit?.score ?? 0, urlHit?.score ?? 0)
      totalScore += best
      if let h = titleHit { titleRanges.append(h.range) }
      if let h = urlHit { urlRanges.append(h.range) }
    }

    guard totalScore > 0 else { return nil }
    return URLMatch(score: totalScore, titleRanges: titleRanges, urlRanges: urlRanges)
  }

  /// Rank `items` against `query`, dropping non-matches and
  /// returning the survivors paired with their match. Stable on
  /// ties: items with equal scores keep their input order.
  public static func rank<T>(
    query: String,
    items: [T],
    title: (T) -> String,
    url: (T) -> String
  ) -> [(item: T, match: URLMatch)] {
    var scored: [(originalIndex: Int, item: T, match: URLMatch)] = []
    scored.reserveCapacity(items.count)
    for (index, item) in items.enumerated() {
      guard let match = match(query: query, title: title(item), url: url(item)) else {
        continue
      }
      scored.append((index, item, match))
    }
    scored.sort { lhs, rhs in
      if lhs.match.score != rhs.match.score {
        return lhs.match.score > rhs.match.score
      }
      return lhs.originalIndex < rhs.originalIndex
    }
    return scored.map { ($0.item, $0.match) }
  }

  // MARK: - Internals

  private struct Hit {
    let score: Int
    let range: Range<Int>
  }

  /// Cached structural information about a URL haystack so the
  /// matcher can score host vs path positions and skip TLD label
  /// matches without re-scanning the string per token.
  private struct URLMeta {
    /// Index right after `://`, or 0 when the haystack carries no
    /// scheme. The host (or whatever begins the URL) starts here.
    let hostStart: Int
    /// Index of the first character past the host: the `/` `?` `#`
    /// or `:` (port) that ends the host portion, or `chars.count`
    /// when the URL is host-only.
    let hostEnd: Int
    /// Start index of the host's last `.label` — the TLD by simple
    /// heuristic. Word-start matching at this index is suppressed so
    /// short queries (`co`) don't stick to every `.com` page.
    /// `nil` when the host has no `.` or the TLD slot is empty.
    let tldStart: Int?

    init(haystack: [Character]) {
      var schemeEnd = 0
      let count = haystack.count
      // `://` finder. Bounded by count - 2 to avoid overshooting
      // when the haystack is shorter than three characters.
      if count >= 3 {
        for i in 0...(count - 3) {
          if haystack[i] == ":",
            haystack[i + 1] == "/",
            haystack[i + 2] == "/"
          {
            schemeEnd = i + 3
            break
          }
        }
      }
      self.hostStart = schemeEnd

      var hostEnd = count
      for i in schemeEnd..<count {
        let c = haystack[i]
        if c == "/" || c == "?" || c == "#" || c == ":" {
          hostEnd = i
          break
        }
      }
      self.hostEnd = hostEnd

      var lastDot: Int?
      if schemeEnd < hostEnd {
        for i in (schemeEnd..<hostEnd).reversed() {
          if haystack[i] == "." {
            lastDot = i
            break
          }
        }
      }
      if let dot = lastDot, dot + 1 < hostEnd {
        self.tldStart = dot + 1
      } else {
        self.tldStart = nil
      }
    }
  }

  private static func bestMatch(
    needle: String, haystack: [Character], urlMeta: URLMeta?
  ) -> Hit? {
    guard !needle.isEmpty else { return nil }
    let needleChars = Array(needle)
    let needleLen = needleChars.count
    guard haystack.count >= needleLen else { return nil }

    var best: Hit?
    var i = 0
    while i <= haystack.count - needleLen {
      let isWordStart: Bool
      if i == 0 {
        isWordStart = true
      } else if urlMeta != nil, i >= 3,
        haystack[i - 3] == ":",
        haystack[i - 2] == "/",
        haystack[i - 1] == "/"
      {
        isWordStart = true
      } else {
        isWordStart = wordSeparators.contains(haystack[i - 1])
      }

      // TLD positions are word-start by punctuation but excluded
      // from matching so common short suffixes don't dominate the
      // suggestion list.
      let isTLD = (urlMeta?.tldStart == i)

      if isWordStart, !isTLD {
        var matched = true
        for j in 0..<needleLen {
          if haystack[i + j] != needleChars[j] {
            matched = false
            break
          }
        }
        if matched {
          let position = positionScore(
            haystack: haystack, start: i, urlMeta: urlMeta
          )
          let candidate = Hit(
            score: position + needleLen,
            range: i..<(i + needleLen)
          )
          if best == nil || candidate.score > best!.score {
            best = candidate
          }
        }
      }
      i += 1
    }
    return best
  }

  private static func positionScore(
    haystack: [Character], start: Int, urlMeta: URLMeta?
  ) -> Int {
    if let meta = urlMeta {
      if start == meta.hostStart, meta.hostStart > 0 {
        return scoreHostStart
      }
      if start == 0 {
        return scorePrefix
      }
      if start <= meta.hostEnd {
        return scoreHostLabelStart
      }
      return scorePathWordStart
    }
    if start == 0 {
      return scorePrefix
    }
    return scoreTitleWordStart
  }
}
