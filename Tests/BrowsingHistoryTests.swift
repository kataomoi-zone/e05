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
}
