import Foundation

/// Render a slice of the bookmarks tree as a Netscape Bookmark File
/// Format document — the de-facto exchange format every major
/// browser accepts on import. Output is UTF-8, includes the
/// preamble (DOCTYPE, META, TITLE, H1), and uses 4-space indentation
/// per nesting level so a human reading the export can follow the
/// structure.
public enum NetscapeBookmarksWriter {
  /// Build a document containing every entry under `parentId` (`nil`
  /// = the whole tree). The output is suitable for round-trip
  /// through `NetscapeBookmarksParser` and for import into any
  /// browser that reads the Netscape format.
  @MainActor
  public static func render(_ store: Bookmarks, underParent parentId: Int64? = nil) -> String {
    var output = preamble
    appendChildren(of: parentId, store: store, depth: 1, into: &output)
    output.append("</DL><p>\n")
    return output
  }

  /// Standard header. The DOCTYPE is the magic string every Netscape
  /// reader looks for, the META anchors the charset (browsers
  /// fall back to system locale without it, which mangles non-ASCII
  /// titles), and the leading `<DL><p>` opens the root list.
  private static let preamble = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>

    """

  @MainActor
  private static func appendChildren(
    of parentId: Int64?, store: Bookmarks, depth: Int, into output: inout String
  ) {
    let indent = String(repeating: "    ", count: depth)
    for entry in store.children(of: parentId) {
      if entry.isFolder {
        output.append(indent)
        output.append(
          "<DT><H3\(addDateAttribute(entry.createdAt))>\(escape(entry.title))</H3>\n")
        output.append(indent)
        output.append("<DL><p>\n")
        appendChildren(of: entry.id, store: store, depth: depth + 1, into: &output)
        output.append(indent)
        output.append("</DL><p>\n")
      } else if let url = entry.url {
        output.append(indent)
        output.append(
          "<DT><A HREF=\"\(escape(url))\"\(addDateAttribute(entry.createdAt))>"
            + "\(escape(entry.title))</A>\n")
      }
    }
  }

  /// Format the ADD_DATE attribute (or empty string when the date is
  /// unrepresentable, e.g. negative / non-finite). Seconds since
  /// epoch as a decimal integer — the canonical form every reader
  /// accepts.
  private static func addDateAttribute(_ date: Date) -> String {
    let secs = date.timeIntervalSince1970
    guard secs.isFinite, secs >= 0 else { return "" }
    return " ADD_DATE=\"\(Int64(secs))\""
  }

  /// Minimal HTML-attribute / text escape. The Netscape format
  /// expects only `&` / `<` / `>` / `"` to be escaped; bookmark
  /// readers are tolerant of unescaped single quotes inside
  /// double-quoted attribute values. Non-ASCII characters travel
  /// through unescaped under UTF-8.
  private static func escape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for scalar in s.unicodeScalars {
      switch scalar {
      case "&": out.append("&amp;")
      case "<": out.append("&lt;")
      case ">": out.append("&gt;")
      case "\"": out.append("&quot;")
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out
  }
}
