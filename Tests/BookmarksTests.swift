import Foundation
import SQLite3
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

  @Test("update rewrites title and url for an existing entry")
  func updateRewrites() {
    let bm = Bookmarks(inMemory: true)
    bm.add(url: "https://old.example.com", title: "Old Title")
    let id = bm.all()[0].id

    let ok = bm.update(id: id, title: "New Title", url: "https://new.example.com")
    #expect(ok == true)

    let all = bm.all()
    #expect(all.count == 1)
    #expect(all[0].title == "New Title")
    #expect(all[0].url == "https://new.example.com")
  }

  @Test("update returns false when target id does not exist")
  func updateMissingId() {
    let bm = Bookmarks(inMemory: true)
    let ok = bm.update(id: 999, title: "x", url: "https://x.example.com")
    #expect(ok == false)
  }

  @Test("update returns false when new url collides with another bookmark")
  func updateUniqueCollision() {
    let bm = Bookmarks(inMemory: true)
    bm.add(url: "https://a.example.com", title: "A")
    bm.add(url: "https://b.example.com", title: "B")
    let aId = bm.all().first(where: { $0.url == "https://a.example.com" })!.id

    // Editing A to use B's URL must fail rather than merge them.
    let ok = bm.update(id: aId, title: "A-renamed", url: "https://b.example.com")
    #expect(ok == false)

    let all = bm.all()
    #expect(all.count == 2)
    // A's original row must stay intact on failure.
    #expect(all.contains { $0.url == "https://a.example.com" && $0.title == "A" })
  }

  @Test("update fires listeners on success only")
  func updateListenerFiring() {
    let bm = Bookmarks(inMemory: true)
    bm.add(url: "https://a.example.com", title: "A")
    let id = bm.all()[0].id

    var fireCount = 0
    bm.addListener { fireCount += 1 }

    _ = bm.update(id: id, title: "A-renamed", url: "https://a.example.com")
    #expect(fireCount == 1)

    _ = bm.update(id: 999, title: "x", url: "https://x.example.com")
    #expect(fireCount == 1)  // no-op shouldn't re-notify
  }

  @Test("createFolder appends under root and returns the new id")
  func createFolderAtRoot() throws {
    let bm = Bookmarks(inMemory: true)
    let id = try #require(bm.createFolder(title: "Work"))

    let children = bm.children(of: nil)
    #expect(children.count == 1)
    #expect(children[0].id == id)
    #expect(children[0].isFolder)
    #expect(children[0].url == nil)
    #expect(children[0].title == "Work")
    #expect(children[0].parentId == nil)
  }

  @Test("createFolder nests under a parent folder")
  func createFolderNested() throws {
    let bm = Bookmarks(inMemory: true)
    let workId = try #require(bm.createFolder(title: "Work"))
    let subId = try #require(bm.createFolder(title: "Reports", parentId: workId))

    #expect(bm.children(of: nil).count == 1)
    let workChildren = bm.children(of: workId)
    #expect(workChildren.count == 1)
    #expect(workChildren[0].id == subId)
    #expect(workChildren[0].parentId == workId)
  }

  @Test("add into a folder records the parent and lands among siblings")
  func addIntoFolder() throws {
    let bm = Bookmarks(inMemory: true)
    let folderId = try #require(bm.createFolder(title: "Reading"))
    _ = bm.add(url: "https://example.com", title: "Example", parentId: folderId)

    let rootChildren = bm.children(of: nil)
    #expect(rootChildren.count == 1)
    #expect(rootChildren[0].isFolder)

    let folderChildren = bm.children(of: folderId)
    #expect(folderChildren.count == 1)
    #expect(folderChildren[0].url == "https://example.com")
    #expect(folderChildren[0].parentId == folderId)
  }

  @Test("sort_order on a fresh insert appends after siblings")
  func sortOrderAppends() {
    let bm = Bookmarks(inMemory: true)
    bm.add(url: "https://a.example.com", title: "A")
    bm.add(url: "https://b.example.com", title: "B")
    bm.add(url: "https://c.example.com", title: "C")

    let children = bm.children(of: nil)
    #expect(children.map(\.url) == [
      "https://a.example.com", "https://b.example.com", "https://c.example.com",
    ])
    // Sibling sort_order strictly increases with each new insert.
    let orders = children.map(\.sortOrder)
    #expect(orders == orders.sorted())
    #expect(Set(orders).count == orders.count)
  }

  @Test("move relocates an entry to a new parent")
  func moveToFolder() throws {
    let bm = Bookmarks(inMemory: true)
    let folderId = try #require(bm.createFolder(title: "Reading"))
    bm.add(url: "https://example.com", title: "Example")

    let id = try #require(bm.children(of: nil).first(where: { !$0.isFolder })).id
    bm.move(id: id, toParent: folderId, sortOrder: 0)

    #expect(bm.children(of: nil).filter { !$0.isFolder }.isEmpty)
    let folderChildren = bm.children(of: folderId)
    #expect(folderChildren.count == 1)
    #expect(folderChildren[0].id == id)
    #expect(folderChildren[0].parentId == folderId)
  }

  @Test("move rejects cycles into the moving subtree")
  func moveRejectsCycle() throws {
    let bm = Bookmarks(inMemory: true)
    let outerId = try #require(bm.createFolder(title: "Outer"))
    let innerId = try #require(bm.createFolder(title: "Inner", parentId: outerId))
    let deepId = try #require(bm.createFolder(title: "Deep", parentId: innerId))

    // Self-move: target == id.
    #expect(!bm.move(id: outerId, toParent: outerId, sortOrder: 0))
    // Direct child: would orphan inner if allowed.
    #expect(!bm.move(id: outerId, toParent: innerId, sortOrder: 0))
    // Grandchild: walks the ancestor chain to detect the cycle.
    #expect(!bm.move(id: outerId, toParent: deepId, sortOrder: 0))

    // The tree shape must be untouched after the rejected moves.
    let outer = try #require(bm.all().first(where: { $0.id == outerId }))
    #expect(outer.parentId == nil)

    // A legitimate move (into a sibling subtree) still works.
    let cousinId = try #require(bm.createFolder(title: "Cousin"))
    #expect(bm.move(id: outerId, toParent: cousinId, sortOrder: 0))
    let movedOuter = try #require(bm.all().first(where: { $0.id == outerId }))
    #expect(movedOuter.parentId == cousinId)
  }

  @Test("removing a folder cascades to its descendants")
  func cascadeDelete() throws {
    let bm = Bookmarks(inMemory: true)
    let folderId = try #require(bm.createFolder(title: "Work"))
    let subId = try #require(bm.createFolder(title: "Reports", parentId: folderId))
    _ = bm.add(url: "https://q1.example.com", title: "Q1", parentId: subId)
    _ = bm.add(url: "https://q2.example.com", title: "Q2", parentId: folderId)

    bm.remove(id: folderId)

    // Root, nested folder, and both bookmarks under the chain
    // disappear in one call thanks to ON DELETE CASCADE.
    #expect(bm.all().isEmpty)
    #expect(!bm.isBookmarked(url: "https://q1.example.com"))
    #expect(!bm.isBookmarked(url: "https://q2.example.com"))
  }

  @Test("duplicate bookmark URL keeps its existing folder placement")
  func upsertPreservesParent() throws {
    let bm = Bookmarks(inMemory: true)
    let folderId = try #require(bm.createFolder(title: "Reading"))
    _ = bm.add(url: "https://example.com", title: "Old Title", parentId: folderId)

    // Re-add the same URL at the root: the UPSERT should update the
    // existing row's title without moving it out of "Reading".
    _ = bm.add(url: "https://example.com", title: "New Title")

    #expect(bm.children(of: nil).count == 1)  // only the folder
    let folderChildren = bm.children(of: folderId)
    #expect(folderChildren.count == 1)
    #expect(folderChildren[0].title == "New Title")
    #expect(folderChildren[0].url == "https://example.com")
  }

  @Test("search skips folder rows")
  func searchSkipsFolders() throws {
    let bm = Bookmarks(inMemory: true)
    _ = bm.createFolder(title: "Example Folder")
    bm.add(url: "https://example.com", title: "Example Site")

    let results = bm.search(query: "Example")
    #expect(results.count == 1)
    #expect(results[0].url == "https://example.com")
  }

  @Test("setTitle renames a folder without touching its (nil) url")
  func setTitleFolder() throws {
    let bm = Bookmarks(inMemory: true)
    let id = try #require(bm.createFolder(title: "Old Name"))

    let ok = bm.setTitle(id: id, title: "New Name")
    #expect(ok)

    let entry = try #require(bm.all().first { $0.id == id })
    #expect(entry.title == "New Name")
    #expect(entry.url == nil)  // Folder url stays nil.
    #expect(entry.isFolder)
  }

  @Test("setTitle on a bookmark rewrites only its title")
  func setTitleBookmark() throws {
    let bm = Bookmarks(inMemory: true)
    bm.add(url: "https://example.com", title: "Example")
    let id = try #require(bm.all().first).id

    let ok = bm.setTitle(id: id, title: "Renamed")
    #expect(ok)

    let entry = try #require(bm.all().first)
    #expect(entry.title == "Renamed")
    #expect(entry.url == "https://example.com")  // URL untouched.
  }

  @Test("setTitle returns false for a missing id and skips listener fire")
  func setTitleMissing() {
    let bm = Bookmarks(inMemory: true)
    var fireCount = 0
    bm.addListener { fireCount += 1 }

    let ok = bm.setTitle(id: 999, title: "x")
    #expect(!ok)
    #expect(fireCount == 0)
  }

  @Test("v0 → v1 migration preserves existing rows and adds folder columns")
  func migrationFromV0() throws {
    // Stage a database on disk with the pre-hierarchy schema, then
    // open it with the current `Bookmarks` and verify the old rows
    // survive with folder columns defaulted appropriately. Using a
    // temp file because `:memory:` databases close with their
    // connection — migration needs the file to outlive the
    // priming connection.
    let dir = try #require(
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    ).appendingPathComponent("e05-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("bookmarks.db").path

    do {
      var raw: OpaquePointer?
      try #require(sqlite3_open(path, &raw) == SQLITE_OK)
      defer { sqlite3_close(raw) }
      let legacy = """
        CREATE TABLE bookmarks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );
        INSERT INTO bookmarks (url, title, created_at) VALUES
            ('https://a.example.com', 'A', 1000),
            ('https://b.example.com', 'B', 2000);
        PRAGMA user_version = 0;
        """
      try #require(sqlite3_exec(raw, legacy, nil, nil, nil) == SQLITE_OK)
    }

    // Now open through `Bookmarks` — `runMigrations` should step the
    // file forward to v1 without losing the seeded rows.
    let bm = Bookmarks(databasePath: path)
    let all = bm.all()
    #expect(all.count == 2)
    let migratedUrls = Set(all.compactMap(\.url))
    #expect(migratedUrls == ["https://a.example.com", "https://b.example.com"])
    // Pre-existing rows must surface as bookmarks (not folders) and
    // sit at the root.
    #expect(all.allSatisfy { !$0.isFolder })
    #expect(all.allSatisfy { $0.parentId == nil })
    // sort_order is dense and monotonic across the migrated batch so
    // the UI render order matches the original `created_at`.
    let orders = bm.children(of: nil).map(\.sortOrder)
    #expect(orders == [0, 1])
  }
}
