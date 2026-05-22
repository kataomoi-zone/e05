import AppKit
import Foundation
import Testing

@testable import E05Lib

@Suite("FaviconCache")
@MainActor
struct FaviconCacheTests {
  private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FaviconCacheTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
  }

  /// 1×1 opaque PNG bytes — small but a real decodable image so
  /// `image(for:)` exercises the `NSImage(data:)` path instead of
  /// the corrupt-blob removal branch.
  private static let pixelPNG: Data = {
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.lockFocus()
    NSColor.black.setFill()
    NSBezierPath.fill(NSRect(x: 0, y: 0, width: 1, height: 1))
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
      fatalError("test setup: failed to encode 1x1 PNG")
    }
    return png
  }()

  @Test("clearAll removes every file under the cache directory")
  func clearAllWipesDisk() throws {
    try withTempDir { dir in
      // Seed a couple of dummy entries so the wipe has something to
      // remove. Bytes don't need to decode and the suffix doesn't
      // need to match the current format — `clearAll` recurses by
      // name only, so a leftover `.png` from a pre-`.bin` cache is
      // also handled.
      try Data([0x89, 0x50, 0x4E, 0x47])
        .write(to: dir.appendingPathComponent("example.com.bin"))
      try Data([0x89, 0x50, 0x4E, 0x47])
        .write(to: dir.appendingPathComponent("legacy.example.com.png"))

      let cache = FaviconCache(cacheDir: dir)
      cache.clearAll()

      let remaining = try FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
      #expect(remaining.isEmpty)
    }
  }

  @Test("clearAll posts didChangeNotification")
  func clearAllNotifies() {
    let cache = FaviconCache(inMemory: true)

    var fireCount = 0
    let token = NotificationCenter.default.addObserver(
      forName: FaviconCache.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in
      fireCount += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    cache.clearAll()
    #expect(fireCount == 1)
  }

  @Test("clearAll tolerates a missing cache directory")
  func clearAllMissingDirIsSafe() throws {
    try withTempDir { dir in
      let missingChild = dir.appendingPathComponent("never-created", isDirectory: true)
      let cache = FaviconCache(cacheDir: missingChild)
      cache.clearAll()  // Must not throw / crash.

      // `clearAll` keeps cache memory clean even when the dir is
      // missing — the in-memory side of the wipe still runs.
      #expect(cache.image(for: "example.com") == nil)
    }
  }

  @Test("clearAll on the in-memory variant clears memory state")
  func clearAllInMemory() {
    let cache = FaviconCache(inMemory: true)
    cache.clearAll()
    // Without disk, `image(for:)` returns nil for any host because
    // there's no resolver to fall back to. The post-clear
    // expectation is just "doesn't crash, returns nil".
    #expect(cache.image(for: "example.com") == nil)
  }

  @Test("dropMemoryCache keeps disk entries intact and lazy-re-decodes")
  func dropMemoryCacheKeepsDiskAndRevives() throws {
    try withTempDir { dir in
      let seed = dir.appendingPathComponent("example.com.bin")
      try Self.pixelPNG.write(to: seed)

      let cache = FaviconCache(cacheDir: dir)
      // Warm the memory slot via a first lookup.
      #expect(cache.image(for: "example.com") != nil)

      cache.dropMemoryCache()

      // Disk entry survives the eviction and the next lookup
      // re-decodes from disk — the property the theme-flip handler
      // depends on for theme-aware SVGs.
      #expect(FileManager.default.fileExists(atPath: seed.path))
      #expect(cache.image(for: "example.com") != nil)
    }
  }

  @Test("dropMemoryCache clears the ingest URL gate")
  func dropMemoryCacheClearsURLGate() {
    let cache = FaviconCache(inMemory: true)
    let url = URL(string: "https://example.com/favicon.ico")!
    cache.ingest(host: "example.com", from: url)

    #expect(cache.lastIngestedURL["example.com"] == url)

    cache.dropMemoryCache()

    // Gate state must be cleared so a host whose disk write failed
    // can recover via a fresh ingest of the same URL.
    #expect(cache.lastIngestedURL["example.com"] == nil)
  }

  @Test("dropMemoryCache posts didChangeNotification")
  func dropMemoryCacheNotifies() {
    let cache = FaviconCache(inMemory: true)

    var fireCount = 0
    let token = NotificationCenter.default.addObserver(
      forName: FaviconCache.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in
      fireCount += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    cache.dropMemoryCache()
    #expect(fireCount == 1)
  }

  @Test("ingest records the URL on the gate")
  func ingestRecordsURLGate() {
    let cache = FaviconCache(inMemory: true)
    let url = URL(string: "https://example.com/favicon.ico")!

    cache.ingest(host: "example.com", from: url)
    #expect(cache.lastIngestedURL["example.com"] == url)
  }

  @Test("ingest ignores a same-URL repeat for the same host")
  func ingestIgnoresSameURLRepeat() {
    let cache = FaviconCache(inMemory: true)
    let url = URL(string: "https://example.com/favicon.ico")!

    cache.ingest(host: "example.com", from: url)
    let firstSnapshot = cache.lastIngestedURL["example.com"]
    cache.ingest(host: "example.com", from: url)
    // Second call must be a no-op on gate state.
    #expect(cache.lastIngestedURL["example.com"] == firstSnapshot)
  }
}
