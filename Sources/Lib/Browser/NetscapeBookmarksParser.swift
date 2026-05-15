import Foundation
import os.log

private let logger = Logger(
  subsystem: "com.kawarimidoll.e05", category: "BookmarksImport")

/// Parsed entry from a Netscape Bookmark File Format document. The
/// format is loosely-HTML and de-facto-shared by Chrome, Firefox,
/// Safari, Brave, Edge, Vivaldi, and Arc.
public enum NetscapeBookmarkEntry {
  case folder(NetscapeBookmarkFolder)
  case bookmark(NetscapeBookmark)
}

public struct NetscapeBookmarkFolder {
  public var title: String
  /// `ADD_DATE` attribute value parsed as Unix epoch seconds, when
  /// present. Browsers historically use seconds; some emit
  /// milliseconds. The parser treats both: values that look like
  /// milliseconds are divided by 1000 to land in the right epoch.
  public var addDate: Date?
  public var children: [NetscapeBookmarkEntry]
}

public struct NetscapeBookmark {
  public var title: String
  public var url: String
  public var addDate: Date?
}

/// Recursive-descent parser for the Netscape Bookmark File Format.
///
/// The format is not well-formed HTML — exporters routinely omit the
/// closing `</DT>` and `</p>` tags — so this parser only looks at
/// the `<DL>` / `<DT>` / `<H3>` / `<A>` shape and tolerates anything
/// else. Folders nest through `<H3>` (folder header) followed by a
/// `<DL>` (folder contents); bookmarks live as `<A HREF="...">title</A>`
/// inside `<DT>` rows. Entities (`&amp;`, `&lt;`, `&gt;`, `&quot;`,
/// `&#39;`, numeric `&#NN;` / `&#xHH;`) are decoded in titles and
/// attribute values.
public enum NetscapeBookmarksParser {
  /// Hard cap on folder nesting. Real-world exports rarely exceed 5,
  /// so 16 leaves a generous margin for unusual organisations while
  /// keeping a malicious document from blowing the recursive-descent
  /// stack. Subtrees deeper than this are truncated (the outer levels
  /// stay intact).
  private static let maxDepth = 16

  public static func parse(_ html: String) -> [NetscapeBookmarkEntry] {
    var scanner = Scanner(input: html)
    scanner.skipUntilTag(named: "dl")
    guard scanner.consumeOpenTag(named: "dl") != nil else {
      logger.info("[bookmarks/parse] no <DL> found; treating as empty")
      return []
    }
    let entries = parseList(&scanner, depth: 1)
    logger.info(
      "[bookmarks/parse] top-level entries=\(entries.count, privacy: .public)")
    return entries
  }

  /// Parse the body of a `<DL>` list up to and including its
  /// matching `</DL>`. Returns the entries that belong directly to
  /// this list (nested folders' children are attached recursively).
  /// `depth` counts how many `<DL>` levels deep we are.
  private static func parseList(
    _ scanner: inout Scanner, depth: Int
  ) -> [NetscapeBookmarkEntry] {
    if depth > maxDepth {
      logger.error(
        "[bookmarks/parse] depth limit \(maxDepth, privacy: .public) hit; truncating subtree")
      scanner.skipUntilCloseTag(named: "dl")
      return []
    }
    var entries: [NetscapeBookmarkEntry] = []
    while !scanner.isAtEnd {
      scanner.skipWhitespaceAndIgnoredTags()
      if scanner.tryConsumeCloseTag(named: "dl") { return entries }
      if let next = scanner.peekTagName() {
        switch next {
        case "dt":
          scanner.consumeOpenTagAnyAttrs(named: "dt")
          scanner.skipWhitespaceAndIgnoredTags()
          if let entry = parseDTBody(&scanner, depth: depth) {
            entries.append(entry)
          }
        case "h3":
          // Recover from missing <DT> wrapper: some emitters drop
          // the `<DT>` before `<H3>` for top-level folders.
          if let folder = parseFolder(&scanner, depth: depth) {
            entries.append(.folder(folder))
          }
        case "a":
          // Same recovery for a stray top-level <A>.
          if let bookmark = parseBookmark(&scanner) {
            entries.append(.bookmark(bookmark))
          }
        default:
          // Unknown / uninteresting tag — skip its opening element
          // and continue. Closing tags are eaten in the loop above
          // (`tryConsumeCloseTag` handled `</dl>`; anything else
          // falls through to a no-op advance).
          scanner.advancePastOneTag()
        }
      } else {
        // No more tags — bail rather than spin on stray text.
        return entries
      }
    }
    return entries
  }

