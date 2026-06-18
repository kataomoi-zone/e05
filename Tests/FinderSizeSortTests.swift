import Foundation
import Testing

@testable import E05Lib

/// The Size-column comparator (`FinderPaneView.compare`, via `sortItems`)
/// is the heart of "sort apps by their measured size". Pin its three-way
/// size tier — a package sorts by `packageSizes[url] ?? 0`, a plain
/// directory by `Int64.min` (clustered at the unknown-size end), a file by
/// its own size — and the not-yet-measured fallback, all just introduced.
@Suite("FinderPaneView size sort")
@MainActor
struct FinderSizeSortTests {
  private struct Fixture {
    let dir: URL
    let plainFolder: FileItem
    let smallFile: FileItem
    let bigFile: FileItem
    let package: FileItem
  }

  private func makeFixture() throws -> Fixture {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("e05-sizesort-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let plain = dir.appendingPathComponent("PlainFolder")
    try fm.createDirectory(at: plain, withIntermediateDirectories: true)
    // A `.app` extension makes the directory a package even when empty.
    let app = dir.appendingPathComponent("Sized.app")
    try fm.createDirectory(at: app, withIntermediateDirectories: true)
    let small = dir.appendingPathComponent("small.txt")
    try Data(count: 10).write(to: small)
    let big = dir.appendingPathComponent("big.txt")
    try Data(count: 1000).write(to: big)
    return Fixture(
      dir: dir,
      plainFolder: FileItem(url: plain),
      smallFile: FileItem(url: small),
      bigFile: FileItem(url: big),
      package: FileItem(url: app))
  }

  @Test("a package sorts by its measured size; plain folders cluster")
  func sortsPackagesByMeasuredSize() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    #expect(fixture.package.isPackage)
    #expect(!fixture.plainFolder.isPackage)

    let items = [fixture.bigFile, fixture.plainFolder, fixture.package, fixture.smallFile]
    let sizes = [fixture.package.url: Int64(5000)]

    let ascending = FinderPaneView.sortItems(
      items, key: .size, ascending: true, packageSizes: sizes)
    #expect(
      ascending.map(\.name) == ["PlainFolder", "small.txt", "big.txt", "Sized.app"])

    let descending = FinderPaneView.sortItems(
      items, key: .size, ascending: false, packageSizes: sizes)
    #expect(
      descending.map(\.name) == ["Sized.app", "big.txt", "small.txt", "PlainFolder"])
  }

  @Test("a not-yet-measured package sorts as 0 bytes")
  func unmeasuredPackageSortsAtZero() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }

    // No packageSizes: the package falls back to 0, landing among the empty
    // files rather than at the folder cluster (`Int64.min`).
    let ascending = FinderPaneView.sortItems(
      [fixture.bigFile, fixture.smallFile, fixture.package, fixture.plainFolder],
      key: .size, ascending: true)
    #expect(
      ascending.map(\.name) == ["PlainFolder", "Sized.app", "small.txt", "big.txt"])
  }
}
