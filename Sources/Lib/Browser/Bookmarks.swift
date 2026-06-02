import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "Bookmarks")

/// Opaque handle returned by `Bookmarks.addListener(_:)`. Pass it back
/// to `removeListener(_:)` to unregister a callback.
public final class BookmarksListenerToken {
  fileprivate let id = UUID()
  fileprivate init() {}
}

/// Persistent bookmarks stored in SQLite at
/// `~/Library/Application Support/<bundle-id>/bookmarks.db` (resolved
/// through `E05Paths.default.dataDir`). Rows are id-keyed (`AUTOINCREMENT`)
/// rather than host-keyed (`MutedSitesStore`, `PermissionsStore`) or
/// path-keyed (`FinderModeStore`) — the same URL can be re-added
/// after deletion and gets a fresh id, so callers must hold onto the
/// `Entry.id` they care about rather than re-deriving it.
///
/// Bookmarks live in a hierarchy: each row either represents a leaf
/// bookmark (`isFolder == false`, `url` non-nil) or a folder
/// (`isFolder == true`, `url == nil`). `parentId` references the
/// enclosing folder (`nil` = top level). `sortOrder` orders siblings
/// within a parent — drag-reorder operations rewrite it, fresh
/// inserts append at `MAX(sort_order) + 1`. URL uniqueness is enforced
/// only on bookmarks via a partial unique index so duplicate folder
/// names don't trip it.
///
/// Mutation observers can register via `addListener(_:)` so UI (the
/// sidebar bookmarks list, future status indicators) refreshes when
/// add / remove / deleteAll happens anywhere in the process without
/// having to poll.
@MainActor
public final class Bookmarks {
  /// Process-wide singleton. `PaneContainerViewController` and the
  /// Settings tab share this instance so a Reset from About is
  /// observed by the live sidebar listeners without a relaunch. The
  /// init signature stays on the public surface so tests keep
  /// reaching for `inMemory: true` instances.
  public static let shared = Bookmarks()

  // nonisolated(unsafe): accessed in deinit which is nonisolated
  nonisolated(unsafe) private var db: OpaquePointer?

  /// Registered mutation observers, keyed by token id.
  private var listeners: [UUID: () -> Void] = [:]

  /// Active `performBatch` nesting depth. Mutations inside a batch
  /// defer their listener fires until the outermost batch exits, so
  /// a multi-row import doesn't repaint the sidebar once per row.
  private var batchDepth: Int = 0
  /// `true` when a mutation tried to fire listeners while inside a
  /// batch; the outermost `performBatch` drains it.
  private var pendingListenerFire = false

  /// Schema version stamped into `PRAGMA user_version` after migrate.
  /// Bump whenever the schema changes; `runMigrations` is responsible
  /// for stepping any older database forward.
  private static let currentSchemaVersion: Int32 = 1

  public struct Entry: Equatable {
    public let id: Int64
    /// `nil` for folder entries. Bookmarks always have a URL.
    public let url: String?
    public let title: String
    public let createdAt: Date
    /// `nil` for top-level entries.
    public let parentId: Int64?
    public let isFolder: Bool
    /// Position among siblings under `parentId`. Lower comes first.
    public let sortOrder: Int
  }

  // MARK: - Lifecycle

  /// Create a bookmarks instance pointing at the production SQLite
  /// file under `~/Library/Application Support/<bundle-id>/bookmarks.db`
  /// (via `E05Paths.default.dataDir`), creating the directory if it
  /// doesn't exist yet — `Application Support/<bundle-id>/` is not
  /// guaranteed to exist on first launch, so the `createDirectory`
  /// stays even after the relocation off `~/.config`. Pass
  /// `inMemory: true` from tests to open a `:memory:` database that
  /// disappears with the instance.
  public convenience init(inMemory: Bool = false) {
    if inMemory {
      self.init(databasePath: ":memory:")
      return
    }
    self.init(databasePath: E05Paths.default.databasePath(E05Filenames.bookmarks))
  }

  /// Internal initialiser that opens the SQLite database at an
  /// arbitrary path. Tests reach this to point at a temp file
  /// without touching the user's real data directory; production
  /// code reaches it via `init(inMemory:)`. The parameter is `String`
  /// rather than `URL?` so the SQLite-native `:memory:` marker can
  /// flow through unchanged; callers passing a filesystem path must
  /// ensure the parent directory already exists, since
  /// `sqlite3_open` fails outright on a missing directory.
  init(databasePath: String) {
    openDatabase(at: databasePath)
    runMigrations()
  }

