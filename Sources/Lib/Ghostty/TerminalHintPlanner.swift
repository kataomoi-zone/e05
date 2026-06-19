import CoreGraphics

/// A labeled, positioned link target for the keyboard hint overlay: a
/// letter to type, the full token text to act on, and the on-screen rect
/// of the matched text in the terminal view's (bottom-left origin) coords.
public struct TerminalHint: Equatable, Sendable {
  public let label: String
  public let text: String
  public let kind: TerminalToken.Kind
  public let rect: CGRect
}

/// Lays out hint labels over a viewport's tokens. Pure: the view supplies
/// the wrap-joined viewport text and the grid metrics, and gets back placed
/// hints — no surface access here, so it unit-tests directly.
public enum TerminalHintPlanner {
  /// Single-character labels in typing order. A viewport with more tokens
  /// than this leaves the overflow unlabeled (callers assume it won't
  /// happen in practice).
  static let labels = Array("abcdefghijklmnopqrstuvwxyz")

  /// One hint per token, scanned on the *logical* lines of `joined` (the
  /// whole-viewport read, where libghostty has merged soft-wrapped rows and
  /// split only hard breaks with a newline). Scanning the merged line means
  /// a wrapped URL is one token, not a head plus a stray `/x` tail that the
  /// path rule would otherwise pick up on the continuation row.
  ///
  /// A logical line of W display cells occupies `ceil(W / columns)` full
  /// visual rows, so a token's *cell* offset divides by `columns` back into
  /// the visual (row, column) where its head sits — that's where the badge
  /// goes. Cell offsets, not character offsets, so a wide (CJK) glyph left
  /// of a token shifts the mapping correctly. `cellWidth` / `cellHeight` are
  /// in points; `viewHeight` flips row indices into the bottom-left origin.
  public static func plan(
    joined: String, columns: Int,
    cellWidth: CGFloat, cellHeight: CGFloat, viewHeight: CGFloat
  ) -> [TerminalHint] {
    guard columns > 0 else { return [] }
    let lines = joined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // Scan every line through one compiled pattern set (`scan` reuses it
    // across lines), then group the tokens back by line for the row math —
    // calling the per-line `tokens(in:)` here would recompile the regexes
    // for every viewport row.
    var tokensByLine = [[TerminalToken]](repeating: [], count: lines.count)
    for rowToken in TerminalTextScanner.scan(lines: lines) {
      tokensByLine[rowToken.row].append(rowToken.token)
    }

    var hints: [TerminalHint] = []
    var visualRow = 0
    for (index, line) in lines.enumerated() {
      let lineWidth = TerminalDisplayWidth.width(of: line)
      defer { visualRow += max(1, (lineWidth + columns - 1) / columns) }
      guard hints.count < labels.count else { continue }
      for token in tokensByLine[index] {
        guard hints.count < labels.count else { break }
        let startIndex = line.index(line.startIndex, offsetBy: token.start)
        let endIndex = line.index(line.startIndex, offsetBy: token.end)
        let cellStart = TerminalDisplayWidth.width(of: line[..<startIndex])
        let cellEnd = cellStart + TerminalDisplayWidth.width(of: line[startIndex..<endIndex])
        let headRow = visualRow + cellStart / columns
        let headColumn = cellStart % columns
        // The badge sits at the head; width is the token's span on its first
        // visual row (it may wrap onto later rows).
        let firstRowEnd = min(cellEnd, (cellStart / columns + 1) * columns)
        let top = viewHeight - CGFloat(headRow) * cellHeight
        let rect = CGRect(
          x: CGFloat(headColumn) * cellWidth,
          y: top - cellHeight,
          width: CGFloat(firstRowEnd - cellStart) * cellWidth,
          height: cellHeight)
        hints.append(
          TerminalHint(
            label: String(labels[hints.count]), text: token.text, kind: token.kind, rect: rect))
      }
    }
    return hints
  }
}