  /// Parse one `<DT>`'s contents: either an `<H3>` folder header
  /// (whose subsequent sibling `<DL>` carries the children) or an
  /// `<A>` bookmark.
  private static func parseDTBody(
    _ scanner: inout Scanner, depth: Int
  ) -> NetscapeBookmarkEntry? {
    switch scanner.peekTagName() {
    case "h3":
      return parseFolder(&scanner, depth: depth).map { .folder($0) }
    case "a":
      return parseBookmark(&scanner).map { .bookmark($0) }
    default:
      return nil
    }
  }

  private static func parseFolder(
    _ scanner: inout Scanner, depth: Int
  ) -> NetscapeBookmarkFolder? {
    guard let attrs = scanner.consumeOpenTag(named: "h3") else { return nil }
    let title = scanner.readTextUntilCloseTag(named: "h3")
    scanner.skipWhitespaceAndIgnoredTags()
    var children: [NetscapeBookmarkEntry] = []
    // The matching <DL> follows. Some emitters skip it for empty
    // folders, so the absence isn't an error — fall through with no
    // children. When present, recurse into the nested list.
    if scanner.consumeOpenTag(named: "dl") != nil {
      children = parseList(&scanner, depth: depth + 1)
    }
    return NetscapeBookmarkFolder(
      title: title, addDate: parseDate(attrs["add_date"]), children: children)
  }

  private static func parseBookmark(_ scanner: inout Scanner) -> NetscapeBookmark? {
    guard let attrs = scanner.consumeOpenTag(named: "a") else { return nil }
    // Always drain the body up to and including `</A>` so a bookmark
    // with a missing or empty `HREF` doesn't strand the scanner
    // mid-tag and stall the surrounding `<DL>` walk on the next
    // sibling.
    let title = scanner.readTextUntilCloseTag(named: "a")
    guard let href = attrs["href"], !href.isEmpty else { return nil }
    return NetscapeBookmark(
      title: title, url: href, addDate: parseDate(attrs["add_date"]))
  }

  /// Browsers emit `ADD_DATE` in seconds, but some (older Firefox
  /// builds, certain plugins) export milliseconds. Anything past
  /// year 3000 in seconds is treated as milliseconds and rescaled
  /// — both forms decode to a sensible recent timestamp.
  private static func parseDate(_ raw: String?) -> Date? {
    guard let raw, let value = Double(raw), value > 0 else { return nil }
    let secondsCap: Double = 32_503_680_000  // year 3000 in seconds
    let seconds = value > secondsCap ? value / 1000 : value
    return Date(timeIntervalSince1970: seconds)
  }
}

// MARK: - Scanner

/// Forward-only HTML-ish scanner. Operates on `String.UnicodeScalarView`
/// indices so multi-byte titles round-trip without surrogate splits.
private struct Scanner {
  let scalars: [Unicode.Scalar]
  var index: Int

  init(input: String) {
    self.scalars = Array(input.unicodeScalars)
    self.index = 0
  }

  var isAtEnd: Bool { index >= scalars.count }

  mutating func skipWhitespaceAndIgnoredTags() {
    while !isAtEnd {
      if scalars[index].isWhitespace {
        index += 1
        continue
      }
      // Tolerate stray `</p>` / `</dt>` between siblings — exporters
      // omit them on the way out and ignoring them on the way in
      // keeps the parser linear.
      if peekScalar() == "<",
        let name = peekTagName(at: index, closing: true),
        name == "p" || name == "dt"
      {
        advancePastOneTag()
        continue
      }
      break
    }
  }

  /// True when the scanner can consume an opening tag with the
  /// given (lower-cased) name without advancing.
  mutating func peekTagName() -> String? {
    peekTagName(at: index, closing: false)
  }

