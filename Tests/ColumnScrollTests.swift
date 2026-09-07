import Foundation
import Testing

@testable import E05Lib

@Suite("PaneContainerViewController.columnScrollTargetX")
struct ColumnScrollTargetTests {
  /// Defaults model a 1000pt viewport holding 3000pt of columns, no
  /// sidebar inset, and the 6pt inter-column gap. The 400pt column at
  /// minX 1000 sits one viewport-width into the content.
  private func target(
    mode: PaneContainerViewController.ColumnScrollMode,
    currentX: CGFloat = 0,
    columnMinX: CGFloat,
    columnWidth: CGFloat,
    visibleWidth: CGFloat = 1000,
    contentWidth: CGFloat = 3000,
    insetLeft: CGFloat = 0,
    insetRight: CGFloat = 0,
    gap: CGFloat = 6
  ) -> CGFloat? {
    PaneContainerViewController.columnScrollTargetX(
      mode: mode, currentX: currentX, columnMinX: columnMinX,
      columnWidth: columnWidth, visibleWidth: visibleWidth,
      contentWidth: contentWidth, insetLeft: insetLeft,
      insetRight: insetRight, gap: gap)
  }

  @Test("whole content fits: no scroll for any mode")
  func contentFitsIsNoOp() {
    let modes: [PaneContainerViewController.ColumnScrollMode] = [
      .frameIn, .alignLeft, .alignRight, .center,
    ]
    for mode in modes {
      #expect(target(mode: mode, columnMinX: 0, columnWidth: 400, contentWidth: 900) == nil)
    }
  }

  @Test("frame-in leaves an already-visible column untouched")
  func frameInAlreadyVisible() {
    #expect(target(mode: .frameIn, currentX: 994, columnMinX: 1000, columnWidth: 400) == nil)
  }

  @Test("frame-in scrolls right just enough when the column overflows the right edge")
  func frameInOverflowRight() {
    #expect(target(mode: .frameIn, currentX: 0, columnMinX: 1000, columnWidth: 400) == 406)
  }

  @Test("frame-in scrolls left just enough when the column overflows the left edge")
  func frameInOverflowLeft() {
    #expect(target(mode: .frameIn, currentX: 2000, columnMinX: 1000, columnWidth: 400) == 994)
  }

  @Test("frame-in pins the leading edge (with the full gap) for a column wider than the viewport")
  func frameInWiderThanViewport() {
    // Oversized columns can't fit either way, so they keep the full 6pt
    // gutter rather than kissing the viewport edge: 1000 - 0 - 6.
    #expect(target(mode: .frameIn, currentX: 0, columnMinX: 1000, columnWidth: 1200) == 994)
  }

  @Test("frame-in breaks an equal-distance tie toward the leading edge")
  func frameInTieGoesLeft() {
    // A 992pt column plus its 4pt padding on each side spans exactly the
    // 1000pt band, so overflowing the right edge from currentX 0 leaves
    // identical left/right correction distances.
    #expect(target(mode: .frameIn, currentX: 0, columnMinX: 1000, columnWidth: 992) == 996)
  }

  @Test("align-left seats the column against the leading edge regardless of current scroll")
  func alignLeft() {
    #expect(target(mode: .alignLeft, currentX: 500, columnMinX: 1000, columnWidth: 400) == 994)
  }

  @Test("align-right seats the column against the trailing edge regardless of current scroll")
  func alignRight() {
    #expect(target(mode: .alignRight, currentX: 500, columnMinX: 1000, columnWidth: 400) == 406)
  }

  @Test("center places the column at the post-inset midpoint")
  func center() {
    #expect(target(mode: .center, columnMinX: 1000, columnWidth: 400) == 700)
  }

  @Test("center pins an oversized column to the leading edge keeping the full gap")
  func centerOversizedFlushesLeft() {
    #expect(target(mode: .center, columnMinX: 1000, columnWidth: 1200) == 994)
  }

