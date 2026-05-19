import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FaviconCache")

/// Per-host favicon cache backed by a memory LRU and a PNG directory
/// under `~/Library/Caches/<bundle-id>/favicons/` (resolved through
/// `E05Paths.default.cacheDir` — `Caches`, not `Application Support`,
/// because the disk entries are regenerable). Disk entries are
/// host-keyed (`<host>.png`); a wipe just means the next visit
/// re-fetches from `https://<host>/favicon.ico`, which is also why
/// missing-dir write failures degrade silently rather than erroring.
///
/// Lookup is synchronous: the UI calls ``image(for:)`` for every row
/// it draws, and ``prefetch(for:)`` enqueues a network fetch when the
/// cache is cold. Fetch completion posts ``didChangeNotification`` so
/// that observers (sidebar worklane, URL bar suggestion list) can
/// reload the affected row.
///
/// Follows the `https://<host>/favicon.ico` convention that the first
/// Chromium / Firefox shipped. Parsing `<link rel="icon">` for
/// higher-fidelity assets can be layered on top later; most popular
/// sites still serve a usable root favicon.
@MainActor
public final class FaviconCache {
  public static let shared = FaviconCache()

  /// Posted on the main actor after a successful fetch. `object` is
  /// the normalized host string so observers can filter on the
  /// specific host they care about. A typical observer just calls
  /// its generic reload on any post.
  public static let didChangeNotification = Notification.Name("FaviconCacheDidChange")

  private var memoryCache: [String: NSImage] = [:]
  private var inFlight: Set<String> = []
  /// Hosts whose fetch has failed in this process. Cleared on restart
  /// so transient outages resolve after a relaunch without needing
  /// explicit bookkeeping. A failed fetch here prevents us from
  /// hammering the network every time a sidebar row rebuilds.
  private var negativeCache: Set<String> = []
  private let cacheDir: URL?

