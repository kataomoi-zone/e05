import Foundation
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "MutedSitesStore")

/// Per-host site mute preferences, mirrored to
/// `~/Library/Application Support/<bundle-id>/muted-sites.json` (resolved
/// through `E05Paths.default.dataDir`). The set holds fully-qualified
/// hosts (`mail.google.com` is distinct from `docs.google.com`) —
/// eTLD+1 collapsing is intentionally avoided so each subdomain
/// decides its own noise budget.
///
/// On disk the file carries a `version` field alongside the host
/// list; the wrapper struct keeps the schema extensible without
/// breaking Codable's default synthesis. Hosts are normalised to
/// lowercase on every read and write so case-mixed entries from
/// hand-edited files don't leak into the in-memory set.
@MainActor
public final class MutedSitesStore {
  /// Process-wide store. Browser panes share this instance so a
  /// "Mute this Site" toggle in one tab is observed by every other
  /// tab on the same host without each pane keeping its own copy.
  public static let shared = MutedSitesStore()

  /// Backing file URL, or `nil` for the in-memory test mode that
  /// skips filesystem IO entirely.
  private let storeURL: URL?

  private var hosts: Set<String>

  /// Production initialiser reads
  /// `~/Library/Application Support/<bundle-id>/muted-sites.json` via
  /// `E05Paths.default.dataDir`. Pass `inMemory: true` from tests to
  /// keep the set ephemeral and avoid touching the user's real data
  /// directory.
  public convenience init(inMemory: Bool = false) {
    if inMemory {
      self.init(storeURL: nil)
      return
    }
    let dir = E05Paths.default.dataDir
    self.init(storeURL: dir.appendingPathComponent("muted-sites.json"))
  }

  /// Internal initialiser that drives the same on-disk format
  /// against an arbitrary file URL. Tests use this to exercise
  /// `save` / `load` end-to-end against a temp file without
  /// touching the user's real data directory; production code
  /// reaches it via `init(inMemory:)`. `nil` keeps the set
  /// ephemeral.
  init(storeURL: URL?) {
    self.storeURL = storeURL
    self.hosts = (storeURL.flatMap { Self.load(at: $0) }) ?? []
  }

  // MARK: - Read

  /// Whether `host` is on the always-mute list. Lookup is case-
  /// insensitive — `host` is lowercased before the contains check
  /// so a caller passing `"Example.COM"` still hits an entry stored
  /// as `"example.com"`.
  public func isMuted(host: String) -> Bool {
    hosts.contains(host.lowercased())
  }

  // MARK: - Write

  /// Add or remove `host` from the always-mute list and persist.
  /// Idempotent — setting the same state that's already stored is a
  /// no-op (no file write). A `save` failure rolls the in-memory
  /// mutation back so callers never act on a value that won't
  /// survive a restart. The caller is responsible for propagating
  /// the toggle to live panes (see
  /// `PaneContainerViewController.applyMuteToPanes(matchingHost:muted:)`)
  /// — there's no broadcast notification because the only consumer
  /// that needs to react synchronously is the toggle's own callsite.
  public func setMuted(_ muted: Bool, host: String) {
    let normalized = host.lowercased()
    let alreadyContains = hosts.contains(normalized)
    if muted == alreadyContains { return }
    if muted {
      hosts.insert(normalized)
    } else {
      hosts.remove(normalized)
    }
    do {
      try save()
    } catch {
      logger.error(
        "Failed to persist muted-sites: \(error.localizedDescription)")
      if muted {
        hosts.remove(normalized)
      } else {
        hosts.insert(normalized)
      }
    }
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
  /// rather than silently overwritten — the next save would
  /// otherwise clobber whatever the user (or a partially-written
  /// previous run) left on disk.
  private static func load(at url: URL) -> Set<String>? {
    let path = url.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    guard let data = try? Data(contentsOf: url) else {
      logger.error("Failed to read muted-sites at \(path, privacy: .public)")
      return nil
    }
    do {
      let stored = try JSONDecoder().decode(Stored.self, from: data)
      return Set(stored.hosts.map { $0.lowercased() })
    } catch {
      let timestamp = ISO8601DateFormatter().string(from: Date())
      let quarantine = url
        .deletingLastPathComponent()
        .appendingPathComponent("\(url.lastPathComponent).corrupt-\(timestamp)")
      do {
        try FileManager.default.moveItem(at: url, to: quarantine)
        logger.error(
          "Quarantined corrupt muted-sites file to \(quarantine.path, privacy: .public): \(error.localizedDescription)"
        )
      } catch let moveError {
        logger.error(
          "Failed to quarantine corrupt muted-sites file: \(moveError.localizedDescription)"
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
