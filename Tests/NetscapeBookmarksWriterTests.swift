import Foundation
import Testing

@testable import E05Lib

@Suite("NetscapeBookmarksWriter")
@MainActor
struct NetscapeBookmarksWriterTests {
  @Test("preamble and root <DL>/<DT> shape match the format spec")
  func preambleShape() throws {
    let store = Bookmarks(inMemory: true)
    _ = store.add(url: "https://example.com", title: "Example")
    let html = NetscapeBookmarksWriter.render(store)
    #expect(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
    #expect(html.contains("charset=UTF-8"))
    #expect(html.contains("<H1>Bookmarks</H1>"))
    #expect(html.contains("<DL><p>"))
    #expect(html.hasSuffix("</DL><p>\n"))
    #expect(html.contains("<DT><A HREF=\"https://example.com\""))
    #expect(html.contains(">Example</A>"))
  }

  @Test("folders nest as <H3>…</H3> followed by <DL><p>…</DL><p>")
  func folderShape() throws {
    let store = Bookmarks(inMemory: true)
    let workId = try #require(store.createFolder(title: "Work"))
    _ = store.add(url: "https://work.example.com", title: "Tool", parentId: workId)

    let html = NetscapeBookmarksWriter.render(store)
    let workIdx = try #require(html.range(of: "<DT><H3"))
    let workEnd = try #require(html.range(of: "</H3>"))
    #expect(workIdx.lowerBound < workEnd.lowerBound)

    // The inner <DL> opens after the H3 close, and contains the
    // nested bookmark before its own </DL>.
    let innerDL = try #require(html.range(of: "<DL><p>", range: workEnd.upperBound..<html.endIndex))
    let innerBookmark = try #require(
      html.range(of: "https://work.example.com", range: innerDL.upperBound..<html.endIndex))
    let innerDLClose = try #require(
      html.range(of: "</DL><p>", range: innerBookmark.upperBound..<html.endIndex))
    #expect(innerBookmark.lowerBound < innerDLClose.lowerBound)
  }

  @Test("ADD_DATE encodes seconds since epoch")
  func addDateOutput() {
    let store = Bookmarks(inMemory: true)
    _ = store.add(url: "https://example.com", title: "Example")
    let html = NetscapeBookmarksWriter.render(store)
    // Some non-zero ADD_DATE attribute lands in the output. The
    // exact value is "now" so just confirm the attribute shape.
    #expect(html.contains("ADD_DATE=\""))
  }

  @Test("entities in titles and URLs are escaped")
  func entitiesEscaped() {
    let store = Bookmarks(inMemory: true)
    _ = store.add(
      url: "https://search.example.com?q=swift&lang=en",
      title: "Swift & <Cocoa>")
    let html = NetscapeBookmarksWriter.render(store)
    #expect(html.contains("?q=swift&amp;lang=en"))
    #expect(html.contains(">Swift &amp; &lt;Cocoa&gt;</A>"))
    // The literal raw `&` should not appear in escaped contexts —
    // every `&` in the output should be followed by an entity name
    // (`amp`/`lt`/`gt`/`quot`/numeric reference).
    let unescaped = html.range(of: "& ")  // bare ampersand + space (impossible if all escaped)
    #expect(unescaped == nil)
  }

  @Test("export round-trips through the parser to the same tree")
  func roundTrip() throws {
    let source = Bookmarks(inMemory: true)
    let workId = try #require(source.createFolder(title: "Work"))
    let reportsId = try #require(source.createFolder(title: "Reports & Q1", parentId: workId))
    _ = source.add(url: "https://q1.example.com", title: "Q1", parentId: reportsId)
    _ = source.add(url: "https://work.example.com?id=42&v=2", title: "Tool", parentId: workId)
    _ = source.add(url: "https://top.example.com", title: "Top")

    let html = NetscapeBookmarksWriter.render(source)
    let parsed = NetscapeBookmarksParser.parse(html)

    let destination = Bookmarks(inMemory: true)
    _ = BookmarksImporter.importDocument(parsed, into: destination)

    // Source and destination should describe the same tree: titles,
    // URLs, folder shape, and sibling order at every level.
    #expect(treeShape(of: source) == treeShape(of: destination))
  }

  @Test("an empty store still produces a valid (empty) document")
  func emptyStore() {
    let store = Bookmarks(inMemory: true)
    let html = NetscapeBookmarksWriter.render(store)
    #expect(html.contains("<DL><p>"))
    #expect(html.contains("</DL><p>"))
    // No row tags at all when the store is empty.
    #expect(!html.contains("<DT>"))
  }

  @Test("scoped export under a parent folder emits only that subtree")
  func scopedExport() throws {
    let store = Bookmarks(inMemory: true)
    let workId = try #require(store.createFolder(title: "Work"))
    _ = store.add(url: "https://work.example.com", title: "Tool", parentId: workId)
    _ = store.add(url: "https://personal.example.com", title: "Personal")

    let html = NetscapeBookmarksWriter.render(store, underParent: workId)
    #expect(html.contains("https://work.example.com"))
    #expect(!html.contains("https://personal.example.com"))
  }

  // MARK: - Helpers

  /// Recursive flat description of a store's tree for set-equality
  /// comparison. Captures titles + URLs + sibling order without
  /// having to inspect every Entry field. Folder ids and timestamps
  /// vary across stores, so they're excluded.
  private func treeShape(of store: Bookmarks) -> String {
    var out = ""
    walk(parentId: nil, store: store, depth: 0, into: &out)
    return out
  }

  private func walk(parentId: Int64?, store: Bookmarks, depth: Int, into out: inout String) {
    for entry in store.children(of: parentId) {
      out.append(String(repeating: "  ", count: depth))
      if entry.isFolder {
        out.append("[\(entry.title)]\n")
        walk(parentId: entry.id, store: store, depth: depth + 1, into: &out)
      } else {
        out.append("\(entry.title)|\(entry.url ?? "")\n")
      }
    }
  }
}
