import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "InputHistory")

/// Learns which destination the user picks for a given URL-bar input so
/// the suggestion list can promote it next time the same text is typed
/// — the idea behind Chromium's ShortcutsProvider and Firefox's
/// `moz_inputhistory`. Each selection reinforces an `(input, url)` pair
/// with an asymptotic counter; a daily decay lets stale associations
/// fade out.
///
/// Stored at `~/Library/Application Support/<bundle-id>/input-history.db`
/// (via `E05Paths.default`). Tests pass `inMemory: true`.
@MainActor
public final class InputHistoryStore {
  /// Process-wide singleton, paired with `BrowsingHistory.shared` at
  /// the URL bar. Tests construct `inMemory: true` instances directly.
  public static let shared = InputHistoryStore()

  // nonisolated(unsafe): accessed in deinit which is nonisolated.
  nonisolated(unsafe) private var db: OpaquePointer?

  /// Ranking boost floor for a destination whose learned input the
  /// current query is a prefix of. Sits in the frecency band so a
  /// learned page leads without an exact match's authority.
  static let prefixBoostBase = 400
  /// Ranking boost floor for an exact input match. Set above the
  /// match-quality + frecency ceiling so "I always pick this for this
  /// text" wins outright — Firefox's "infinite frecency" lane.
  static let exactBoostBase = 800
  /// Per-use-count increment layered on the base so a more-reinforced
  /// association edges out a weaker one at the same tier.
  static let useCountWeight = 10

  public convenience init(inMemory: Bool = false) {
    if inMemory {
      self.init(databasePath: ":memory:")
      return
    }
    self.init(databasePath: E05Paths.default.databasePath(E05Filenames.inputHistory))
  }

  init(databasePath: String) {
    openDatabase(at: databasePath)
    createTable()
  }

  deinit {
    if let db { sqlite3_close(db) }
  }

  private func openDatabase(at path: String) {
    if sqlite3_open(path, &db) != SQLITE_OK {
      logger.error("Failed to open input-history database at \(path)")
      db = nil
    }
  }

  private func createTable() {
    guard let db else { return }
    let sql = """
      CREATE TABLE IF NOT EXISTS input_history (
          input TEXT NOT NULL,
          url TEXT NOT NULL,
          use_count REAL NOT NULL DEFAULT 1.0,
          last_used REAL NOT NULL,
          PRIMARY KEY (input, url)
      );
      """
    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
      logger.error(
        "Failed to create input_history table: \(String(cString: sqlite3_errmsg(db)))")
    }
  }

  /// Normalised lookup key: trimmed + lowercased so "  KAW " and "kaw"
  /// reinforce and match the same association.
  private static func normalize(_ input: String) -> String {
    input.trimmingCharacters(in: .whitespaces).lowercased()
  }

  /// Reinforce the `(input → url)` association after the user commits a
  /// suggestion. The counter is asymptotic — `use_count = *0.9 + 1`
  /// tops out near 10 — so frequent picks saturate rather than running
  /// away. No-op for an empty input or url.
  public func record(input: String, url: String) {
    guard let db else { return }
    let key = Self.normalize(input)
    guard !key.isEmpty, !url.isEmpty else { return }
    let sql = """
      INSERT INTO input_history (input, url, use_count, last_used)
      VALUES (?, ?, 1.0, ?)
      ON CONFLICT(input, url) DO UPDATE SET
          use_count = use_count * 0.9 + 1.0,
          last_used = excluded.last_used
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
    defer { sqlite3_finalize(stmt) }
    _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
    _ = url.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
    sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
    if sqlite3_step(stmt) != SQLITE_DONE {
      logger.error("Failed to record input history: \(String(cString: sqlite3_errmsg(db)))")
    }
  }

  /// Ranking boosts (keyed by url) for destinations the user has
  /// committed for inputs the current `query` is a prefix of — i.e.
  /// typing partway toward something selected before. Per url the
  /// strongest matching association wins; an exact input match outranks
  /// a prefix-only one. Empty for an empty query or no learned match.
  public func boosts(forQueryPrefix query: String) -> [String: Int] {
    guard let db else { return [:] }
    let key = Self.normalize(query)
    guard !key.isEmpty else { return [:] }
    // Escape LIKE metacharacters in the user's text, then anchor a
    // prefix match: stored inputs that begin with `key`.
    let escaped =
      key
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    let pattern = escaped + "%"
    let sql = "SELECT input, url, use_count FROM input_history WHERE input LIKE ? ESCAPE '\\'"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
    defer { sqlite3_finalize(stmt) }
    _ = pattern.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }

    var best: [String: (count: Double, exact: Bool)] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let inputPtr = sqlite3_column_text(stmt, 0),
        let urlPtr = sqlite3_column_text(stmt, 1)
      else { continue }
      let input = String(cString: inputPtr)
      let url = String(cString: urlPtr)
      let count = sqlite3_column_double(stmt, 2)
      let exact = (input == key)
      if let cur = best[url] {
        best[url] = (max(cur.count, count), cur.exact || exact)
      } else {
        best[url] = (count, exact)
      }
    }
    return best.mapValues { entry in
      let base = entry.exact ? Self.exactBoostBase : Self.prefixBoostBase
      return base + Int(entry.count * Double(Self.useCountWeight))
    }
  }

  /// Decay every association: `use_count *= 0.975`, pruning rows that
  /// fall below 0.1. Called once per launch-day (gated in AppDelegate),
  /// so a row reaches the prune threshold after ~90 launch-days unused —
  /// calendar time depends on how often the app is started.
  public func decay() {
    guard let db else { return }
    if sqlite3_exec(db, "UPDATE input_history SET use_count = use_count * 0.975", nil, nil, nil)
      != SQLITE_OK
    {
      logger.error("Failed to decay input history: \(String(cString: sqlite3_errmsg(db)))")
      return
    }
    if sqlite3_exec(db, "DELETE FROM input_history WHERE use_count < 0.1", nil, nil, nil)
      != SQLITE_OK
    {
      logger.error(
        "Failed to prune decayed input history: \(String(cString: sqlite3_errmsg(db)))")
    }
  }
}
