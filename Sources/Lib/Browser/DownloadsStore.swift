import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "DownloadsStore")

/// Persistent download records stored in SQLite (`~/.config/e05/downloads.db`).
///
/// Mirrors the structure of `BrowsingHistory` / `Bookmarks` (C API +
/// `@MainActor` + in-memory mode for tests). Rows cover both active and
/// finished downloads; state (see `DownloadState`) distinguishes them.
@MainActor
public final class DownloadsStore {
    // nonisolated(unsafe): accessed in deinit which is nonisolated
    nonisolated(unsafe) private var db: OpaquePointer?

    public struct Entry: Equatable {
        public let id: Int64
        public let url: String
        public let filename: String
        public let destination: String
        public let state: Int
        public let bytesWritten: Int64
        public let totalBytes: Int64
        public let startedAt: Date
        public let completedAt: Date?
        public let errorMessage: String?
    }

    // MARK: - Lifecycle

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
        return configDir.appendingPathComponent("downloads.db").path
    }

    private func openDatabase(inMemory: Bool) {
        let path = inMemory ? ":memory:" : Self.dbPath
        if sqlite3_open(path, &db) != SQLITE_OK {
            logger.error("Failed to open downloads database at \(path)")
            db = nil
        }
    }

    private func createTable() {
        guard let db else { return }
        let sql = """
            CREATE TABLE IF NOT EXISTS downloads (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL,
                filename TEXT NOT NULL,
                destination TEXT NOT NULL,
                state INTEGER NOT NULL,
                bytes_written INTEGER NOT NULL DEFAULT 0,
                total_bytes INTEGER NOT NULL DEFAULT 0,
                started_at REAL NOT NULL,
                completed_at REAL,
                error_message TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_downloads_started_at ON downloads(started_at DESC);
            """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            logger.error("Failed to create downloads table: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    // MARK: - Write

    @discardableResult
    public func insert(
        url: String, filename: String, destination: String, state: Int
    ) -> Int64 {
        guard let db else { return -1 }
        let sql = """
            INSERT INTO downloads (url, filename, destination, state, started_at)
            VALUES (?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return -1 }
        defer { sqlite3_finalize(stmt) }

        _ = url.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        _ = filename.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        _ = destination.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(stmt, 4, Int32(state))
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            logger.error("Failed to insert download: \(String(cString: sqlite3_errmsg(db)))")
            return -1
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Update filename + destination once WKDownload resolves the final path.
    public func updateFilename(id: Int64, filename: String, destination: String) {
        guard let db else { return }
        let sql = "UPDATE downloads SET filename = ?, destination = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        _ = filename.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        _ = destination.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_step(stmt)
    }

    public func updateProgress(id: Int64, bytesWritten: Int64, totalBytes: Int64) {
        guard let db else { return }
        let sql = "UPDATE downloads SET bytes_written = ?, total_bytes = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, bytesWritten)
        sqlite3_bind_int64(stmt, 2, totalBytes)
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_step(stmt)
    }

    public func updateState(
        id: Int64, state: Int, completedAt: Date?, errorMessage: String?
    ) {
        guard let db else { return }
        let sql = """
            UPDATE downloads SET state = ?, completed_at = ?, error_message = ?
            WHERE id = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(state))
        if let completedAt {
            sqlite3_bind_double(stmt, 2, completedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let errorMessage {
            _ = errorMessage.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_int64(stmt, 4, id)
        sqlite3_step(stmt)
    }

    public func delete(id: Int64) {
        guard let db else { return }
        let sql = "DELETE FROM downloads WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    /// Delete all non-active rows (completed, failed, cancelled).
    /// State 0 (`.downloading`) is preserved.
    public func deleteCompleted() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM downloads WHERE state != 0", nil, nil, nil)
    }

    public func deleteAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM downloads", nil, nil, nil)
    }

    // MARK: - Read

    /// Fetch all downloads, most recent first.
    public func all() -> [Entry] {
        query(
            sql: """
                SELECT id, url, filename, destination, state, bytes_written,
                       total_bytes, started_at, completed_at, error_message
                FROM downloads
                ORDER BY started_at DESC
                """,
            bind: { _ in }
        )
    }

    // MARK: - Internal

    private func query(sql: String, bind: (OpaquePointer) -> Void) -> [Entry] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        bind(stmt)

        var entries: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            guard let urlPtr = sqlite3_column_text(stmt, 1),
                  let filenamePtr = sqlite3_column_text(stmt, 2),
                  let destPtr = sqlite3_column_text(stmt, 3) else { continue }
            let url = String(cString: urlPtr)
            let filename = String(cString: filenamePtr)
            let destination = String(cString: destPtr)
            let state = Int(sqlite3_column_int(stmt, 4))
            let bytesWritten = sqlite3_column_int64(stmt, 5)
            let totalBytes = sqlite3_column_int64(stmt, 6)
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            let completedAt: Date? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            let errorMessage: String? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
                ? nil
                : sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) }
            entries.append(Entry(
                id: id, url: url, filename: filename, destination: destination,
                state: state, bytesWritten: bytesWritten, totalBytes: totalBytes,
                startedAt: startedAt, completedAt: completedAt,
                errorMessage: errorMessage
            ))
        }
        return entries
    }
}
