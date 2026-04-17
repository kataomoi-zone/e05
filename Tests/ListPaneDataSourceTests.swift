import Testing

@testable import E05Lib

@MainActor
@Suite("HistoryDataSource")
struct HistoryDataSourceTests {
    @Test("load maps history entries to ListPaneRow")
    func loadMapsEntries() {
        let history = BrowsingHistory(inMemory: true)
        history.recordVisit(url: "https://example.com", title: "Example")
        history.recordVisit(url: "https://swift.org", title: "Swift")

        let ds = HistoryDataSource(history: history)
        let rows = ds.load()

        #expect(rows.count == 2)
        // mostRecent returns latest first
        #expect(rows[0].url == "https://swift.org")
        #expect(rows[0].title == "Swift")
        #expect(!rows[0].subtitle.isEmpty)
    }

    @Test("delete removes entry from backing store")
    func deleteRemovesEntry() {
        let history = BrowsingHistory(inMemory: true)
        history.recordVisit(url: "https://a.test", title: "A")
        history.recordVisit(url: "https://b.test", title: "B")

        let ds = HistoryDataSource(history: history)
        let rows = ds.load()
        #expect(rows.count == 2)

        ds.delete(id: rows[0].id)
        #expect(ds.load().count == 1)
    }

    @Test("title is History")
    func titleLabel() {
        let ds = HistoryDataSource(history: BrowsingHistory(inMemory: true))
        #expect(ds.title == "History")
    }
}

@MainActor
@Suite("BookmarksDataSource")
struct BookmarksDataSourceTests {
    @Test("load maps bookmark entries to ListPaneRow")
    func loadMapsEntries() {
        let bm = Bookmarks(inMemory: true)
        bm.add(url: "https://example.com", title: "Example")
        bm.add(url: "https://swift.org", title: "Swift")

        let ds = BookmarksDataSource(bookmarks: bm)
        let rows = ds.load()

        #expect(rows.count == 2)
        #expect(rows.contains { $0.url == "https://example.com" && $0.title == "Example" })
        #expect(rows.allSatisfy { $0.subtitle.hasPrefix("Added ") })
    }

    @Test("delete removes bookmark from backing store")
    func deleteRemovesEntry() {
        let bm = Bookmarks(inMemory: true)
        bm.add(url: "https://a.test", title: "A")
        bm.add(url: "https://b.test", title: "B")

        let ds = BookmarksDataSource(bookmarks: bm)
        let rows = ds.load()
        #expect(rows.count == 2)

        ds.delete(id: rows[0].id)
        #expect(ds.load().count == 1)
    }

    @Test("title is Bookmarks")
    func titleLabel() {
        let ds = BookmarksDataSource(bookmarks: Bookmarks(inMemory: true))
        #expect(ds.title == "Bookmarks")
    }
}
