import Foundation

/// Terminal cell width of text, matching libghostty's East Asian Width
/// based metric closely enough to map a string offset to a grid column.
///
/// ghostty (via the `uucode` width table) counts a Wide / Fullwidth scalar
/// — CJK ideographs, kana, Hangul, fullwidth forms, most emoji, regional
/// indicators — as two cells, a combining or default-ignorable scalar
/// (ZWJ, variation selectors) as zero, and everything else (including East
/// Asian Ambiguous) as one. Swift exposes no East Asian Width property, so
/// the wide set is a range table; the zero / one split uses the scalar's
/// general category and default-ignorable flag.
///
/// Measured per grapheme cluster by its base scalar, so a base + combining
/// mark, or an emoji + skin-tone modifier, counts once. Exotic promotions
/// (a VS16 widening a default-narrow base) aren't tracked — rare in the
/// terminal text this positions hints over, and never in CJK runs, which is
/// the case that matters.
enum TerminalDisplayWidth {
  static func width(of text: some StringProtocol) -> Int {
    text.reduce(0) { $0 + width(ofGrapheme: $1) }
  }

  static func width(ofGrapheme character: Character) -> Int {
    guard let base = character.unicodeScalars.first else { return 0 }
    return width(of: base)
  }

  static func width(of scalar: Unicode.Scalar) -> Int {
    // Soft hyphen is default-ignorable but ghostty renders it one cell.
    if scalar.value == 0x00AD { return 1 }
    if scalar.properties.isDefaultIgnorableCodePoint { return 0 }
    switch scalar.properties.generalCategory {
    case .control, .surrogate, .lineSeparator, .paragraphSeparator,
      .nonspacingMark, .enclosingMark:
      return 0
    default:
      return isWide(scalar.value) ? 2 : 1
    }
  }

  private static func isWide(_ value: UInt32) -> Bool {
    wideRanges.contains { $0.contains(value) }
  }

  /// East Asian Wide + Fullwidth code-point ranges (the standard wcwidth
  /// wide set). Covers the CJK / kana / Hangul / fullwidth / emoji blocks
  /// that render two cells wide.
  private static let wideRanges: [ClosedRange<UInt32>] = [
    0x1100...0x115F,  // Hangul Jamo
    0x2329...0x232A,  // angle brackets
    0x2E80...0x303E,  // CJK Radicals … CJK Symbols and Punctuation
    0x3041...0x33FF,  // Hiragana … CJK Compatibility
    0x3400...0x4DBF,  // CJK Unified Ideographs Extension A
    0x4E00...0x9FFF,  // CJK Unified Ideographs
    0xA000...0xA4CF,  // Yi Syllables / Radicals
    0xA960...0xA97F,  // Hangul Jamo Extended-A
    0xAC00...0xD7A3,  // Hangul Syllables
    0xF900...0xFAFF,  // CJK Compatibility Ideographs
    0xFE10...0xFE19,  // Vertical Forms
    0xFE30...0xFE6F,  // CJK Compatibility Forms / Small Form Variants
    0xFF00...0xFF60,  // Fullwidth Forms
    0xFFE0...0xFFE6,  // Fullwidth signs
    0x1F1E6...0x1F1FF,  // Regional Indicators (flags)
    0x1F300...0x1F64F,  // Misc Symbols and Pictographs / Emoticons
    0x1F680...0x1F6FF,  // Transport and Map Symbols
    0x1F900...0x1F9FF,  // Supplemental Symbols and Pictographs
    0x1FA00...0x1FAFF,  // Symbols and Pictographs Extended-A
    0x20000...0x3FFFD,  // CJK Unified Ideographs Extension B and beyond
  ]
}