  deinit {
    if let db {
      sqlite3_close(db)
    }
  }

  // MARK: - Database Setup

  private func openDatabase(at path: String) {
    if sqlite3_open(path, &db) != SQLITE_OK {
      logger.error("Failed to open bookmarks database at \(path)")
      db = nil
      return
    }
    // Cascade deletes through `parent_id` only fire when foreign keys
    // are enabled (off by default in SQLite for back-compat reasons),
    // so removing a folder also removes its descendants in one call.
    sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
  }

  private func runMigrations() {
    guard db != nil else { return }
    var current = readSchemaVersion()

    // v0 → v1: introduce folders. Pre-v1 schemas have either no
    // `bookmarks` table at all (fresh install) or the original flat
    // `(id, url NOT NULL UNIQUE, title, created_at)` shape. Both are
    // covered by creating the new schema and copying any rows over.
    // Advance `current` only when the migration committed; bailing
    // early on failure keeps `user_version` honest so the next
    // launch re-attempts instead of running against a half-built
    // schema.
    if current < 1 {
      guard migrateToV1() else {
        logger.error(
          "[bookmarks/migrate] aborted before v1; leaving user_version=\(current)")
        return
      }
      current = 1
    }

    setSchemaVersion(current)
  }

  private func readSchemaVersion() -> Int32 {
    guard let db else { return 0 }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return 0 }
    defer { sqlite3_finalize(stmt) }
    return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
  }

  private func setSchemaVersion(_ version: Int32) {
    guard let db else { return }
    sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil)
  }

  /// Returns `true` when the database is at the v1 schema on exit,
  /// `false` when a step failed and the table was rolled back.
  /// `runMigrations` gates `setSchemaVersion(1)` on the return value
  /// so a partial migrate doesn't stamp v1 over a v0 table.
  private func migrateToV1() -> Bool {
    guard let db else { return false }
    // Fresh install: no rebuild needed, just create the v1 schema
    // directly. Skipping the table-rename dance avoids the
    // `SELECT ... FROM bookmarks` reference that would error before
    // the EXISTS subquery filters it out (SQLite resolves table
    // references at compile time, not at row time).
    if !tableExists("bookmarks") {
      let fresh = """
        CREATE TABLE bookmarks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT,
            title TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            parent_id INTEGER REFERENCES bookmarks(id) ON DELETE CASCADE,
            is_folder INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_bookmarks_parent ON bookmarks(parent_id);
        CREATE UNIQUE INDEX idx_bookmarks_url_unique
            ON bookmarks(url) WHERE is_folder = 0 AND url IS NOT NULL;
        """
      if sqlite3_exec(db, fresh, nil, nil, nil) != SQLITE_OK {
        logger.error(
          "[bookmarks/migrate] v1 fresh schema failed: \(String(cString: sqlite3_errmsg(db)))")
        return false
      }
      return true
    }

    // SQLite can't drop a column-level NOT NULL / UNIQUE in place, so
    // rebuild the table. Wrapping in a transaction keeps the old data
    // available if any step fails — without it, a crash mid-migrate
    // would leave a half-built `bookmarks_new` alongside the lost
    // original.
    let migration = """
      BEGIN TRANSACTION;
      CREATE TABLE bookmarks_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          url TEXT,
          title TEXT NOT NULL DEFAULT '',
          created_at REAL NOT NULL,
          parent_id INTEGER REFERENCES bookmarks_new(id) ON DELETE CASCADE,
          is_folder INTEGER NOT NULL DEFAULT 0,
          sort_order INTEGER NOT NULL DEFAULT 0
      );
      INSERT INTO bookmarks_new (id, url, title, created_at, parent_id, is_folder, sort_order)
          SELECT id, url, title, created_at, NULL, 0,
                 (ROW_NUMBER() OVER (ORDER BY created_at)) - 1
          FROM bookmarks;
      DROP TABLE bookmarks;
      ALTER TABLE bookmarks_new RENAME TO bookmarks;
      CREATE INDEX idx_bookmarks_parent ON bookmarks(parent_id);
      CREATE UNIQUE INDEX idx_bookmarks_url_unique
          ON bookmarks(url) WHERE is_folder = 0 AND url IS NOT NULL;
      COMMIT;
      """
    if sqlite3_exec(db, migration, nil, nil, nil) != SQLITE_OK {
      logger.error(
        "[bookmarks/migrate] v1 rebuild failed: \(String(cString: sqlite3_errmsg(db)))")
      sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
      return false
    }
    return true
  }

  private func tableExists(_ name: String) -> Bool {
    guard let db else { return false }
    let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return false }
    defer { sqlite3_finalize(stmt) }
    _ = name.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    return sqlite3_step(stmt) == SQLITE_ROW
  }

  // MARK: - Observers

  /// Register a mutation observer. Fires after every add / remove /
  /// deleteAll. Returns a token; pass it to `removeListener(_:)` to
  /// unsubscribe. Listeners are invoked synchronously on the main
  /// actor right after the mutation's SQL statement commits.
  @discardableResult
  public func addListener(_ block: @escaping () -> Void) -> BookmarksListenerToken {
    let token = BookmarksListenerToken()
    listeners[token.id] = block
    return token
  }

  /// Unregister a previously added listener. No-op if the token is
  /// unknown (already removed or from a different manager).
  public func removeListener(_ token: BookmarksListenerToken) {
    listeners.removeValue(forKey: token.id)
  }

  private func fireListeners() {
    // Defer the fire while a batch is active so a bulk operation
    // (import, future restore-from-backup) collapses its N row
    // mutations into a single listener pass at the end.
    if batchDepth > 0 {
      pendingListenerFire = true
      return
    }
    // Snapshot the values before iterating so a listener that
    // registers or unregisters from within its callback doesn't
    // mutate the dictionary mid-iteration.
    for block in Array(listeners.values) { block() }
  }

  /// Run `block` with every contained mutation deferred onto a single
  /// SQLite transaction and a single listener notification at the end.
  /// SQLite's auto-commit mode fsyncs after every statement, so a
  /// 5000-row import without the wrapper takes thousands of fsyncs;
  /// `BEGIN`/`COMMIT` reduces that to one. Listener coalescing keeps
  /// the sidebar from reloading per row. Nested calls are flattened
  /// onto the outermost batch.
  @discardableResult
  public func performBatch<T>(_ block: () -> T) -> T {
    guard let db else { return block() }
    let wasOutermost = batchDepth == 0
    batchDepth += 1
    if wasOutermost, sqlite3_exec(db, "BEGIN", nil, nil, nil) != SQLITE_OK {
      logger.error(
        "[bookmarks/batch] BEGIN failed: \(String(cString: sqlite3_errmsg(db)))")
    }
    let result = block()
    batchDepth -= 1
    if batchDepth == 0 {
      if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
        logger.error(
          "[bookmarks/batch] COMMIT failed: \(String(cString: sqlite3_errmsg(db)))")
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
      }
      if pendingListenerFire {
        pendingListenerFire = false
        for block in Array(listeners.values) { block() }
      }
    }
    return result
  }

  // MARK: - Write

  /// Add a bookmark. If the URL already exists, updates the title in
  /// place; the existing row's folder placement and sibling order are
  /// preserved so re-bookmarking from the URL bar doesn't yank an
  /// entry out of the folder the user moved it into. New rows append
  /// at the end of their parent's sibling list.
  @discardableResult
  public func add(url: String, title: String, parentId: Int64? = nil) -> Bool {
    guard let db else { return false }
    let order = nextSortOrder(under: parentId)
    let sql = """
      INSERT INTO bookmarks (url, title, created_at, parent_id, is_folder, sort_order)
      VALUES (?, ?, ?, ?, 0, ?)
      ON CONFLICT(url) WHERE is_folder = 0 AND url IS NOT NULL
      DO UPDATE SET title = excluded.title
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else {
      logger.error("Failed to prepare add: \(String(cString: sqlite3_errmsg(db)))")
      return false
    }
    defer { sqlite3_finalize(stmt) }

    _ = url.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    _ = title.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
    sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
    bindOptionalInt64(stmt, index: 4, value: parentId)
    sqlite3_bind_int(stmt, 5, Int32(order))

    if sqlite3_step(stmt) != SQLITE_DONE {
      logger.error("Failed to add bookmark: \(String(cString: sqlite3_errmsg(db)))")
      return false
    }
    fireListeners()
    return true
  }

  /// Create a folder under `parentId` (`nil` = top level). Folders
  /// have no URL and act as containers for nested folders and
  /// bookmarks. Returns the new folder's id, or `nil` on failure.
  @discardableResult
  public func createFolder(title: String, parentId: Int64? = nil) -> Int64? {
    guard let db else { return nil }
    let order = nextSortOrder(under: parentId)
    let sql = """
      INSERT INTO bookmarks (url, title, created_at, parent_id, is_folder, sort_order)
      VALUES (NULL, ?, ?, ?, 1, ?)
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return nil }
    defer { sqlite3_finalize(stmt) }

    _ = title.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
    bindOptionalInt64(stmt, index: 3, value: parentId)
    sqlite3_bind_int(stmt, 4, Int32(order))

    guard sqlite3_step(stmt) == SQLITE_DONE else {
      logger.error(
        "Failed to create folder: \(String(cString: sqlite3_errmsg(db)))")
      return nil
    }
    let newId = sqlite3_last_insert_rowid(db)
    fireListeners()
    return newId
  }

  /// Move an entry under a new parent at the given position among
  /// its new siblings. The caller is responsible for choosing a
  /// reasonable `sortOrder` — typically `nextSortOrder(under:)` for
  /// "append" semantics, or the existing sibling's `sortOrder + 1`
  /// for "insert after this row". Returns `false` when the move
  /// would create a cycle (`newParentId` is the row itself or one
  /// of its descendants); the sidebar drag-drop checks for this in
  /// the UI layer too, but the store-level guard keeps any other
  /// caller (palette action, future CLI op) from building a broken
  /// tree.
  @discardableResult
  public func move(id: Int64, toParent newParentId: Int64?, sortOrder: Int) -> Bool {
    guard let db else { return false }
    if let target = newParentId, wouldCreateCycle(moving: id, into: target) {
      return false
    }
    let sql = "UPDATE bookmarks SET parent_id = ?, sort_order = ? WHERE id = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return false }
    defer { sqlite3_finalize(stmt) }
    bindOptionalInt64(stmt, index: 1, value: newParentId)
    sqlite3_bind_int(stmt, 2, Int32(sortOrder))
    sqlite3_bind_int64(stmt, 3, id)
    if sqlite3_step(stmt) != SQLITE_DONE {
      logger.error(
        "[bookmarks/move] step failed for id=\(id): \(String(cString: sqlite3_errmsg(db)))")
      return false
    }
    fireListeners()
    return true
  }

  /// True when moving `id` so that its new parent is `target` would
  /// build a cycle in the tree — i.e. `target` is `id` itself, or
  /// `target` already sits somewhere under `id`. Implemented as a
  /// recursive CTE so the walk runs entirely in SQLite (one query
  /// no matter how deep the subtree).
  private func wouldCreateCycle(moving id: Int64, into target: Int64) -> Bool {
    if target == id { return true }
    guard let db else { return false }
    let sql = """
      WITH RECURSIVE ancestors(id) AS (
          SELECT ?
          UNION ALL
          SELECT b.parent_id FROM bookmarks b
          JOIN ancestors a ON b.id = a.id
          WHERE b.parent_id IS NOT NULL
      )
      SELECT 1 FROM ancestors WHERE id = ? LIMIT 1
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt
    else { return false }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, target)
    sqlite3_bind_int64(stmt, 2, id)
    return sqlite3_step(stmt) == SQLITE_ROW
  }

  /// Rewrite every sibling's `parent_id` and `sort_order` under
  /// `parentId` to match `orderedIds` (`orderedIds[0]` ends up at
  /// `sort_order = 0`, etc.). Used by drag-drop where the new
  /// ordering is the source of truth and slotting via fractional
  /// indexes would require renumbering anyway. Ids not currently
  /// stored are silently skipped, so stale references from a
  /// concurrent reload don't error the whole transaction. Listeners
  /// fire once at the end.
  public func reorder(parentId: Int64?, orderedIds: [Int64]) {
    guard let db, !orderedIds.isEmpty else { return }
    // Bail early if the transaction can't even open. Without this
    // check the subsequent UPDATEs would auto-commit individually
    // and the final COMMIT would error on `no transaction is
    // active`, leaving a half-applied reorder in place but no
    // listener fire.
    guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
      logger.error(
        "[bookmarks/reorder] BEGIN failed: \(String(cString: sqlite3_errmsg(db)))")
      return
    }
    let sql = "UPDATE bookmarks SET parent_id = ?, sort_order = ? WHERE id = ?"
    for (idx, id) in orderedIds.enumerated() {
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
        let stmt
      else { continue }
      bindOptionalInt64(stmt, index: 1, value: parentId)
      sqlite3_bind_int(stmt, 2, Int32(idx))
      sqlite3_bind_int64(stmt, 3, id)
      sqlite3_step(stmt)
      sqlite3_finalize(stmt)
    }
    if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
      logger.error(
        "reorder commit failed: \(String(cString: sqlite3_errmsg(db)))")
      sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
      return
    }
    fireListeners()
  }

  /// Overwrite the `sort_order` of a single entry. Use this for fine
  /// grained drag-reorder operations where the parent doesn't change.
  public func setSortOrder(id: Int64, sortOrder: Int) {
    guard let db else { return }
    let sql = "UPDATE bookmarks SET sort_order = ? WHERE id = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int(stmt, 1, Int32(sortOrder))
    sqlite3_bind_int64(stmt, 2, id)
    if sqlite3_step(stmt) == SQLITE_DONE {
      fireListeners()
    }
  }

  /// Remove an entry by id. Folder rows cascade through `parent_id`'s
  /// `ON DELETE CASCADE` so removing a folder also removes every
  /// descendant in a single call.
  public func remove(id: Int64) {
    guard let db else { return }
    let sql = "DELETE FROM bookmarks WHERE id = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, id)
    sqlite3_step(stmt)
    fireListeners()
  }

  /// Edit a bookmark's title and URL. Returns `true` when the update
  /// commits, `false` when the target id doesn't exist or when the
  /// new URL collides with another bookmark (the partial UNIQUE
  /// index on `url` would throw otherwise). The UI layer uses the
  /// return value to surface an "URL already bookmarked" error.
  /// Fires listeners only on success so a rejected edit doesn't
  /// churn consumers. Bookmarks only — for folders use `setTitle`
  /// which leaves the (nil) url column alone.
  @discardableResult
  public func update(id: Int64, title: String, url: String) -> Bool {
    guard let db else { return false }
    let sql = "UPDATE bookmarks SET title = ?, url = ? WHERE id = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return false }
    defer { sqlite3_finalize(stmt) }

    _ = title.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    _ = url.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
    sqlite3_bind_int64(stmt, 3, id)

    let result = sqlite3_step(stmt)
    switch result {
    case SQLITE_DONE:
      break
    case SQLITE_CONSTRAINT:
      // UNIQUE violation on `url`: another row already holds the
      // requested URL. Distinct from other failures so callers
      // can surface "URL already bookmarked" without misleading
      // the user on transient errors (SQLITE_BUSY) or disk
      // issues (SQLITE_IOERR). No error log — this is a normal
      // user-facing condition, not a bug.
      return false
    default:
      logger.error(
        "Failed to update bookmark \(id): \(String(cString: sqlite3_errmsg(db)))"
      )
      return false
    }
    // `sqlite3_changes` reads the row count affected by the most
    // recent write. Zero means the id didn't exist — don't fire
    // listeners for a no-op so callers can distinguish "not found"
    // from "updated" via the return value.
    guard sqlite3_changes(db) > 0 else { return false }
    fireListeners()
    return true
  }

  /// Rename an entry without touching the URL. Used for folder
  /// rename (where there is no URL) and for any title-only edit on
  /// a bookmark that doesn't also change its destination. Returns
  /// `true` when the row exists and was rewritten, `false`
  /// otherwise. Listeners fire only on success so `setTitle` on a
  /// missing id is a silent no-op for consumers.
  @discardableResult
  public func setTitle(id: Int64, title: String) -> Bool {
    guard let db else { return false }
    let sql = "UPDATE bookmarks SET title = ? WHERE id = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return false }
    defer { sqlite3_finalize(stmt) }
    _ = title.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    sqlite3_bind_int64(stmt, 2, id)
    guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 else {
      return false
    }
    fireListeners()
    return true
  }

  /// Remove a bookmark by URL. Only targets bookmarks (`is_folder = 0`);
  /// folders carry no URL.
  public func remove(url: String) {
    guard let db else { return }
    let sql = "DELETE FROM bookmarks WHERE url = ? AND is_folder = 0"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return }
    defer { sqlite3_finalize(stmt) }
    _ = url.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    sqlite3_step(stmt)
    fireListeners()
  }

  // MARK: - Read

  /// Check whether a URL is bookmarked anywhere in the tree.
  public func isBookmarked(url: String) -> Bool {
    guard let db else { return false }
    let sql = "SELECT 1 FROM bookmarks WHERE url = ? AND is_folder = 0 LIMIT 1"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return false }
    defer { sqlite3_finalize(stmt) }
    _ = url.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    return sqlite3_step(stmt) == SQLITE_ROW
  }

  /// Get every entry — folders and bookmarks — in the tree. Order is
  /// "most recently created first" so the flat callers (URL bar
  /// suggest, palette `Open Bookmarks`) keep the recency ranking
  /// they used to expect from a flat `created_at DESC` table. UI
  /// consumers that care about hierarchy use `children(of:)`.
  public func all() -> [Entry] {
    query(
      sql: entryColumns + "FROM bookmarks ORDER BY created_at DESC",
      bind: { _ in })
  }

  /// Direct children of `parentId` (`nil` = top level) ordered by
  /// `sort_order` ascending. Used by the sidebar's outline view to
  /// populate one node at a time without walking the whole tree.
  public func children(of parentId: Int64?) -> [Entry] {
    let predicate = parentId == nil ? "parent_id IS NULL" : "parent_id = ?"
    return query(
      sql: entryColumns + "FROM bookmarks WHERE \(predicate) ORDER BY sort_order ASC, id ASC",
      bind: { stmt in
        if let parentId { sqlite3_bind_int64(stmt, 1, parentId) }
      })
  }

  /// Search bookmarks (not folders) by URL or title substring,
  /// case-insensitive. Folders are excluded so a global search bar
  /// surfaces destinations rather than containers; folder-by-name
  /// search is a separate concern handled in the sidebar UI.
  public func search(query searchText: String, limit: Int = 50) -> [Entry] {
    let escaped =
      searchText
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    let pattern = "%\(escaped)%"
    return query(
      sql:
        entryColumns + """
          FROM bookmarks
          WHERE is_folder = 0
            AND (url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')
          ORDER BY created_at DESC LIMIT ?
          """,
      bind: { stmt in
        _ = pattern.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        _ = pattern.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 3, Int32(limit))
      }
    )
  }

  /// Delete every entry. Hierarchy goes with it.
  public func deleteAll() {
    guard let db else { return }
    sqlite3_exec(db, "DELETE FROM bookmarks", nil, nil, nil)
    fireListeners()
  }

  // MARK: - Internal

  /// `MAX(sort_order) + 1` for the requested parent, or `0` when the
  /// parent has no children yet. New inserts append at the bottom of
  /// their sibling list.
  private func nextSortOrder(under parentId: Int64?) -> Int {
    guard let db else { return 0 }
    let predicate = parentId == nil ? "parent_id IS NULL" : "parent_id = ?"
    let sql = "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM bookmarks WHERE \(predicate)"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return 0 }
    defer { sqlite3_finalize(stmt) }
    if let parentId { sqlite3_bind_int64(stmt, 1, parentId) }
    return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
  }

  private func bindOptionalInt64(_ stmt: OpaquePointer, index: Int32, value: Int64?) {
    if let value {
      sqlite3_bind_int64(stmt, index, value)
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }

  /// Shared column list. Pulling it out keeps the column index
  /// numbers below in lockstep with the SELECT projection. Includes
  /// a trailing space so callers can concatenate the rest of the
  /// statement without worrying about token-joining.
  private let entryColumns =
    "SELECT id, url, title, created_at, parent_id, is_folder, sort_order "

  private func query(sql: String, bind: (OpaquePointer) -> Void) -> [Entry] {
    guard let db else { return [] }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else {
      logger.error(
        "query prepare failed: \(String(cString: sqlite3_errmsg(db))) sql=\(sql, privacy: .public)"
      )
      return []
    }
    defer { sqlite3_finalize(stmt) }

    bind(stmt)

    var entries: [Entry] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let id = sqlite3_column_int64(stmt, 0)
      let url: String? =
        sqlite3_column_type(stmt, 1) == SQLITE_NULL
        ? nil
        : sqlite3_column_text(stmt, 1).map { String(cString: $0) }
      guard let titlePtr = sqlite3_column_text(stmt, 2) else { continue }
      let title = String(cString: titlePtr)
      let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
      let parentId: Int64? =
        sqlite3_column_type(stmt, 4) == SQLITE_NULL
        ? nil
        : sqlite3_column_int64(stmt, 4)
      let isFolder = sqlite3_column_int(stmt, 5) != 0
      let sortOrder = Int(sqlite3_column_int(stmt, 6))
      entries.append(
        Entry(
          id: id, url: url, title: title, createdAt: createdAt,
          parentId: parentId, isFolder: isFolder, sortOrder: sortOrder))
    }
    return entries
  }
}
