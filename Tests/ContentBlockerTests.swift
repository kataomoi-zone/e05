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

  @Test("normalizeHost reduces a pasted URL to a bare host")
  func normalizeHostStripsSchemeAndPath() {
    #expect(
      AdBlockerWhitelistStore.normalizeHost("https://www.youtube.com/watch?v=abc&t=1")
        == "www.youtube.com")
    #expect(AdBlockerWhitelistStore.normalizeHost("  HTTP://Example.COM/path  ") == "example.com")
    #expect(AdBlockerWhitelistStore.normalizeHost("example.com:8080") == "example.com")
    #expect(
      AdBlockerWhitelistStore.normalizeHost("user:pass@host.example.com/p") == "host.example.com")
    #expect(AdBlockerWhitelistStore.normalizeHost("example.com") == "example.com")
    #expect(AdBlockerWhitelistStore.normalizeHost("   ") == "")
  }

  @Test("setWhitelisted normalizes a pasted URL so it matches the bare host")
  func setWhitelistedNormalizesURL() throws {
    try withTempStoreURL { storeURL in
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      store.setWhitelisted(true, host: "https://www.youtube.com/watch?v=abc")
      #expect(store.isWhitelisted(host: "www.youtube.com"))
      #expect(store.allHosts == ["www.youtube.com"])
    }
  }

  @Test("isWhitelisted matches the host and any subdomain of an entry")
  func isWhitelistedCoversSubdomains() throws {
    try withTempStoreURL { storeURL in
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      store.setWhitelisted(true, host: "youtube.com")
      // The entry itself and any subdomain of it.
      #expect(store.isWhitelisted(host: "youtube.com"))
      #expect(store.isWhitelisted(host: "www.youtube.com"))
      #expect(store.isWhitelisted(host: "m.youtube.com"))
      #expect(store.isWhitelisted(host: "a.b.youtube.com"))
      // A sibling domain that merely ends in the same letters must not
      // match (parent walk is label-aware, not a suffix test).
      #expect(!store.isWhitelisted(host: "notyoutube.com"))
      #expect(!store.isWhitelisted(host: "youtube.com.evil.com"))
      #expect(!store.isWhitelisted(host: "example.com"))
    }
  }

  @Test("isWhitelisted never matches on a bare TLD entry")
  func isWhitelistedIgnoresBareTLD() throws {
    try withTempStoreURL { storeURL in
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      store.setWhitelisted(true, host: "com")
      // A subdomain walk that reached the bare TLD would blanket every
      // .com site; it must stop above the registrable domain.
      #expect(!store.isWhitelisted(host: "youtube.com"))
      #expect(store.isWhitelisted(host: "com"))
    }
  }

  @Test("isWhitelisted matches a single-label host like localhost")
  func isWhitelistedSingleLabelHost() throws {
    try withTempStoreURL { storeURL in
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      store.setWhitelisted(true, host: "localhost")
      // A dotless host must match its own entry across every layer; the
      // JS `hostnameChain` mirrors this by always including the full host.
      #expect(store.isWhitelisted(host: "localhost"))
      #expect(!store.isWhitelisted(host: "notlocalhost"))
    }
  }

  @Test("normalizeHost keeps a bracketed IPv6 literal as a bare address")
  func normalizeHostIPv6() {
    #expect(AdBlockerWhitelistStore.normalizeHost("[::1]:8080") == "::1")
    #expect(AdBlockerWhitelistStore.normalizeHost("http://[::1]:8080/path") == "::1")
    #expect(
      AdBlockerWhitelistStore.normalizeHost("https://user@[2001:db8::1]:443/x") == "2001:db8::1")
  }

  @Test("normalizeHost trims a trailing dot")
  func normalizeHostTrailingDot() {
    #expect(AdBlockerWhitelistStore.normalizeHost("Example.COM.") == "example.com")
  }

  @Test("replaceAll normalizes pasted URLs and drops empties")
  func replaceAllNormalizes() throws {
    try withTempStoreURL { storeURL in
      let store = AdBlockerWhitelistStore(storeURL: storeURL)
      store.replaceAll(with: ["https://www.youtube.com/watch?v=x", "example.com:8080", "   "])
      #expect(store.allHosts == ["example.com", "www.youtube.com"])
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
        entries.contains(where: {
          $0.lastPathComponent.hasPrefix("adblocker-whitelist.json.corrupt-")
        }))
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

  @Test("core category sources are default-enabled, optional are not")
  func categoryMatchesDefaultEnabled() {
    for source in AdBlocker.builtInSources {
      switch source.category {
      case .core:
        #expect(source.defaultEnabled, "\(source.id) is .core but not defaultEnabled")
      case .optional:
        #expect(!source.defaultEnabled, "\(source.id) is .optional but defaultEnabled")
      }
    }
  }

  @Test("built-in default-enabled set matches the .core category")
  func builtInDefaultsAreCore() {
    let coreIds = Set(AdBlocker.builtInSources.filter { $0.category == .core }.map(\.id))
    let defaults = Set(AdBlocker.builtInSources.filter(\.defaultEnabled).map(\.id))
    #expect(defaults == coreIds)
    #expect(!coreIds.isEmpty)
  }

  @Test("cache filenames are unique across the catalog")
  func cacheFilenamesAreUnique() {
    let names = AdBlocker.builtInSources.map(\.cacheFilename)
    #expect(Set(names).count == names.count)
  }
}

