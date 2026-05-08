import Foundation
import Testing

@testable import E05Lib

@Suite("FinderModeStore")
@MainActor
struct FinderModeStoreTests {
  @Test("default mode is list for an unseen URL")
  func defaultsToList() {
    let store = FinderModeStore(inMemory: true)
    let url = URL(fileURLWithPath: "/Users/test/foo")
    #expect(store.mode(for: url) == .list)
  }

  @Test("setMode round-trips icon for a directory")
  func setIconMode() {
    let store = FinderModeStore(inMemory: true)
    let url = URL(fileURLWithPath: "/Users/test/foo")
    store.setMode(.icon, for: url)
    #expect(store.mode(for: url) == .icon)
  }

  @Test("setMode list reverts to default for a previously iconified directory")
  func revertToList() {
    let store = FinderModeStore(inMemory: true)
    let url = URL(fileURLWithPath: "/Users/test/foo")
    store.setMode(.icon, for: url)
    store.setMode(.list, for: url)
    #expect(store.mode(for: url) == .list)
  }

  @Test("modes are independent across directories")
  func independentDirectories() {
    let store = FinderModeStore(inMemory: true)
    let a = URL(fileURLWithPath: "/Users/test/a")
    let b = URL(fileURLWithPath: "/Users/test/b")
    store.setMode(.icon, for: a)
    #expect(store.mode(for: a) == .icon)
    #expect(store.mode(for: b) == .list)
  }

  @Test("URL forms differing only in trailing slash share an entry")
  func trailingSlashCollapses() {
    let store = FinderModeStore(inMemory: true)
    let withSlash = URL(fileURLWithPath: "/Users/test/foo/")
    let withoutSlash = URL(fileURLWithPath: "/Users/test/foo")
    store.setMode(.icon, for: withSlash)
    #expect(store.mode(for: withoutSlash) == .icon)
  }

  @Test("root path is preserved as the dict key")
  func rootPathKeyIntact() {
    let store = FinderModeStore(inMemory: true)
    let root = URL(fileURLWithPath: "/")
    store.setMode(.icon, for: root)
    #expect(store.mode(for: root) == .icon)
  }

  @Test("setMode posts didChangeNotification on change")
  func notificationFiresOnChange() {
    let store = FinderModeStore(inMemory: true)
    let url = URL(fileURLWithPath: "/Users/test/foo")

    var fireCount = 0
    let token = NotificationCenter.default.addObserver(
      forName: FinderModeStore.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in
      fireCount += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    store.setMode(.icon, for: url)
    #expect(fireCount == 1)
  }

  @Test("setMode does not fire when the value is unchanged")
  func notificationSilentOnNoOp() {
    let store = FinderModeStore(inMemory: true)
    let url = URL(fileURLWithPath: "/Users/test/foo")
    store.setMode(.icon, for: url)

    var fireCount = 0
    let token = NotificationCenter.default.addObserver(
      forName: FinderModeStore.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in
      fireCount += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    store.setMode(.icon, for: url)
    #expect(fireCount == 0)
  }

  @Test("setMode list on never-set directory is silent")
  func notificationSilentOnDefaultListWrite() {
    let store = FinderModeStore(inMemory: true)
    let url = URL(fileURLWithPath: "/Users/test/foo")

    var fireCount = 0
    let token = NotificationCenter.default.addObserver(
      forName: FinderModeStore.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in
      fireCount += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    store.setMode(.list, for: url)
    #expect(fireCount == 0)
  }

  @Test("Codable round-trip of the on-disk shape preserves modes")
  func codableRoundTrip() throws {
    let modes: [String: FinderViewMode] = [
      "/Users/test/photos": .icon,
      "/Users/test/code": .list,
    ]
    let data = try JSONEncoder().encode(modes)
    let decoded = try JSONDecoder().decode([String: FinderViewMode].self, from: data)
    #expect(decoded == modes)
  }

  @Test("FinderViewMode rawValues match the persisted JSON form")
  func rawValuesArePersisted() throws {
    let data = try JSONEncoder().encode(["x": FinderViewMode.icon, "y": .list])
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"icon\""))
    #expect(json.contains("\"list\""))
  }

  // MARK: - Disk-backed paths

  /// Allocate a unique temp directory for one disk-backed test and
  /// remove the whole tree at scope exit. Each test gets its own
  /// directory so concurrent runs don't see each other's files.
  private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FinderModeStoreTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
  }

  @Test("a disk-backed store round-trips through save and re-load")
  func diskRoundTrip() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("finder-modes.json")
      let target = URL(fileURLWithPath: "/Users/test/photos")

      let writer = FinderModeStore(storeURL: storeURL)
      writer.setMode(.icon, for: target)

      // A second instance reading the same file sees the persisted value.
      let reader = FinderModeStore(storeURL: storeURL)
      #expect(reader.mode(for: target) == .icon)
    }
  }

  @Test("a corrupted JSON file is quarantined, store starts empty")
  func corruptedJSONIsQuarantined() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("finder-modes.json")
      try Data("not valid json".utf8).write(to: storeURL)

      let store = FinderModeStore(storeURL: storeURL)

      // Default empty start — corrupted data isn't surfaced as state.
      #expect(store.mode(for: URL(fileURLWithPath: "/anywhere")) == .list)

      // Original file moved aside, not silently destroyed: a sibling
      // named `<filename>.corrupt-<timestamp>` should now exist.
      #expect(!FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))
      let siblings = try FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
      #expect(siblings.contains { $0.lastPathComponent.hasPrefix("finder-modes.json.corrupt-") })
    }
  }

  @Test("setting back to .list prunes the entry from disk")
  func pruneShrinksDisk() throws {
    try withTempDir { dir in
      let storeURL = dir.appendingPathComponent("finder-modes.json")
      let target = URL(fileURLWithPath: "/Users/test/photos")

      let store = FinderModeStore(storeURL: storeURL)
      store.setMode(.icon, for: target)
      store.setMode(.list, for: target)

      // The on-disk dict is empty after the prune — the reader returns
      // `.list` because the key is missing, not because it was stored.
      let data = try Data(contentsOf: storeURL)
      let decoded = try JSONDecoder().decode([String: FinderViewMode].self, from: data)
      #expect(decoded.isEmpty)

      let fresh = FinderModeStore(storeURL: storeURL)
      #expect(fresh.mode(for: target) == .list)
    }
  }

  @Test("save failure rolls back the in-memory mutation")
  func saveFailureRollsBack() {
    // `/dev/null` is a character device, not a directory. `createDirectory(at:)`
    // on it fails, so `save()` throws, exercising the setMode rollback path.
    let unwritable = URL(fileURLWithPath: "/dev/null/finder-modes.json")
    let store = FinderModeStore(storeURL: unwritable)
    let target = URL(fileURLWithPath: "/Users/test/photos")

    var fireCount = 0
    let token = NotificationCenter.default.addObserver(
      forName: FinderModeStore.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in
      fireCount += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    store.setMode(.icon, for: target)

    // Mutation rolled back: the in-memory state matches what's on disk
    // (i.e. nothing), and observers were not told about a change that
    // didn't survive.
    #expect(store.mode(for: target) == .list)
    #expect(fireCount == 0)
  }
}
