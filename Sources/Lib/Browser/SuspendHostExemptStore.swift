import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "SuspendHostExemptStore")

/// Per-host "always keep active" preferences, mirrored to
/// `~/Library/Application Support/<bundle-id>/suspend-exempt.json`
/// (resolved through `E05Paths.default.dataDir`). The set holds fully-
/// qualified hosts (`mail.google.com` is distinct from
/// `docs.google.com`) — eTLD+1 collapsing is intentionally avoided so
/// each subdomain decides its own suspend budget.
///
/// Mirrors `MutedSitesStore` on disk (versioned wrapper, lowercase
/// hosts, corrupt-file quarantine) and exposes `allHosts` /
/// `remove(host:)` so any consumer that iterates host-keyed stores
/// can do so with one shape.
@MainActor
public final class SuspendHostExemptStore {
  /// Process-wide store. Suspend sweeps and the surface that toggles
  /// individual hosts share this instance so a change in one is
  /// observed by the other without each caller keeping its own copy.
  public static let shared = SuspendHostExemptStore()

  /// Backing file URL, or `nil` for the in-memory test mode that
  /// skips filesystem IO entirely.
  private let storeURL: URL?

  private var hosts: Set<String>

  /// Production initialiser reads
  /// `~/Library/Application Support/<bundle-id>/suspend-exempt.json`
  /// via `E05Paths.default.dataDir`. Pass `inMemory: true` from tests
  /// to keep the set ephemeral and avoid touching the user's real
  /// data directory.
  public convenience init(inMemory: Bool = false) {
    if inMemory {
      self.init(storeURL: nil)
      return
    }
    self.init(storeURL: E05Paths.default.dataFile(E05Filenames.suspendExempt))
  }

  /// Internal initialiser that drives the same on-disk format
  /// against an arbitrary file URL. Tests use this to exercise
  /// `save` / `load` end-to-end against a temp file; production code
  /// reaches it via `init(inMemory:)`. `nil` keeps the set ephemeral.
  init(storeURL: URL?) {
    self.storeURL = storeURL
    self.hosts = (storeURL.flatMap { Self.load(at: $0) }) ?? []
  }

  // MARK: - Read

  /// Whether `host` is on the always-active list. Lookup is case-
  /// insensitive — `host` is lowercased before the contains check so
  /// a caller passing `"Example.COM"` still hits an entry stored as
  /// `"example.com"`.
  public func isExempt(host: String) -> Bool {
    hosts.contains(host.lowercased())
  }

  /// Every host on the always-active list. Sorted for deterministic
  /// UI ordering. Mirrors `PermissionsStore.allHosts` so iterators
  /// can use one pattern across host-keyed stores.
  public var allHosts: [String] {
    hosts.sorted()
  }

  // MARK: - Write

  /// Add or remove `host` from the always-active list and persist.
  /// Idempotent — setting the same state that's already stored is a
  /// no-op (no file write). A `save` failure rolls the in-memory
  /// mutation back so callers never act on a value that won't
  /// survive a restart.
  public func setExempt(_ exempt: Bool, host: String) {
    let normalized = host.lowercased()
    let alreadyContains = hosts.contains(normalized)
    if exempt == alreadyContains { return }
    if exempt {
      hosts.insert(normalized)
    } else {
      hosts.remove(normalized)
    }
    do {
      try save()
    } catch {
      logger.error(
        "[suspend-exempt/save] Failed to persist: \(error.localizedDescription, privacy: .public)"
      )
      if exempt {
        hosts.remove(normalized)
      } else {
        hosts.insert(normalized)
      }
    }
  }

  /// Drop `host` from the always-active list. Convenience wrapper
  /// matching the `remove(host:)` shape shared across host-keyed
  /// stores.
  public func remove(host: String) {
    setExempt(false, host: host)
  }

  // MARK: - Private

  /// On-disk wrapper. The `version` field gives future schema bumps
  /// a hook (adding optional fields stays Codable-default-friendly;
  /// a rename would warrant `feat!` + a version bump and a custom
  /// decoder branch).
  private struct Stored: Codable {
    var version: Int
    var hosts: [String]
  }

  /// Read the persisted set, distinguishing first-run / unreadable
  /// from genuine corruption. A missing file (first launch) and a
  /// present-but-unreadable file both return `nil` so the next
  /// mutation retries the write path. A present-but-undecodable
  /// file is renamed aside to `<filename>.corrupt-<timestamp>`
  /// rather than silently overwritten.
  private static func load(at url: URL) -> Set<String>? {
    let path = url.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    guard let data = try? Data(contentsOf: url) else {
      logger.error(
        "[suspend-exempt/load] Failed to read at \(path, privacy: .public)")
      return nil
    }
    do {
      let stored = try JSONDecoder().decode(Stored.self, from: data)
      return Set(stored.hosts.map { $0.lowercased() })
    } catch {
      let timestamp = ISO8601DateFormatter().string(from: Date())
      let quarantine =
        url
        .deletingLastPathComponent()
        .appendingPathComponent("\(url.lastPathComponent).corrupt-\(timestamp)")
      do {
        try FileManager.default.moveItem(at: url, to: quarantine)
        logger.error(
          "[suspend-exempt/load] Quarantined corrupt file to \(quarantine.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      } catch let moveError {
        logger.error(
          "[suspend-exempt/load] Failed to quarantine corrupt file: \(moveError.localizedDescription, privacy: .public)"
        )
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
    let stored = Stored(version: 1, hosts: hosts.sorted())
    let data = try encoder.encode(stored)
    try data.write(to: storeURL, options: .atomic)
  }
}
