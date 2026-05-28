import AppKit
import Foundation

/// A suggestion entry displayed in the URL bar dropdown.
public struct Suggestion: Equatable {
  public let url: String
  public let title: String
  public let isBookmark: Bool
  /// When non-nil, the URL is currently open in this pane somewhere
  /// in the workspace. Selecting the suggestion focuses that pane
  /// (across workspaces if needed) instead of triggering a fresh
  /// navigation in the active pane.
  public let openPaneID: ULID?
  /// True for the synthetic search-engine row. Selection preview keeps
  /// the typed query in the field for this row rather than filling the
  /// engine's query URL.
  public let isSearch: Bool

  public init(
    url: String, title: String, isBookmark: Bool, openPaneID: ULID? = nil,
    isSearch: Bool = false
  ) {
    self.url = url
    self.title = title
    self.isBookmark = isBookmark
    self.openPaneID = openPaneID
    self.isSearch = isSearch
  }

  public var displayTitle: String {
    let prefix = isBookmark ? "\u{2605} " : ""
    return title.isEmpty ? "\(prefix)\(url)" : "\(prefix)\(title)"
  }

  /// Rank a pool of suggestion candidates against an URL-bar query.
  ///
  /// Candidates are filtered through `URLMatcher`: query tokens must
  /// appear as contiguous substrings in title or URL, scored higher
  /// when they land at word boundaries (host start, path segment
  /// start, title word start) and dropped entirely when no token
  /// matches. Bookmark / frecency bonuses are layered on top of the
  /// matcher score so highly-visited and starred sites surface
  /// without burying weak-but-relevant new entries.
  ///
  /// Caller responsibility: build `candidates` with dedup already
  /// applied (e.g. URL appearing in both bookmarks and history
  /// should be present only once, marked `isBookmark: true`). This
  /// keeps the ranker free of dedup policy decisions.
  ///
  /// - Parameters:
  ///   - query: search query. Empty query ranks by bookmark bonus
  ///     and frecency only (recency-decayed visit count).
  ///   - candidates: pre-built suggestion pool.
  ///   - bookmarkBonus: score added to `isBookmark == true` items.
  ///     Default 100 lifts a starred page above similarly-scored
  ///     history without overpowering a strong host match.
  ///   - frecencyByURL: optional per-URL raw frecency
  ///     (`Frecency.score`). Mapped through
  ///     `Frecency.rankingContribution` to a bucketed bonus large
  ///     enough that a frequently-visited page can outrank a
  ///     stronger-matching but rarely-visited one, while the bucket
  ///     ceiling keeps a runaway visit count from burying fresh
  ///     matches.
  ///   - inputBoosts: optional per-URL boost from learned
  ///     input→selection associations (`InputHistoryStore.boosts`),
  ///     added on top so a page the user repeatedly picks for this
  ///     text leads. Only affects candidates that already match the
  ///     query — there's no unmatched-destination injection.
  ///   - maxResults: cap on returned suggestions.
  public static func rank(
    query: String,
    candidates: [Suggestion],
    bookmarkBonus: Int = 100,
    frecencyByURL: [String: Int] = [:],
    inputBoosts: [String: Int] = [:],
    maxResults: Int = 8  // keep in sync with SuggestionListView.maxVisibleRows
  ) -> [Suggestion] {
    if query.isEmpty {
      // No query → no matcher score. Pure ordering by bookmark
      // status and frecency, capped at `maxResults`.
      let scored = candidates.enumerated().map { index, item -> (Suggestion, Int, Int) in
        let total =
          (item.isBookmark ? bookmarkBonus : 0)
          + Frecency.rankingContribution(raw: frecencyByURL[item.url] ?? 0)
          + (inputBoosts[item.url] ?? 0)
        return (item, total, index)
      }
      return
        scored
        .sorted { lhs, rhs in
          lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.2 < rhs.2
        }
        .prefix(maxResults)
        .map { $0.0 }
    }

    let ranked = URLMatcher.rank(
      query: query,
      items: candidates,
      title: { $0.title },
      url: { $0.url }
    )
    struct Scored {
      let item: Suggestion
      let matchScore: Int
      let bookmarkBonus: Int
      let frecency: Int
      let inputBoost: Int
      let order: Int
      var total: Int { matchScore + bookmarkBonus + frecency + inputBoost }
    }
    let scored: [Scored] = ranked.enumerated().map { index, pair in
      Scored(
        item: pair.item,
        matchScore: pair.match.score,
        bookmarkBonus: pair.item.isBookmark ? bookmarkBonus : 0,
        frecency: Frecency.rankingContribution(raw: frecencyByURL[pair.item.url] ?? 0),
        inputBoost: inputBoosts[pair.item.url] ?? 0,
        order: index)
    }
    let ordered = scored.sorted { lhs, rhs in
      lhs.total != rhs.total ? lhs.total > rhs.total : lhs.order < rhs.order
    }
    // Opt-in ranking breakdown for verifying "popularity-led" ordering
    // before browsing history accumulates enough to show in feel.
    // Enable with E05_SUGGEST_DEBUG=1; dev builds pipe stderr straight
    // through (`./scripts/dev.sh`).
    if ProcessInfo.processInfo.environment["E05_SUGGEST_DEBUG"] != nil {
      var report = "[suggest] query=\"\(query)\" matched=\(ordered.count)\n"
      for s in ordered.prefix(maxResults) {
        report +=
          "  total=\(s.total) match=\(s.matchScore) frec=\(s.frecency) "
          + "bm=\(s.bookmarkBonus) learn=\(s.inputBoost)  \(s.item.url)\n"
      }
      FileHandle.standardError.write(Data(report.utf8))
    }
    return ordered.prefix(maxResults).map(\.item)
  }
}

