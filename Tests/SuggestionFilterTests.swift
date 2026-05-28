import Foundation
import Testing

@testable import E05Lib

@Suite("URL bar suggestion filters")
struct SuggestionFilterTests {
  @Test("error-titled pages are filtered out")
  func errorTitleFilter() {
    #expect(PaneContainerViewController.isErrorTitle("Error 400 (Bad Request)!!1") == true)
    #expect(PaneContainerViewController.isErrorTitle("404 Not Found") == true)
    #expect(PaneContainerViewController.isErrorTitle("500 Internal Server Error") == true)
    // Pages where 3-digit numbers appear later in the title are not
    // error pages.
    #expect(
      PaneContainerViewController.isErrorTitle("Issue #123: Investigating crash") == false
    )
    #expect(PaneContainerViewController.isErrorTitle("kawarimidoll/e05") == false)
    #expect(PaneContainerViewController.isErrorTitle("") == false)
  }

  @Test("legitimate 3-digit-leading titles are not mistaken for errors")
  func threeDigitPrefixFalsePositives() {
    // Outside the 4xx / 5xx range, a leading 3-digit number is
    // almost always part of a real page title.
    #expect(PaneContainerViewController.isErrorTitle("100% completion guide") == false)
    #expect(PaneContainerViewController.isErrorTitle("123 ways to ship faster") == false)
    #expect(PaneContainerViewController.isErrorTitle("300 Multiple Choices") == false)
    // A status-code-like literal that runs into a host name is not
    // an error page either.
    #expect(PaneContainerViewController.isErrorTitle("404Found.com") == false)
    // 4-digit leading numbers shouldn't trip the filter.
    #expect(PaneContainerViewController.isErrorTitle("1234 reasons") == false)
  }

  @Test("search engine query key collapses parameter variants")
  func searchEngineQueryKey() {
    let a = PaneContainerViewController.searchEngineQueryKey(
      for: "https://duckduckgo.com/?q=bluesky"
    )
    let b = PaneContainerViewController.searchEngineQueryKey(
      for: "https://duckduckgo.com/?q=bluesky&ia=web"
    )
    let c = PaneContainerViewController.searchEngineQueryKey(
      for: "https://duckduckgo.com/?q=connpass"
    )
    #expect(a != nil)
    #expect(a == b)
    #expect(a != c)
  }

  @Test("non-search hosts return nil so they aren't deduped")
  func nonSearchHostsBypass() {
    #expect(
      PaneContainerViewController.searchEngineQueryKey(
        for: "https://github.com/?q=anything"
      ) == nil
    )
  }

  @Test("folds canonical-key-equivalent history and sums visit counts")
  func foldHistorySumsVisits() {
    let now = Date()
    let entries = [
      BrowsingHistory.AggregatedEntry(
        url: "https://example.com/?utm_source=x", title: "Newer",
        visits: 2, typedVisits: 1, lastVisit: now),
      BrowsingHistory.AggregatedEntry(
        url: "https://example.com", title: "Older",
        visits: 3, typedVisits: 2, lastVisit: now.addingTimeInterval(-100)),
    ]
    let folded = PaneContainerViewController.foldHistoryByCanonicalKey(entries)
    #expect(folded.count == 1)
    #expect(folded[0].visits == 5)
    #expect(folded[0].typedVisits == 3)
    // The most recent member is the representative url/title.
    #expect(folded[0].url == "https://example.com/?utm_source=x")
    #expect(folded[0].title == "Newer")
  }

  @Test("fold keeps distinct pages and preserves recency order")
  func foldKeepsDistinctOrder() {
    let now = Date()
    let entries = [
      BrowsingHistory.AggregatedEntry(
        url: "https://a.com", title: "A", visits: 1, typedVisits: 0, lastVisit: now),
      BrowsingHistory.AggregatedEntry(
        url: "https://b.com", title: "B", visits: 1, typedVisits: 0,
        lastVisit: now.addingTimeInterval(-50)),
    ]
    let folded = PaneContainerViewController.foldHistoryByCanonicalKey(entries)
    #expect(folded.map(\.url) == ["https://a.com", "https://b.com"])
  }
}
