import Foundation

/// A linkifiable token found in terminal screen text — a URL, a filesystem
/// path, or a hex hash (git SHA, checksum). libghostty only auto-detects
/// URLs, and only highlights them under a held modifier, so e05 scans the
/// rendered text itself to offer the same affordances from a right-click
/// menu (and, later, a keyboard hint overlay) for any of these kinds.
///
/// Columns are character offsets into the row string. For the monospace
/// ASCII that URLs / hashes / paths are made of this equals the grid
/// column; a row with wide (CJK) glyphs left of the match can shift the
/// mapping, an accepted v1 limitation since these tokens are ASCII.
public struct TerminalToken: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case url
    case path
    case hash
  }

  public let kind: Kind
  public let text: String
  /// First column of the token within its row, inclusive.
  public let start: Int
  /// One past the last column of the token within its row.
  public let end: Int
}

/// A token tagged with the viewport row it was found on. Produced by the
/// full-viewport scan that the hint overlay drives.
public struct TerminalRowToken: Equatable, Sendable {
  public let row: Int
  public let token: TerminalToken
}

/// Pure regex scanner over terminal text. Holds no surface state so it can
/// be unit-tested against plain strings.
public enum TerminalTextScanner {
  // A URL/path/mailto runs until a character that can't appear in one. The
  // class excludes whitespace, the angle/quote/brace/pipe/caret/bracket set
  // shells and markup wrap URLs in, and the backtick.
  private static let bodyClass = #"[^\s<>"'`{}|\\^\[\]]"#

  // `Regex` is not `Sendable`, so it can't live in a global `static let`
  // under strict concurrency. Compiling the set is cheap and a scan is a
  // one-shot user action, so build them per scan into a local value that is
  // never shared across actors.
  private struct Patterns {
    let url: Regex<AnyRegexOutput>
    let mailto: Regex<AnyRegexOutput>
    let hash: Regex<AnyRegexOutput>
    let path: Regex<AnyRegexOutput>

    init() {
      url = try! Regex(#"\b(?:https?|ftp|ftps|ssh|git|file)://"# + bodyClass + "+")
      mailto = try! Regex(#"\bmailto:"# + bodyClass + "+")
      // At least one a–f so plain decimal runs (timestamps, PIDs) aren't
      // taken for hashes. 7–64 covers an abbreviated git SHA up to SHA-256.
      hash = try! Regex(#"\b(?=[0-9a-fA-F]*[a-fA-F])[0-9a-fA-F]{7,64}\b"#)
      path = try! Regex(#"(?:~|\.\.?)?/[\w.\-+@%/~]+"#)
    }
  }

  // Trailing sentence punctuation rarely belongs to the token — a URL at
  // the end of a sentence picks up the period, a path inside prose the
  // comma. A closing paren is kept only when the token opened one.
  private static let trailingPunctuation: Set<Character> = [
    ".", ",", ";", ":", "!", "?", "'", "\"",
  ]

  /// Tokens on a single row, left to right, with overlaps resolved by
  /// precedence: URL (and mailto) beat hashes beat paths. A path regex
  /// matches the `/` runs inside a URL, so dropping overlaps keeps a URL
  /// from also surfacing as a bogus path.
  public static func tokens(in line: String) -> [TerminalToken] {
    tokens(in: line, patterns: Patterns())
  }

  /// The token covering grid `column` on the row, if any — the one a
  /// right-click at that cell should act on. Compares against each token's
  /// *cell* span (not its character offsets) so a wide (CJK) glyph earlier
  /// on the row doesn't shift the hit test.
  public static func token(at column: Int, in line: String) -> TerminalToken? {
    for token in tokens(in: line) {
      let startIndex = line.index(line.startIndex, offsetBy: token.start)
      let endIndex = line.index(line.startIndex, offsetBy: token.end)
      let cellStart = TerminalDisplayWidth.width(of: line[..<startIndex])
      let cellEnd = cellStart + TerminalDisplayWidth.width(of: line[startIndex..<endIndex])
      if cellStart <= column, column < cellEnd { return token }
    }
    return nil
  }

  /// Reunite a token clipped by a soft wrap with its full text. A token at
  /// a row's right edge (or column 0) may continue on the next visual row;
  /// libghostty's whole-viewport read joins soft-wrapped rows and separates
  /// only hard line breaks with a newline, so `joined` holds the token
  /// intact on one logical line. `slice` is the clipped text read from the
  /// clicked row — return the same-kind token on any logical line that
  /// contains it, else `slice` unchanged (no join available, or the read
  /// kept the wrap split). Whitespace-only slices never match.
  public static func expandedText(
    of slice: String, kind: TerminalToken.Kind, inJoined joined: String
  ) -> String {
    guard !slice.trimmingCharacters(in: .whitespaces).isEmpty else { return slice }
    let patterns = Patterns()
    for line in joined.split(separator: "\n", omittingEmptySubsequences: false) {
      let lineString = String(line)
      for token in tokens(in: lineString, patterns: patterns)
      where token.kind == kind && token.text.contains(slice) {
        return token.text
      }
    }
    return slice
  }

  /// Every token across a viewport's rows, for the hint overlay. Compiles
  /// the pattern set once and reuses it across rows.
  public static func scan(lines: [String]) -> [TerminalRowToken] {
    let patterns = Patterns()
    return lines.enumerated().flatMap { row, line in
      tokens(in: line, patterns: patterns).map { TerminalRowToken(row: row, token: $0) }
    }
  }

  private static func tokens(in line: String, patterns: Patterns) -> [TerminalToken] {
    var result: [TerminalToken] = []

    func add(_ regex: Regex<AnyRegexOutput>, kind: TerminalToken.Kind) {
      for match in line.matches(of: regex) {
        let start = line.distance(from: line.startIndex, to: match.range.lowerBound)
        let rawEnd = line.distance(from: line.startIndex, to: match.range.upperBound)
        let (text, end) = trimTrailing(String(line[match.range]), end: rawEnd)
        guard end > start else { continue }
        // Skip anything overlapping a higher-precedence token already taken.
        guard !result.contains(where: { start < $0.end && $0.start < end }) else { continue }
        result.append(TerminalToken(kind: kind, text: text, start: start, end: end))
      }
    }

    add(patterns.url, kind: .url)
    add(patterns.mailto, kind: .url)
    add(patterns.hash, kind: .hash)
    add(patterns.path, kind: .path)

    return result.sorted { $0.start < $1.start }
  }

  /// Strip trailing sentence punctuation, and a trailing `)` the token
  /// never opened, adjusting the end column to match.
  private static func trimTrailing(_ text: String, end: Int) -> (String, Int) {
    var text = text
    var end = end
    while let last = text.last {
      if trailingPunctuation.contains(last) {
        text.removeLast()
        end -= 1
      } else if last == ")", !text.contains("(") {
        text.removeLast()
        end -= 1
      } else {
        break
      }
    }
    return (text, end)
  }
}
