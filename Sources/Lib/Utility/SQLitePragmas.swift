import SQLite3

/// Enable WAL journaling on `db`, and switch to `synchronous = NORMAL`
/// only when WAL actually took.
///
/// WAL + NORMAL trades a full fsync per commit for far cheaper writes;
/// the residual durability window (a power loss can drop the last
/// commit) is fine for the app's local, non-critical stores. But
/// `NORMAL` is only crash-safe *under WAL* — paired with a rollback
/// journal it can corrupt the file on power loss — so if `journal_mode`
/// doesn't come back `wal` (e.g. a filesystem that can't support it),
/// the default `FULL` is left in place. On the app's `~/Library`
/// (local APFS) WAL always succeeds; the guard is defence in depth.
///
/// Shared by the SQLite-backed stores (bookmarks / history /
/// input-history / downloads) so the mode switch stays consistent.
func enableWALWithNormalSync(_ db: OpaquePointer) {
  var walActive = false
  var stmt: OpaquePointer?
  if sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &stmt, nil) == SQLITE_OK {
    if sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) {
      walActive = String(cString: cString).lowercased() == "wal"
    }
  }
  sqlite3_finalize(stmt)
  if walActive {
    sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
  }
}
