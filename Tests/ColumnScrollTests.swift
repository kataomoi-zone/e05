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
      .frameIn, .alignLeft, .alignRight, .center, .settle,
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

  @Test("settle seats against the post-inset band")
  func settleHonoursInsets() {
    // A 60pt sidebar and a 40pt trailing inset shrink the band to 900pt,
    // which seats the 400pt column at minX 1000 across origins
    // [trailing 446, leading 934]. Every `.settle` case above runs with
    // both insets at zero, where a swapped bound would still pass.
    func settle(_ currentX: CGFloat) -> CGFloat? {
      target(
        mode: .settle, currentX: currentX, columnMinX: 1000, columnWidth: 400,
        insetLeft: 60, insetRight: 40)
    }
    #expect(settle(700) == nil)
    #expect(settle(300) == 446)
    #expect(settle(1200) == 934)
  }

  @Test("settle never answers with the origin it was handed")
  func settleNeverReturnsANoOp() {
    // Non-nil is what tells the caller to scroll, so a target equal to
    // `currentX` queues a tween to where the view already is — and a
    // hover resting on a seated column would start one on every check.
    // The clamp is where one could come from, so this sweeps a column at
    // each end of the content as well as the middle.
    for insetLeft in [CGFloat(0), 60] {
      for insetRight in [CGFloat(0), 40] {
        for width in [CGFloat(200), 400, 900, 1200, 2400] {
          for columnMinX in [CGFloat(6), 1000, 3000 - 6 - width] {
            for currentX in stride(from: CGFloat(-100), through: 2100, by: 50) {
              guard
                let x = target(
                  mode: .settle, currentX: currentX, columnMinX: columnMinX,
                  columnWidth: width, insetLeft: insetLeft, insetRight: insetRight)
              else { continue }
              #expect(
                x != currentX,
                """
                settle returned its own input at currentX \(currentX), \
                minX \(columnMinX), width \(width), insets \(insetLeft)/\(insetRight)
                """)
            }
          }
        }
      }
    }
  }

  @Test("settling a settled scroll moves nothing")
  func settleIsIdempotent() {
    // Hover re-arms its check whenever the origin moves, so a settle
    // landing somewhere that would settle again gives the next check a
    // reason to scroll, and the one after that, without the pointer ever
    // moving.
    for width in [CGFloat(400), 900, 1200, 2400] {
      for currentX in stride(from: CGFloat(0), through: 2400, by: 120) {
        guard
          let once = target(
            mode: .settle, currentX: currentX, columnMinX: 1000, columnWidth: width)
        else { continue }
        #expect(
          target(mode: .settle, currentX: once, columnMinX: 1000, columnWidth: width) == nil,
          "settle moved again from \(once) for width \(width)")
      }
    }
  }
}

/// The band a column has to show more than half of itself in is the
/// scroll view minus its insets; these use a 1000pt band at x=0.
@Suite("PaneContainerViewController.visibleColumnIndices")
struct VisibleColumnIndicesTests {
  private let band = CGRect(x: 0, y: 0, width: 1000, height: 800)

  private func column(minX: CGFloat, width: CGFloat) -> CGRect {
    CGRect(x: minX, y: 0, width: width, height: 800)
  }

  @Test("a column fully inside the band counts")
  func fullyVisible() {
    let frames = [column(minX: 10, width: 400), column(minX: 420, width: 400)]
    #expect(PaneContainerViewController.visibleColumnIndices(frames: frames, band: band) == [0, 1])
  }

  /// The whole point of the majority rule: a two-column screen with a
  /// sliver of a third peeking in still tiles as two.
  @Test("a sliver at the trailing edge does not count")
  func sliverIsIgnored() {
    let frames = [
      column(minX: 0, width: 480), column(minX: 486, width: 480), column(minX: 972, width: 480),
    ]
    #expect(PaneContainerViewController.visibleColumnIndices(frames: frames, band: band) == [0, 1])
  }

