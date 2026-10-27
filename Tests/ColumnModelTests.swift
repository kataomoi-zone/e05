import AppKit
import Testing

@testable import E05Lib

@Suite("ColumnModel")
@MainActor
struct ColumnModelTests {
  /// A preset can write a width below the floor, which Auto Layout lifts
  /// the column to. A folded column turns the floor off for its strip.
  @Test("the laid-out width is the requested one lifted to the floor while it applies")
  func laidOutWidthLiftsToTheFloor() {
    let column = ColumnModel(pane: PaneModel(address: .blankBrowser, ghosttyApp: nil))
    let width = column.containerView.widthAnchor.constraint(equalToConstant: 300)
    let floor = column.containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 450)
    floor.isActive = true
    column.widthConstraint = width
    column.minimumWidthConstraint = floor

    #expect(column.laidOutWidth == 450)
    width.constant = 600
    #expect(column.laidOutWidth == 600)
    width.constant = 30
    floor.isActive = false
    #expect(column.laidOutWidth == 30)
  }
}
