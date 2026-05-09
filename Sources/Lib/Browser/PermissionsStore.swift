import Foundation
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "PermissionsStore")

/// What kind of capability a host is asking for. Matches the three
/// `WKUIDelegate` permission hooks the browser pane wires up:
/// camera / microphone via `requestMediaCapturePermissionFor`, and
/// geolocation via `requestGeolocationPermissionFor`.
public enum PermissionKind: String, Codable, CaseIterable, Sendable {
  case camera
  case microphone
  case geolocation
}

/// Resolved decision for a `(host, kind)` pair. `nil` (= no entry)
/// means "ask the user the next time the host requests it"; the
/// state is binary on purpose so the on-disk format mirrors what
/// `WKPermissionDecision` consumes (`.grant` / `.deny`).
public enum PermissionState: String, Codable, Sendable {
  case grant
  case deny
}

/// All persisted decisions for a single host. Each capability is
/// optional so a host that has only granted geolocation doesn't
/// imply anything about its camera / mic state — the auto-respond
/// path treats `nil` as "still needs to prompt".
public struct PermissionEntry: Codable, Equatable, Sendable {
  public var camera: PermissionState?
  public var microphone: PermissionState?
  public var geolocation: PermissionState?

  public init(
    camera: PermissionState? = nil,
    microphone: PermissionState? = nil,
    geolocation: PermissionState? = nil
  ) {
    self.camera = camera
    self.microphone = microphone
    self.geolocation = geolocation
  }

  public func state(for kind: PermissionKind) -> PermissionState? {
    switch kind {
    case .camera: return camera
    case .microphone: return microphone
    case .geolocation: return geolocation
    }
  }

  public mutating func setState(
    _ state: PermissionState?, for kind: PermissionKind
  ) {
    switch kind {
    case .camera: camera = state
    case .microphone: microphone = state
    case .geolocation: geolocation = state
    }
  }

  var isEmpty: Bool {
    camera == nil && microphone == nil && geolocation == nil
  }
}

/// Per-host capability decisions, mirrored to
/// `~/.config/e05/permissions.json`. Keys are fully-qualified hosts
/// (`mail.google.com` is distinct from `docs.google.com`); eTLD+1
/// collapsing is intentionally avoided so each subdomain decides
/// its own capability budget. Mirrors `MutedSitesStore` so a future
/// site-settings UI can iterate every host-keyed store with the
/// same shape.
@MainActor
public final class PermissionsStore {
  /// Process-wide store. Browser panes share this instance so a
  /// permission grant in one tab is observed by every other tab on
  /// the same host without each pane keeping its own copy.
  public static let shared = PermissionsStore()

  /// Backing file URL, or `nil` for the in-memory test mode that
  /// skips filesystem IO entirely.
  private let storeURL: URL?

  private var entries: [String: PermissionEntry]

  /// Production initialiser reads `~/.config/e05/permissions.json`.
  /// Pass `inMemory: true` from tests to keep the dict ephemeral and
  /// avoid touching the user's real config directory.
  public convenience init(inMemory: Bool = false) {
    if inMemory {
      self.init(storeURL: nil)
      return
    }
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/e05")
    self.init(storeURL: dir.appendingPathComponent("permissions.json"))
  }

  /// Internal initialiser that drives the same on-disk format
  /// against an arbitrary file URL. Tests reach this via
  /// `init(inMemory:)`; production code never calls it directly.
  init(storeURL: URL?) {
    self.storeURL = storeURL
    self.entries = (storeURL.flatMap { Self.load(at: $0) }) ?? [:]
  }

  // MARK: - Read

  /// Resolved decision for `(host, kind)`, or `nil` when the user
  /// hasn't decided yet. Lookup is case-insensitive.
  public func state(for host: String, kind: PermissionKind) -> PermissionState? {
    entries[host.lowercased()]?.state(for: kind)
  }

  /// Every host with at least one persisted decision. Sorted for
  /// deterministic UI ordering. Used by the future site-settings
  /// surface; the auto-respond path itself uses `state(for:kind:)`.
  public var allHosts: [String] {
    entries.keys.sorted()
  }

