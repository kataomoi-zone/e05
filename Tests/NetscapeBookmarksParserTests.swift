import Foundation
import Testing

@testable import E05Lib

@Suite("NetscapeBookmarksParser")
struct NetscapeBookmarksParserTests {
  @Test("parses a flat list of bookmarks")
  func flatList() {
    let html = """
      <!DOCTYPE NETSCAPE-Bookmark-file-1>
      <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
      <TITLE>Bookmarks</TITLE>
      <H1>Bookmarks</H1>
      <DL><p>
          <DT><A HREF="https://example.com">Example</A>
          <DT><A HREF="https://other.example.com">Other</A>
      </DL><p>
      """
    let entries = NetscapeBookmarksParser.parse(html)
    #expect(entries.count == 2)
    #expect(bookmark(entries[0])?.url == "https://example.com")
    #expect(bookmark(entries[0])?.title == "Example")
    #expect(bookmark(entries[1])?.url == "https://other.example.com")
  }

  @Test("parses nested folders")
  func nestedFolders() {
    let html = """
      <DL><p>
          <DT><H3>Work</H3>
          <DL><p>
              <DT><A HREF="https://work.example.com">Work Tool</A>
              <DT><H3>Reports</H3>
              <DL><p>
                  <DT><A HREF="https://q1.example.com">Q1</A>
              </DL><p>
          </DL><p>
          <DT><A HREF="https://top.example.com">Top Level</A>
      </DL><p>
      """
    let entries = NetscapeBookmarksParser.parse(html)
    #expect(entries.count == 2)

    let work = folder(entries[0])
    #expect(work?.title == "Work")
    #expect(work?.children.count == 2)

    let tool = bookmark(work?.children[0])
    #expect(tool?.url == "https://work.example.com")

    let reports = folder(work?.children[1])
    #expect(reports?.title == "Reports")
    #expect(reports?.children.count == 1)
    #expect(bookmark(reports?.children[0])?.url == "https://q1.example.com")

    let top = bookmark(entries[1])
    #expect(top?.url == "https://top.example.com")
  }

  @Test("tolerates missing </DT> and </p>")
  func malformedClosingTags() {
    // Chrome / Firefox both drop the `</DT>` and `</p>` closers
    // when exporting. The body below mirrors that shape so the
    // parser regression-protects against a future emitter switch.
    let html = """
      <DL><p>
          <DT><A HREF="https://a.example.com">A</A>
          <DT><A HREF="https://b.example.com">B</A>
      </DL>
      """
    let entries = NetscapeBookmarksParser.parse(html)
    #expect(entries.count == 2)
    #expect(bookmark(entries[0])?.url == "https://a.example.com")
    #expect(bookmark(entries[1])?.url == "https://b.example.com")
  }

  @Test("decodes HTML entities in titles and URLs")
  func entities() {
    let html = """
      <DL><p>
          <DT><A HREF="https://search.example.com?q=swift&amp;lang=en">Swift &amp; Cocoa</A>
          <DT><A HREF="https://example.com">&lt;script&gt; tag</A>
          <DT><A HREF="https://example.com/&#x2603;">snowman &#9731;</A>
      </DL>
      """
    let entries = NetscapeBookmarksParser.parse(html)
    #expect(entries.count == 3)
    #expect(bookmark(entries[0])?.url == "https://search.example.com?q=swift&lang=en")
    #expect(bookmark(entries[0])?.title == "Swift & Cocoa")
    #expect(bookmark(entries[1])?.title == "<script> tag")
    #expect(bookmark(entries[2])?.url == "https://example.com/☃")
    #expect(bookmark(entries[2])?.title.contains("☃") == true)
  }

  @Test("reads ADD_DATE in seconds and rescales millisecond values")
  func addDate() {
    // Two bookmarks at the same moment in time: one in seconds, one
    // in milliseconds. Both should land at the same Date.
    let html = """
      <DL><p>
          <DT><A HREF="https://a.example.com" ADD_DATE="1700000000">A</A>
          <DT><A HREF="https://b.example.com" ADD_DATE="1700000000000">B</A>
          <DT><A HREF="https://c.example.com">No date</A>
      </DL>
      """
    let entries = NetscapeBookmarksParser.parse(html)
    let a = bookmark(entries[0])
    let b = bookmark(entries[1])
    let c = bookmark(entries[2])
    #expect(a?.addDate?.timeIntervalSince1970 == 1_700_000_000)
    #expect(b?.addDate?.timeIntervalSince1970 == 1_700_000_000)
    #expect(c?.addDate == nil)
  }

