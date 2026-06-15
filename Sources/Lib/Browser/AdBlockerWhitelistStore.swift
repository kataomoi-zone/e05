import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "AdBlockerWhitelistStore")

/// Per-host adblocker whitelist, mirrored to
/// `<dataDir>/adblocker-whitelist.json`. A host on this list bypasses
/// both the declarative ``WKContentRuleList`` (via `unless-domain`
/// injected at compile time) and the procedural
/// ``CosmeticFilterEngine`` (which consults the same set when
/// answering hostname queries).
///
/// The shape mirrors ``MutedSitesStore``: fully-qualified hosts kept
/// distinct (no eTLD+1 collapsing), lowercase normalisation, a
/// versioned `Stored` wrapper for forward compatibility, and an
/// atomic write with in-memory rollback on failure.
///
/// Whitelisting a host is destination-side: a tab visiting that host
/// loads unfiltered, regardless of where the request originated.
/// `WKContentRuleList`'s `unless-domain` matches the *page domain*
/// (the document the rule list runs against), not the *resource*
/// domain, which is the semantic users expect when typing a host
/// into a "don't filter on this site" field.
@MainActor
public final class AdBlockerWhitelistStore {
  /// Process-wide store. Settings UI and live browser panes share
  /// this instance so a host added in the Settings tab is observed
  /// by every pane on the next ``didChangeNotification``.
  public static let shared = AdBlockerWhitelistStore()

  /// Posted on ``NotificationCenter.default`` after a successful
  /// ``setWhitelisted(_:host:)`` or ``replaceAll(with:)`` mutation
  /// so browser panes can re-evaluate their current host's
  /// whitelist status and attach or detach the adblocker rule
  /// lists accordingly.
  public static let didChangeNotification = Notification.Name(
    "e05.AdBlockerWhitelistStore.didChange"
  )

  /// Backing file URL, or `nil` for the in-memory test mode.
  private let storeURL: URL?

  private var hosts: Set<String>

  /// Production initialiser reads
  /// `<dataDir>/adblocker-whitelist.json`. Pass `inMemory: true`
  /// from tests to skip filesystem IO entirely.
  public convenience init(inMemory: Bool = false) {
    if inMemory {
      self.init(storeURL: nil)
      return
    }
    self.init(storeURL: E05Paths.default.dataFile(E05Filenames.adblockerWhitelist))
  }

  init(storeURL: URL?) {
    self.storeURL = storeURL
    self.hosts = (storeURL.flatMap { Self.load(at: $0) }) ?? []
  }

  // MARK: - Read

  /// Whether `host` (case-insensitive) is exempt — it matches an entry
  /// directly or sits under one. Whitelisting `youtube.com` therefore
  /// also exempts `www.youtube.com` / `m.youtube.com`, which is what
  /// users expect from a per-site toggle (and what the Settings copy
  /// promises). Walks the parent chain down to but excluding the bare
  /// TLD so a stray `com` entry can't blanket every site — the same walk
  /// the cosmetic / declarative / scriptlet layers use
  /// (mirrors `CosmeticFilterEngine.parentHostnames` and the JS
  /// `hostnameChain`). Used for the per-host content rule list bypass
  /// and the cosmetic engine's hostname-query suppression.
  public func isWhitelisted(host: String) -> Bool {
    let normalized = host.lowercased()
    guard !normalized.isEmpty else { return false }
    if hosts.contains(normalized) { return true }
    var current = normalized[...]
    while let dot = current.firstIndex(of: ".") {
      let parent = current[current.index(after: dot)...]
      guard parent.contains(".") else { break }  // stop above the bare TLD
      if hosts.contains(String(parent)) { return true }
      current = parent
    }
    return false
  }

  /// Every host on the whitelist, sorted for deterministic UI
  /// rendering. Mirrors `MutedSitesStore.allHosts`.
  public var allHosts: [String] {
    hosts.sorted()
  }

  // MARK: - Write

