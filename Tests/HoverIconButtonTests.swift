import AppKit
import Testing

@testable import E05Lib

@Suite("HoverIconButton.sidebarIcon")
@MainActor
struct HoverIconButtonTests {
  /// Where the glyph's ink lands inside the button, rendered at
  /// `scale` device pixels per point: the offset of its centre from the
  /// button's centre, in points.
  private func inkOffset(of symbol: String, scale: Int) -> (dx: CGFloat, dy: CGFloat) {
    let button = HoverIconButton.sidebarIcon(symbol, description: symbol)
    button.contentTintColor = .black
    // In a window, so the factory's size constraints hold as they do
    // in a row.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 18, height: 18), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = window.contentView!
    host.addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      button.topAnchor.constraint(equalTo: host.topAnchor),
    ])
    host.layoutSubtreeIfNeeded()
    // The 18pt constraint sizes the button itself, not a text box inside it.
    #expect(
      button.frame.size == NSSize(width: 18, height: 18), "\(symbol) frame is \(button.frame)")
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 18 * scale, pixelsHigh: 18 * scale, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 18, height: 18)
    button.cacheDisplay(in: button.bounds, to: rep)
    let ink = HoverIconButton.inkBounds(in: rep)!
    return (ink.midX - 9, ink.midY - 9)
  }

  @Test(
    "the glyph sits on the button's centre, whatever its symbol's text alignment",
    arguments: ["xmark", "ellipsis", "folder", "link", "plus", "chevron.down"], [1, 2])
  func glyphIsCentered(symbol: String, scale: Int) {
    let offset = inkOffset(of: symbol, scale: scale)
    // Within one device pixel at 2x: the glyph's edge is anti-aliased,
    // so its centre is itself only known to about a quarter point.
    #expect(abs(offset.dx) <= 0.5, "\(symbol) at \(scale)x is \(offset.dx)pt off horizontally")
    #expect(abs(offset.dy) <= 0.5, "\(symbol) at \(scale)x is \(offset.dy)pt off vertically")
  }
}