  /// Create a cache pointing at the production directory under
  /// `~/Library/Caches/<bundle-id>/favicons/` (via
  /// `E05Paths.default.cacheDir`), creating it if it doesn't exist
  /// yet — `Caches/<bundle-id>/` is not guaranteed to exist on
  /// first launch, and the fetch-completion write degrades silently
  /// against a missing dir, so the `createDirectory` matters even
  /// though the read path is forgiving. Pass `inMemory: true` from
  /// tests to skip disk persistence entirely.
  public convenience init(inMemory: Bool = false) {
    if inMemory {
      self.init(cacheDir: nil)
      return
    }
    let dir = E05Paths.default.cacheDir
      .appendingPathComponent("favicons", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    self.init(cacheDir: dir)
  }

  /// Internal initialiser that points the cache at an arbitrary
  /// directory (or no directory at all). Tests reach this to use a
  /// temp dir without touching the user's real cache directory;
  /// production code reaches it via `init(inMemory:)`. The parameter
  /// is `URL?` to mirror the lazy-save stores' `init(storeURL:)`
  /// shape (no SQLite-native marker is in play here), and `nil`
  /// keeps the cache memory-only. Callers passing a non-`nil` URL
  /// should ensure the directory already exists if they expect the
  /// PNG persistence path to actually write — `image(for:)` reads
  /// gracefully against a missing dir, but the fetch-completion
  /// write fails silently otherwise.
  init(cacheDir: URL?) {
    self.cacheDir = cacheDir
  }

  /// Synchronous lookup. Returns the cached favicon on memory or disk
  /// hit, `nil` otherwise. Callers should pair an `image(for:)` call
  /// with a ``prefetch(for:)`` so that a miss kicks off a fetch and
  /// the row can be redrawn on the `didChangeNotification` post.
  ///
  /// Corrupted on-disk blobs (empty file, decode failure, zero-sized
  /// image) get purged on miss so the next fetch path can overwrite
  /// instead of re-hitting the same failure on every lookup.
  public func image(for host: String) -> NSImage? {
    let key = Self.normalize(host)
    guard !key.isEmpty else { return nil }
    if let img = memoryCache[key] { return img }
    guard let dir = cacheDir else { return nil }
    let file = dir.appendingPathComponent("\(key).png")
    guard let data = try? Data(contentsOf: file) else { return nil }
    if let img = NSImage(data: data), img.size.width > 0 {
      memoryCache[key] = img
      return img
    }
    try? FileManager.default.removeItem(at: file)
    return nil
  }

  /// Enqueue an async fetch for `host`. Idempotent: repeated calls
  /// for the same host while a fetch is in flight coalesce into one
  /// network request, and a second call after a successful fetch
  /// returns immediately via the memory cache.
  ///
  /// The fetch target is `https://<host>/favicon.ico` — the "legacy"
  /// Chromium/Firefox path. Sites that route that URL to 404 need
  /// ``ingest(host:from:)`` to feed the real icon discovered from
  /// the page's `<link rel="icon">` tag.
  public func prefetch(for host: String) {
    let key = Self.normalize(host)
    guard !key.isEmpty else { return }
    guard !Self.isPrivateHost(key) else { return }
    if memoryCache[key] != nil { return }
    if inFlight.contains(key) { return }
    if negativeCache.contains(key) { return }
    if let dir = cacheDir {
      let file = dir.appendingPathComponent("\(key).png")
      if FileManager.default.fileExists(atPath: file.path) {
        // Disk hit — leave warming to the next `image(for:)` call so
        // we don't double-read the file when the view hasn't asked
        // for it yet.
        return
      }
    }
    inFlight.insert(key)
    fetch(host: key, url: Self.legacyIcoURL(for: key))
  }

  /// Ingest a favicon from an arbitrary absolute URL — typically the
  /// `<link rel="icon">` href scraped out of the rendered DOM. Used
  /// by ``BrowserPaneView`` after `didFinish` navigation so SPAs and
  /// sites whose `/favicon.ico` 404s still land a real icon.
  ///
  /// The ingest bypasses the negative cache on the first hit: a
  /// `<link>` tag is a more authoritative hint than the legacy ICO
  /// path we first tried, and the original failure may have been
  /// against a non-existent `/favicon.ico`.
  ///
  /// Only `http` / `https` are accepted. `file:` / `javascript:` /
  /// `data:` / `about:` links scraped from a page's DOM are
  /// silently dropped so a malicious page can't push us into the
  /// local filesystem or a non-network scheme. Private-network
  /// hosts (`localhost`, RFC1918 ranges, `169.254/16`, IPv6
  /// loopback) are likewise rejected as a defense-in-depth against
  /// cross-origin `<link>` tags aimed at internal infrastructure.
  public func ingest(host: String, from url: URL) {
    guard let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return }
    if let fetchHost = url.host(percentEncoded: false), Self.isPrivateHost(fetchHost) {
      return
    }
    let key = Self.normalize(host)
    guard !key.isEmpty else { return }
    guard !Self.isPrivateHost(key) else { return }
    if memoryCache[key] != nil { return }
    if inFlight.contains(key) { return }
    inFlight.insert(key)
    negativeCache.remove(key)
    fetch(host: key, url: url)
  }

  /// Forget the in-memory copy for `host`, keeping the disk copy
  /// intact. Testing helper — not currently called by production
  /// code.
  public func invalidateMemory(for host: String) {
    memoryCache.removeValue(forKey: Self.normalize(host))
  }

  /// Wipe both the in-memory LRU and the on-disk PNG directory.
  /// Used by the Settings Reset "Clear Cache" action. The next
  /// favicon lookup for any host re-fetches from
  /// `https://<host>/favicon.ico`, so missing-dir write failures
  /// stay silently degrade-safe in the read path. Posts
  /// ``didChangeNotification`` with `nil` object so subscribers
  /// (sidebar / URL bar) can full-reload.
  public func clearAll() {
    memoryCache.removeAll()
    inFlight.removeAll()
    negativeCache.removeAll()
    if let cacheDir {
      do {
        let entries = try FileManager.default.contentsOfDirectory(
          at: cacheDir, includingPropertiesForKeys: nil)
        for entry in entries {
          try FileManager.default.removeItem(at: entry)
        }
      } catch {
        logger.error(
          "Failed to clear favicons dir: \(error.localizedDescription, privacy: .public)")
      }
    }
    NotificationCenter.default.post(
      name: Self.didChangeNotification, object: nil)
  }

