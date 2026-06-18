import Foundation
import Testing

@testable import E05Lib

/// `FinderPaneView.totalSize` is the `du -A` walk shared by the copy
/// progress bar's denominator and the finder Size column's package size.
/// It was re-derived three times (on-disk allocated → naive logical → du
/// -A) to match Finder, so these pin the two properties that distinguish
/// the final form from the wrong ones: hard links count once and symlinks
/// aren't followed.
@Suite("FinderPaneView.totalSize")
struct FinderTotalSizeTests {
  private func makeTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("e05-totalsize-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test("a single file reports its byte size")
  func singleFile() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a.dat")
    try Data(count: 500).write(to: file)
    #expect(FinderPaneView.totalSize(of: file) == 500)
  }

  @Test("a hard link counts its inode once and a symlink isn't followed")
  func dedupsHardLinksAndSkipsSymlinks() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let big = dir.appendingPathComponent("big.dat")
    try Data(count: 1_000_000).write(to: big)
    // Same inode under a second name — must not be re-counted.
    try FileManager.default.linkItem(
      at: big, to: dir.appendingPathComponent("hardlink.dat"))
    // Following this would re-count the 1 MB payload — it must not.
    try FileManager.default.createSymbolicLink(
      at: dir.appendingPathComponent("alias.lnk"), withDestinationURL: big)
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("emptysub"),
      withIntermediateDirectories: true)

    let total = FinderPaneView.totalSize(of: dir)
    // The payload is counted exactly once. A naive sum would reach ~3 MB:
    // the hard link and the followed symlink would each re-add the 1 MB.
    #expect(total >= 1_000_000)
    #expect(total < 1_100_000)
  }
}
