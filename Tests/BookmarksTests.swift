import Foundation
import Testing

@testable import E05Lib

@Suite("Bookmarks")
@MainActor
struct BookmarksTests {
    @Test("add and retrieve bookmarks")
    func addAndRetrieve() {
        let bm = Bookmarks(inMemory: true)

        bm.add(url: "https://example.com", title: "Example")
        bm.add(url: "https://other.com", title: "Other")

        let all = bm.all()
        #expect(all.count == 2)
        #expect(all[0].url == "https://other.com")
        #expect(all[1].url == "https://example.com")
    }

    @Test("duplicate URL updates title instead of inserting")
    func upsert() {
        let bm = Bookmarks(inMemory: true)

        bm.add(url: "https://example.com", title: "Old Title")
        bm.add(url: "https://example.com", title: "New Title")

        let all = bm.all()
        #expect(all.count == 1)
        #expect(all[0].title == "New Title")
    }

    @Test("isBookmarked returns correct state")
    func isBookmarked() {
        let bm = Bookmarks(inMemory: true)

        #expect(!bm.isBookmarked(url: "https://example.com"))
        bm.add(url: "https://example.com", title: "Example")
        #expect(bm.isBookmarked(url: "https://example.com"))
    }

    @Test("remove by URL")
    func removeByURL() {
        let bm = Bookmarks(inMemory: true)

        bm.add(url: "https://example.com", title: "Example")
        bm.remove(url: "https://example.com")

        #expect(!bm.isBookmarked(url: "https://example.com"))
        #expect(bm.all().isEmpty)
    }

    @Test("remove by ID")
    func removeByID() {
        let bm = Bookmarks(inMemory: true)

        bm.add(url: "https://a.com", title: "A")
        bm.add(url: "https://b.com", title: "B")

        let all = bm.all()
        bm.remove(id: all[0].id)

        let remaining = bm.all()
        #expect(remaining.count == 1)
        #expect(remaining[0].url == "https://a.com")
    }

    @Test("search by URL substring")
    func searchURL() {
        let bm = Bookmarks(inMemory: true)

        bm.add(url: "https://github.com", title: "GitHub")
        bm.add(url: "https://example.com", title: "Example")

        let results = bm.search(query: "github")
        #expect(results.count == 1)
        #expect(results[0].url == "https://github.com")
    }

    @Test("search by title substring")
    func searchTitle() {
        let bm = Bookmarks(inMemory: true)

        bm.add(url: "https://example.com", title: "My Favorite Page")

        let results = bm.search(query: "Favorite")
        #expect(results.count == 1)
    }
}