  @Test("ignores preamble, DOCTYPE, and unknown tags")
  func preamble() {
    let html = """
      <!DOCTYPE NETSCAPE-Bookmark-file-1>
      <!-- This is an automatically generated file. -->
      <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
      <TITLE>Bookmarks</TITLE>
      <H1>Bookmarks Bar</H1>
      <DL><p>
          <DT><A HREF="https://example.com" ICON="data:image/png;base64,iVBOR…">Example</A>
      </DL><p>
      """
    let entries = NetscapeBookmarksParser.parse(html)
    #expect(entries.count == 1)
    #expect(bookmark(entries[0])?.title == "Example")
  }

  @Test("strips inline formatting tags from titles")
  func inlineTags() {
    let html = """
      <DL><p>
          <DT><A HREF="https://example.com"><B>Bold</B> title</A>
          <DT><H3><EM>Italic</EM> folder</H3>
          <DL><p></DL><p>
      </DL><p>
      """
    let entries = NetscapeBookmarksParser.parse(html)
    #expect(bookmark(entries[0])?.title == "Bold title")
    #expect(folder(entries[1])?.title == "Italic folder")
  }

  @Test("returns empty for malformed or empty input")
  func emptyInput() {
    #expect(NetscapeBookmarksParser.parse("").isEmpty)
    #expect(NetscapeBookmarksParser.parse("<html><body>no bookmarks here</body></html>").isEmpty)
    #expect(NetscapeBookmarksParser.parse("<DL><p></DL><p>").isEmpty)
  }

  @Test("handles non-ASCII titles and URLs")
  func nonASCII() {
    let html = """
      <DL><p>
          <DT><A HREF="https://日本語.example.com/path">日本語タイトル</A>
          <DT><H3>フォルダ名</H3>
          <DL><p>
              <DT><A HREF="https://example.com/é">é</A>
          </DL><p>
      </DL><p>
      """
    let entries = NetscapeBookmarksParser.parse(html)
    #expect(bookmark(entries[0])?.title == "日本語タイトル")
    #expect(bookmark(entries[0])?.url == "https://日本語.example.com/path")
    let f = folder(entries[1])
    #expect(f?.title == "フォルダ名")
    #expect(bookmark(f?.children.first)?.title == "é")
  }

  @Test("skips bookmarks missing an HREF")
  func missingHref() {
    let html = """
      <DL><p>
          <DT><A>No href</A>
          <DT><A HREF="">Empty href</A>
          <DT><A HREF="https://valid.example.com">Valid</A>
      </DL><p>
      """
    let entries = NetscapeBookmarksParser.parse(html)
    // The two invalid <A>s are dropped; only the valid bookmark
    // makes it through.
    #expect(entries.count == 1)
    #expect(bookmark(entries[0])?.url == "https://valid.example.com")
  }

  @Test("truncates subtrees beyond the maximum nesting depth")
  func deepNesting() {
    // Build 32 levels of nested `<DL>` — beyond the parser's 16-level
    // cap. The outer levels should land; everything past the cap is
    // dropped and the document still parses cleanly (no stack
    // overflow, no stuck scanner).
    var html = ""
    let depth = 32
    for level in 0..<depth {
      html += "<DL><p>\n"
      html += "<DT><H3>F\(level)</H3>\n"
    }
    html += "<DT><A HREF=\"https://leaf.example.com\">leaf</A>\n"
    for _ in 0..<depth {
      html += "</DL><p>\n"
    }

    let entries = NetscapeBookmarksParser.parse(html)
    // The outermost folder must be present and openable; the deeper
    // levels should bottom out at the cap rather than crashing.
    #expect(entries.count == 1)
    var current = folder(entries[0])
    var actualDepth = 1
    while let f = current, let next = f.children.first {
      if case .folder(let inner) = next {
        current = inner
        actualDepth += 1
      } else {
        break
      }
    }
    #expect(actualDepth <= 16)
  }

  @Test("handles empty folders with no inner <DL>")
  func emptyFolder() {
    // An exporter may emit a folder header with no child list when
    // the folder is empty. The parser tolerates the missing <DL>
    // and yields a folder with an empty `children` array.
    let html = """
      <DL><p>
          <DT><H3>Empty</H3>
          <DT><A HREF="https://after.example.com">After</A>
      </DL><p>
      """
    let entries = NetscapeBookmarksParser.parse(html)
    #expect(entries.count == 2)
    let f = folder(entries[0])
    #expect(f?.title == "Empty")
    #expect(f?.children.isEmpty == true)
    #expect(bookmark(entries[1])?.url == "https://after.example.com")
  }

  // MARK: - Helpers

  private func bookmark(_ entry: NetscapeBookmarkEntry?) -> NetscapeBookmark? {
    if case .bookmark(let b) = entry { return b }
    return nil
  }

  private func folder(_ entry: NetscapeBookmarkEntry?) -> NetscapeBookmarkFolder? {
    if case .folder(let f) = entry { return f }
    return nil
  }
}

