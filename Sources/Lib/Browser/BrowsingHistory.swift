import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "BrowsingHistory")

/// Opaque handle returned by `BrowsingHistory.addListener(_:)`. Pass it
/// back to `removeListener(_:)` to unregister a callback.
public final class BrowsingHistoryListenerToken {
  fileprivate let id = UUID()
  fileprivate init() {}
}

/// Persistent browsing history stored in SQLite at
/// `~/Library/Application Support/<bundle-id>/history.db` (resolved
/// through `E05Paths.default.dataDir`). Rows are id-keyed (`AUTOINCREMENT`)
/// rather than host-keyed or path-keyed — the same URL can be
/// visited many times and each visit gets its own row id, while
/// per-URL aggregation lives in `AggregatedEntry`.
///
/// Mutation observers can register via `addListener(_:)` so UI (the
/// sidebar history list, future status indicators) refreshes when
/// recordVisit / updateTitle / delete / deleteAll happens anywhere in
/// the process without having to poll.
@MainActor
public final class BrowsingHistory {
  // nonisolated(unsafe): accessed in deinit which is nonisolated
  nonisolated(unsafe) private var db: OpaquePointer?

  /// In-memory cache to avoid DB query on every recordVisit call.
  private var lastRecordedURL: String?

  /// Registered mutation observers, keyed by token id.
  private var listeners: [UUID: () -> Void] = [:]

  public struct Entry: Equatable {
    public let id: Int64
    public let url: String
    public let title: String
    public let visitedAt: Date
  }

  /// Per-URL aggregated row used by URL-bar suggestion ranking.
  /// `mostRecent` returns one row per visit-deduplicated URL; this
  /// adds the visit count so callers can compute frecency on top.
  public struct AggregatedEntry: Equatable {
    public let url: String
    public let title: String
    public let visits: Int
    public let lastVisit: Date
  }

  // MARK: - Lifecycle