  /// Reduce free-form input to a bare host so a pasted URL still lands a
  /// usable entry: `https://www.youtube.com/watch?v=…` → `www.youtube.com`.
  /// Drops a scheme prefix, then any path / query / fragment, then
  /// userinfo, then a `:port` (bracketed IPv6 literals keep the address
  /// and lose the brackets, matching what `URL.host` reports), then a
  /// trailing dot, and lowercases. Returns "" when nothing host-like
  /// remains. The match side (`isWhitelisted`) reads a bare `URL.host`,
  /// so an un-normalized entry with a scheme or path could never match —
  /// this keeps both sides in the same shape.
  public static func normalizeHost(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !s.isEmpty else { return "" }
    if let scheme = s.range(of: "://") {
      s = String(s[scheme.upperBound...])
    }
    if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
      s = String(s[..<cut])
    }
    if let at = s.lastIndex(of: "@") {
      s = String(s[s.index(after: at)...])
    }
    if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
      // Bracketed IPv6 literal (`[::1]:8080`): keep the address, drop the
      // brackets and any `:port`. `URL.host` reports IPv6 unbracketed, so
      // this matches the lookup side.
      s = String(s[s.index(after: s.startIndex)..<close])
    } else if let port = s.firstIndex(of: ":") {
      s = String(s[..<port])
    }
    if s.hasSuffix(".") {
      s.removeLast()
    }
    return s
  }

  /// Add or remove `host` from the whitelist and persist. Idempotent
  /// — setting the same state that's already stored is a no-op (no
  /// file write). A `save` failure rolls the in-memory mutation back
  /// so callers never act on a value that won't survive a restart.
  /// Propagating the change to the live rule list is the caller's
  /// responsibility — there is no broadcast notification because the
  /// only call site that needs to react synchronously is the
  /// Settings tab. `host` is run through ``normalizeHost(_:)`` so a
  /// pasted URL still lands a matchable entry.
  public func setWhitelisted(_ whitelisted: Bool, host: String) {
    let normalized = Self.normalizeHost(host)
    guard !normalized.isEmpty else { return }
    let alreadyContains = hosts.contains(normalized)
    if whitelisted == alreadyContains { return }
    if whitelisted {
      hosts.insert(normalized)
    } else {
      hosts.remove(normalized)
    }
    do {
      try save()
      broadcastChange()
    } catch {
      logger.error(
        "[adblocker/whitelist] failed to persist (setWhitelisted): \(error.localizedDescription)"
      )
      if whitelisted {
        hosts.remove(normalized)
      } else {
        hosts.insert(normalized)
      }
    }
  }

  /// Replace the whitelist with `newHosts`. Used by bulk operations
  /// (Reset, Import) so the caller does not have to drive a sequence
  /// of single-host writes through ``setWhitelisted(_:host:)``. Each
  /// entry goes through ``normalizeHost(_:)`` so an imported URL lands
  /// the same matchable shape a single add would.
  public func replaceAll(with newHosts: [String]) {
    let normalized = Set(newHosts.map { Self.normalizeHost($0) }.filter { !$0.isEmpty })
    if normalized == hosts { return }
    let previous = hosts
    hosts = normalized
    do {
      try save()
      broadcastChange()
    } catch {
      logger.error(
        "[adblocker/whitelist] failed to persist (replaceAll): \(error.localizedDescription)")
      hosts = previous
    }
  }

  private func broadcastChange() {
    NotificationCenter.default.post(
      name: Self.didChangeNotification,
      object: self
    )
  }

  // MARK: - Private

  private struct Stored: Codable {
    var version: Int
    var hosts: [String]
  }

  private static func load(at url: URL) -> Set<String>? {
    let path = url.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    guard let data = try? Data(contentsOf: url) else {
      logger.error("[adblocker/whitelist] failed to read at \(path, privacy: .public)")
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
          "Quarantined corrupt adblocker-whitelist to \(quarantine.path, privacy: .public): \(error.localizedDescription)"
        )
      } catch let moveError {
        logger.error(
          "Failed to quarantine corrupt adblocker-whitelist: \(moveError.localizedDescription)"
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
