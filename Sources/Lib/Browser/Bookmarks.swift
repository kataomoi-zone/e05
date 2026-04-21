import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "Bookmarks")

/// Opaque handle returned by `Bookmarks.addListener(_:)`. Pass it back
/// to `removeListener(_:)` to unregister a callback.
public final class BookmarksListenerToken {
  fileprivate let id = UUID()
  fileprivate init() {}
}

/// Persistent bookmarks stored in SQLite (~/.config/e05/bookmarks.db).
///
/// Mutation observers can register via `addListener(_:)` so UI (the
/// sidebar bookmarks list, future status indicators) refreshes when
/// add / remove / deleteAll happens anywhere in the process without
/// having to poll.
@MainActor
public final class Bookmarks {
  // nonisolated(unsafe): accessed in deinit which is nonisolated
  nonisolated(unsafe) private var db: OpaquePointer?

  /// Registered mutation observers, keyed by token id.
  private var listeners: [UUID: () -> Void] = [:]

  public struct Entry: Equatable {
    public let id: Int64
    public let url: String
    public let title: String
    public let createdAt: Date
  }

  // MARK: - Lifecycle

  /// Create a bookmarks instance. Pass `inMemory: true` for testing.
  public init(inMemory: Bool = false) {
    openDatabase(inMemory: inMemory)
    createTable()
  }

  deinit {
    if let db {
      sqlite3_close(db)
    }
  }

  // MARK: - Database Setup

  private static var dbPath: String {
    let configDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/e05")
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    return configDir.appendingPathComponent("bookmarks.db").path
  }

  private func openDatabase(inMemory: Bool) {
    let path = inMemory ? ":memory:" : Self.dbPath
    if sqlite3_open(path, &db) != SQLITE_OK {
      logger.error("Failed to open bookmarks database at \(path)")
      db = nil
    }
  }

  private func createTable() {
    guard let db else { return }
    let sql = """
      CREATE TABLE IF NOT EXISTS bookmarks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          url TEXT NOT NULL UNIQUE,
          title TEXT NOT NULL DEFAULT '',
          created_at REAL NOT NULL
      );
      """
    // No explicit url index needed — UNIQUE constraint creates one implicitly
    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
      logger.error("Failed to create bookmarks table: \(String(cString: sqlite3_errmsg(db)))")
    }
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
    // Snapshot the values before iterating so a listener that
    // registers or unregisters from within its callback doesn't
    // mutate the dictionary mid-iteration.
    for block in Array(listeners.values) { block() }
  }

  // MARK: - Write

  /// Add a bookmark. If the URL already exists, updates the title.
  @discardableResult
  public func add(url: String, title: String) -> Bool {
    guard let db else { return false }
    let sql =
      "INSERT INTO bookmarks (url, title, created_at) VALUES (?, ?, ?) ON CONFLICT(url) DO UPDATE SET title = excluded.title"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return false }
    defer { sqlite3_finalize(stmt) }

    _ = url.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    _ = title.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
    sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)

    if sqlite3_step(stmt) != SQLITE_DONE {
      logger.error("Failed to add bookmark: \(String(cString: sqlite3_errmsg(db)))")
      return false
    }
    fireListeners()
    return true
  }

  /// Remove a bookmark by ID.
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

  /// Edit an existing bookmark's title and URL. Returns `true` when
  /// the update commits, `false` when the target id doesn't exist or
  /// when the new URL collides with another row (the UNIQUE
  /// constraint on `url` would throw otherwise). The UI layer uses
  /// the return value to surface an "URL already bookmarked" error.
  /// Fires listeners only on success so a rejected edit doesn't
  /// churn consumers.
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

  /// Remove a bookmark by URL.
  public func remove(url: String) {
    guard let db else { return }
    let sql = "DELETE FROM bookmarks WHERE url = ?"
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

  /// Check if a URL is bookmarked.
  public func isBookmarked(url: String) -> Bool {
    guard let db else { return false }
    let sql = "SELECT 1 FROM bookmarks WHERE url = ? LIMIT 1"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return false }
    defer { sqlite3_finalize(stmt) }
    _ = url.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    return sqlite3_step(stmt) == SQLITE_ROW
  }

  /// Get all bookmarks, most recent first.
  public func all() -> [Entry] {
    query(
      sql: "SELECT id, url, title, created_at FROM bookmarks ORDER BY created_at DESC",
      bind: { _ in })
  }

  /// Search bookmarks by URL or title substring (case-insensitive).
  public func search(query searchText: String, limit: Int = 50) -> [Entry] {
    let escaped =
      searchText
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    let pattern = "%\(escaped)%"
    return query(
      sql: """
        SELECT id, url, title, created_at FROM bookmarks
        WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
        ORDER BY created_at DESC LIMIT ?
        """,
      bind: { stmt in
        _ = pattern.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        _ = pattern.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 3, Int32(limit))
      }
    )
  }

  /// Delete all bookmarks.
  public func deleteAll() {
    guard let db else { return }
    sqlite3_exec(db, "DELETE FROM bookmarks", nil, nil, nil)
    fireListeners()
  }

  // MARK: - Internal

  private func query(sql: String, bind: (OpaquePointer) -> Void) -> [Entry] {
    guard let db else { return [] }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return [] }
    defer { sqlite3_finalize(stmt) }

    bind(stmt)

    var entries: [Entry] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let id = sqlite3_column_int64(stmt, 0)
      guard let urlPtr = sqlite3_column_text(stmt, 1),
        let titlePtr = sqlite3_column_text(stmt, 2)
      else { continue }
      let url = String(cString: urlPtr)
      let title = String(cString: titlePtr)
      let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
      entries.append(Entry(id: id, url: url, title: title, createdAt: createdAt))
    }
    return entries
  }
}