  /// Create a history instance pointing at the production SQLite
  /// file under `~/Library/Application Support/<bundle-id>/history.db`
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
    self.init(databasePath: E05Paths.default.databasePath(E05Filenames.history))
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
    createTable()
    // Warm up cache
    lastRecordedURL = mostRecent(limit: 1).first?.url
  }

  deinit {
    if let db {
      sqlite3_close(db)
    }
  }

  // MARK: - Database Setup

  private func openDatabase(at path: String) {
    if sqlite3_open(path, &db) != SQLITE_OK {
      logger.error("Failed to open history database at \(path)")
      db = nil
    }
  }

  // MARK: - Observers

  /// Register a mutation observer. Fires after every successful
  /// recordVisit (dedup skips do not fire), updateTitle, delete, and
  /// deleteAll. Returns a token; pass it to `removeListener(_:)` to
  /// unsubscribe. Listeners are invoked synchronously on the main
  /// actor right after the mutation's SQL statement commits.
  @discardableResult
  public func addListener(_ block: @escaping () -> Void) -> BrowsingHistoryListenerToken {
    let token = BrowsingHistoryListenerToken()
    listeners[token.id] = block
    return token
  }

  /// Unregister a previously added listener. No-op if the token is
  /// unknown (already removed or from a different manager).
  public func removeListener(_ token: BrowsingHistoryListenerToken) {
    listeners.removeValue(forKey: token.id)
  }

  private func fireListeners() {
    // Snapshot the values before iterating so a listener that
    // registers or unregisters from within its callback doesn't
    // mutate the dictionary mid-iteration.
    for block in Array(listeners.values) { block() }
  }

  private func createTable() {
    guard let db else { return }
    let sql = """
      CREATE TABLE IF NOT EXISTS history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          url TEXT NOT NULL,
          title TEXT NOT NULL DEFAULT '',
          visited_at REAL NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_history_visited_at ON history(visited_at DESC);
      CREATE INDEX IF NOT EXISTS idx_history_url ON history(url);
      """
    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
      logger.error("Failed to create history table: \(String(cString: sqlite3_errmsg(db)))")
    }
  }

  // MARK: - Write

  /// Record a page visit. Deduplicates consecutive visits to the same URL.
  public func recordVisit(url: String, title: String) {
    guard let db else { return }
    // Skip consecutive duplicates (KVO noise avoidance)
    if lastRecordedURL == url { return }

    let sql = "INSERT INTO history (url, title, visited_at) VALUES (?, ?, ?)"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return }
    defer { sqlite3_finalize(stmt) }

    _ = url.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    _ = title.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
    sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)

    if sqlite3_step(stmt) != SQLITE_DONE {
      logger.error("Failed to insert history: \(String(cString: sqlite3_errmsg(db)))")
    } else {
      lastRecordedURL = url
      fireListeners()
    }
  }

  /// Update the title of the most recent visit to a given URL.
  public func updateTitle(url: String, title: String) {
    guard let db, !title.isEmpty else { return }
    let sql =
      "UPDATE history SET title = ? WHERE id = (SELECT id FROM history WHERE url = ? ORDER BY visited_at DESC LIMIT 1)"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return }
    defer { sqlite3_finalize(stmt) }

    _ = title.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    _ = url.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
    sqlite3_step(stmt)
    fireListeners()
  }

  // MARK: - Read

  /// Default cap on the aggregated-history pool the URL bar walks
  /// through `Suggestion.rank`. Sized large enough that even
  /// frequently-visited tail entries reach the rank step, small
  /// enough that the per-keystroke `O(N × |query|)` substring scan
  /// stays under the ~150ms debounce budget.
  public static let defaultAggregatedLimit = 500

  /// Get the most recent history entries deduplicated by URL,
  /// joined with the URL's total visit count and last-visit
  /// timestamp. The URL bar feeds these into a frecency bonus on
  /// top of the substring-match score.
  public func mostRecentAggregated(limit: Int = defaultAggregatedLimit) -> [AggregatedEntry] {
    guard let db else { return [] }
    let sql = """
      SELECT h.url, h.title, agg.visits, agg.last_visit
      FROM history h
      INNER JOIN (
          SELECT url, COUNT(*) AS visits, MAX(visited_at) AS last_visit
          FROM history GROUP BY url
      ) agg ON h.url = agg.url AND h.visited_at = agg.last_visit
      ORDER BY agg.last_visit DESC LIMIT ?
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int(stmt, 1, Int32(limit))

    var entries: [AggregatedEntry] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let urlPtr = sqlite3_column_text(stmt, 0),
        let titlePtr = sqlite3_column_text(stmt, 1)
      else { continue }
      let url = String(cString: urlPtr)
      let title = String(cString: titlePtr)
      let visits = Int(sqlite3_column_int(stmt, 2))
      let lastVisit = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
      entries.append(
        AggregatedEntry(url: url, title: title, visits: visits, lastVisit: lastVisit)
      )
    }
    return entries
  }

  /// Get the most recent history entries, deduplicated by URL (keeps latest visit).
  /// Note: `id` corresponds to the row with the latest `visited_at` per URL.
  public func mostRecent(limit: Int = 100) -> [Entry] {
    query(
      sql: """
        SELECT h.id, h.url, h.title, h.visited_at FROM history h
        INNER JOIN (
            SELECT url, MAX(visited_at) AS max_visited FROM history GROUP BY url
        ) latest ON h.url = latest.url AND h.visited_at = latest.max_visited
        ORDER BY h.visited_at DESC LIMIT ?
        """,
      bind: { sqlite3_bind_int($0, 1, Int32(limit)) })
  }

  /// Search history by URL or title substring (case-insensitive).
  public func search(query searchText: String, limit: Int = 50) -> [Entry] {
    let escaped =
      searchText
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    let pattern = "%\(escaped)%"
    return query(
      sql: """
        SELECT id, url, title, visited_at FROM history
        WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
        ORDER BY visited_at DESC LIMIT ?
        """,
      bind: { stmt in
        _ = pattern.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        _ = pattern.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 3, Int32(limit))
      }
    )
  }

  /// Delete a single history entry.
  public func delete(id: Int64) {
    guard let db else { return }
    let sql = "DELETE FROM history WHERE id = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
      let stmt
    else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, id)
    sqlite3_step(stmt)
    fireListeners()
  }

  /// Delete all history.
  public func deleteAll() {
    guard let db else { return }
    sqlite3_exec(db, "DELETE FROM history", nil, nil, nil)
    lastRecordedURL = nil
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
      // NOT NULL constraint guarantees non-nil, but guard defensively
      guard let urlPtr = sqlite3_column_text(stmt, 1),
        let titlePtr = sqlite3_column_text(stmt, 2)
      else { continue }
      let url = String(cString: urlPtr)
      let title = String(cString: titlePtr)
      let visitedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
      entries.append(Entry(id: id, url: url, title: title, visitedAt: visitedAt))
    }
    return entries
  }
}
