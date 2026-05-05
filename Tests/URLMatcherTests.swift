import Foundation
import Testing

@testable import E05Lib

@Suite("URLMatcher")
struct URLMatcherTests {
  @Test("rejects candidate when no token appears anywhere")
  func rejectsNonMatch() {
    #expect(URLMatcher.match(query: "xyz", title: "Apple", url: "https://apple.com") == nil)
  }

  @Test("mid-word substrings do not count as a match")
  func midWordDoesNotMatch() {
    // `co` appears as a substring of `attmcojp` but not at any word
    // start, so the candidate must not be ranked.
    #expect(
      URLMatcher.match(
        query: "co",
        title: "Slite",
        url: "https://attmcojp.slite.app"
      ) == nil
    )
    // And the query matches the host start when the host begins with it.
    #expect(
      URLMatcher.match(
        query: "co",
        title: "x",
        url: "https://connpass.com"
      ) != nil
    )
  }

  @Test("TLD label is excluded from word-start matching")
  func tldExcluded() {
    // `co` would score against the `.com` segment without the TLD
    // exclusion, polluting the suggestion list with every `.com`
    // page in history. The only word starts left for "co" against
    // `https://example.com` are the TLD itself, so the candidate
    // drops.
    #expect(
      URLMatcher.match(query: "co", title: "x", url: "https://example.com") == nil
    )
    // A non-TLD host label sharing the same prefix still matches —
    // here `co` lines up with the leftmost host label.
    #expect(
      URLMatcher.match(query: "co", title: "x", url: "https://co.example.com") != nil
    )
  }

  @Test("host-start outranks host-internal label, which outranks path")
  func hostScoringTiers() {
    let hostStart =
      URLMatcher.match(query: "git", title: "x", url: "https://github.com")?.score ?? 0
    let hostInternal =
      URLMatcher.match(query: "git", title: "x", url: "https://gist.github.com")?.score ?? 0
    let pathOnly =
      URLMatcher.match(query: "git", title: "x", url: "https://example.com/git")?.score ?? 0
    #expect(hostStart > hostInternal)
    #expect(hostInternal > pathOnly)
  }

  @Test("matches a substring at the host start")
  func hostStartMatch() {
    let m = URLMatcher.match(query: "apple", title: "Apple", url: "https://apple.com")
    #expect(m != nil)
    let urlScore = URLMatcher.match(query: "apple", title: "x", url: "https://apple.com")?.score ?? 0
    let midPathScore =
      URLMatcher.match(query: "apple", title: "x", url: "https://x.com/apple")?.score ?? 0
    // Host-start is the strongest URL signal; mid-path lands as a
    // word-start match (after `/`) and ranks lower.
    #expect(urlScore > midPathScore)
  }

  @Test("smart case: lowercase query is case-insensitive")
  func smartCaseLowercase() {
    #expect(URLMatcher.match(query: "apple", title: "APPLE", url: "https://APPLE.com") != nil)
  }

  @Test("smart case: uppercase query becomes case-sensitive")
  func smartCaseUppercase() {
    #expect(URLMatcher.match(query: "APPLE", title: "apple", url: "https://apple.com") == nil)
    #expect(URLMatcher.match(query: "APPLE", title: "APPLE", url: "https://example.com") != nil)
  }

  @Test("multi-token query allows partial credit but requires at least one match")
  func multiTokenPartialCredit() {
    // Both tokens hit → highest score.
    let bothScore = URLMatcher.match(query: "git e05", title: "kawarimidoll/e05", url: "https://github.com/kawarimidoll/e05")?.score ?? 0
    // Only the `git` token hits.
    let oneScore = URLMatcher.match(query: "git e05", title: "Gist", url: "https://gist.github.com")?.score ?? 0
    // Neither token hits → drop.
    #expect(URLMatcher.match(query: "git e05", title: "x", url: "https://example.com") == nil)
    #expect(bothScore > oneScore)
    #expect(oneScore > 0)
  }

  @Test("title and url ranges include every matched token position")
  func rangesCoverMatches() {
    let m = URLMatcher.match(
      query: "git", title: "kawarimidoll/git", url: "https://github.com/kawarimidoll/git"
    )!
    #expect(!m.titleRanges.isEmpty)
    #expect(!m.urlRanges.isEmpty)
    // Title has "git" starting at character 13 (after the slash).
    #expect(m.titleRanges.contains(13..<16))
    // URL has "git" starting at index 8 (after `https://`).
    #expect(m.urlRanges.contains(8..<11))
  }

  @Test("rank stable-sorts ties by input order")
  func rankStableTies() {
    struct Item {
      let title: String
      let url: String
    }
    let items = [
      Item(title: "alpha", url: "https://a.com/alpha"),
      Item(title: "alpha", url: "https://b.com/alpha"),
    ]
    let result = URLMatcher.rank(
      query: "alpha", items: items,
      title: { $0.title }, url: { $0.url }
    )
    #expect(result[0].item.url == "https://a.com/alpha")
    #expect(result[1].item.url == "https://b.com/alpha")
  }
}
