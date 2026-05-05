import AppKit
import Foundation

/// A suggestion entry displayed in the URL bar dropdown.
public struct Suggestion: Equatable {
  public let url: String
  public let title: String
  public let isBookmark: Bool

  public init(url: String, title: String, isBookmark: Bool) {
    self.url = url
    self.title = title
    self.isBookmark = isBookmark
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
  ///     Default 100 sits between a word-start match (100) and a
  ///     host-start match (200), so a starred page leads similarly-
  ///     scored history without overpowering a strong host match.
  ///   - frecencyByURL: optional per-URL bonus (typically derived
  ///     from history visit count + recency). Capped internally so
  ///     a runaway visit count can't dominate exact-name matches.
  ///   - maxResults: cap on returned suggestions.
  public static func rank(
    query: String,
    candidates: [Suggestion],
    bookmarkBonus: Int = 100,
    frecencyByURL: [String: Int] = [:],
    maxResults: Int = 8  // keep in sync with SuggestionListView.maxVisibleRows
  ) -> [Suggestion] {
    if query.isEmpty {
      // No query → no matcher score. Pure ordering by bookmark
      // status and frecency, capped at `maxResults`.
      let scored = candidates.enumerated().map { index, item -> (Suggestion, Int, Int) in
        let total =
          (item.isBookmark ? bookmarkBonus : 0)
          + min(frecencyByURL[item.url] ?? 0, 200)
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
      let score: Int
      let order: Int
    }
    let scored: [Scored] = ranked.enumerated().map { index, pair in
      var total = pair.match.score
      if pair.item.isBookmark { total += bookmarkBonus }
      total += min(frecencyByURL[pair.item.url] ?? 0, 200)
      return Scored(item: pair.item, score: total, order: index)
    }
    return
      scored
      .sorted { lhs, rhs in
        lhs.score != rhs.score ? lhs.score > rhs.score : lhs.order < rhs.order
      }
      .prefix(maxResults)
      .map(\.item)
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
  var result: [NSRange] = []
  result.reserveCapacity(characterRanges.count)
  for range in characterRanges {
    guard range.lowerBound >= 0,
      range.upperBound <= chars.count,
      range.lowerBound < range.upperBound
    else { continue }
    let prefix = String(chars[0..<range.lowerBound])
    let slice = String(chars[range.lowerBound..<range.upperBound])
    let location = prefix.utf16.count
    let length = slice.utf16.count
    result.append(NSRange(location: location, length: length))
  }
  return result
}
