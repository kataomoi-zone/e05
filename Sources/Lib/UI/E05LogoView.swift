import AppKit

/// The e05 logo without the app icon's plate: the colour ring and the
/// letters, drawn from the geometry and palette of the app icon itself
/// (`.github/assets/e05logo-*.svg`, whose ring layer the icon package
/// carries). The ring palette is the mark's own, not the workspace
/// accent palette that happens to open on the same four colours.
///
/// Drawn in code rather than shipped as an SVG because the letters follow
/// the appearance and the muted variant recolours the ring — an `NSImage`
/// loaded from SVG has no `currentColor` to hook either into.
@MainActor
final class E05LogoView: NSView {
  /// Draws the whole logo in faded letter ink: the ring drops its
  /// palette, each segment keeping its palette colour's luminance.
  var isMuted = false {
    didSet { needsDisplay = true }
  }

  /// The logo's 1024-unit canvas is cropped to the ring's outer edge
  /// (centre 512, radius 375 + half the 80-unit stroke).
  private static let cropOrigin: CGFloat = 97
  private static let cropSide: CGFloat = 830

  /// Arcs in degrees on the y-down canvas, clockwise from the bottom:
  /// three quarters, then three twelfths.
  private typealias Segment = (start: CGFloat, end: CGFloat, color: NSColor)
  private static let segments: [Segment] = [
    (90, 360, NSColor(srgbRed: 0.808, green: 0.020, blue: 0.357, alpha: 1)),
    (0, 30, NSColor(srgbRed: 0.690, green: 0.749, blue: 0.122, alpha: 1)),
    (30, 60, NSColor(srgbRed: 0.925, green: 0.431, blue: 0.396, alpha: 1)),
    (60, 90, NSColor(srgbRed: 0.008, green: 0.475, blue: 0.761, alpha: 1)),
  ]

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    // A display pass can land before Auto Layout has given the view its
    // size, and scaling by zero makes every stroke below a CG error.
    let side = min(bounds.width, bounds.height)
    guard side > 0 else { return }
    context.translateBy(x: bounds.midX - side / 2, y: bounds.midY - side / 2)
    context.scaleBy(x: side / Self.cropSide, y: side / Self.cropSide)
    context.translateBy(x: -Self.cropOrigin, y: -Self.cropOrigin)

    let ink = AppColors.logoInk
    // Muted strokes are opaque blends toward the pane surface both hosts
    // sit on, not alpha: overlapping translucent strokes would double up
    // where the arcs overlap below and where the E's bar meets its stem.
    func muted(_ strength: CGFloat) -> NSColor {
      ink.blended(withFraction: 1 - strength * 0.35, of: AppColors.paneSurface) ?? ink
    }

    for segment in Self.segments {
      let arc = NSBezierPath()
      // Each arc runs half a degree past both ends so neighbours overlap:
      // butt ends that merely touch leave an anti-aliased seam.
      arc.appendArc(
        withCenter: NSPoint(x: 512, y: 512), radius: 375,
        startAngle: segment.start - 0.5, endAngle: segment.end + 0.5, clockwise: false)
      arc.lineWidth = 80
      arc.lineCapStyle = .butt
      // Darker palette colours keep more ink, so the segments stay
      // distinguishable without their hues.
      let grey = segment.color.usingColorSpace(.genericGray)?.whiteComponent ?? 0
      (isMuted ? muted(1 - grey) : segment.color).setStroke()
      arc.stroke()
    }

    let letters = NSBezierPath()
    // E
    letters.move(to: NSPoint(x: 591.81, y: 227.51))
    letters.line(to: NSPoint(x: 449.87, y: 227.51))
    letters.line(to: NSPoint(x: 449.87, y: 447.51))
    letters.line(to: NSPoint(x: 599.88, y: 447.51))
    letters.move(to: NSPoint(x: 449.86, y: 337.51))
    letters.line(to: NSPoint(x: 589.88, y: 337.51))
    // 0
    letters.appendOval(in: NSRect(x: 397.75 - 95, y: 648.86 - 110, width: 190, height: 220))
    // 5
    letters.move(to: NSPoint(x: 699.77, y: 538.86))
    letters.line(to: NSPoint(x: 603.42, y: 538.86))
    letters.line(to: NSPoint(x: 581.97, y: 624.85))
    letters.curve(
      to: NSPoint(x: 721.24, y: 692.69),
      controlPoint1: NSPoint(x: 636.16, y: 624.85),
      controlPoint2: NSPoint(x: 720.68, y: 623.69))
    letters.curve(
      to: NSPoint(x: 563.15, y: 734.66),
      controlPoint1: NSPoint(x: 721.81, y: 764.21),
      controlPoint2: NSPoint(x: 620.08, y: 778.43))
    letters.lineWidth = 48
    letters.lineCapStyle = .square
    letters.lineJoinStyle = .miter
    letters.miterLimit = 2.2
    (isMuted ? muted(1) : ink).setStroke()
    letters.stroke()
  }
}
