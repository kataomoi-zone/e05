import Testing

@testable import E05Lib

/// `TerminalDisplayWidth` maps text to terminal cell columns the way
/// libghostty does, so hint badges and the right-click hit test land on the
/// right cell when a line mixes ASCII and wide glyphs.
@Suite("TerminalDisplayWidth")
struct TerminalDisplayWidthTests {
  @Test("ASCII is one cell each")
  func ascii() {
    #expect(TerminalDisplayWidth.width(of: "abc") == 3)
    #expect(TerminalDisplayWidth.width(of: "") == 0)
  }

  @Test("CJK and kana are two cells each")
  func wide() {
    #expect(TerminalDisplayWidth.width(of: "あ") == 2)
    #expect(TerminalDisplayWidth.width(of: "日本語") == 6)
    #expect(TerminalDisplayWidth.width(of: "Ａ") == 2)  // fullwidth A
  }

  @Test("mixed runs sum per glyph")
  func mixed() {
    #expect(TerminalDisplayWidth.width(of: "あa") == 3)
    #expect(TerminalDisplayWidth.width(of: "x日y") == 4)
  }

  @Test("combining marks add no width")
  func combining() {
    // "e" + combining acute is one grapheme, one cell.
    #expect(TerminalDisplayWidth.width(of: "e\u{0301}") == 1)
  }

  @Test("a zero-width joiner counts as nothing")
  func zeroWidth() {
    #expect(TerminalDisplayWidth.width(of: "\u{200D}") == 0)
  }

  @Test("transport and map emoji are two cells")
  func transportEmoji() {
    #expect(TerminalDisplayWidth.width(of: "🚀") == 2)  // U+1F680
    #expect(TerminalDisplayWidth.width(of: "🛒") == 2)  // U+1F6D2
  }
}
