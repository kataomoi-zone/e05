import Foundation
import Testing

@testable import E05Lib

/// Two workspaces, one row each, separated along y. Which way is up on
/// screen does not enter into it: moves within a column and into the next
/// workspace follow the model's own order (pane 0 is the top of a column),
/// and the overlap that decides where they land sideways is measured
/// against the other axis.
///
/// ```
/// ws 0:  [ A ][ B pane 0 ][ C ]
///        [ A ][ B pane 1 ][ C ]
/// ws 1:  [ D        ][ E ]
/// ```
private func fixture() -> [[[PaneMapGeometry.Slot]]] {
  func slot(_ ws: Int, _ col: Int, _ pane: Int, _ rect: CGRect) -> PaneMapGeometry.Slot {
    PaneMapGeometry.Slot(workspace: ws, column: col, pane: pane, rect: rect)
  }
  return [
    [
      [slot(0, 0, 0, CGRect(x: 0, y: 0, width: 600, height: 800))],
      [
        slot(0, 1, 0, CGRect(x: 600, y: 0, width: 400, height: 400)),
        slot(0, 1, 1, CGRect(x: 600, y: 400, width: 400, height: 400)),
      ],
      [slot(0, 2, 0, CGRect(x: 1000, y: 0, width: 500, height: 800))],
    ],
    [
      [slot(1, 0, 0, CGRect(x: 0, y: 960, width: 900, height: 800))],
      [slot(1, 1, 0, CGRect(x: 900, y: 960, width: 400, height: 800))],
    ],
  ]
}

private let noPreference = [[0, 0, 0], [0, 0]]

@Suite("Pane map projection")
struct PaneMapProjectionTests {
  let center = CGPoint(x: 300, y: 400)
  let target = CGPoint(x: 640, y: 400)

  @Test("what the camera is pointed at lands on the target")
  func centerLandsOnTarget() {
    let point = PaneMapGeometry.project(center, scale: 0.42, center: center, target: target)
    #expect(point == target)
  }

  @Test("a rect shrinks by the scale")
  func rectShrinks() {
    let rect = PaneMapGeometry.project(
      CGRect(x: 0, y: 0, width: 600, height: 800), scale: 0.5, center: center, target: target)
    #expect(rect.size == CGSize(width: 300, height: 400))
  }
}

@Suite("Pane map panning")
struct PaneMapPanTests {
  // Halved around the origin, so the projected box is the target ± half
  // of it: a 400pt map draws 200pt wide, its leading edge 50pt left of
  // wherever the camera is aimed.
  let scale: CGFloat = 0.5
  let center = CGPoint.zero
  let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
  let big = CGRect(x: -100, y: -100, width: 400, height: 400)
  let small = CGRect(x: -20, y: -20, width: 40, height: 40)

  private func clamp(_ target: CGPoint, _ box: CGRect) -> CGPoint {
    PaneMapGeometry.clampedTarget(
      target, box: box, scale: scale, center: center, viewport: viewport)
  }

  @Test("a map covering the window can be panned freely inside it")
  func coveringStaysPut() {
    #expect(clamp(CGPoint(x: 50, y: 50), big) == CGPoint(x: 50, y: 50))
  }

  @Test("a map covering the window stops when an edge reaches the window's")
  func coveringStopsAtEdges() {
    // Pushed right until its leading edge would come into view.
    #expect(clamp(CGPoint(x: 120, y: 50), big).x == 50)
    // And the other way, until its trailing edge would.
    #expect(clamp(CGPoint(x: -60, y: 50), big).x == -50)
  }

  @Test("a map smaller than the window is kept inside it")
  func smallerStaysInside() {
    #expect(clamp(CGPoint(x: 50, y: 50), small) == CGPoint(x: 50, y: 50))
    #expect(clamp(CGPoint(x: 5, y: 50), small).x == 10)
    #expect(clamp(CGPoint(x: 95, y: 50), small).x == 90)
  }

  @Test("the vertical axis is clamped on the same terms")
  func verticalToo() {
    #expect(clamp(CGPoint(x: 50, y: 120), big).y == 50)
    #expect(clamp(CGPoint(x: 50, y: 5), small).y == 10)
  }
}

@Suite("Pane map navigation")
struct PaneMapNavigationTests {
  let slots = fixture()

  private func move(
    _ from: (Int, Int, Int), _ direction: PaneMapGeometry.Direction,
    preferring: [[Int]] = noPreference
  ) -> (Int, Int, Int)? {
    let current = slots[from.0][from.1][from.2]
    guard
      let next = PaneMapGeometry.neighbor(
        of: current, direction: direction, in: slots, preferring: preferring)
    else { return nil }
    return (next.workspace, next.column, next.pane)
  }

