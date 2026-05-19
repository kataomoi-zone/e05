import Foundation
import Testing

@testable import E05Lib

@Suite("DownloadsManager")
@MainActor
struct DownloadsManagerTests {
  @Test("clearAll empties the in-memory list and the underlying store")
  func clearAllEmpties() {
    let store = DownloadsStore(inMemory: true)
    _ = store.insert(
      url: "https://example.com/a.zip", filename: "a.zip",
      destination: "/tmp/a.zip", state: DownloadState.completed.rawValue)
    _ = store.insert(
      url: "https://example.com/b.zip", filename: "b.zip",
      destination: "/tmp/b.zip", state: DownloadState.completed.rawValue)

    let manager = DownloadsManager(store: store)
    #expect(manager.all().count == 2)

    manager.clearAll()

    #expect(manager.all().isEmpty)
    #expect(store.all().isEmpty)
  }

  @Test("clearAll fires listeners exactly once")
  func clearAllNotifies() {
    let store = DownloadsStore(inMemory: true)
    _ = store.insert(
      url: "https://example.com/a.zip", filename: "a.zip",
      destination: "/tmp/a.zip", state: DownloadState.completed.rawValue)
    let manager = DownloadsManager(store: store)

    var fireCount = 0
    let token = manager.addListener { fireCount += 1 }
    defer { manager.removeListener(token) }

    manager.clearAll()
    #expect(fireCount == 1)
  }

  @Test("clearAll on an already-empty manager still notifies")
  func clearAllOnEmptyNotifies() {
    let manager = DownloadsManager(store: DownloadsStore(inMemory: true))

    var fireCount = 0
    let token = manager.addListener { fireCount += 1 }
    defer { manager.removeListener(token) }

    manager.clearAll()
    // The listener fires unconditionally so subscribers can pick up
    // the "list is empty now" state even when nothing was loaded —
    // the sidebar listens for the empty-list transition the same
    // way it listens for additions.
    #expect(fireCount == 1)
    #expect(manager.all().isEmpty)
  }
}
