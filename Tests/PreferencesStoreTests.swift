import Foundation
import Testing

@testable import E05Lib

@Suite("PreferencesStore")
@MainActor
struct PreferencesStoreTests {
  @Test("fresh store returns the default preferences")
  func defaults() {
    let store = PreferencesStore(inMemory: true)
    #expect(store.preferences == .default)
    #expect(store.preferences.homeURL == nil)
    #expect(store.preferences.searchTemplate == "https://duckduckgo.com/?q={query}")
    #expect(store.preferences.alwaysPromptDownload == true)
    #expect(store.preferences.defaultDownloadDir == nil)
  }

  @Test("update mutates the stored value and notifies listeners")
  func updateFiresListener() {
    let store = PreferencesStore(inMemory: true)
    var lastSeen: E05Preferences?
    let token = store.addListener { lastSeen = $0 }
    defer { store.removeListener(token) }

    store.update { $0.homeURL = "https://example.com" }
    #expect(store.preferences.homeURL == "https://example.com")
    #expect(lastSeen?.homeURL == "https://example.com")
  }

  @Test("update with the same value is a no-op and does not notify")
  func updateNoOpDoesNotNotify() {
    let store = PreferencesStore(inMemory: true)
    var fireCount = 0
    let token = store.addListener { _ in fireCount += 1 }
    defer { store.removeListener(token) }

    store.update { $0.alwaysPromptDownload = true }
    #expect(fireCount == 0)
  }

  @Test("removed listeners no longer receive callbacks")
  func removeListenerStops() {
    let store = PreferencesStore(inMemory: true)
    var fireCount = 0
    let token = store.addListener { _ in fireCount += 1 }
    store.removeListener(token)

    store.update { $0.homeURL = "https://example.com" }
    #expect(fireCount == 0)
  }

  // MARK: - Disk-backed paths

  private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("PreferencesStoreTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
  }

  @Test("a disk-backed store round-trips through save and re-load")
  func diskRoundTrip() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("preferences.json")

      let writer = PreferencesStore(storeURL: storeURL)
      writer.update {
        $0.homeURL = "https://example.com"
        $0.searchTemplate = "https://kagi.com/search?q={query}"
        $0.alwaysPromptDownload = false
        $0.defaultDownloadDir = "/Users/test/Downloads"
      }

      let reader = PreferencesStore(storeURL: storeURL)
      #expect(reader.preferences.homeURL == "https://example.com")
      #expect(reader.preferences.searchTemplate == "https://kagi.com/search?q={query}")
      #expect(reader.preferences.alwaysPromptDownload == false)
      #expect(reader.preferences.defaultDownloadDir == "/Users/test/Downloads")
    }
  }

  @Test("missing file yields defaults, never throws")
  func missingFileYieldsDefault() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("preferences.json")
      let store = PreferencesStore(storeURL: storeURL)
      #expect(store.preferences == .default)
    }
  }

  @Test("a corrupted JSON file is quarantined and the store falls back to defaults")
  func corruptedJSONIsQuarantined() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("preferences.json")
      try Data("not valid json".utf8).write(to: storeURL)

      let store = PreferencesStore(storeURL: storeURL)
      #expect(store.preferences == .default)

      #expect(!FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))
      let siblings = try FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
      #expect(siblings.contains { $0.lastPathComponent.hasPrefix("preferences.json.corrupt-") })
    }
  }

  @Test("save failure rolls back the in-memory mutation and skips listeners")
  func saveFailureRollsBack() {
    let unwritable = URL(fileURLWithPath: "/dev/null/preferences.json")
    let store = PreferencesStore(storeURL: unwritable)

    var fireCount = 0
    let token = store.addListener { _ in fireCount += 1 }
    defer { store.removeListener(token) }

    store.update { $0.homeURL = "https://example.com" }

    #expect(store.preferences.homeURL == nil)
    #expect(fireCount == 0)
  }

  @Test("on-disk shape uses a versioned wrapper")
  func onDiskShape() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("preferences.json")
      let store = PreferencesStore(storeURL: storeURL)
      store.update { $0.homeURL = "https://example.com" }

      let data = try Data(contentsOf: storeURL)
      let json = try #require(String(data: data, encoding: .utf8))
      #expect(json.contains("\"version\""))
      #expect(json.contains("\"preferences\""))
      #expect(json.contains("\"homeURL\""))
    }
  }
}
