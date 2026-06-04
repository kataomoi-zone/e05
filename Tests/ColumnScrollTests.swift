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
}
