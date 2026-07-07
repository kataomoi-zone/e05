import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "HostSetStore")

/// A persisted set of fully-qualified hosts, mirrored to a JSON file
/// under `E05Paths.default.dataDir`. Backs the per-host preference
/// stores (site mute, suspend-exempt) that all share the same shape:
/// a versioned wrapper on disk, lowercase-normalised hosts, corrupt-file
/// quarantine on load, and an in-memory rollback when a save fails so a
/// caller never acts on a value that won't survive a restart.
///
/// Hosts are stored fully qualified (`mail.google.com` is distinct from
/// `docs.google.com`) — eTLD+1 collapsing is intentionally avoided so
/// each subdomain decides its own budget. Callers wrap this with
/// domain-named methods (`isMuted` / `setMuted`, `isExempt` /
/// `setExempt`) so the intent reads at the call site.
@MainActor
public final class HostSetStore {
  /// Backing file URL, or `nil` for the in-memory test mode that skips
  /// filesystem IO entirely.
  private let storeURL: URL?
  /// On-disk filename, used only to label log lines.
  private let label: String
  private var hosts: Set<String>

  /// - Parameters:
  ///   - storeURL: file to mirror to, or `nil` to stay ephemeral.
  ///   - label: the store's filename, for log messages.
  public init(storeURL: URL?, label: String) {
    self.storeURL = storeURL
    self.label = label
    self.hosts = storeURL.flatMap { Self.load(at: $0, label: label) } ?? []
  }

  // MARK: - Read

  /// Whether `host` is in the set. Case-insensitive — `host` is
  /// lowercased before the lookup so `"Example.COM"` still hits an
  /// entry stored as `"example.com"`.
  public func contains(_ host: String) -> Bool {
    hosts.contains(host.lowercased())
  }

  /// Every host in the set, sorted for deterministic UI ordering.
  public var allHosts: [String] {
    hosts.sorted()
  }

  // MARK: - Write

  /// Add (`member == true`) or remove (`false`) `host` and persist.
  /// Idempotent — setting the state that's already stored is a no-op
  /// with no file write. A `save` failure rolls the in-memory mutation
  /// back so callers never act on a value that won't survive a restart.
  public func set(_ member: Bool, host: String) {
    let normalized = host.lowercased()
    let alreadyContains = hosts.contains(normalized)
    if member == alreadyContains { return }
    if member {
      hosts.insert(normalized)
    } else {
      hosts.remove(normalized)
    }
    do {
      try save()
    } catch {
      logger.error(
        "Failed to persist \(self.label, privacy: .public): \(error.localizedDescription)")
      if member {
        hosts.remove(normalized)
      } else {
        hosts.insert(normalized)
      }
    }
  }

  // MARK: - Private

  /// On-disk wrapper. The `version` field gives future schema bumps a
  /// hook (adding optional fields stays Codable-default-friendly; a
  /// rename would warrant `feat!` + a version bump and a custom decoder
  /// branch).
  private struct Stored: Codable {
    var version: Int
    var hosts: [String]
  }

  /// Read the persisted set, distinguishing first-run / unreadable from
  /// genuine corruption. A missing file (first launch) and a present-
  /// but-unreadable file both return `nil` so the next mutation retries
  /// the write path. A present-but-undecodable file is renamed aside to
  /// `<filename>.corrupt-<timestamp>` rather than silently overwritten.
  private static func load(at url: URL, label: String) -> Set<String>? {
    let path = url.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    guard let data = try? Data(contentsOf: url) else {
      logger.error("Failed to read \(label, privacy: .public) at \(path, privacy: .public)")
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
          "Quarantined corrupt \(label, privacy: .public) file to \(quarantine.path, privacy: .public): \(error.localizedDescription)"
        )
      } catch let moveError {
        logger.error(
          "Failed to quarantine corrupt \(label, privacy: .public) file: \(moveError.localizedDescription)"
        )
      }
      return nil
    }
  }

  private func save() throws {
    guard let storeURL else { return }
    let dir = storeURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stored = Stored(version: 1, hosts: hosts.sorted())
    let data = try encoder.encode(stored)
    try data.write(to: storeURL, options: .atomic)
  }
}
