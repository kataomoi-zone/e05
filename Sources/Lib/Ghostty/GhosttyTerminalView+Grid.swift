import AppKit
import GhosttyKit

/// Shared grid geometry and selection-text reads over a terminal surface,
/// used by the right-click menu and the keyboard hint overlay. Cell metrics
/// come back in points (libghostty reports pixels; the view works in
/// points), and text comes through libghostty's selection-text API.
extension GhosttyTerminalView {
  /// libghostty grid size plus per-cell point metrics. nil when there's no
  /// surface / window or a degenerate (zero) grid.
  func gridMetrics() -> (size: ghostty_surface_size_s, cellWidth: CGFloat, cellHeight: CGFloat)? {
    guard let surface, let scale = window?.backingScaleFactor else { return nil }
    let size = ghostty_surface_size(surface)
    guard size.columns > 0, size.rows > 0, size.cell_width_px > 0, size.cell_height_px > 0
    else { return nil }
    return (size, CGFloat(size.cell_width_px) / scale, CGFloat(size.cell_height_px) / scale)
  }

  /// Grid cell under a window-space point, or nil when the click lands
  /// outside the addressable grid.
  func cell(
    at locationInWindow: NSPoint, size: ghostty_surface_size_s,
    cellWidth: CGFloat, cellHeight: CGFloat
  ) -> (column: Int, row: Int)? {
    let local = convert(locationInWindow, from: nil)
    let xFromLeft = Double(local.x)
    let yFromTop = Double(bounds.height - local.y)
    guard xFromLeft >= 0, yFromTop >= 0 else { return nil }
    let column = Int(xFromLeft / cellWidth)
    let row = Int(yFromTop / cellHeight)
    guard column < Int(size.columns), row < Int(size.rows) else { return nil }
    return (column, row)
  }

  /// Text of one viewport row. A single-row read can carry a trailing
  /// newline; drop it so column offsets stay aligned to the grid.
  func readRowText(row: Int, columns: Int) -> String? {
    guard
      let text = readText(
        topRow: row, topColumn: 0, bottomRow: row, bottomColumn: columns - 1)
    else { return nil }
    return text.hasSuffix("\n") ? String(text.dropLast()) : text
  }

  /// The whole viewport as one read, newlines intact so a soft-wrapped row
  /// stays joined onto one logical line and only hard breaks separate them.
  /// Lets a clipped token be recovered to its full text.
  func readViewportText(rows: Int, columns: Int) -> String? {
    readText(topRow: 0, topColumn: 0, bottomRow: rows - 1, bottomColumn: columns - 1)
  }

  /// Read a point range through libghostty's selection-text API. Returns
  /// "" for an empty range and nil on failure.
  func readText(topRow: Int, topColumn: Int, bottomRow: Int, bottomColumn: Int) -> String? {
    guard let surface, bottomColumn >= 0, bottomRow >= 0 else { return nil }
    let selection = ghostty_selection_s(
      top_left: ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
        x: UInt32(topColumn), y: UInt32(topRow)),
      bottom_right: ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
        x: UInt32(bottomColumn), y: UInt32(bottomRow)),
      rectangle: false)
    var out = ghostty_text_s()
    guard ghostty_surface_read_text(surface, selection, &out) else { return nil }
    defer { ghostty_surface_free_text(surface, &out) }
    guard let ptr = out.text, out.text_len > 0 else { return "" }
    return ptr.withMemoryRebound(to: UInt8.self, capacity: Int(out.text_len)) {
      String(decoding: UnsafeBufferPointer(start: $0, count: Int(out.text_len)), as: UTF8.self)
    }
  }
}
