import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "GhosttyConfigFileStore")

/// Reads and writes the user-editable `~/.config/e05/config.ghostty`
/// that the libghostty runtime loads at launch. The Terminal settings
/// tab uses this store to surface the live text and persist edits;
/// the runtime keeps using `ghostty_config_load_file` directly so a
/// future CLI / IPC writer that bypasses this store still drives the
/// same on-disk file.
///
/// Singleton so every consumer observes the same
/// `didChangeNotification` post on a successful write. External edits
/// (the user editing the file in another editor) are not auto-detected
/// here — the Settings UI offers a "Reload from disk" affordance for
/// that path.
@MainActor
public final class GhosttyConfigFileStore {
  public static let shared = GhosttyConfigFileStore()

  /// Fired after a successful ``write(_:)``. The object is the store
  /// instance; no userInfo. Subscribers re-read through ``read()`` to
  /// pick up the new content.
  public static let didChangeNotification = Notification.Name(
    "E05GhosttyConfigFileStoreDidChange"
  )

  /// Absolute on-disk URL of the config file. Exposed so consumers
  /// can hand it to `NSWorkspace.activateFileViewerSelecting`
  /// (Reveal in Finder) without re-deriving the path.
  public let url: URL

  private init() {
    self.url = E05Paths.default.configFile(E05Filenames.terminalConfig)
  }

  /// Read the on-disk text. A missing file returns an empty string so
  /// a fresh install sees a clean editor surface; an unreadable file
  /// (permission denied / IO error) also returns empty after logging
  /// the failure so the UI can keep working even if the user has
  /// locked themselves out of the path.
  public func read() -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return ""
    }
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch {
      logger.error(
        "[ghostty/config-file-store] read failed: \(error.localizedDescription, privacy: .public)"
      )
      return ""
    }
  }

  /// Write `text` atomically. Creates the parent directory if absent
  /// (a fresh install never had `~/.config/e05/` before today). Fires
  /// ``didChangeNotification`` only on success so listeners do not
  /// rebuild from a half-written file.
  public func write(_ text: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }
}
