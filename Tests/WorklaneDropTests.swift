import Testing

@testable import E05Lib

@Suite("WorklaneSectionView.paneDropSlot")
struct WorklanePaneDropSlotTests {
  private func slot(
    _ row: WorklaneSectionView.PaneDropRow, lowerHalf: Bool
  ) -> WorklaneSectionView.PaneDropSlot {
    WorklaneSectionView.paneDropSlot(on: row, lowerHalf: lowerHalf)
  }

  @Test(
    "under a column's last pane: its lower half ends the column, the next row's upper half follows it"
  )
  func gapUnderColumnSplitsByRow() {
    // Column 1 holds two panes; column 2 follows it.
    #expect(slot(.paneInColumn(index: 1), lowerHalf: true) == .intoColumn(position: 2))
    #expect(slot(.pane(column: 2), lowerHalf: false) == .newColumn(position: 2))
    #expect(
      slot(.column(index: 2, paneCount: 2, isExpanded: true), lowerHalf: false)
        == .newColumn(position: 2))
  }

  @Test("above a workspace header is the end of the workspace before it")
  func aboveHeaderEndsPreviousWorkspace() {
    #expect(
      slot(.workspace(previousColumnCount: 3), lowerHalf: false)
        == .newColumnInPreviousWorkspace(position: 3))
    #expect(slot(.workspace(previousColumnCount: 3), lowerHalf: true) == .newColumn(position: 0))
    #expect(slot(.workspace(previousColumnCount: nil), lowerHalf: false) == .newColumn(position: 0))
  }

  @Test("below a column header is the column's start, or its end while it is collapsed")
  func columnHeader() {
    #expect(
      slot(.column(index: 1, paneCount: 3, isExpanded: true), lowerHalf: true)
        == .intoColumn(position: 0))
    #expect(
      slot(.column(index: 1, paneCount: 3, isExpanded: false), lowerHalf: true)
        == .intoColumn(position: 3))
  }

  @Test("pane rows drop before themselves on the upper half and after on the lower")
  func paneHalves() {
    #expect(slot(.pane(column: 0), lowerHalf: false) == .newColumn(position: 0))
    #expect(slot(.pane(column: 0), lowerHalf: true) == .newColumn(position: 1))
    #expect(slot(.paneInColumn(index: 0), lowerHalf: false) == .intoColumn(position: 0))
    #expect(slot(.paneInColumn(index: 0), lowerHalf: true) == .intoColumn(position: 1))
  }
}
