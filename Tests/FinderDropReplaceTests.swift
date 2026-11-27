import Foundation
import Testing

@testable import E05Lib

@Suite("Finder drop replace")
@MainActor
struct FinderDropReplaceTests {
  private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

  @Test("a folder holding the source counts as containing it")
  func ancestorOccupant() {
    #expect(FinderPaneView.occupant(at: url("/a/b"), contains: url("/a/b/b")))
    #expect(FinderPaneView.occupant(at: url("/a/b"), contains: url("/a/b/c/b")))
  }

  @Test("an unrelated item of the same name does not")
  func unrelatedOccupant() {
    #expect(!FinderPaneView.occupant(at: url("/a/b"), contains: url("/x/b")))
    // A name that merely starts the same way is a sibling, not a parent.
    #expect(!FinderPaneView.occupant(at: url("/a/b"), contains: url("/a/bc/b")))
  }
}
