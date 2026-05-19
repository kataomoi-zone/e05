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

  @Test("clearAll removes every file under the cache directory")
  func clearAllWipesDisk() throws {
    try withTempDir { dir in
      // Seed a couple of dummy PNG files so the wipe has something
      // to remove. The bytes don't need to decode — `clearAll`
      // recurses by name only.
      try Data([0x89, 0x50, 0x4E, 0x47])
        .write(to: dir.appendingPathComponent("example.com.png"))
      try Data([0x89, 0x50, 0x4E, 0x47])
        .write(to: dir.appendingPathComponent("github.com.png"))

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
}