  private func peekTagName(at startIndex: Int, closing: Bool) -> String? {
    var i = startIndex
    guard i < scalars.count, scalars[i] == "<" else { return nil }
    i += 1
    if closing {
      guard i < scalars.count, scalars[i] == "/" else { return nil }
      i += 1
    } else {
      if i < scalars.count, scalars[i] == "/" { return nil }
    }
    let start = i
    while i < scalars.count, isNameChar(scalars[i]) {
      i += 1
    }
    guard i > start else { return nil }
    return String(String.UnicodeScalarView(scalars[start..<i])).lowercased()
  }

  /// Consume an opening tag with the given name and return its
  /// attributes (keys lower-cased, values entity-decoded). Returns
  /// `nil` when the next token isn't that tag.
  mutating func consumeOpenTag(named name: String) -> [String: String]? {
    let savedIndex = index
    guard peekTagName() == name else { return nil }
    // Step past `<name`.
    index += 1 + name.count
    let attrs = readAttributes()
    if !isAtEnd, scalars[index] == ">" {
      index += 1
      return attrs
    }
    index = savedIndex
    return nil
  }

  /// Consume an opening tag with the given name regardless of which
  /// attributes it carries. Used for the structural tags whose
  /// attributes we don't read (`<dt>`, `<p>`, …).
  mutating func consumeOpenTagAnyAttrs(named name: String) {
    _ = consumeOpenTag(named: name)
  }

  /// Consume `</name>` if the scanner is sitting at it. Returns
  /// whether the close tag was consumed.
  mutating func tryConsumeCloseTag(named name: String) -> Bool {
    guard peekTagName(at: index, closing: true) == name else { return false }
    advancePastOneTag()
    return true
  }

  /// Advance past whatever single tag (`<…>` or `</…>`) sits at the
  /// scanner head. Used to skip over tags the parser doesn't model
  /// without resolving their attribute lists or contents.
  mutating func advancePastOneTag() {
    guard !isAtEnd, scalars[index] == "<" else { return }
    while !isAtEnd, scalars[index] != ">" {
      index += 1
    }
    if !isAtEnd { index += 1 }
  }

  /// Skip everything up to (but not including) the next opening
  /// tag with `name`. Used to step past the preamble (`<META>`,
  /// `<TITLE>`, `<H1>`) before the first `<DL>`.
  mutating func skipUntilTag(named name: String) {
    while !isAtEnd {
      if scalars[index] == "<" {
        if peekTagName() == name { return }
        advancePastOneTag()
      } else {
        index += 1
      }
    }
  }

  /// Skip everything up to and including the next `</name>`. Used by
  /// the depth-limit guard to drop a too-deep subtree while keeping
  /// the surrounding `<DL>` walk aligned with the right closing tag.
  mutating func skipUntilCloseTag(named name: String) {
    while !isAtEnd {
      if scalars[index] == "<" {
        if peekTagName(at: index, closing: true) == name {
          advancePastOneTag()
          return
        }
        advancePastOneTag()
      } else {
        index += 1
      }
    }
  }

  /// Read text content up to (and consuming) the next `</name>`.
  /// Inner tags between the open and the close are stripped — title
  /// text can legally contain `<B>` / `<I>` / `<EM>` in exports from
  /// some browsers, and we only want the user-visible string.
  mutating func readTextUntilCloseTag(named name: String) -> String {
    var buffer: [Unicode.Scalar] = []
    while !isAtEnd {
      if scalars[index] == "<" {
        if peekTagName(at: index, closing: true) == name {
          advancePastOneTag()
          return decodeEntities(String(String.UnicodeScalarView(buffer))).trimmed
        }
        // Either an inline formatting tag (drop it) or some other
        // open tag (drop it too — we only care about the text).
        advancePastOneTag()
      } else {
        buffer.append(scalars[index])
        index += 1
      }
    }
    return decodeEntities(String(String.UnicodeScalarView(buffer))).trimmed
  }

  // MARK: Attribute parsing

