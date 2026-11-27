import Foundation
import Testing

@testable import E05Lib

@Suite("Cancellable copy")
struct CancellableCopyTests {
  @Test("a copy refused by an occupied target leaves the occupant alone")
  func occupiedTargetSurvives() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("e05-copy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.txt")
    let target = dir.appendingPathComponent("target.txt")
    try Data("new".utf8).write(to: source)
    try Data("kept".utf8).write(to: target)

    let outcome = FinderPaneView.cancellableCopy(
      from: source, to: target, token: CopyCancellationToken())

    guard case .failed = outcome else {
      Issue.record("expected the copy to be refused, got \(outcome)")
      return
    }
    #expect(try Data(contentsOf: target) == Data("kept".utf8))
  }
}
