import AppKit
import Testing

@testable import E05Lib

@Suite("Bookmark drop order")
@MainActor
struct BookmarkDropOrderTests {
  @Test("dragging down within a parent lands at the gap that was dropped on")
  func downWithinParent() {
    // Gap 2 is between 20 and 30 while 10 still sits in its old slot.
    #expect(
      BookmarksSidebarView.order(of: [10, 20, 30], dropping: 10, atChildIndex: 2)
        == [20, 10, 30])
    #expect(
      BookmarksSidebarView.order(of: [10, 20, 30], dropping: 10, atChildIndex: 3)
        == [20, 30, 10])
  }

  @Test("dragging up, or in from another parent, keeps the index")
  func upOrFromElsewhere() {
    #expect(
      BookmarksSidebarView.order(of: [10, 20, 30], dropping: 30, atChildIndex: 0)
        == [30, 10, 20])
    #expect(
      BookmarksSidebarView.order(of: [10, 20, 30], dropping: 99, atChildIndex: 1)
        == [10, 99, 20, 30])
  }

  @Test("a drop on the parent itself appends")
  func onParent() {
    #expect(
      BookmarksSidebarView.order(
        of: [10, 20], dropping: 10, atChildIndex: NSOutlineViewDropOnItemIndex)
        == [20, 10])
  }
}
