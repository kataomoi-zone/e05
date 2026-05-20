import Foundation
import Testing

@testable import E05Lib

@Suite("AdBlockerWhitelistStore")
@MainActor
struct AdBlockerWhitelistStoreTests {
  private func withTempStoreURL(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AdBlockerWhitelistStoreTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir.appendingPathComponent("adblocker-whitelist.json"))
  }

  @Test("setWhitelisted round-trips through disk")
  func setWhitelistedRoundTrips() throws {
    try withTempStoreURL { storeURL in
      let writer = AdBlockerWhitelistStore(storeURL: storeURL)
      writer.setWhitelisted(true, host: "Example.COM")
      writer.setWhitelisted(true, host: "news.example.com")

      let reader = AdBlockerWhitelistStore(storeURL: storeURL)
      #expect(reader.isWhitelisted(host: "example.com"))
      #expect(reader.isWhitelisted(host: "EXAMPLE.com"))
      #expect(reader.isWhitelisted(host: "news.example.com"))
      #expect(!reader.isWhitelisted(host: "other.com"))
    }
  }

  @Test("allHosts returns sorted lowercase entries")
  func allHostsSortedLowercase() throws {
    try withTempStoreURL { storeURL in
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      store.setWhitelisted(true, host: "Zeta.example")
      store.setWhitelisted(true, host: "alpha.example")
      store.setWhitelisted(true, host: "MIKE.example")
      #expect(store.allHosts == ["alpha.example", "mike.example", "zeta.example"])
    }
  }

  @Test("setWhitelisted is idempotent (no write on duplicate)")
  func setWhitelistedIdempotent() throws {
    try withTempStoreURL { storeURL in
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      store.setWhitelisted(true, host: "example.com")
      // Tampering the on-disk bytes lets the test prove the second
      // setWhitelisted call did not rewrite the file. Comparing
      // bytes avoids relying on filesystem mtime resolution and
      // keeps the suite fast.
      let sentinel = Data("__sentinel__".utf8)
      try sentinel.write(to: storeURL)
      store.setWhitelisted(true, host: "example.com")
      let after = try Data(contentsOf: storeURL)
      #expect(after == sentinel)
    }
  }

  @Test("setWhitelisted false removes the entry")
  func setWhitelistedRemoves() throws {
    try withTempStoreURL { storeURL in
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      store.setWhitelisted(true, host: "example.com")
      store.setWhitelisted(false, host: "Example.COM")
      #expect(!store.isWhitelisted(host: "example.com"))
      #expect(store.allHosts.isEmpty)
    }
  }

  @Test("replaceAll swaps the entire list and normalises hosts")
  func replaceAllSwaps() throws {
    try withTempStoreURL { storeURL in
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      store.setWhitelisted(true, host: "previous.example")
      store.replaceAll(with: ["Foo.example", "BAR.example", "foo.example"])
      #expect(store.allHosts == ["bar.example", "foo.example"])
      #expect(!store.isWhitelisted(host: "previous.example"))
    }
  }

  @Test("corrupt file is quarantined and the store boots empty")
  func corruptFileQuarantine() throws {
    try withTempStoreURL { storeURL in
      try "not valid json".data(using: .utf8)!.write(to: storeURL)
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      #expect(store.allHosts.isEmpty)
      let dir = storeURL.deletingLastPathComponent()
      let entries =
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
        ?? []
      #expect(
        entries.contains(where: { $0.lastPathComponent.hasPrefix("adblocker-whitelist.json.corrupt-") }))
    }
  }

  @Test("setWhitelisted posts the didChangeNotification")
  func setWhitelistedPostsNotification() async throws {
    try withTempStoreURL { storeURL in
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      // `for await` consumes the very next post; race-prone here
      // because the test runs synchronously, so install an
      // observer-with-token instead.
      var posted = false
      let token = NotificationCenter.default.addObserver(
        forName: AdBlockerWhitelistStore.didChangeNotification,
        object: store,
        queue: .main
      ) { _ in
        posted = true
      }
      defer { NotificationCenter.default.removeObserver(token) }
      store.setWhitelisted(true, host: "example.com")
      #expect(posted)
    }
  }

  @Test("replaceAll posts the didChangeNotification")
  func replaceAllPostsNotification() throws {
    try withTempStoreURL { storeURL in
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      var postCount = 0
      let token = NotificationCenter.default.addObserver(
        forName: AdBlockerWhitelistStore.didChangeNotification,
        object: store,
        queue: .main
      ) { _ in
        postCount += 1
      }
      defer { NotificationCenter.default.removeObserver(token) }
      store.replaceAll(with: ["one.example", "two.example"])
      store.replaceAll(with: ["one.example", "two.example"])  // no-op
      store.replaceAll(with: [])
      #expect(postCount == 2)
    }
  }
}

@Suite("AdBlocker.FilterSource")
@MainActor
struct AdBlockerFilterSourceTests {
  @Test("allSources expose unique non-empty ids")
  func sourceIdsAreUnique() {
    let ids = AdBlocker.allSources.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids.allSatisfy { !$0.isEmpty })
  }

  @Test("every shipped source carries a homepage URL")
  func everySourceHasHomepage() {
    for source in AdBlocker.allSources {
      #expect(source.homepage != nil, "\(source.id) missing homepage")
    }
  }
}

@Suite("Content Blocker preferences fan-out")
@MainActor
struct ContentBlockerPreferencesTests {
  private func withTempStoreURL(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ContentBlockerPreferencesTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir.appendingPathComponent("preferences.json"))
  }

  @Test("preferences round-trip enabled sources / interval / last refresh")
  func roundTripAdblockerFields() throws {
    try withTempStoreURL { storeURL in
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      let writer = PreferencesStore(storeURL: storeURL)
      writer.update {
        $0.adblockerEnabledSources = ["easylist"]
        $0.adblockerAutoUpdateIntervalHours = 24
        $0.adblockerLastRefreshedAt = now
      }

      let reader = PreferencesStore(storeURL: storeURL)
      #expect(reader.preferences.adblockerEnabledSources == ["easylist"])
      #expect(reader.preferences.adblockerAutoUpdateIntervalHours == 24)
      #expect(reader.preferences.adblockerLastRefreshedAt == now)
    }
  }

  @Test("older preferences without adblocker fields still decode")
  func legacyDecodeCompatibility() throws {
    try withTempStoreURL { storeURL in
      let legacy = """
        {
          "version": 1,
          "preferences": {
            "searchTemplate": "https://duckduckgo.com/?q={query}",
            "alwaysPromptDownload": true
          }
        }
        """
      try legacy.data(using: .utf8)!.write(to: storeURL)

      let store = PreferencesStore(storeURL: storeURL)
      #expect(store.preferences.adblockerEnabledSources == nil)
      #expect(store.preferences.adblockerAutoUpdateIntervalHours == nil)
      #expect(store.preferences.adblockerLastRefreshedAt == nil)
    }
  }
}