  @Test("sideways steps one column over, staying in the workspace")
  func sideways() {
    #expect(move((0, 0, 0), .right).map { $0 == (0, 1, 0) } == true)
    #expect(move((0, 2, 0), .left).map { $0 == (0, 1, 0) } == true)
  }

  @Test("a row ends at its outer columns")
  func rowEnds() {
    #expect(move((0, 0, 0), .left) == nil)
    #expect(move((0, 2, 0), .right) == nil)
  }

  @Test("a split column hands over the pane sharing the most height")
  func splitColumnOverlap() {
    // From the bottom half of column 1, the full-height column 2 is the
    // only candidate; coming back picks the half the pointer faces.
    #expect(move((0, 1, 1), .right).map { $0 == (0, 2, 0) } == true)
    #expect(
      move((0, 2, 0), .left, preferring: [[0, 1, 0], [0, 0]]).map { $0 == (0, 1, 1) } == true)
  }

  @Test("an even tie goes to the pane that column was last on")
  func tieUsesPreference() {
    #expect(
      move((0, 0, 0), .right, preferring: [[0, 1, 0], [0, 0]]).map { $0 == (0, 1, 1) } == true)
    #expect(
      move((0, 0, 0), .right, preferring: [[0, 0, 0], [0, 0]]).map { $0 == (0, 1, 0) } == true)
  }

  @Test("up and down walk the column before leaving it")
  func withinColumn() {
    #expect(move((0, 1, 0), .down).map { $0 == (0, 1, 1) } == true)
    #expect(move((0, 1, 1), .up).map { $0 == (0, 1, 0) } == true)
  }

  @Test("leaving the column carries on into the next workspace")
  func acrossWorkspaces() {
    // Column 0 of ws 0 (x 0..600) overlaps ws 1's first column most.
    #expect(move((0, 0, 0), .down).map { $0 == (1, 0, 0) } == true)
    // Column 2 (x 1000..1500) overlaps ws 1's second column (900..1300).
    #expect(move((0, 2, 0), .down).map { $0 == (1, 1, 0) } == true)
    #expect(move((1, 1, 0), .up).map { $0 == (0, 2, 0) } == true)
  }

  @Test("the bottom pane of a split column is the one a move up arrives at")
  func entersFromTheNearEdge() {
    // Slide ws 1's first column right so the split column wins the overlap.
    var shifted = slots
    shifted[1][0] = [
      PaneMapGeometry.Slot(
        workspace: 1, column: 0, pane: 0, rect: CGRect(x: 600, y: 960, width: 400, height: 800))
    ]
    let intoSplit = PaneMapGeometry.neighbor(
      of: shifted[1][0][0], direction: .up, in: shifted, preferring: noPreference)
    #expect(intoSplit.map { ($0.column, $0.pane) == (1, 1) } == true)
  }

  @Test("a move is measured from where the pane is now, not from a stale rect")
  func staleRectIgnored() {
    // What the caller holds after a camera move: the right slot, at the
    // place it occupied a pan ago.
    let stale = PaneMapGeometry.Slot(
      workspace: 0, column: 2, pane: 0, rect: CGRect(x: -900, y: 0, width: 500, height: 800))
    // That rect faces ws 1's first column; the live one faces its second.
    #expect(
      PaneMapGeometry.neighbor(of: stale, direction: .down, in: slots, preferring: noPreference)
        .map { ($0.workspace, $0.column) == (1, 1) } == true)
  }

  @Test("the map ends above the first workspace and below the last")
  func mapEnds() {
    #expect(move((0, 0, 0), .up) == nil)
    #expect(move((1, 0, 0), .down) == nil)
  }

  @Test("sideways follows the screen, not the column index")
  func sidewaysFollowsTheScreen() {
    // A pinned column leaves the scrolling stack for the row's leading
    // edge: column 1 by index, leftmost on screen. Handed over in drawn
    // order, moving right from it reaches column 0, not column 2.
    let pinned = PaneMapGeometry.Slot(
      workspace: 0, column: 1, pane: 0, rect: CGRect(x: 0, y: 0, width: 300, height: 800))
    let middle = PaneMapGeometry.Slot(
      workspace: 0, column: 0, pane: 0, rect: CGRect(x: 300, y: 0, width: 600, height: 800))
    let last = PaneMapGeometry.Slot(
      workspace: 0, column: 2, pane: 0, rect: CGRect(x: 900, y: 0, width: 400, height: 800))
    let drawn = [[[pinned], [middle], [last]]]
    let preferring = [[0, 0, 0]]
    #expect(
      PaneMapGeometry.neighbor(of: pinned, direction: .right, in: drawn, preferring: preferring)
        == middle)
    #expect(
      PaneMapGeometry.neighbor(of: middle, direction: .left, in: drawn, preferring: preferring)
        == pinned)
    #expect(
      PaneMapGeometry.neighbor(of: pinned, direction: .left, in: drawn, preferring: preferring)
        == nil)
  }
}