  // MARK: - Internals

  /// Folded-lowercase host with characters that aren't safe on the
  /// macOS filesystem (IPv6 brackets, colons in host:port pairs)
  /// replaced by `_`. Normal DNS hosts pass through unchanged.
  static func normalize(_ host: String) -> String {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var out = ""
    out.reserveCapacity(trimmed.count)
    for ch in trimmed {
      if ch.isLetter || ch.isNumber || ch == "." || ch == "-" {
        out.append(ch)
      } else {
        out.append("_")
      }
    }
    return out
  }

  /// Build the legacy `https://<host>/favicon.ico` URL from a
  /// normalized key via `URLComponents` so the host never flows
  /// through a raw string interpolation. Path-style injection
  /// (`"evil.com/../…"`) would be silently dropped by
  /// `URLComponents` when assigned to `host`.
  static func legacyIcoURL(for normalizedHost: String) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = normalizedHost
    components.path = "/favicon.ico"
    return components.url
  }

  /// Whether `host` resolves to a private-network range that favicon
  /// fetches should never touch. Exact string-level match rather
  /// than DNS resolution — enough to stop an attacker-controlled
  /// page from pointing `<link rel="icon">` at `http://localhost/…`
  /// or `http://10.0.0.1/…` and having us send the request. Doesn't
  /// block public hostnames that happen to resolve to private IPs
  /// (that would need a resolving `URLSessionDelegate` guard, which
  /// is out of scope for favicon fetch).
  static func isPrivateHost(_ host: String) -> Bool {
    let lower = host.lowercased()
    if lower.isEmpty { return false }
    if lower == "localhost" || lower.hasSuffix(".localhost") { return true }
    if lower == "::1" || lower == "[::1]" { return true }
    if lower.hasPrefix("127.") || lower.hasPrefix("10.") { return true }
    if lower.hasPrefix("192.168.") { return true }
    if lower.hasPrefix("169.254.") { return true }
    if lower.hasPrefix("172.") {
      let parts = lower.split(separator: ".")
      if parts.count >= 2, let octet = Int(parts[1]), (16...31).contains(octet) {
        return true
      }
    }
    return false
  }

  private func fetch(host: String, url: URL?) {
    guard let url else {
      inFlight.remove(host)
      negativeCache.insert(host)
      return
    }
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.setValue("Mozilla/5.0 (Macintosh; e05)", forHTTPHeaderField: "User-Agent")
    Task { @MainActor [weak self] in
      let data: Data?
      do {
        let (d, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          !d.isEmpty
        {
          data = d
        } else {
          data = nil
        }
      } catch {
        data = nil
      }
      self?.finishFetch(host: host, data: data)
    }
  }

  private func finishFetch(host: String, data: Data?) {
    inFlight.remove(host)
    guard let data, let image = NSImage(data: data), image.size.width > 0 else {
      negativeCache.insert(host)
      logger.debug("Favicon fetch failed for \(host, privacy: .public)")
      return
    }
    memoryCache[host] = image
    NotificationCenter.default.post(name: Self.didChangeNotification, object: host as NSString)

    // Persist the PNG to disk off the main actor so ICO → PNG
    // re-encoding doesn't block the UI when a burst of favicon
    // fetches lands during a cold sidebar reload. TIFF is taken on
    // the main actor (NSImage is not Sendable); the downstream
    // NSBitmapImageRep / write happens on a utility queue.
    guard let dir = cacheDir, let tiff = image.tiffRepresentation else { return }
    let file = dir.appendingPathComponent("\(host).png")
    let hostForLog = host
    DispatchQueue.global(qos: .utility).async {
      guard let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
      else {
        return
      }
      do {
        try png.write(to: file, options: .atomic)
      } catch {
        logger.warning(
          "Favicon disk write failed for \(hostForLog, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }
}