  @Test("the target is clamped to the maximum scroll origin")
  func clampsToMax() {
    #expect(
      target(mode: .alignRight, columnMinX: 2900, columnWidth: 400, contentWidth: 3300) == 2300)
  }

  @Test("the target is clamped to the minimum scroll origin")
  func clampsToMin() {
    #expect(target(mode: .alignLeft, columnMinX: 0, columnWidth: 400) == 0)
  }

  @Test("the sidebar inset shifts the leading-edge alignment")
  func honoursLeftInset() {
    #expect(target(mode: .alignLeft, columnMinX: 1000, columnWidth: 400, insetLeft: 50) == 944)
  }

  @Test("frame-in resolves the leading edge against the post-inset band")
  func frameInHonoursLeftInset() {
    // The most common real path: a pinned sidebar reserves a 60pt left
    // inset and the focused column sits off the left of the band, so
    // frame-in seats it at columnMinX - insetLeft - gap = 1000 - 60 - 6.
    #expect(
      target(mode: .frameIn, currentX: 2000, columnMinX: 1000, columnWidth: 400, insetLeft: 60)
        == 934)
  }

  @Test("align-right resolves the trailing edge against the right inset")
  func alignRightHonoursRightInset() {
    // The visible band's right edge is `visibleWidth - insetRight`, so a
    // 40pt right inset pulls the trailing-edge seat in by that much:
    // 1000 + 400 + 6 - (1000 - 40).
    #expect(
      target(mode: .alignRight, columnMinX: 1000, columnWidth: 400, insetRight: 40) == 446)
  }

  @Test("frame-in treats a column inside the doubly-inset band as visible")
  func frameInBothInsetsAlreadyVisible() {
    // Insets on both sides shrink the band to 900pt; the column at
    // [1000, 1400] with 6pt padding fits inside the band [750, 1650]
    // when scrolled to 700, so frame-in leaves it be.
    #expect(
      target(
        mode: .frameIn, currentX: 700, columnMinX: 1000, columnWidth: 400,
        insetLeft: 50, insetRight: 50) == nil)
  }

  // MARK: - settle

  @Test("settle leaves a seated column alone")
  func settleAlreadySeated() {
    #expect(target(mode: .settle, currentX: 700, columnMinX: 1000, columnWidth: 400) == nil)
  }

  @Test("settle rounds a narrow column back the same way frame-in fits it")
  func settleMatchesFrameInWhenNarrow() {
    // The separate case exists for the oversized column; for anything
    // that fits, settle must not invent a second answer.
    for currentX in stride(from: CGFloat(0), through: 2000, by: 250) {
      for width in [CGFloat(200), 400, 900] {
        #expect(
          target(mode: .settle, currentX: currentX, columnMinX: 1000, columnWidth: width)
            == target(mode: .frameIn, currentX: currentX, columnMinX: 1000, columnWidth: width),
          "settle and frame-in disagree at currentX \(currentX), width \(width)")
      }
    }
  }

  @Test("settle leaves a scroll inside an oversized column untouched")
  func settleOversizedKeepsPosition() {
    // The column spans [1000, 2200] against a 1000pt viewport. Origins
    // from 1000 (leading edge flush) to 1200 (trailing edge flush) all
    // have it covering the whole band, so scrolling through its far side
    // has to survive the settle — this is what frame-in gets wrong, and
    // the reason for the extra case.
    for currentX in [CGFloat(1000), 1100, 1200] {
      #expect(
        target(mode: .settle, currentX: currentX, columnMinX: 1000, columnWidth: 1200) == nil,
        "settle moved an oversized column at currentX \(currentX)")
    }
    // Frame-in, by contrast, drags every one of those back to the leading edge.
    #expect(target(mode: .frameIn, currentX: 1100, columnMinX: 1000, columnWidth: 1200) == 994)
  }

  @Test("settle pulls an oversized column back once an edge comes into the band")
  func settleOversizedFlushesNearestEdge() {
    // Scrolled past the trailing edge: seat it there rather than dragging
    // all the way back to the column's start.
    #expect(target(mode: .settle, currentX: 1400, columnMinX: 1000, columnWidth: 1200) == 1200)
    // Scrolled before the leading edge: seat that edge instead.
    #expect(target(mode: .settle, currentX: 800, columnMinX: 1000, columnWidth: 1200) == 1000)
  }

  @Test("settle never moves further than the misalignment it was given")
  func settleStaysWithinTheSlack() {
    // The correction runs against the direction just scrolled, so the
    // caller only applies it while the gap is under
    // `scrollSettleSlack`. This is the arithmetic that lets it: settle
    // closes the gap and never overshoots into a scroll of its own.
    let slack = PaneContainerViewController.scrollSettleSlack
    for width in [CGFloat(400), 900, 1200, 2400] {
      for offset in stride(from: CGFloat(0), through: slack, by: 8) {
        // Start seated against the leading edge, then nudge by `offset`.
        let seated: CGFloat = 1000 - 6  // leadingEdgeX with the full gap
        let moved = target(
          mode: .settle, currentX: seated + offset, columnMinX: 1000, columnWidth: width)
        let distance = moved.map { abs($0 - (seated + offset)) } ?? 0
        #expect(
          distance <= slack,
          "settle moved \(distance) for width \(width) at offset \(offset)")
      }
    }
  }
}

/// `scrollFocusHandoff` decides which column owns focus once a
/// horizontal scroll stops. Half of the focused column has to remain on
/// screen for it to keep focus; below that it passes to the neighbour on
/// the side it was pushed from.
@Suite("PaneContainerViewController.scrollFocusHandoff")
struct ScrollFocusHandoffTests {
  /// Five 400pt columns laid out edge to edge from 0, viewed through a
  /// 1000pt viewport with no insets.
  private let columns: [(minX: CGFloat, width: CGFloat)] =
    (0..<5).map { (CGFloat($0) * 400, CGFloat(400)) }

  private func handoff(
    from index: Int,
    currentX: CGFloat,
    columns: [(minX: CGFloat, width: CGFloat)]? = nil,
    visibleWidth: CGFloat = 1000,
    insetLeft: CGFloat = 0,
    insetRight: CGFloat = 0
  ) -> Int? {
    PaneContainerViewController.scrollFocusHandoff(
      from: index, columns: columns ?? self.columns, currentX: currentX,
      visibleWidth: visibleWidth, insetLeft: insetLeft, insetRight: insetRight)
  }

