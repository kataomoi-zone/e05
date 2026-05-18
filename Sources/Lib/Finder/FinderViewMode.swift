import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FinderModeStore")

/// Visual presentation mode for a finder pane.
public enum FinderViewMode: String, Codable, Sendable {
  case list
  case icon
}

/// Per-directory `FinderViewMode` cache mirrored to
/// `~/Library/Application Support/<bundle-id>/finder-modes.json`
/// (resolved through `E05Paths.default.dataDir`) so revisiting a
/// folder restores the mode the user last left it in. Entries are
/// **path-keyed** rather than host-keyed (the user's mental model
/// here is per-folder, not per-origin), so a site-settings UI that
/// iterates host-keyed stores skips this one. The on-disk shape is a
/// flat `[absolutePath: FinderViewMode]` dict — Codable
/// auto-synthesis drives the JSON layer, and `setMode` writes the
/// dict back atomically (`Data.WritingOptions.atomic`) so a crash
/// mid-write can't truncate the previous state into a half-valid
/// file.
///
/// `.list` is the implicit default for unseen directories. `setMode`
/// prunes `.list` entries from the dict instead of writing them so
/// the file stays small as the user explores the filesystem; the
/// reader returns `.list` for any missing key, so reverting through
/// either an explicit ⌘1 or pruning at save time round-trips to the
/// same observable state.
@MainActor
public final class FinderModeStore {
  /// Process-wide store. Open finder panes share this instance so
  /// every ⌘1 / ⌘2 toggle is visible to the others without each
  /// pane keeping its own dict and racing with the file.
  public static let shared = FinderModeStore()

  /// Posted after `setMode` mutates the dict. Object is left nil —
  /// open finder panes re-read `mode(for:)` against their own
  /// `currentURL`, so a coarse "something changed" signal is enough.
  public static let didChangeNotification = Notification.Name(
    "FinderModeStoreDidChange")

  /// Backing file URL, or `nil` for the in-memory test mode that
  /// skips filesystem IO entirely.
  private let storeURL: URL?

  private var modes: [String: FinderViewMode]

  /// Production initialiser reads
  /// `~/Library/Application Support/<bundle-id>/finder-modes.json` via
  /// `E05Paths.default.dataDir`. Pass `inMemory: true` from tests to
  /// keep the dict ephemeral and avoid touching the user's real data
  /// directory.
  public convenience init(inMemory: Bool = false) {
    if inMemory {
      self.init(storeURL: nil)
      return
    }
    self.init(storeURL: E05Paths.default.dataFile(E05Filenames.finderModes))
  }

  /// Internal initialiser that drives the same on-disk format against
  /// an arbitrary file URL. Tests use this to exercise `save` / `load`
  /// end-to-end against a temp file without touching the user's real
  /// data directory; production code reaches it via the public
  /// `init(inMemory:)` convenience. `nil` keeps the dict ephemeral.
  init(storeURL: URL?) {
    self.storeURL = storeURL
    self.modes = (storeURL.flatMap { Self.load(at: $0) }) ?? [:]
  }

  // MARK: - Read

  /// Mode previously persisted for `url`, or `.list` when the
  /// directory has never been switched. The dict key is the absolute
  /// POSIX path with percent-encoding decoded so URL forms that
  /// differ only in their encoding share a single entry.
  public func mode(for url: URL) -> FinderViewMode {
    modes[Self.key(for: url)] ?? .list
  }

  // MARK: - Write

  /// Persist `mode` for `url` and broadcast `didChangeNotification`.
  /// Setting the same mode that's already stored is a no-op — the
  /// dict isn't touched and no notification fires, so observers
  /// don't churn on idempotent writes. A `save` failure rolls the
  /// in-memory mutation back and skips the notification so observers
  /// never act on a value that won't survive a restart — keeping the
  /// in-memory dict consistent with what's actually on disk.
  public func setMode(_ mode: FinderViewMode, for url: URL) {
    let key = Self.key(for: url)
    let target: FinderViewMode? = (mode == .list) ? nil : mode
    if modes[key] == target { return }
    let previous = modes[key]
    if let target {
      modes[key] = target
    } else {
      modes.removeValue(forKey: key)
    }
    do {
      try save()
    } catch {
      logger.error("Failed to persist finder-modes: \(error.localizedDescription)")
      if let previous {
        modes[key] = previous
      } else {
        modes.removeValue(forKey: key)
      }
      return
    }
    NotificationCenter.default.post(
      name: Self.didChangeNotification, object: nil)
  }

  // MARK: - Private

  /// Canonicalise `url` to a single dict key. `path(percentEncoded:)`
  /// preserves a trailing slash on directory-marked URLs while `URL`
  /// callers across the finder pane are inconsistent about whether
  /// they pass `URL(fileURLWithPath: …)` (no slash) or
  /// `appendingPathComponent` results that retain one. Strip the
  /// trailing slash (except on root) so both forms collapse onto the
  /// same entry — the user's mental model is "this directory", not
  /// "this URL form".
  private static func key(for url: URL) -> String {
    var path = url.path(percentEncoded: false)
    if path.count > 1 && path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  /// Read the persisted dict, distinguishing first-run / unreadable
  /// from genuine corruption. A missing file (first launch on a fresh
  /// machine) and a present-but-unreadable file (transient I/O,
  /// permission glitch) both return `nil` so `setMode` retries the
  /// write path on the next mutation. A present-but-undecodable file
  /// is renamed aside to `<filename>.corrupt-<timestamp>` instead of
  /// being silently overwritten on the next save — without the
  /// quarantine, the next `setMode` would clobber whatever the user
  /// (or a partially-written previous run) left on disk.
  private static func load(at url: URL) -> [String: FinderViewMode]? {
    let path = url.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    guard let data = try? Data(contentsOf: url) else {
      logger.error("Failed to read finder-modes at \(path, privacy: .public)")
      return nil
    }
    do {
      return try JSONDecoder().decode([String: FinderViewMode].self, from: data)
    } catch {
      let timestamp = ISO8601DateFormatter().string(from: Date())
      let quarantine = url
        .deletingLastPathComponent()
        .appendingPathComponent("\(url.lastPathComponent).corrupt-\(timestamp)")
      do {
        try FileManager.default.moveItem(at: url, to: quarantine)
        logger.error(
          "Quarantined corrupt finder-modes file to \(quarantine.path, privacy: .public): \(error.localizedDescription)"
        )
      } catch let moveError {
        logger.error(
          "Failed to quarantine corrupt finder-modes file: \(moveError.localizedDescription)")
      }
      return nil
    }
  }

  private func save() throws {
    guard let storeURL else { return }
    let dir = storeURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(modes)
    try data.write(to: storeURL, options: .atomic)
  }
}
