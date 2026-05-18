import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "PreferencesStore")

/// App-wide preferences store backed by
/// `<dataDir>/preferences.json`. Mirrors the shape of
/// `MutedSitesStore` / `PermissionsStore` so the same conventions
/// (versioned `Stored` wrapper, atomic write, corrupt-file
/// quarantine, in-memory rollback on save failure) apply.
@MainActor
public final class PreferencesStore {
  /// Process-wide store. Settings UI and hardcode-replacement sites
  /// share this instance so a toggle in the Settings window is
  /// observed by callers (new pane factory / search resolver /
  /// downloads manager) without each holding its own copy.
  public static let shared = PreferencesStore()

  /// Backing file URL, or `nil` for the in-memory test mode.
  private let storeURL: URL?

  /// Snapshot of the current values. Mutations route through
  /// ``update(_:)`` so save and listener fan-out stay coupled.
  public private(set) var preferences: E05Preferences

  private var listeners: [UUID: (E05Preferences) -> Void] = [:]

  /// Production initialiser reads
  /// `~/Library/Application Support/<bundle-id>/preferences.json` via
  /// `E05Paths.default.dataFile(_:)`. Pass `inMemory: true` from
  /// tests to keep the value ephemeral.
  public convenience init(inMemory: Bool = false) {
    if inMemory {
      self.init(storeURL: nil)
      return
    }
    self.init(storeURL: E05Paths.default.dataFile(E05Filenames.preferences))
  }

  /// Internal initialiser that drives the same on-disk format
  /// against an arbitrary file URL. Tests use this to exercise
  /// `save` / `load` end-to-end against a temp file without
  /// touching the user's real data directory.
  init(storeURL: URL?) {
    self.storeURL = storeURL
    self.preferences = (storeURL.flatMap { Self.load(at: $0) }) ?? .default
  }

  /// Atomically mutate, persist, and notify. The mutation runs
  /// against a copy; only after a successful disk write does
  /// ``preferences`` flip and listeners fire. A `save` failure rolls
  /// the in-memory value back so callers never observe a state that
  /// won't survive a restart.
  public func update(_ mutate: (inout E05Preferences) -> Void) {
    var next = preferences
    mutate(&next)
    guard next != preferences else { return }
    let previous = preferences
    preferences = next
    do {
      try save()
      for callback in listeners.values {
        callback(preferences)
      }
    } catch {
      logger.error(
        "Failed to persist preferences: \(error.localizedDescription)")
      preferences = previous
    }
  }

  /// Subscribe to preference changes. Returns a token that must be
  /// passed to ``removeListener(_:)`` to unsubscribe. Callbacks fire
  /// on the main actor after a successful disk write.
  @discardableResult
  public func addListener(_ callback: @escaping (E05Preferences) -> Void) -> UUID {
    let token = UUID()
    listeners[token] = callback
    return token
  }

  public func removeListener(_ token: UUID) {
    listeners.removeValue(forKey: token)
  }

  // MARK: - Private

  /// On-disk wrapper. The `version` field gives future schema bumps
  /// a hook; adding optional fields stays Codable-default-friendly,
  /// a rename would warrant `feat!` + a version bump and a custom
  /// decoder branch.
  private struct Stored: Codable {
    var version: Int
    var preferences: E05Preferences
  }

  private static func load(at url: URL) -> E05Preferences? {
    let path = url.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    guard let data = try? Data(contentsOf: url) else {
      logger.error(
        "Failed to read preferences at \(path, privacy: .public)")
      return nil
    }
    do {
      let stored = try JSONDecoder().decode(Stored.self, from: data)
      return stored.preferences
    } catch {
      let timestamp = ISO8601DateFormatter().string(from: Date())
      let quarantine = url
        .deletingLastPathComponent()
        .appendingPathComponent("\(url.lastPathComponent).corrupt-\(timestamp)")
      do {
        try FileManager.default.moveItem(at: url, to: quarantine)
        logger.error(
          "Quarantined corrupt preferences file to \(quarantine.path, privacy: .public): \(error.localizedDescription)"
        )
      } catch let moveError {
        logger.error(
          "Failed to quarantine corrupt preferences file: \(moveError.localizedDescription)"
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
    let stored = Stored(version: 1, preferences: preferences)
    let data = try encoder.encode(stored)
    try data.write(to: storeURL, options: .atomic)
  }
}
