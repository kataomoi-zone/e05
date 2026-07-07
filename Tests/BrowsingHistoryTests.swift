import Foundation
import Testing

@testable import E05Lib

@Suite("BrowsingHistory")
@MainActor
struct BrowsingHistoryTests {
  @Test("records and retrieves visits")
  func recordAndRetrieve() {
    let history = BrowsingHistory(inMemory: true)
    history.deleteAll()

    history.recordVisit(url: "https://example.com", title: "Example")
    history.recordVisit(url: "https://other.com", title: "Other")

    let entries = history.mostRecent(limit: 10)
    #expect(entries.count == 2)
    #expect(entries[0].url == "https://other.com")
    #expect(entries[1].url == "https://example.com")
  }

  @Test("deduplicates consecutive same-URL visits")
  func deduplication() {
    let history = BrowsingHistory(inMemory: true)
    history.deleteAll()

    history.recordVisit(url: "https://example.com", title: "Example")
    history.recordVisit(url: "https://example.com", title: "Example")

    let entries = history.mostRecent(limit: 10)
    #expect(entries.count == 1)
  }

  @Test("search by URL substring")
  func searchURL() {
    let history = BrowsingHistory(inMemory: true)
    history.deleteAll()

    history.recordVisit(url: "https://github.com/kawarimidoll", title: "GitHub")
    history.recordVisit(url: "https://example.com", title: "Example")

    let results = history.search(query: "github")
    #expect(results.count == 1)
    #expect(results[0].url == "https://github.com/kawarimidoll")
  }

  @Test("search by title substring")
  func searchTitle() {
    let history = BrowsingHistory(inMemory: true)
    history.deleteAll()

    history.recordVisit(url: "https://example.com", title: "My Page")

    let results = history.search(query: "My Page")
    #expect(results.count == 1)
  }

  @Test("updateTitle updates most recent entry")
  func updateTitle() {
    let history = BrowsingHistory(inMemory: true)
    history.deleteAll()

    history.recordVisit(url: "https://example.com", title: "")
    history.updateTitle(url: "https://example.com", title: "Updated Title")

    let entries = history.mostRecent(limit: 1)
    #expect(entries[0].title == "Updated Title")
  }

  @Test("mostRecentAggregated reports per-URL visit count and last visit")
  func mostRecentAggregatedReports() {
    let history = BrowsingHistory(inMemory: true)
    history.deleteAll()

    // The dedup guard collapses consecutive same-URL records, so
    // interleave the visits to keep three rows for `a.com`.
    history.recordVisit(url: "https://a.com", title: "A1")
    history.recordVisit(url: "https://b.com", title: "B")
    history.recordVisit(url: "https://a.com", title: "A2")
    history.recordVisit(url: "https://b.com", title: "B")
    history.recordVisit(url: "https://a.com", title: "A3")

    let aggregated = history.mostRecentAggregated(limit: 10)
    #expect(aggregated.count == 2)

    let aRow = try? #require(aggregated.first { $0.url == "https://a.com" })
    let bRow = try? #require(aggregated.first { $0.url == "https://b.com" })
    #expect(aRow?.visits == 3)
    #expect(bRow?.visits == 2)
    // Title should be the latest captured value, not the first.
    #expect(aRow?.title == "A3")
  }

  @Test("delete removes single entry")
  func deleteSingle() {
    let history = BrowsingHistory(inMemory: true)
    history.deleteAll()

    history.recordVisit(url: "https://a.com", title: "A")
    history.recordVisit(url: "https://b.com", title: "B")

    let entries = history.mostRecent(limit: 10)
    #expect(entries.count == 2)

    history.delete(id: entries[0].id)
    let remaining = history.mostRecent(limit: 10)
    #expect(remaining.count == 1)
    #expect(remaining[0].url == "https://a.com")
  }

  @Test("aggregates typed-visit counts per URL")
  func typedVisitAggregation() {
    let history = BrowsingHistory(inMemory: true)
    history.deleteAll()

    // Interleave to dodge the consecutive-dup guard; `a.com` gets
    // two typed visits, `b.com` a single link visit.
    history.recordVisit(url: "https://a.com", title: "A", transition: .typed)
    history.recordVisit(url: "https://b.com", title: "B", transition: .link)
    history.recordVisit(url: "https://a.com", title: "A", transition: .typed)

    let aggregated = history.mostRecentAggregated(limit: 10)
    let aRow = try? #require(aggregated.first { $0.url == "https://a.com" })
    let bRow = try? #require(aggregated.first { $0.url == "https://b.com" })
    #expect(aRow?.visits == 2)
    #expect(aRow?.typedVisits == 2)
    #expect(bRow?.visits == 1)
    #expect(bRow?.typedVisits == 0)
  }

  @Test("defaulted transition records as a non-typed visit")
  func defaultTransitionNotTyped() {
    let history = BrowsingHistory(inMemory: true)
    history.deleteAll()

    history.recordVisit(url: "https://a.com", title: "A")

    let aggregated = history.mostRecentAggregated(limit: 10)
    let aRow = try? #require(aggregated.first { $0.url == "https://a.com" })
    #expect(aRow?.visits == 1)
    #expect(aRow?.typedVisits == 0)
  }

  @Test("pruneOlderThan removes visits before the cutoff")
  func pruneRemovesOldVisits() {
    let history = BrowsingHistory(inMemory: true)
    history.deleteAll()
    history.recordVisit(url: "https://a.com", title: "A")
    history.recordVisit(url: "https://b.com", title: "B")

    // A cutoff in the future is newer than every just-recorded visit,
    // so all of them prune.
    let removed = history.pruneOlderThan(Date().addingTimeInterval(3600))
    #expect(removed == 2)
    #expect(history.mostRecent(limit: 10).isEmpty)
  }

  @Test("pruneOlderThan keeps visits after the cutoff")
  func pruneKeepsRecentVisits() {
    let history = BrowsingHistory(inMemory: true)
    history.deleteAll()
    history.recordVisit(url: "https://a.com", title: "A")

    // A cutoff in the past is older than the visit, so nothing prunes.
    let removed = history.pruneOlderThan(Date().addingTimeInterval(-3600))
    #expect(removed == 0)
    #expect(history.mostRecent(limit: 10).count == 1)
  }
}