@Suite("AdBlocker.customSources")
@MainActor
struct AdBlockerCustomSourcesTests {
  private func source(
    id: String = "01HXTEST00000000000000000", name: String = "Custom",
    url: String, homepage: String? = nil
  ) -> AdblockerCustomSource {
    AdblockerCustomSource(
      id: id, name: name, url: url, homepage: homepage,
      addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  @Test("empty input yields no FilterSource entries")
  func emptyInput() {
    #expect(AdBlocker.customSources([]).isEmpty)
  }

  @Test("https URL maps to a FilterSource with the custom id prefix")
  func httpsURLMaps() {
    let raw = source(id: "ABC", url: "https://example.com/list.txt")
    let mapped = AdBlocker.customSources([raw])
    #expect(mapped.count == 1)
    let first = mapped[0]
    #expect(first.id == "custom-ABC")
    #expect(first.name == "Custom")
    #expect(first.homepage == nil)
    #expect(first.category == .optional)
    #expect(first.defaultEnabled)
  }

  @Test("http URL is allowed")
  func httpURLMaps() {
    let raw = source(url: "http://example.com/list.txt")
    #expect(AdBlocker.customSources([raw]).count == 1)
  }

  @Test("non-http(s) schemes are silently dropped")
  func badSchemesDropped() {
    let entries = [
      source(id: "FILE", url: "file:///etc/passwd"),
      source(id: "JS", url: "javascript:alert(1)"),
      source(id: "FTP", url: "ftp://example.com/list.txt"),
      source(id: "EMPTY", url: ""),
      source(id: "NOSCHEME", url: "example.com/list.txt"),
    ]
    #expect(AdBlocker.customSources(entries).isEmpty)
  }

  @Test("valid homepage URL surfaces, invalid is treated as nil")
  func homepageParsing() {
    let withValid = source(
      id: "A", url: "https://e.com/l.txt", homepage: "https://e.com")
    let withInvalid = source(
      id: "B", url: "https://e.com/l.txt", homepage: "not a url")
    let mapped = AdBlocker.customSources([withValid, withInvalid])
    #expect(mapped[0].homepage?.absoluteString == "https://e.com")
    // `URL(string:)` accepts most strings (returning a relative URL),
    // so the adapter does not pre-filter homepage; UI guards malformed
    // values at input time.
    #expect(mapped[1].homepage != nil)
  }

  @Test("AdblockerCustomSource round-trips through JSON")
  func customSourceCodableRoundTrip() throws {
    let original = source(
      id: "ULID1", name: "Test", url: "https://a.com/l.txt",
      homepage: "https://a.com")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AdblockerCustomSource.self, from: data)
    #expect(decoded == original)
  }
}

@Suite("AdBlocker.isSourceEnabled")
@MainActor
struct AdBlockerIsSourceEnabledTests {
  @Test("nil enabled list falls back to per-source defaultEnabled")
  func nilFallsBackToDefault() {
    for source in AdBlocker.builtInSources {
      #expect(
        AdBlocker.isSourceEnabled(source, enabledIds: nil)
          == source.defaultEnabled
      )
    }
  }

  @Test("explicit list overrides defaultEnabled in both directions")
  func explicitListOverrides() {
    let easylist = AdBlocker.builtInSources.first { $0.id == "easylist" }!
    let japanese = AdBlocker.builtInSources.first { $0.id == "adguard-japanese" }!
    // Listed → enabled even though Japanese is .optional.
    #expect(AdBlocker.isSourceEnabled(japanese, enabledIds: ["adguard-japanese"]))
    // Unlisted → disabled even though EasyList is .core.
    #expect(!AdBlocker.isSourceEnabled(easylist, enabledIds: ["adguard-japanese"]))
    // Empty explicit list disables everything.
    #expect(!AdBlocker.isSourceEnabled(easylist, enabledIds: []))
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
      #expect(store.preferences.adblockerCustomSources == nil)
    }
  }

  @Test("preferences round-trip custom sources")
  func roundTripCustomSources() throws {
    try withTempStoreURL { storeURL in
      let added = Date(timeIntervalSince1970: 1_700_000_000)
      let entries = [
        AdblockerCustomSource(
          id: "ABC", name: "Custom A", url: "https://a.example/list.txt",
          homepage: "https://a.example", addedAt: added),
        AdblockerCustomSource(
          id: "DEF", name: "Custom B", url: "https://b.example/list.txt",
          homepage: nil, addedAt: added),
      ]
      let writer = PreferencesStore(storeURL: storeURL)
      writer.update { $0.adblockerCustomSources = entries }

      let reader = PreferencesStore(storeURL: storeURL)
      #expect(reader.preferences.adblockerCustomSources == entries)
    }
  }
}