  /// Snapshot of one host's full entry, or `nil` when nothing is
  /// stored. Lets the site-settings UI render every capability for
  /// a host in one read without a triple lookup.
  public func entry(for host: String) -> PermissionEntry? {
    entries[host.lowercased()]
  }

  // MARK: - Write

  /// Persist a decision for `(host, kind)`. Idempotent — writing the
  /// same value that's already stored is a no-op (no file write). A
  /// `save` failure rolls the in-memory mutation back so callers
  /// never act on a value that won't survive a restart.
  public func setState(
    _ state: PermissionState, for host: String, kind: PermissionKind
  ) {
    mutate(host: host) { $0.setState(state, for: kind) }
  }

  /// Drop a single capability decision so the next request prompts
  /// again. Removes the host entirely when its last capability is
  /// cleared so `allHosts` stays tight.
  public func clear(host: String, kind: PermissionKind) {
    mutate(host: host) { $0.setState(nil, for: kind) }
  }

  /// Drop every capability decision for `host`. Used by the
  /// site-settings UI's per-host delete affordance.
  public func remove(host: String) {
    let normalized = host.lowercased()
    guard let previous = entries[normalized] else { return }
    entries[normalized] = nil
    do {
      try save()
    } catch {
      entries[normalized] = previous
      logger.error(
        "[permissions/save] Failed to persist removal for host: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  // MARK: - Private

  /// Apply `mutation` to the (possibly fresh) entry for `host`,
  /// persist the result, and roll back on save failure. Centralises
  /// the prune-when-empty rule so `setState` and `clear` share one
  /// consistency contract.
  private func mutate(
    host: String, mutation: (inout PermissionEntry) -> Void
  ) {
    let normalized = host.lowercased()
    let previous = entries[normalized]
    var updated = previous ?? PermissionEntry()
    mutation(&updated)
    if updated == previous { return }
    if updated.isEmpty {
      entries[normalized] = nil
    } else {
      entries[normalized] = updated
    }
    do {
      try save()
    } catch {
      entries[normalized] = previous
      logger.error(
        "[permissions/save] Failed to persist host \(normalized, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// On-disk wrapper. The `version` field gives future schema bumps
  /// a hook (adding optional fields stays Codable-default-friendly;
  /// a rename would warrant `feat!` + a version bump and a custom
  /// decoder branch).
  private struct Stored: Codable {
    var version: Int
    var entries: [String: PermissionEntry]
  }

  /// Read the persisted dict, distinguishing first-run / unreadable
  /// from genuine corruption. A missing file (first launch) and a
  /// present-but-unreadable file both return `nil` so the next
  /// mutation retries the write path. A present-but-undecodable
  /// file is renamed aside to `<filename>.corrupt-<timestamp>`
  /// rather than silently overwritten — the next save would
  /// otherwise clobber whatever the user (or a partially-written
  /// previous run) left on disk.
  private static func load(at url: URL) -> [String: PermissionEntry]? {
    let path = url.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    guard let data = try? Data(contentsOf: url) else {
      logger.error(
        "[permissions/load] Failed to read permissions at \(path, privacy: .public)")
      return nil
    }
    do {
      let stored = try JSONDecoder().decode(Stored.self, from: data)
      var normalized: [String: PermissionEntry] = [:]
      for (host, entry) in stored.entries where !entry.isEmpty {
        normalized[host.lowercased()] = entry
      }
      return normalized
    } catch {
      let timestamp = ISO8601DateFormatter().string(from: Date())
      let quarantine = url
        .deletingLastPathComponent()
        .appendingPathComponent("\(url.lastPathComponent).corrupt-\(timestamp)")
      do {
        try FileManager.default.moveItem(at: url, to: quarantine)
        logger.error(
          "[permissions/load] Quarantined corrupt file to \(quarantine.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      } catch let moveError {
        logger.error(
          "[permissions/load] Failed to quarantine corrupt file: \(moveError.localizedDescription, privacy: .public)"
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
    let stored = Stored(version: 1, entries: entries)
    let data = try encoder.encode(stored)
    try data.write(to: storeURL, options: .atomic)
  }
}
