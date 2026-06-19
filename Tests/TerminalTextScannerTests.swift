import Testing

@testable import E05Lib

/// `TerminalTextScanner` finds the URL / path / hash tokens the terminal
/// context menu (and later the hint overlay) act on. These pin the
/// detection rules and the column bookkeeping the right-click hit test
/// depends on, without needing a live ghostty surface.
@Suite("TerminalTextScanner")
struct TerminalTextScannerTests {
  @Test("a scheme URL is found with its column range")
  func urlWithRange() {
    let line = "see https://example.com/path now"
    let tokens = TerminalTextScanner.tokens(in: line)
    #expect(tokens.count == 1)
    let token = tokens[0]
    #expect(token.kind == .url)
    #expect(token.text == "https://example.com/path")
    #expect(token.start == 4)
    #expect(token.end == 4 + "https://example.com/path".count)
  }

  @Test("trailing sentence punctuation is dropped from a URL")
  func urlTrailingPunctuation() {
    #expect(
      TerminalTextScanner.tokens(in: "visit https://example.com.")[0].text == "https://example.com")
    #expect(
      TerminalTextScanner.tokens(in: "(https://example.com)")[0].text == "https://example.com")
  }

  @Test("a balanced paren inside a URL is kept")
  func urlBalancedParen() {
    let line = "https://en.wikipedia.org/wiki/Swift_(language)"
    #expect(TerminalTextScanner.tokens(in: line)[0].text == line)
  }

  @Test("mailto is treated as a URL")
  func mailto() {
    let tokens = TerminalTextScanner.tokens(in: "reach mailto:foo@bar.com please")
    #expect(tokens.count == 1)
    #expect(tokens[0].kind == .url)
    #expect(tokens[0].text == "mailto:foo@bar.com")
  }

  @Test("a URL does not also surface as a path")
  func urlNotPath() {
    let tokens = TerminalTextScanner.tokens(in: "open https://ex.com/a/b/c end")
    #expect(tokens.count == 1)
    #expect(tokens.allSatisfy { $0.kind == .url })
  }

  @Test("a hex run with a letter is a hash")
  func hash() {
    let tokens = TerminalTextScanner.tokens(in: "build a1b2c3d4 ok")
    #expect(tokens.count == 1)
    #expect(tokens[0].kind == .hash)
    #expect(tokens[0].text == "a1b2c3d4")
  }

  @Test("a plain decimal run is not a hash")
  func decimalNotHash() {
    #expect(TerminalTextScanner.tokens(in: "pid 1234567 here").isEmpty)
  }

  @Test("absolute and home paths are found")
  func paths() {
    #expect(TerminalTextScanner.tokens(in: "edit /usr/local/bin")[0].kind == .path)
    let home = TerminalTextScanner.tokens(in: "cat ~/.config/e05/config.ghostty")
    #expect(home.count == 1)
    #expect(home[0].kind == .path)
    #expect(home[0].text == "~/.config/e05/config.ghostty")
  }

  @Test("token(at:) returns the token covering a column and nil elsewhere")
  func tokenAtColumn() {
    let line = "x https://a.com y"
    #expect(TerminalTextScanner.token(at: 5, in: line)?.kind == .url)
    #expect(TerminalTextScanner.token(at: 0, in: line) == nil)
    #expect(TerminalTextScanner.token(at: 1, in: line) == nil)
    // The trailing space past the URL is not part of any token.
    #expect(TerminalTextScanner.token(at: line.count - 1, in: line) == nil)
  }

  @Test("token(at:) uses cell columns, not character offsets")
  func tokenAtColumnWithWideGlyphs() {
    // "あ " is 3 cells (2 + 1), so the URL starts at column 3, not 2.
    let line = "あ https://x.test"
    #expect(TerminalTextScanner.token(at: 3, in: line)?.kind == .url)
    #expect(TerminalTextScanner.token(at: 0, in: line) == nil)  // the wide glyph
    #expect(TerminalTextScanner.token(at: 1, in: line) == nil)  // its second cell
  }

  @Test("scan tags each token with its viewport row")
  func scanTagsRows() {
    let lines = ["nothing here", "go https://a.com", "/etc/hosts"]
    let scanned = TerminalTextScanner.scan(lines: lines)
    #expect(scanned.count == 2)
    #expect(scanned.contains { $0.row == 1 && $0.token.kind == .url })
    #expect(scanned.contains { $0.row == 2 && $0.token.kind == .path })
  }

  @Test("a clipped URL is expanded from the joined viewport")
  func expandClippedURL() {
    // A wrap joins onto one logical line; the clicked row held only a slice.
    let joined = "open https://example.test/very/long/path here\nnext line"
    let slice = "https://example.test/very"
    #expect(
      TerminalTextScanner.expandedText(of: slice, kind: .url, inJoined: joined)
        == "https://example.test/very/long/path")
  }

  @Test("expansion only matches the same kind")
  func expandKindGuard() {
    let joined = "/usr/local/share/data"
    // A path slice never resolves against a URL-kind lookup.
    #expect(
      TerminalTextScanner.expandedText(of: "/usr/local", kind: .url, inJoined: joined)
        == "/usr/local")
    #expect(
      TerminalTextScanner.expandedText(of: "/usr/local", kind: .path, inJoined: joined)
        == "/usr/local/share/data")
  }

  @Test("expansion returns the slice when no logical line contains it")
  func expandNoMatch() {
    let joined = "unrelated content only"
    #expect(
      TerminalTextScanner.expandedText(of: "https://gone.test", kind: .url, inJoined: joined)
        == "https://gone.test")
  }
}
