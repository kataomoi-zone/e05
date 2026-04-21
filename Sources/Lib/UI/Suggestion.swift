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

  /// Rank a pool of suggestion candidates against a fuzzy query.
  ///
  /// Candidates are ranked by `FuzzyMatcher` across their title and URL;
  /// items with no subsequence match are dropped. Bookmarks receive a
  /// constant score bonus so they outrank equal-fuzzy-score history —
  /// matching the previous SQLite-based behavior where bookmarks always
  /// sorted above history in the URL-bar dropdown. The bonus is small
  /// enough that a strong fuzzy match on a history item (e.g. prefix
  /// match on a long URL) still wins over a weaker bookmark match.
  ///
  /// Caller responsibility: build `candidates` with dedup already applied
  /// (e.g. URL appearing in both bookmarks and history should be present
  /// only once, marked `isBookmark: true`). This keeps the ranker free of
  /// dedup policy decisions.
  ///
  /// - Parameters:
  ///   - query: search query. Empty query ranks by bookmark bonus only
  ///     (bookmarks first, then input order within each group), limited
  ///     to `maxResults`.
  ///   - candidates: pre-built suggestion pool.
  ///   - bookmarkBonus: score added to `isBookmark == true` items. Default
  ///     50 ≈ one consecutive-match bonus (`scoreConsecutive = 35`) plus
  ///     a small margin.
  ///   - maxResults: cap on returned suggestions.
  public static func rank(
    query: String,
    candidates: [Suggestion],
    bookmarkBonus: Int = 50,
    maxResults: Int = 8  // keep in sync with SuggestionListView.maxVisibleRows
  ) -> [Suggestion] {
    let ranked = FuzzyMatcher.rank(
      query: query,
      items: candidates,
      keys: { [$0.title, $0.url] }
    )
    // Tag with enumeration index before sorting so that ties are broken
    // by the order produced by FuzzyMatcher.rank (itself stable by input
    // order). Swift's Array.sorted(by:) is documented as unstable, so
    // relying on sorted() alone would leave same-score results in an
    // undefined order across stdlib versions.
    struct Scored {
      let item: Suggestion
      let score: Int
      let order: Int
    }
    let scored: [Scored] = ranked.enumerated().map { index, pair in
      let boosted = pair.match.score + (pair.item.isBookmark ? bookmarkBonus : 0)
      return Scored(item: pair.item, score: boosted, order: index)
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
public struct SuggestionCellModel: Equatable {
  public let primary: String
  public let secondary: String
  public let accessory: String?

  public init(primary: String, secondary: String, accessory: String? = nil) {
    self.primary = primary
    self.secondary = secondary
    self.accessory = accessory
  }
}
