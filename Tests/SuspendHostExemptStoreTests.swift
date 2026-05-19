import Foundation
import Testing

@testable import E05Lib

@Suite("SuspendHostExemptStore")
@MainActor
struct SuspendHostExemptStoreTests {
  @Test("fresh store reports every host as non-exempt")
  func defaultsToNonExempt() {
    let store = SuspendHostExemptStore(inMemory: true)
    #expect(!store.isExempt(host: "example.com"))
    #expect(store.allHosts.isEmpty)
  }

  @Test("setExempt true adds the host to the always-active list")
  func addsExempt() {
    let store = SuspendHostExemptStore(inMemory: true)
    store.setExempt(true, host: "example.com")
    #expect(store.isExempt(host: "example.com"))
    #expect(store.allHosts == ["example.com"])
  }

  @Test("setExempt false drops a previously added host")
  func removesExempt() {
    let store = SuspendHostExemptStore(inMemory: true)
    store.setExempt(true, host: "example.com")
    store.setExempt(false, host: "example.com")
    #expect(!store.isExempt(host: "example.com"))
    #expect(store.allHosts.isEmpty)
  }

  @Test("remove(host:) is the same as setExempt false")
  func removeAlias() {
    let store = SuspendHostExemptStore(inMemory: true)
    store.setExempt(true, host: "example.com")
    store.remove(host: "example.com")
    #expect(!store.isExempt(host: "example.com"))
  }

  @Test("host lookup is case-insensitive on both read and write")
  func caseInsensitive() {
    let store = SuspendHostExemptStore(inMemory: true)
    store.setExempt(true, host: "Example.COM")
    #expect(store.isExempt(host: "example.com"))
    #expect(store.isExempt(host: "EXAMPLE.com"))
    #expect(store.allHosts == ["example.com"])
  }

  @Test("subdomains are independent entries")
  func subdomainsIndependent() {
    let store = SuspendHostExemptStore(inMemory: true)
    store.setExempt(true, host: "mail.google.com")
    #expect(store.isExempt(host: "mail.google.com"))
    #expect(!store.isExempt(host: "docs.google.com"))
    #expect(!store.isExempt(host: "google.com"))
  }

  @Test("allHosts returns hosts in sorted order")
  func sortedHosts() {
    let store = SuspendHostExemptStore(inMemory: true)
    store.setExempt(true, host: "zebra.example.com")
    store.setExempt(true, host: "alpha.example.com")
    store.setExempt(true, host: "mike.example.com")
    #expect(store.allHosts == ["alpha.example.com", "mike.example.com", "zebra.example.com"])
  }

  // MARK: - Disk-backed paths

  /// Allocate a unique temp directory for one disk-backed test and
  /// remove the whole tree at scope exit. Each test gets its own
  /// directory so concurrent runs don't see each other's files.
  private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SuspendHostExemptStoreTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
  }

  @Test("a disk-backed store round-trips through save and re-load")
  func diskRoundTrip() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("suspend-exempt.json")
      let writer = SuspendHostExemptStore(storeURL: storeURL)
      writer.setExempt(true, host: "example.com")
      writer.setExempt(true, host: "mail.google.com")

      let reader = SuspendHostExemptStore(storeURL: storeURL)
      #expect(reader.isExempt(host: "example.com"))
      #expect(reader.isExempt(host: "mail.google.com"))
      #expect(!reader.isExempt(host: "docs.google.com"))
    }
  }

  @Test("missing file yields an empty store, never throws")
  func missingFileEmpty() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("suspend-exempt.json")
      let store = SuspendHostExemptStore(storeURL: storeURL)
      #expect(store.allHosts.isEmpty)
    }
  }

  @Test("a corrupted JSON file is quarantined and the store starts empty")
  func corruptedJSONIsQuarantined() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("suspend-exempt.json")
      try Data("not valid json".utf8).write(to: storeURL)

      let store = SuspendHostExemptStore(storeURL: storeURL)
      #expect(store.allHosts.isEmpty)

      #expect(!FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))
      let siblings = try FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
      #expect(siblings.contains { $0.lastPathComponent.hasPrefix("suspend-exempt.json.corrupt-") })
    }
  }

  @Test("save failure rolls back the in-memory mutation")
  func saveFailureRollsBack() {
    // `/dev/null` is a character device, not a directory.
    // `createDirectory(at:)` on it fails, so `save()` throws,
    // exercising the setExempt rollback path.
    let unwritable = URL(fileURLWithPath: "/dev/null/suspend-exempt.json")
    let store = SuspendHostExemptStore(storeURL: unwritable)
    store.setExempt(true, host: "example.com")
    #expect(!store.isExempt(host: "example.com"))
  }

  @Test("on-disk shape uses a versioned wrapper")
  func onDiskShape() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("suspend-exempt.json")
      let store = SuspendHostExemptStore(storeURL: storeURL)
      store.setExempt(true, host: "example.com")

      let data = try Data(contentsOf: storeURL)
      let json = try #require(String(data: data, encoding: .utf8))
      #expect(json.contains("\"version\""))
      #expect(json.contains("\"hosts\""))
      #expect(json.contains("\"example.com\""))
    }
  }
}
