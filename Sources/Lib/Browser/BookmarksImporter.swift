import Foundation
import os.log

private let logger = Logger(
  subsystem: "com.kawarimidoll.e05", category: "BookmarksImport")

/// Apply a Netscape-formatted bookmarks document to a live
/// `Bookmarks` store. Folders are recreated with `createFolder`,
/// bookmarks with `add`; the tree's hierarchy translates 1-to-1.
///
/// The importer runs as a fresh import — duplicate URLs already
/// present in the store update their title in place (the existing
/// `Bookmarks.add` upsert path preserves the existing row's folder
/// placement and `sort_order`). Imports therefore stack on top of
/// whatever the user already has rather than wiping the store.
public enum BookmarksImporter {
  public struct Result {
    public let folders: Int
    public let bookmarks: Int
    public let skipped: Int
  }

  /// URL schemes the importer will trust from an untrusted file.
  /// Anything else (`javascript:`, `data:`, `file://`, custom app
  /// schemes) gets routed to `skipped`. The store would happily
  /// accept those strings, but clicking the resulting row in the
  /// sidebar could execute arbitrary script in a web view — not
  /// something the importer should silently enable for a one-click
  /// "import this HTML file" gesture.
  private static let allowedSchemes: Set<String> = ["http", "https", "ftp"]

  @MainActor
  public static func importDocument(
    _ entries: [NetscapeBookmarkEntry], into store: Bookmarks,
    underParent rootParentId: Int64? = nil
  ) -> Result {
    var folders = 0
    var bookmarks = 0
    var skipped = 0
    // Wrap the whole walk in one SQLite transaction + single listener
    // fire. Without this a 5000-row export from Chrome would issue
    // 5000 individual fsyncs and 5000 sidebar reloads.
    store.performBatch {
      walk(
        entries, parentId: rootParentId, store: store,
        folders: &folders, bookmarks: &bookmarks, skipped: &skipped)
    }
    logger.info(
      """
      [bookmarks/import] done folders=\(folders, privacy: .public) \
      bookmarks=\(bookmarks, privacy: .public) \
      skipped=\(skipped, privacy: .public)
      """)
    return Result(folders: folders, bookmarks: bookmarks, skipped: skipped)
  }

  @MainActor
  private static func walk(
    _ entries: [NetscapeBookmarkEntry], parentId: Int64?, store: Bookmarks,
    folders: inout Int, bookmarks: inout Int, skipped: inout Int
  ) {
    for entry in entries {
      switch entry {
      case .bookmark(let b):
        guard hasAllowedScheme(b.url) else {
          skipped += 1
          continue
        }
        if store.add(url: b.url, title: b.title, parentId: parentId) {
          bookmarks += 1
        } else {
          skipped += 1
        }
      case .folder(let f):
        guard let newId = store.createFolder(title: f.title, parentId: parentId)
        else {
          skipped += 1
          continue
        }
        folders += 1
        walk(
          f.children, parentId: newId, store: store,
          folders: &folders, bookmarks: &bookmarks, skipped: &skipped)
      }
    }
  }

  private static func hasAllowedScheme(_ url: String) -> Bool {
    guard let components = URLComponents(string: url),
      let scheme = components.scheme?.lowercased()
    else { return false }
    return allowedSchemes.contains(scheme)
  }
}
