import Testing

@testable import E05Lib

/// `normalizedCommandText` cleans up the raw command/output text libghostty
/// returns: a themed prompt pads itself with blank lines that land in the
/// command region, and the selection has no trailing newline.
@Suite("normalizedCommandText")
struct TerminalCommandTextTests {
  @Test("leading blank lines are dropped")
  func leadingBlanks() {
    #expect(
      GhosttyTerminalView.normalizedCommandText("\n\n$ ls\nfile") == "$ ls\nfile\n")
  }

  @Test("a single trailing newline is guaranteed")
  func trailingNewline() {
    #expect(GhosttyTerminalView.normalizedCommandText("output") == "output\n")
    #expect(GhosttyTerminalView.normalizedCommandText("output\n\n") == "output\n")
  }

  @Test("whitespace-only lines count as blank")
  func whitespaceLines() {
    #expect(GhosttyTerminalView.normalizedCommandText("   \n$ pwd\n/tmp\n  ") == "$ pwd\n/tmp\n")
  }

  @Test("interior blank lines are kept")
  func interiorBlanks() {
    #expect(
      GhosttyTerminalView.normalizedCommandText("$ cmd\nline1\n\nline2")
        == "$ cmd\nline1\n\nline2\n")
  }

  @Test("all-blank input yields nil")
  func allBlank() {
    #expect(GhosttyTerminalView.normalizedCommandText("\n  \n\n") == nil)
  }
}