@Suite("BookmarksImporter")
@MainActor
struct BookmarksImporterTests {
  @Test("import recreates the parsed tree under the requested parent")
  func importIntoEmptyStore() throws {
    let html = """
      <DL><p>
          <DT><H3>Work</H3>
          <DL><p>
              <DT><A HREF="https://work.example.com">Work Tool</A>
              <DT><H3>Reports</H3>
              <DL><p>
                  <DT><A HREF="https://q1.example.com">Q1</A>
              </DL><p>
          </DL><p>
          <DT><A HREF="https://top.example.com">Top Level</A>
      </DL><p>
      """
    let parsed = NetscapeBookmarksParser.parse(html)
    let store = Bookmarks(inMemory: true)
    let result = BookmarksImporter.importDocument(parsed, into: store)

    #expect(result.folders == 2)
    #expect(result.bookmarks == 3)
    #expect(result.skipped == 0)

    let roots = store.children(of: nil)
    #expect(roots.count == 2)
    let work = try #require(roots.first { $0.isFolder })
    #expect(work.title == "Work")
    let top = try #require(roots.first { !$0.isFolder })
    #expect(top.url == "https://top.example.com")

    let workChildren = store.children(of: work.id)
    #expect(workChildren.count == 2)
    let reports = try #require(workChildren.first { $0.isFolder })
    let reportsChildren = store.children(of: reports.id)
    #expect(reportsChildren.count == 1)
    #expect(reportsChildren[0].url == "https://q1.example.com")
  }

  @Test("import upsert preserves existing bookmark placement")
  func importOverExisting() throws {
    let store = Bookmarks(inMemory: true)
    let folderId = try #require(store.createFolder(title: "Reading"))
    _ = store.add(url: "https://example.com", title: "Old Title", parentId: folderId)

    let html = """
      <DL><p>
          <DT><A HREF="https://example.com">New Title</A>
      </DL><p>
      """
    let parsed = NetscapeBookmarksParser.parse(html)
    _ = BookmarksImporter.importDocument(parsed, into: store)

    // The duplicate URL kept its folder placement — `Bookmarks.add`
    // upserts on the partial unique index, so the existing row's
    // `parent_id` is untouched while the title flips to the imported
    // value.
    #expect(store.children(of: nil).filter { !$0.isFolder }.isEmpty)
    let inFolder = store.children(of: folderId)
    #expect(inFolder.count == 1)
    #expect(inFolder[0].title == "New Title")
  }

  @Test("import rejects bookmarks with disallowed URL schemes")
  func importDropsDangerousSchemes() {
    let html = """
      <DL><p>
          <DT><A HREF="javascript:alert(1)">JS</A>
          <DT><A HREF="data:text/html,<script>1</script>">Data</A>
          <DT><A HREF="file:///etc/passwd">File</A>
          <DT><A HREF="https://example.com">OK</A>
      </DL><p>
      """
    let parsed = NetscapeBookmarksParser.parse(html)
    let store = Bookmarks(inMemory: true)
    let result = BookmarksImporter.importDocument(parsed, into: store)

    // Only the https URL should make it into the store. The other
    // three are routed to `skipped` so they can't be clicked into a
    // web view after import.
    #expect(result.bookmarks == 1)
    #expect(result.skipped == 3)
    let stored = store.children(of: nil)
    #expect(stored.count == 1)
    #expect(stored[0].url == "https://example.com")
  }

  @Test("import coalesces listener fires into a single notification")
  func importFiresListenerOnce() {
    var fireCount = 0
    let store = Bookmarks(inMemory: true)
    _ = store.addListener { fireCount += 1 }

    let html = """
      <DL><p>
          <DT><H3>Folder</H3>
          <DL><p>
              <DT><A HREF="https://a.example.com">A</A>
              <DT><A HREF="https://b.example.com">B</A>
              <DT><A HREF="https://c.example.com">C</A>
          </DL><p>
      </DL><p>
      """
    let parsed = NetscapeBookmarksParser.parse(html)
    _ = BookmarksImporter.importDocument(parsed, into: store)

    // The walk above hits `createFolder` once and `add` three times.
    // Without batching every mutation fires the listener, so the
    // sidebar would reload four times. `performBatch` should collapse
    // those into one final fire.
    #expect(fireCount == 1)
  }

  @Test("import under a non-nil parent grafts the tree as a subtree")
  func importUnderParent() throws {
    let html = """
      <DL><p>
          <DT><A HREF="https://example.com">Example</A>
      </DL><p>
      """
    let parsed = NetscapeBookmarksParser.parse(html)
    let store = Bookmarks(inMemory: true)
    let parentId = try #require(store.createFolder(title: "Imported"))
    _ = BookmarksImporter.importDocument(parsed, into: store, underParent: parentId)

    #expect(store.children(of: nil).count == 1)
    let inFolder = store.children(of: parentId)
    #expect(inFolder.count == 1)
    #expect(inFolder[0].url == "https://example.com")
    #expect(inFolder[0].parentId == parentId)
  }
}