  @Test("half in is not enough, more than half is")
  func majorityBoundary() {
    let halfOut = [column(minX: -200, width: 400)]
    #expect(PaneContainerViewController.visibleColumnIndices(frames: halfOut, band: band).isEmpty)
    let mostlyIn = [column(minX: -199, width: 400)]
    #expect(PaneContainerViewController.visibleColumnIndices(frames: mostlyIn, band: band) == [0])
  }

  /// Measured against the column, not the band, so a column too wide to
  /// fit still counts while most of it is showing — the tile then pulls it
  /// back down to the viewport. Past twice the band it can never show half
  /// of itself, and the gesture leaves it where it is.
  @Test("a column wider than the band counts while most of it is showing")
  func widerThanBand() {
    #expect(
      PaneContainerViewController.visibleColumnIndices(
        frames: [column(minX: 0, width: 1400)], band: band) == [0])
    #expect(
      PaneContainerViewController.visibleColumnIndices(
        frames: [column(minX: -100, width: 1400)], band: band) == [0])
    #expect(
      PaneContainerViewController.visibleColumnIndices(
        frames: [column(minX: 0, width: 2400)], band: band
      ).isEmpty)
  }

  /// The columns span the band's height by construction, so the rule is
  /// horizontal. A rect intersection would answer "not visible" for every
  /// column the moment that stopped holding — mid workspace-slide, or after
  /// any change to the height pin — and the tile would silently do nothing.
  @Test("the vertical axis has no say")
  func verticalIsIgnored() {
    let above = [CGRect(x: 100, y: 2000, width: 400, height: 800)]
    #expect(PaneContainerViewController.visibleColumnIndices(frames: above, band: band) == [0])
    let shorter = [CGRect(x: 100, y: 400, width: 400, height: 10)]
    #expect(PaneContainerViewController.visibleColumnIndices(frames: shorter, band: band) == [0])
  }

  @Test("a column entirely off screen counts for nothing")
  func offScreen() {
    let frames = [column(minX: -500, width: 400), column(minX: 1200, width: 400)]
    #expect(PaneContainerViewController.visibleColumnIndices(frames: frames, band: band).isEmpty)
  }
}

/// The numbers come from the worked example in `applyPreset`: a 1000pt
/// window with a 6pt perimeter leaves 988pt usable.
@Suite("PaneContainerViewController.tiledColumnWidth")
struct TiledColumnWidthTests {
  private func width(count: Int, fixed: [CGFloat] = [], usable: CGFloat = 988) -> CGFloat? {
    PaneContainerViewController.tiledColumnWidth(
      usableWidth: usable, gap: 6, columnCount: count, fixedWidths: fixed)
  }

  /// Same answer `applyPreset(.fraction(0.5))` writes, which is what makes
  /// a tiled pair line up with the width-cycle presets.
  @Test("two columns split the viewport the way the 50% preset does")
  func twoColumns() {
    // 6 + 491 + 6 + 491 + 6 = the 1000pt window.
    #expect(width(count: 2) == 491)
  }

  @Test("one column takes the whole usable width")
  func oneColumn() {
    #expect(width(count: 1) == 988)
  }

  @Test("three columns split what the two gaps leave")
  func threeColumns() {
    let share = width(count: 3) ?? 0
    let expected: CGFloat = 976.0 / 3.0
    #expect(abs(share - expected) < 0.0001)
  }

  /// A folded column is a 30pt strip whose width belongs to the fold, so
  /// it keeps it and the others divide the remainder.
  @Test("a folded column holds its width and the rest share the remainder")
  func foldedColumnHoldsItsWidth() {
    // 988 usable, less the folded 30 and the two 6pt gaps, halved.
    let expected: CGFloat = 473
    #expect(width(count: 3, fixed: [30]) == expected)
  }

  @Test("nothing to resize means no width to hand back")
  func nothingResizable() {
    #expect(width(count: 2, fixed: [30, 30]) == nil)
    #expect(width(count: 0) == nil)
  }

  /// A viewport with no room left answers nil rather than a negative
  /// width; the caller leaves the columns alone.
  @Test("a band too narrow for the count answers nil")
  func noRoom() {
    #expect(width(count: 4, usable: 18) == nil)
  }
}