  private mutating func readAttributes() -> [String: String] {
    var attrs: [String: String] = [:]
    while !isAtEnd {
      skipWhitespaceOnly()
      if isAtEnd { break }
      let s = scalars[index]
      if s == ">" || s == "/" { break }
      guard let name = readAttributeName() else { break }
      skipWhitespaceOnly()
      var value = ""
      if !isAtEnd, scalars[index] == "=" {
        index += 1
        skipWhitespaceOnly()
        value = readAttributeValue()
      }
      attrs[name.lowercased()] = decodeEntities(value)
    }
    // Self-closing slash: some HTML5-ish exporters add `/>` even on
    // legacy tags. Skip the slash so the caller's `>` check still
    // succeeds.
    if !isAtEnd, scalars[index] == "/" { index += 1 }
    return attrs
  }

  private mutating func readAttributeName() -> String? {
    let start = index
    while !isAtEnd, isNameChar(scalars[index]) {
      index += 1
    }
    guard index > start else { return nil }
    return String(String.UnicodeScalarView(scalars[start..<index]))
  }

  private mutating func readAttributeValue() -> String {
    guard !isAtEnd else { return "" }
    let quote = scalars[index]
    if quote == "\"" || quote == "'" {
      index += 1
      let start = index
      while !isAtEnd, scalars[index] != quote {
        index += 1
      }
      let end = index
      if !isAtEnd { index += 1 }
      return String(String.UnicodeScalarView(scalars[start..<end]))
    }
    // Unquoted attribute value: read up to whitespace or `>`.
    let start = index
    while !isAtEnd {
      let c = scalars[index]
      if c.isWhitespace || c == ">" || c == "/" { break }
      index += 1
    }
    return String(String.UnicodeScalarView(scalars[start..<index]))
  }

  private mutating func skipWhitespaceOnly() {
    while !isAtEnd, scalars[index].isWhitespace {
      index += 1
    }
  }

  private func peekScalar() -> Unicode.Scalar? {
    index < scalars.count ? scalars[index] : nil
  }

  private func isNameChar(_ s: Unicode.Scalar) -> Bool {
    if s.isASCII {
      let v = s.value
      return (v >= 0x30 && v <= 0x39)  // 0-9
        || (v >= 0x41 && v <= 0x5A)  // A-Z
        || (v >= 0x61 && v <= 0x7A)  // a-z
        || s == "_" || s == "-" || s == ":"
    }
    return false
  }
}

// MARK: - Entity decoding

private func decodeEntities(_ input: String) -> String {
  guard input.contains("&") else { return input }
  var result = ""
  result.reserveCapacity(input.count)
  var iter = input.unicodeScalars.makeIterator()
  while let scalar = iter.next() {
    if scalar != "&" {
      result.unicodeScalars.append(scalar)
      continue
    }
    // Read up to `;` or whitespace. Cap the lookahead so a bare `&`
    // in a title doesn't gobble half the document. 32 covers every
    // HTML5 named entity that fits the format's use cases (long
    // mathematical ops `CounterClockwiseContourIntegral` exceed
    // this, but they don't appear in bookmark titles in practice).
    var name = ""
    var inner = iter
    var found = false
    for _ in 0..<32 {
      guard let next = inner.next() else { break }
      if next == ";" {
        found = true
        break
      }
      if next.isWhitespace { break }
      name.unicodeScalars.append(next)
    }
    if found, let decoded = decodeEntity(name) {
      result.append(decoded)
      iter = inner
    } else {
      result.unicodeScalars.append(scalar)
    }
  }
  return result
}

private func decodeEntity(_ name: String) -> Character? {
  switch name {
  case "amp": return "&"
  case "lt": return "<"
  case "gt": return ">"
  case "quot": return "\""
  case "apos": return "'"
  case "nbsp": return "\u{00A0}"
  default:
    // Numeric: `#NNN` (decimal) or `#xHH` (hex).
    guard name.hasPrefix("#") else { return nil }
    let body = String(name.dropFirst())
    let value: UInt32?
    if body.hasPrefix("x") || body.hasPrefix("X") {
      value = UInt32(body.dropFirst(), radix: 16)
    } else {
      value = UInt32(body, radix: 10)
    }
    guard let value, let scalar = Unicode.Scalar(value) else { return nil }
    return Character(scalar)
  }
}

private extension Unicode.Scalar {
  var isWhitespace: Bool {
    self == " " || self == "\t" || self == "\n" || self == "\r"
  }
}

private extension String {
  var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
