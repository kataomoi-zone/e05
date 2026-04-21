import Foundation
import Testing

@testable import E05Lib

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
  // MARK: - Basic matching

  @Test("empty query returns zero-score match")
  func emptyQuery() {
    let result = FuzzyMatcher.match(query: "", against: "anything")
    #expect(result?.score == 0)
    #expect(result?.matchedIndices == [])
  }

  @Test("non-subsequence returns nil")
  func noMatch() {
    #expect(FuzzyMatcher.match(query: "xyz", against: "hello world") == nil)
  }

  @Test("exact prefix matches")
  func prefixMatch() {
    let result = FuzzyMatcher.match(query: "hel", against: "hello")
    #expect(result != nil)
    #expect(result?.matchedIndices == [0, 1, 2])
  }

  @Test("non-contiguous subsequence matches")
  func subsequenceMatch() {
    let result = FuzzyMatcher.match(query: "abc", against: "a_b_c")
    #expect(result != nil)
    #expect(result?.matchedIndices == [0, 2, 4])
  }

  @Test("empty candidate fails for non-empty query")
  func emptyCandidate() {
    #expect(FuzzyMatcher.match(query: "a", against: "") == nil)
  }

  // MARK: - Smart case

  @Test("all-lowercase query matches case-insensitively")
  func smartCaseLowercase() {
    #expect(FuzzyMatcher.match(query: "hel", against: "HELLO") != nil)
  }

  @Test("uppercase in query switches to case-sensitive")
  func smartCaseUppercase() {
    #expect(FuzzyMatcher.match(query: "Hel", against: "hello") == nil)
    #expect(FuzzyMatcher.match(query: "Hel", against: "Hello") != nil)
  }

  // MARK: - Scoring ordering

  @Test("consecutive match scores higher than scattered")
  func consecutiveBeatsScattered() {
    let consecutive = FuzzyMatcher.match(query: "abc", against: "abcdef")!
    let scattered = FuzzyMatcher.match(query: "abc", against: "a_b_c")!
    #expect(consecutive.score > scattered.score)
  }

  @Test("boundary match scores higher than middle match")
  func boundaryBeatsMiddle() {
    // 'c' appears after '/' in first (boundary), in middle of word in second.
    let boundary = FuzzyMatcher.match(query: "c", against: "ab/cd")!
    let middle = FuzzyMatcher.match(query: "c", against: "abccd")!
    #expect(boundary.score > middle.score)
  }

  @Test("head-of-string match scores higher than internal match")
  func headBeatsInternal() {
    let head = FuzzyMatcher.match(query: "a", against: "abc")!
    let internalMatch = FuzzyMatcher.match(query: "a", against: "bac")!
    #expect(head.score > internalMatch.score)
  }

  @Test("CamelCase boundary boosts score")
  func camelCaseBoundary() {
    // Both candidates contain an uppercase R the query can match.
    // In `paneResize` the R sits at a lowercase->uppercase transition
    // (CamelCase boundary). In `PANERESIZE` the R is surrounded by
    // uppercase letters — no transition, no bonus.
    let camel = FuzzyMatcher.match(query: "R", against: "paneResize")!
    let plain = FuzzyMatcher.match(query: "R", against: "PANERESIZE")!
    #expect(camel.score > plain.score)
  }

  @Test("gap penalty lowers far-scattered match below near-scattered")
  func gapPenalty() {
    let near = FuzzyMatcher.match(query: "ab", against: "a_b_______")!
    let far = FuzzyMatcher.match(query: "ab", against: "a_________b")!
    #expect(near.score > far.score)
  }

  // MARK: - The motivating example from the plan

  @Test("gite05 ranks github.com/kawarimidoll/e05 above unrelated candidates")
  func motivatingExample() {
    let candidates = [
      "https://google.com",
      "https://gist.github.com/example",
      "https://github.com/kawarimidoll/e05",
      "https://example.com",
      "https://github.com/someone-else/other-repo",
    ]
    let ranked = FuzzyMatcher.rank(query: "gite05", items: candidates, keys: { [$0] })
    #expect(ranked.first?.item == "https://github.com/kawarimidoll/e05")
  }

  // MARK: - rank

  @Test("rank drops non-matching items")
  func rankFilters() {
    let items = ["apple", "banana", "grape", "orange"]
    let ranked = FuzzyMatcher.rank(query: "an", items: items, keys: { [$0] })
    let urls = ranked.map(\.item)
    // "apple" has no 'an' subsequence, "grape" has no 'an' subsequence.
    #expect(!urls.contains("apple"))
    #expect(!urls.contains("grape"))
    #expect(urls.contains("banana"))
    #expect(urls.contains("orange"))
  }

  @Test("rank sorts by descending score")
  func rankSortsByScore() {
    let items = ["a_b_c_d", "abcd", "a_bcd"]
    let ranked = FuzzyMatcher.rank(query: "abcd", items: items, keys: { [$0] })
    // Fully contiguous "abcd" must be highest.
    #expect(ranked.first?.item == "abcd")
  }

  @Test("rank is stable for equal scores")
  func rankStable() {
    let items = ["abc", "abc"]
    let ranked = FuzzyMatcher.rank(query: "ab", items: items, keys: { [$0] })
    #expect(ranked.count == 2)
    #expect(ranked[0].match.score == ranked[1].match.score)
  }

  @Test("rank uses best score across multiple keys")
  func rankMultipleKeys() {
    // Each item has a title and a url. Query matches url but not title.
    let items: [(title: String, url: String)] = [
      (title: "Some Page", url: "github.com/kawarimidoll/e05"),
      (title: "Another Page", url: "example.com/other"),
    ]
    let ranked = FuzzyMatcher.rank(
      query: "github",
      items: items,
      keys: { [$0.title, $0.url] }
    )
    #expect(ranked.first?.item.url == "github.com/kawarimidoll/e05")
  }

  @Test("empty query in rank returns items unchanged")
  func rankEmptyQuery() {
    let items = ["c", "a", "b"]
    let ranked = FuzzyMatcher.rank(query: "", items: items, keys: { [$0] })
    #expect(ranked.map(\.item) == items)
    #expect(ranked.allSatisfy { $0.match.score == 0 })
  }

  // MARK: - Unicode handling

  @Test("handles Japanese characters")
  func japaneseCharacters() {
    let result = FuzzyMatcher.match(query: "日本", against: "私は日本語を勉強しています")
    #expect(result != nil)
  }

  @Test("Japanese matchedIndices point to the correct Character positions")
  func japaneseMatchedIndices() {
    // The candidate is pre-composed (NFC) — each Japanese character is a
    // single Character. matchedIndices are indices into Array(candidate),
    // so "日" at Character offset 2 and "本" at Character offset 3.
    let result = FuzzyMatcher.match(query: "日本", against: "私は日本語を")
    #expect(result?.matchedIndices == [2, 3])
  }
}
