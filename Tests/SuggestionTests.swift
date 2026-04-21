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

  @Test("drops candidates with no fuzzy match")
  func dropsNonMatches() {
    let candidates = [
      history("https://apple.com"),
      history("https://banana.com"),
      history("https://grape.com"),
    ]
    let result = Suggestion.rank(query: "an", candidates: candidates)
    let urls = result.map(\.url)
    // "apple" and "grape" have no "an" subsequence; "banana" does.
    #expect(!urls.contains("https://apple.com"))
    #expect(!urls.contains("https://grape.com"))
    #expect(urls.contains("https://banana.com"))
  }

  @Test("motivating example: gite05 finds github.com/kawarimidoll/e05")
  func motivatingExample() {
    let candidates = [
      history("https://google.com"),
      history("https://gist.github.com/example"),
      history("https://github.com/kawarimidoll/e05"),
      history("https://example.com"),
      history("https://github.com/someone-else/other-repo"),
    ]
    let result = Suggestion.rank(query: "gite05", candidates: candidates)
    #expect(result.first?.url == "https://github.com/kawarimidoll/e05")
  }

  @Test("ranks by fuzzy score across title and url")
  func rankAcrossTitleAndUrl() {
    // Title contains the query, URL does not — should still match.
    let candidates = [
      Suggestion(url: "https://a.com", title: "apple fruit", isBookmark: false),
      Suggestion(url: "https://b.com", title: "banana", isBookmark: false),
    ]
    let result = Suggestion.rank(query: "apple", candidates: candidates)
    #expect(result.first?.url == "https://a.com")
  }

  // MARK: - Bookmark bonus

  @Test("bookmark outranks history at equal fuzzy score")
  func bookmarkBeatsHistoryAtTie() {
    let candidates = [
      history("https://example.com/a", "Example A"),
      bookmark("https://example.com/a-book", "Example A"),
    ]
    // Both match "Example A" equivalently on title; bookmark bonus tips it.
    let result = Suggestion.rank(query: "Example", candidates: candidates)
    #expect(result.first?.isBookmark == true)
  }

  @Test("strong history fuzzy match beats weak bookmark")
  func strongHistoryBeatsWeakBookmark() {
    // Bookmark: query letters separated by non-boundary filler (x's).
    // Large gaps hit the -20 penalty cap on each step — no boundary
    // bonuses either — so even with the +50 bonus the bookmark scores
    // well below a clean prefix match.
    // (An underscore-separated URL like g_i_t_h_u_b would NOT work here:
    // '_' is a boundary char, giving +30 per step, which easily tops
    // the history score even across long gaps.)
    let candidates = [
      bookmark("https://gxxxxxxxxxxixxxxxxxxxxt.com", "weak"),
      history("https://git.example.com", "git"),
    ]
    let result = Suggestion.rank(query: "git", candidates: candidates)
    #expect(result.first?.url == "https://git.example.com")
  }

  @Test("bookmarkBonus=0 disables priority — pure fuzzy order")
  func bookmarkBonusZero() {
    // With bonus=0, identical-fuzzy-score bookmark and history are
    // ordered only by FuzzyMatcher's stable tiebreaker (input order).
    let candidates = [
      history("https://a.com", "same"),
      bookmark("https://b.com", "same"),
    ]
    let result = Suggestion.rank(query: "same", candidates: candidates, bookmarkBonus: 0)
    // History came first in input, so it stays first.
    #expect(result.first?.url == "https://a.com")
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
      history("https://a.com", "apple"),
      history("https://b.com", "banana"),
    ]
    let result = Suggestion.rank(query: "a", candidates: candidates, maxResults: 15)
    #expect(result.count == 2)
  }

  // MARK: - Edge cases

  @Test("empty query returns candidates in input order up to maxResults")
  func emptyQueryPassthrough() {
    let candidates = [
      history("https://a.com"),
      bookmark("https://b.com"),
      history("https://c.com"),
    ]
    let result = Suggestion.rank(query: "", candidates: candidates, maxResults: 10)
    // Bookmark bonus (default 50) pushes b.com to top even with empty
    // query (all candidates get score 0 from FuzzyMatcher before bonus).
    #expect(result.first?.url == "https://b.com")
    #expect(result.count == 3)
  }

  @Test("empty candidates returns empty result")
  func emptyCandidates() {
    let result = Suggestion.rank(query: "anything", candidates: [])
    #expect(result.isEmpty)
  }
}
