import Foundation
import Testing

@testable import E05Lib

@Suite("Suggestion.rank")
struct SuggestionTests {
  // MARK: - Fixtures

  private func history(_ url: String, _ title: String = "") -> Suggestion {
    Suggestion(url: url, title: title, isBookmark: false)
  }

  private func bookmark(_ url: String, _ title: String = "") -> Suggestion {
    Suggestion(url: url, title: title, isBookmark: true)
  }

  // MARK: - Basic matching

  @Test("drops candidates whose title and URL contain none of the query tokens")
  func dropsNonMatches() {
    let candidates = [
      history("https://apple.com"),
      history("https://banana.com"),
      history("https://grape.com"),
    ]
    let result = Suggestion.rank(query: "ban", candidates: candidates)
    let urls = result.map(\.url)
    #expect(!urls.contains("https://apple.com"))
    #expect(!urls.contains("https://grape.com"))
    #expect(urls.contains("https://banana.com"))
  }

  @Test("multi-token query: tokens may match different fields with partial credit")
  func multiTokenPartial() {
    // Query "git e05" → tokens ["git", "e05"]. Both must contribute
    // somewhere; a candidate matching both ranks above one matching
    // only one.
    let candidates = [
      history("https://google.com", "Google"),
      history("https://gist.github.com/example", "Gist · example"),
      history("https://github.com/kawarimidoll/e05", "kawarimidoll/e05"),
      history("https://example.com"),
      history("https://github.com/someone-else/other-repo", "someone-else/other-repo"),
    ]
    let result = Suggestion.rank(query: "git e05", candidates: candidates)
    #expect(result.first?.url == "https://github.com/kawarimidoll/e05")
  }

  @Test("ranks across title and url")
  func rankAcrossTitleAndUrl() {
    // Title contains the query, URL does not — should still match.
    let candidates = [
      Suggestion(url: "https://a.com", title: "apple fruit", isBookmark: false),
      Suggestion(url: "https://b.com", title: "banana", isBookmark: false),
    ]
    let result = Suggestion.rank(query: "apple", candidates: candidates)
    #expect(result.first?.url == "https://a.com")
  }

  @Test("host-start match outranks mid-path match")
  func hostStartBeatsMidPath() {
    let candidates = [
      history("https://example.com/notes/connpass", "Notes"),
      history("https://connpass.com", "connpass"),
    ]
    let result = Suggestion.rank(query: "connpass", candidates: candidates)
    #expect(result.first?.url == "https://connpass.com")
  }

  // MARK: - Bookmark bonus

  @Test("bookmark outranks history at equal match score")
  func bookmarkBeatsHistoryAtTie() {
    let candidates = [
      history("https://example.com/a", "Example A"),
      bookmark("https://example.com/a-book", "Example A"),
    ]
    let result = Suggestion.rank(query: "Example", candidates: candidates)
    #expect(result.first?.isBookmark == true)
  }

  @Test("strong host match beats weak bookmark mid-word match")
  func strongHistoryBeatsWeakBookmark() {
    let candidates = [
      // Bookmark, but the query "git" only appears mid-word inside
      // a long random hostname.
      bookmark("https://digitalstuff.example.com", "weak"),
      // History entry with the query at host start.
      history("https://git.example.com", "git"),
    ]
    let result = Suggestion.rank(query: "git", candidates: candidates)
    #expect(result.first?.url == "https://git.example.com")
  }

  @Test("bookmarkBonus=0 disables priority — pure match-score order")
  func bookmarkBonusZero() {
    let candidates = [
      history("https://a.com", "same"),
      bookmark("https://b.com", "same"),
    ]
    let result = Suggestion.rank(query: "same", candidates: candidates, bookmarkBonus: 0)
    // Both score identically; ranker stable-sorts by input order.
    #expect(result.first?.url == "https://a.com")
  }

  // MARK: - Frecency

  @Test("frecency bonus surfaces frequently-visited matches")
  func frecencyTipsTie() {
    let candidates = [
      history("https://a.example.com", "alpha example"),
      history("https://b.example.com", "alpha example"),
    ]
    // Both candidates score equally on the matcher. The frecency
    // bonus on `b` (visited more recently) tips the ordering.
    let result = Suggestion.rank(
      query: "alpha example",
      candidates: candidates,
      frecencyByURL: ["https://b.example.com": 150]
    )
    #expect(result.first?.url == "https://b.example.com")
  }

  @Test("a popular page outranks a stronger-matching rarely-visited one")
  func frecencyLeadsOverMatchTier() {
    // `example.com` matches the query at host start (strong); the
    // other matches only mid-path (weak). With enough frecency the
    // weak-but-popular page should still win — ranking is led by how
    // often the user goes there, not match position alone.
    let strongFreshMatch = history("https://example.com", "Example")
    let weakPopularMatch = history("https://other.com/example-page", "Other")
    let result = Suggestion.rank(
      query: "example",
      candidates: [strongFreshMatch, weakPopularMatch],
      frecencyByURL: ["https://other.com/example-page": 200]
    )
    #expect(result.first?.url == "https://other.com/example-page")
  }

  // MARK: - Result cap

  @Test("respects maxResults cap")
  func maxResultsCap() {
    let candidates = (0..<30).map { i in
      history("https://example.com/\(i)", "item \(i)")
    }
    let result = Suggestion.rank(query: "item", candidates: candidates, maxResults: 5)
    #expect(result.count == 5)
  }

  @Test("returns all matches when fewer than maxResults")
  func maxResultsNotExceeded() {
    let candidates = [
      history("https://apple.com", "apple"),
      history("https://avocado.com", "avocado"),
    ]
    let result = Suggestion.rank(query: "a", candidates: candidates, maxResults: 15)
    #expect(result.count == 2)
  }

  // MARK: - Edge cases

  @Test("empty query orders bookmarks above history, then by frecency")
  func emptyQueryPassthrough() {
    let candidates = [
      history("https://a.com"),
      bookmark("https://b.com"),
      history("https://c.com"),
    ]
    let result = Suggestion.rank(query: "", candidates: candidates, maxResults: 10)
    // Bookmark bonus (default 100) wins under an empty query.
    #expect(result.first?.url == "https://b.com")
    #expect(result.count == 3)
  }

  @Test("empty candidates returns empty result")
  func emptyCandidates() {
    let result = Suggestion.rank(query: "anything", candidates: [])
    #expect(result.isEmpty)
  }
}
