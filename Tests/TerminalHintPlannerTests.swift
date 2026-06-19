import CoreGraphics
import Testing

@testable import E05Lib

/// `TerminalHintPlanner` turns the wrap-joined viewport into labeled,
/// positioned hints. These pin label assignment, the 26-label cap, the
/// row→rect geometry, and — the part that regressed — that a soft-wrapped
/// URL is one hint at its head, not a head plus a stray tail.
@Suite("TerminalHintPlanner")
struct TerminalHintPlannerTests {
  private func plan(_ joined: String, columns: Int = 80) -> [TerminalHint] {
    TerminalHintPlanner.plan(
      joined: joined, columns: columns, cellWidth: 10, cellHeight: 20, viewHeight: 200)
  }

  @Test("tokens get sequential labels top to bottom")
  func sequentialLabels() {
    let hints = plan("go https://a.test\nsee https://b.test\nand https://c.test")
    #expect(hints.map(\.label) == ["a", "b", "c"])
    #expect(hints.allSatisfy { $0.kind == .url })
  }

  @Test("the rect maps a token's row and column into view coords")
  func rectGeometry() {
    // Two logical lines; the URL on line 2 starts at column 4, row 1.
    let hints = plan("first line\nsee https://a.test")
    #expect(hints.count == 1)
    // viewHeight 200, cellHeight 20, row 1 → y = 200 - 2*20 = 160.
    #expect(hints[0].rect.minX == 40)
    #expect(hints[0].rect.minY == 160)
  }

  @Test("labels stop at 26 even with more tokens")
  func cappedAt26() {
    let joined = (0..<30).map { "x https://h\($0).test" }.joined(separator: "\n")
    let hints = plan(joined)
    #expect(hints.count == 26)
    #expect(hints.last?.label == "z")
  }

  @Test("a soft-wrapped URL is one hint at its head, not a tail too")
  func wrappedURLIsSingleHint() {
    // columns = 20: the URL overflows the first visual row and continues on
    // the next. Scanning the merged logical line keeps it whole, and the
    // path-like tail (/x) never surfaces as its own token.
    let hints = plan("right-click https://old.test/x", columns: 20)
    #expect(hints.count == 1)
    #expect(hints[0].kind == .url)
    #expect(hints[0].text == "https://old.test/x")
    // Head is at column 12 of the (single) logical line, still on row 0.
    #expect(hints[0].rect.minX == 120)
  }

  @Test("a token past the wrap maps onto a later visual row")
  func wrapAdvancesVisualRow() {
    // 25-char filler wraps to 2 visual rows at columns = 20, so the URL on
    // the next logical line lands on visual row 2.
    let filler = String(repeating: "x", count: 25)
    let hints = plan("\(filler)\nhttps://a.test", columns: 20)
    #expect(hints.count == 1)
    // row 2 → y = 200 - 3*20 = 140.
    #expect(hints[0].rect.minY == 140)
  }

  @Test("wide glyphs before a token shift its head column by cells")
  func widePrefixColumn() {
    // "あいう " is 3×2 + 1 = 7 cells, so the URL head sits at column 7.
    let hints = plan("あいう https://a.test")
    #expect(hints.count == 1)
    #expect(hints[0].rect.minX == 70)
    #expect(hints[0].text == "https://a.test")
  }

  @Test("nothing linkable yields no hints")
  func emptyWhenNoTokens() {
    #expect(plan("just some words\nno links here").isEmpty)
  }
}