  @Test("a fully visible column keeps focus")
  func fullyVisibleKeepsFocus() {
    #expect(handoff(from: 0, currentX: 0) == nil)
  }

  @Test("the settle corrects less than the hand-off tolerates")
  func settleSlackIsTheSmallerOfTheTwo() {
    // Both numbers are taste, but the order between them is the design:
    // it opens a band where a column pushed aside on purpose is left
    // where the user put it — too small to be worth tidying, too small
    // to move focus. Equal values close that band and every clip short
    // of a hand-off snaps back; a larger settle slack would pull back
    // scrolls that were on their way to handing off.
    #expect(
      PaneContainerViewController.scrollSettleSlack
        < PaneContainerViewController.focusHandoffSlack)
  }

  @Test("the threshold is the slack, not a share of the column")
  func thresholdIsTheSlack() {
    // The distance a column may be pushed has to be the same whatever
    // its width, because the scrollable range is `content - viewport`
    // and a fraction of a wide column easily exceeds it. Column 0 spans
    // [0, 400] and the slack is 48, so it holds focus up to origin 48
    // and lets go at 49 — the same two origins a 4000pt column would
    // have.
    let slack = PaneContainerViewController.focusHandoffSlack
    #expect(handoff(from: 0, currentX: slack) == nil)
    #expect(handoff(from: 0, currentX: slack + 1) == 1)
  }

  @Test("focus passes right when the holder is pushed off the leading edge")
  func handsOffRight() {
    #expect(handoff(from: 0, currentX: 201) == 1)
  }

  @Test("focus passes left when the holder is pushed off the trailing edge")
  func handsOffLeft() {
    // Column 4 spans [1600, 2000], so the band's trailing edge cuts into
    // it below origin 1000 and the slack is used up one point before
    // that. Derived from the constant rather than written out, so the
    // relationship survives a change to the number.
    let edge = 1000 - PaneContainerViewController.focusHandoffSlack
    #expect(handoff(from: 4, currentX: edge - 1) == 3)
    #expect(handoff(from: 4, currentX: edge + 1) == nil)
  }

  @Test("focus can move in a workspace whose whole scroll range is short")
  func worksWhenTravelIsShort() {
    // Two 600pt columns in a 1000pt viewport leave 208pt of travel in
    // total — less than half of either column, which is what made a
    // fractional threshold unreachable in the layouts people actually
    // keep open.
    let pair: [(minX: CGFloat, width: CGFloat)] = [(0, 600), (608, 600)]
    #expect(handoff(from: 0, currentX: 0, columns: pair) == nil)
    #expect(handoff(from: 0, currentX: 208, columns: pair) == 1)
  }

  @Test("a long scroll walks past every column it cleared")
  func walksMultipleColumns() {
    // Origin 1700 leaves columns 0-3 entirely or mostly behind, so focus
    // starting on column 0 has to end up on 4 rather than stopping at 1.
    #expect(handoff(from: 0, currentX: 1700) == 4)
  }

  @Test("focus stops at the first and last column")
  func clampsAtTheEnds() {
    #expect(handoff(from: 0, currentX: -400) == nil)
    #expect(handoff(from: 4, currentX: 4000) == nil)
  }

  @Test("a column wider than the viewport keeps focus while it covers the screen")
  func oversizedKeepsFocusWhileCovering() {
    // Reading "half of itself" literally, a 2400pt column in a 1000pt
    // viewport could never satisfy the threshold and would try to hand
    // focus off in both directions at once. Measured against what it can
    // show at most, it holds focus for as long as it fills the screen.
    let wide: [(minX: CGFloat, width: CGFloat)] = [(0, 400), (400, 2400), (2800, 400)]
    for currentX in [CGFloat(400), 1000, 1800] {
      #expect(
        handoff(from: 1, currentX: currentX, columns: wide) == nil,
        "an oversized column lost focus while covering the screen at \(currentX)")
    }
  }

  @Test("a column wider than the viewport gives focus up once it stops covering the screen")
  func oversizedHandsOffOnceMostlyGone() {
    let wide: [(minX: CGFloat, width: CGFloat)] = [(0, 400), (400, 2400), (2800, 400)]
    // The column ends at 2800; at origin 2400 only 400pt of the 1000pt
    // band is on it, so the column after it takes over.
    #expect(handoff(from: 1, currentX: 2400, columns: wide) == 2)
  }

  @Test("the threshold is measured against the post-inset band")
  func honoursInsets() {
    // A 200pt left inset shrinks the band to 800pt, so the band starts at
    // currentX + 200. Column 0 spans [0, 400]; at origin 1 the band opens
    // at 201 and only 199pt of the column is inside — below its 200pt
    // threshold, where the same origin with no inset would keep focus.
    #expect(handoff(from: 0, currentX: 1) == nil)
    #expect(handoff(from: 0, currentX: 1, insetLeft: 200) == 1)
  }
}