/// Presentation-only model consumed by `SuggestionListView`.
///
/// The list view is deliberately domain-agnostic: it never sees `Suggestion`
/// or `Action` types. Callers convert their own domain values into this
/// model before handing them off, which keeps the list view reusable for
/// future item kinds (action palette, file pickers, etc.) without touching
/// its internals.
///
/// - `primary`: top-line text (e.g. page title, action name).
/// - `secondary`: bottom-line text (e.g. URL). Empty string when absent.
/// - `accessory`: trailing-edge text (e.g. keyboard shortcut "⌥⌃L").
///   `nil` hides the label entirely.
/// - `leadingImage`: 16pt icon rendered before the text stack (favicon
///   for URL rows, SF Symbol for actions). `nil` collapses the icon
///   slot so action rows that opt out don't leave dead whitespace.
/// - `primaryHighlights` / `secondaryHighlights`: NSRange (UTF-16)
///   regions to render in bold. Empty arrays render as plain
///   strings, so non-URL-bar consumers (command palette) don't have
///   to construct ranges.
public struct SuggestionCellModel {
  public let primary: String
  public let secondary: String
  public let accessory: String?
  public let leadingImage: NSImage?
  public let primaryHighlights: [NSRange]
  public let secondaryHighlights: [NSRange]

  public init(
    primary: String,
    secondary: String,
    accessory: String? = nil,
    leadingImage: NSImage? = nil,
    primaryHighlights: [NSRange] = [],
    secondaryHighlights: [NSRange] = []
  ) {
    self.primary = primary
    self.secondary = secondary
    self.accessory = accessory
    self.leadingImage = leadingImage
    self.primaryHighlights = primaryHighlights
    self.secondaryHighlights = secondaryHighlights
  }
}

/// Convert a list of character (Swift `String.Index`-equivalent) ranges
/// into the UTF-16 ranges that `NSAttributedString` operates on. URL bar
/// content commonly contains percent-escaped non-ASCII bytes (Japanese
/// path components, emoji in titles); using character ranges directly
/// as `NSRange.location` desynchronises every highlight beyond a
/// surrogate pair or composing sequence.
///
/// Out-of-range entries are silently dropped — they would crash
/// `addAttribute(_:value:range:)` and the matcher would never produce
/// them in practice anyway, so accepting the input as-is would only
/// risk a crash if a future caller built ranges from a different
/// haystack than the displayed text.
public func nsRanges(from characterRanges: [Range<Int>], in text: String) -> [NSRange] {
  guard !characterRanges.isEmpty else { return [] }
  let chars = Array(text)
  // Prefix sum of UTF-16 lengths so each range converts in O(1). The
  // previous per-range `String(chars[0..<lower]).utf16.count` rebuilt a
  // prefix string every time, making the whole pass O(ranges · length).
  var utf16Offsets = [Int](repeating: 0, count: chars.count + 1)
  for i in chars.indices {
    utf16Offsets[i + 1] = utf16Offsets[i] + chars[i].utf16.count
  }
  var result: [NSRange] = []
  result.reserveCapacity(characterRanges.count)
  for range in characterRanges {
    guard range.lowerBound >= 0,
      range.upperBound <= chars.count,
      range.lowerBound < range.upperBound
    else { continue }
    let location = utf16Offsets[range.lowerBound]
    let length = utf16Offsets[range.upperBound] - location
    result.append(NSRange(location: location, length: length))
  }
  return result
}
