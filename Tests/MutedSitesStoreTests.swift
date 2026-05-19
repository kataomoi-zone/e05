import Foundation
import Testing

@testable import E05Lib

@Suite("MutedSitesStore")
@MainActor
struct MutedSitesStoreTests {
  @Test("fresh store reports every host as unmuted")
  func defaultsToUnmuted() {
    let store = MutedSitesStore(inMemory: true)
    #expect(!store.isMuted(host: "example.com"))
    #expect(store.allHosts.isEmpty)
  }

  @Test("setMuted true adds the host to the always-mute list")
  func addsMuted() {
    let store = MutedSitesStore(inMemory: true)
    store.setMuted(true, host: "example.com")
    #expect(store.isMuted(host: "example.com"))
    #expect(store.allHosts == ["example.com"])
  }

  @Test("setMuted false drops a previously muted host")
  func dropsMuted() {
    let store = MutedSitesStore(inMemory: true)
    store.setMuted(true, host: "example.com")
    store.setMuted(false, host: "example.com")
    #expect(!store.isMuted(host: "example.com"))
    #expect(store.allHosts.isEmpty)
  }

  @Test("setMuted is idempotent")
  func idempotent() {
    let store = MutedSitesStore(inMemory: true)
    store.setMuted(true, host: "example.com")
    store.setMuted(true, host: "example.com")
    #expect(store.allHosts == ["example.com"])
  }

  @Test("host lookup is case-insensitive on both read and write")
  func caseInsensitive() {
    let store = MutedSitesStore(inMemory: true)
    store.setMuted(true, host: "Example.COM")
    #expect(store.isMuted(host: "example.com"))
    #expect(store.isMuted(host: "EXAMPLE.com"))
    #expect(store.allHosts == ["example.com"])
  }

  @Test("subdomains are independent entries")
  func subdomainsIndependent() {
    let store = MutedSitesStore(inMemory: true)
    store.setMuted(true, host: "mail.google.com")
    #expect(store.isMuted(host: "mail.google.com"))
    #expect(!store.isMuted(host: "docs.google.com"))
    #expect(!store.isMuted(host: "google.com"))
  }

  @Test("allHosts returns hosts in sorted order")
  func sortedHosts() {
    let store = MutedSitesStore(inMemory: true)
    store.setMuted(true, host: "zebra.example.com")
    store.setMuted(true, host: "alpha.example.com")
    store.setMuted(true, host: "mike.example.com")
    #expect(store.allHosts == ["alpha.example.com", "mike.example.com", "zebra.example.com"])
  }

  // MARK: - Disk-backed paths

  private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("MutedSitesStoreTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
  }

  @Test("a disk-backed store round-trips through save and re-load")
  func diskRoundTrip() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("muted-sites.json")
      let writer = MutedSitesStore(storeURL: storeURL)
      writer.setMuted(true, host: "example.com")
      writer.setMuted(true, host: "mail.google.com")

      let reader = MutedSitesStore(storeURL: storeURL)
      #expect(reader.isMuted(host: "example.com"))
      #expect(reader.isMuted(host: "mail.google.com"))
      #expect(!reader.isMuted(host: "docs.google.com"))
    }
  }

  @Test("a corrupted JSON file is quarantined and the store starts empty")
  func corruptedJSONIsQuarantined() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("muted-sites.json")
      try Data("not valid json".utf8).write(to: storeURL)

      let store = MutedSitesStore(storeURL: storeURL)
      #expect(store.allHosts.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))
      let siblings = try FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
      #expect(siblings.contains { $0.lastPathComponent.hasPrefix("muted-sites.json.corrupt-") })
    }
  }
}
